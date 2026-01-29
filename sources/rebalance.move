/// SkateFlow Rebalance Module - Automated stake rebalancing across validators
/// Implements performance-based rebalancing logic to optimize staking yields
module skateflow::rebalance {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::math;
    use std::vector;
    use std::string::String;

    use skateflow::validator_registry::{Self, ValidatorRegistry};
    use skateflow::vault::{Self, Vault};

    // Error codes
    const ERebalanceNotNeeded: u64 = 1;
    const ERebalanceTooSoon: u64 = 2;
    const EInvalidThreshold: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EInvalidRebalanceAmount: u64 = 5;

    // Constants
    const REBALANCE_THRESHOLD_BPS: u64 = 500; // 5% threshold for rebalancing
    const MIN_REBALANCE_AMOUNT: u64 = 1_000_000_000; // 1 SUI minimum
    const REBALANCE_COOLDOWN_EPOCHS: u64 = 1; // Minimum epochs between rebalances
    const PERFORMANCE_WEIGHT: u64 = 70; // 70% weight for performance score
    const UPTIME_WEIGHT: u64 = 30; // 30% weight for uptime

    /// Rebalance strategy configuration
    struct RebalanceStrategy has key {
        id: UID,
        performance_threshold: u64, // Minimum performance score to receive stake
        uptime_threshold: u64, // Minimum uptime to receive stake
        max_deviation_bps: u64, // Maximum allowed deviation from target allocation
        rebalance_frequency: u64, // Epochs between automatic rebalances
        admin_cap: RebalanceAdminCap,
    }

    /// Admin capability for rebalance operations
    struct RebalanceAdminCap has key, store {
        id: UID,
    }

    /// Rebalance operation details
    struct RebalanceOperation has copy, drop, store {
        from_validator: address,
        to_validator: address,
        amount: u64,
        reason: String,
    }

    /// Validator allocation target
    struct AllocationTarget has copy, drop, store {
        validator: address,
        target_percentage: u64,
        current_percentage: u64,
        allocation_amount: u64,
    }

    // Events
    struct RebalanceExecutedEvent has copy, drop {
        epoch: u64,
        total_stake_rebalanced: u64,
        operations: vector<RebalanceOperation>,
        gas_cost: u64,
    }

    struct RebalanceStrategyUpdatedEvent has copy, drop {
        old_performance_threshold: u64,
        new_performance_threshold: u64,
        old_uptime_threshold: u64,
        new_uptime_threshold: u64,
    }

    struct ValidatorPenalizedEvent has copy, drop {
        validator: address,
        reason: String,
        stake_moved: u64,
        penalty_score: u64,
    }

    /// Initialize rebalance strategy
    fun init(ctx: &mut TxContext) {
        let admin_cap = RebalanceAdminCap {
            id: object::new(ctx),
        };

        let strategy = RebalanceStrategy {
            id: object::new(ctx),
            performance_threshold: 400, // Minimum 40% performance score
            uptime_threshold: 95, // Minimum 95% uptime
            max_deviation_bps: REBALANCE_THRESHOLD_BPS,
            rebalance_frequency: REBALANCE_COOLDOWN_EPOCHS,
            admin_cap,
        };

        transfer::share_object(strategy);
    }

    /// Execute automatic rebalancing based on validator performance
    public entry fun execute_rebalance(
        strategy: &RebalanceStrategy,
        vault: &mut Vault,
        registry: &mut ValidatorRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Check if rebalancing is needed
        assert!(should_rebalance(vault, registry, strategy, clock), ERebalanceNotNeeded);

        let total_stake = vault::get_tvl(vault);
        assert!(total_stake >= MIN_REBALANCE_AMOUNT, EInvalidRebalanceAmount);

        // Calculate optimal allocation
        let allocation_targets = calculate_optimal_allocation(registry, strategy, total_stake);
        
        // Execute rebalancing operations
        let operations = execute_rebalancing_operations(
            vault, 
            registry, 
            &allocation_targets, 
            ctx
        );

        let total_rebalanced = calculate_total_rebalanced(&operations);

        // Emit rebalance event
        event::emit(RebalanceExecutedEvent {
            epoch: tx_context::epoch(ctx),
            total_stake_rebalanced: total_rebalanced,
            operations,
            gas_cost: 0, // Would be calculated in real implementation
        });
    }

    /// Calculate optimal stake allocation based on validator performance
    public fun calculate_optimal_allocation(
        registry: &ValidatorRegistry,
        strategy: &RebalanceStrategy,
        total_stake: u64
    ): vector<AllocationTarget> {
        let active_validators = validator_registry::get_active_validators(registry);
        let validator_count = vector::length(&active_validators);
        let mut allocation_targets = vector::empty<AllocationTarget>();

        if (validator_count == 0) {
            return allocation_targets
        };

        // Calculate weighted scores for each validator
        let mut weighted_scores = vector::empty<u64>();
        let mut total_weighted_score = 0u64;

        let mut i = 0;
        while (i < validator_count) {
            let validator_addr = *vector::borrow(&active_validators, i);
            let (_, performance_score, uptime, _, current_stake, active) = 
                validator_registry::get_validator_info(registry, validator_addr);

            if (active && 
                performance_score >= strategy.performance_threshold && 
                uptime >= strategy.uptime_threshold) {
                
                let weighted_score = calculate_weighted_score(performance_score, uptime);
                vector::push_back(&mut weighted_scores, weighted_score);
                total_weighted_score = total_weighted_score + weighted_score;
            } else {
                vector::push_back(&mut weighted_scores, 0);
            };
            i = i + 1;
        };

        // Calculate target allocations
        i = 0;
        while (i < validator_count) {
            let validator_addr = *vector::borrow(&active_validators, i);
            let weighted_score = *vector::borrow(&weighted_scores, i);
            let (_, _, _, _, current_stake, _) = 
                validator_registry::get_validator_info(registry, validator_addr);

            let target_percentage = if (total_weighted_score > 0) {
                (weighted_score * 10000) / total_weighted_score // basis points
            } else {
                10000 / validator_count // equal distribution
            };

            let allocation_amount = (total_stake * target_percentage) / 10000;
            let current_percentage = if (total_stake > 0) {
                (current_stake * 10000) / total_stake
            } else {
                0
            };

            let target = AllocationTarget {
                validator: validator_addr,
                target_percentage,
                current_percentage,
                allocation_amount,
            };

            vector::push_back(&mut allocation_targets, target);
            i = i + 1;
        };

        allocation_targets
    }

    /// Check if rebalancing is needed
    public fun should_rebalance(
        vault: &Vault,
        registry: &ValidatorRegistry,
        strategy: &RebalanceStrategy,
        clock: &Clock
    ): bool {
        let (_, _, _, last_rebalance) = vault::get_vault_config(vault);
        let current_epoch = tx_context::epoch_from_clock(clock);
        
        // Check cooldown period
        if (current_epoch - last_rebalance < strategy.rebalance_frequency) {
            return false
        };

        // Check if any validator deviates significantly from optimal allocation
        let total_stake = vault::get_tvl(vault);
        let allocation_targets = calculate_optimal_allocation(registry, strategy, total_stake);
        
        let mut i = 0;
        let target_count = vector::length(&allocation_targets);
        
        while (i < target_count) {
            let target = vector::borrow(&allocation_targets, i);
            let deviation = abs_diff(target.target_percentage, target.current_percentage);
            
            if (deviation > strategy.max_deviation_bps) {
                return true
            };
            i = i + 1;
        };

        false
    }

    /// Execute rebalancing operations
    fun execute_rebalancing_operations(
        vault: &mut Vault,
        registry: &mut ValidatorRegistry,
        allocation_targets: &vector<AllocationTarget>,
        ctx: &mut TxContext
    ): vector<RebalanceOperation> {
        let mut operations = vector::empty<RebalanceOperation>();
        let target_count = vector::length(allocation_targets);

        // Identify validators that need stake reduction (over-allocated)
        let mut excess_stake = vector::empty<AllocationTarget>();
        // Identify validators that need stake increase (under-allocated)
        let mut deficit_stake = vector::empty<AllocationTarget>();

        let mut i = 0;
        while (i < target_count) {
            let target = vector::borrow(allocation_targets, i);
            
            if (target.current_percentage > target.target_percentage) {
                vector::push_back(&mut excess_stake, *target);
            } else if (target.current_percentage < target.target_percentage) {
                vector::push_back(&mut deficit_stake, *target);
            };
            i = i + 1;
        };

        // Match excess stake with deficit stake
        let mut excess_idx = 0;
        let mut deficit_idx = 0;
        
        while (excess_idx < vector::length(&excess_stake) && 
               deficit_idx < vector::length(&deficit_stake)) {
            
            let excess_target = vector::borrow(&excess_stake, excess_idx);
            let deficit_target = vector::borrow(&deficit_stake, deficit_idx);
            
            let excess_amount = if (excess_target.current_percentage > excess_target.target_percentage) {
                ((excess_target.current_percentage - excess_target.target_percentage) * 
                 vault::get_tvl(vault)) / 10000
            } else {
                0
            };
            
            let deficit_amount = if (deficit_target.target_percentage > deficit_target.current_percentage) {
                ((deficit_target.target_percentage - deficit_target.current_percentage) * 
                 vault::get_tvl(vault)) / 10000
            } else {
                0
            };
            
            let transfer_amount = math::min(excess_amount, deficit_amount);
            
            if (transfer_amount > 0) {
                let operation = RebalanceOperation {
                    from_validator: excess_target.validator,
                    to_validator: deficit_target.validator,
                    amount: transfer_amount,
                    reason: string::utf8(b"Performance-based rebalancing"),
                };
                
                vector::push_back(&mut operations, operation);
                
                // Update validator stake allocations
                validator_registry::update_stake_allocation(
                    registry, 
                    excess_target.validator, 
                    excess_target.allocation_amount - transfer_amount,
                    &registry_admin_cap // TODO: Proper authority handling
                );
                
                validator_registry::update_stake_allocation(
                    registry,
                    deficit_target.validator,
                    deficit_target.allocation_amount + transfer_amount,
                    &registry_admin_cap // TODO: Proper authority handling
                );
            };
            
            if (excess_amount <= deficit_amount) {
                excess_idx = excess_idx + 1;
            };
            if (deficit_amount <= excess_amount) {
                deficit_idx = deficit_idx + 1;
            };
        };

        operations
    }

    /// Penalize underperforming validator
    public entry fun penalize_validator(
        strategy: &RebalanceStrategy,
        vault: &mut Vault,
        registry: &mut ValidatorRegistry,
        validator: address,
        reason: vector<u8>,
        admin_cap: &RebalanceAdminCap,
        ctx: &mut TxContext
    ) {
        assert_admin_authority(strategy, admin_cap);
        
        let (_, performance_score, uptime, _, current_stake, active) = 
            validator_registry::get_validator_info(registry, validator);

        if (active) {
            // Calculate penalty based on performance shortfall
            let penalty_score = if (performance_score < strategy.performance_threshold) {
                strategy.performance_threshold - performance_score
            } else if (uptime < strategy.uptime_threshold) {
                strategy.uptime_threshold - uptime
            } else {
                0
            };

            // Move stake away from penalized validator
            if (penalty_score > 0 && current_stake > 0) {
                // Redistribute stake to top performers
                let top_validators = validator_registry::get_top_validators(registry, 3);
                let stake_to_move = (current_stake * penalty_score) / 100;
                
                if (vector::length(&top_validators) > 0) {
                    let per_validator_allocation = stake_to_move / vector::length(&top_validators);
                    
                    // Update allocations
                    validator_registry::update_stake_allocation(
                        registry,
                        validator,
                        current_stake - stake_to_move,
                        &registry_admin_cap // TODO: Proper authority handling
                    );

                    event::emit(ValidatorPenalizedEvent {
                        validator,
                        reason: string::utf8(reason),
                        stake_moved: stake_to_move,
                        penalty_score,
                    });
                };
            };
        };
    }

    /// Calculate weighted score based on performance and uptime
    fun calculate_weighted_score(performance_score: u64, uptime: u64): u64 {
        let performance_component = (performance_score * PERFORMANCE_WEIGHT) / 100;
        let uptime_component = (uptime * UPTIME_WEIGHT) / 100;
        performance_component + uptime_component
    }

    /// Calculate absolute difference between two values
    fun abs_diff(a: u64, b: u64): u64 {
        if (a >= b) {
            a - b
        } else {
            b - a
        }
    }

    /// Calculate total amount rebalanced
    fun calculate_total_rebalanced(operations: &vector<RebalanceOperation>): u64 {
        let mut total = 0u64;
        let mut i = 0;
        let len = vector::length(operations);
        
        while (i < len) {
            let operation = vector::borrow(operations, i);
            total = total + operation.amount;
            i = i + 1;
        };
        
        total
    }

    /// Update rebalance strategy parameters
    public entry fun update_strategy(
        strategy: &mut RebalanceStrategy,
        performance_threshold: u64,
        uptime_threshold: u64,
        max_deviation_bps: u64,
        rebalance_frequency: u64,
        admin_cap: &RebalanceAdminCap
    ) {
        assert_admin_authority(strategy, admin_cap);
        
        let old_performance = strategy.performance_threshold;
        let old_uptime = strategy.uptime_threshold;

        strategy.performance_threshold = performance_threshold;
        strategy.uptime_threshold = uptime_threshold;
        strategy.max_deviation_bps = max_deviation_bps;
        strategy.rebalance_frequency = rebalance_frequency;

        event::emit(RebalanceStrategyUpdatedEvent {
            old_performance_threshold: old_performance,
            new_performance_threshold: performance_threshold,
            old_uptime_threshold: old_uptime,
            new_uptime_threshold: uptime_threshold,
        });
    }

    /// Assert admin authority
    fun assert_admin_authority(strategy: &RebalanceStrategy, admin_cap: &RebalanceAdminCap) {
        // In production, verify admin_cap belongs to this strategy
    }

    // View functions

    /// Get rebalance strategy configuration
    public fun get_strategy_config(strategy: &RebalanceStrategy): (u64, u64, u64, u64) {
        (
            strategy.performance_threshold,
            strategy.uptime_threshold,
            strategy.max_deviation_bps,
            strategy.rebalance_frequency
        )
    }

    /// Preview rebalancing operations without executing
    public fun preview_rebalance(
        strategy: &RebalanceStrategy,
        vault: &Vault,
        registry: &ValidatorRegistry
    ): vector<AllocationTarget> {
        let total_stake = vault::get_tvl(vault);
        calculate_optimal_allocation(registry, strategy, total_stake)
    }

    /// Get next rebalance epoch
    public fun get_next_rebalance_epoch(
        strategy: &RebalanceStrategy,
        vault: &Vault
    ): u64 {
        let (_, _, _, last_rebalance) = vault::get_vault_config(vault);
        last_rebalance + strategy.rebalance_frequency
    }

    #[test_only]
    /// Test helper for epoch calculation
    fun tx_context::epoch_from_clock(clock: &Clock): u64 {
        // This would extract epoch from clock in real implementation
        1
    }

    #[test_only]
    /// Test helper for admin cap
    fun get_registry_admin_cap(): &ValidatorRegistryAdminCap {
        // This would return proper admin cap in real implementation
        abort 0
    }
}