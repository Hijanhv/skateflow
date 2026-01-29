/// SkateFlow Validator Registry Module - Manages validator performance and selection
/// Tracks validator metrics, performance scores, and stake allocation weights
module skateflow::validator_registry {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::math;
    use std::vector;
    use std::string::{Self, String};

    // Error codes
    const EValidatorNotFound: u64 = 1;
    const EValidatorAlreadyExists: u64 = 2;
    const EInvalidPerformanceScore: u64 = 3;
    const EMaxValidatorsReached: u64 = 4;
    const EUnauthorized: u64 = 5;
    const EInvalidStakeWeight: u64 = 6;

    // Constants
    const MAX_VALIDATORS: u64 = 100;
    const MAX_PERFORMANCE_SCORE: u64 = 1000; // 0-1000 scale
    const MIN_UPTIME_THRESHOLD: u64 = 95; // 95% minimum uptime
    const MAX_STAKE_PER_VALIDATOR: u64 = 20; // 20% max stake per validator

    /// Validator information struct
    struct ValidatorInfo has store, copy, drop {
        address: address,
        name: String,
        performance_score: u64, // 0-1000 scale
        uptime_percentage: u64, // 0-100 scale
        stake_weight: u64, // Current stake allocation weight
        total_stake: u64, // Total SUI staked with this validator
        commission_rate: u64, // Commission rate in basis points (0-10000)
        active: bool,
        last_updated: u64, // Timestamp of last update
        epoch_added: u64, // Epoch when validator was added
    }

    /// Registry holding all validator information
    struct ValidatorRegistry has key {
        id: UID,
        validators: Table<address, ValidatorInfo>,
        active_validators: vector<address>,
        total_validators: u64,
        admin_cap: RegistryAdminCap,
        config: RegistryConfig,
    }

    /// Registry configuration
    struct RegistryConfig has store {
        max_validators: u64,
        min_uptime_threshold: u64,
        max_stake_per_validator: u64,
        performance_update_interval: u64, // epochs between updates
    }

    /// Admin capability for registry operations
    struct RegistryAdminCap has key, store {
        id: UID,
    }

    // Events
    struct ValidatorAddedEvent has copy, drop {
        validator_address: address,
        name: String,
        performance_score: u64,
        epoch: u64,
    }

    struct ValidatorRemovedEvent has copy, drop {
        validator_address: address,
        reason: String,
        epoch: u64,
    }

    struct ValidatorUpdatedEvent has copy, drop {
        validator_address: address,
        old_performance_score: u64,
        new_performance_score: u64,
        old_uptime: u64,
        new_uptime: u64,
    }

    struct StakeRebalancedEvent has copy, drop {
        validator_address: address,
        old_weight: u64,
        new_weight: u64,
        total_stake: u64,
    }

    /// Initialize the validator registry
    fun init(ctx: &mut TxContext) {
        let admin_cap = RegistryAdminCap {
            id: object::new(ctx),
        };

        let registry = ValidatorRegistry {
            id: object::new(ctx),
            validators: table::new(ctx),
            active_validators: vector::empty(),
            total_validators: 0,
            admin_cap,
            config: RegistryConfig {
                max_validators: MAX_VALIDATORS,
                min_uptime_threshold: MIN_UPTIME_THRESHOLD,
                max_stake_per_validator: MAX_STAKE_PER_VALIDATOR,
                performance_update_interval: 1,
            },
        };

        transfer::share_object(registry);
    }

    /// Add a new validator to the registry
    public entry fun add_validator(
        registry: &mut ValidatorRegistry,
        validator_address: address,
        name: vector<u8>,
        commission_rate: u64,
        admin_cap: &RegistryAdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert_admin_authority(registry, admin_cap);
        assert!(registry.total_validators < registry.config.max_validators, EMaxValidatorsReached);
        assert!(!table::contains(&registry.validators, validator_address), EValidatorAlreadyExists);

        let validator_info = ValidatorInfo {
            address: validator_address,
            name: string::utf8(name),
            performance_score: 500, // Start with medium score
            uptime_percentage: 100, // Start with 100% uptime
            stake_weight: 0, // No stake initially
            total_stake: 0,
            commission_rate,
            active: true,
            last_updated: clock::timestamp_ms(clock),
            epoch_added: tx_context::epoch(ctx),
        };

        table::add(&mut registry.validators, validator_address, validator_info);
        vector::push_back(&mut registry.active_validators, validator_address);
        registry.total_validators = registry.total_validators + 1;

        event::emit(ValidatorAddedEvent {
            validator_address,
            name: string::utf8(name),
            performance_score: 500,
            epoch: tx_context::epoch(ctx),
        });
    }

    /// Remove a validator from the registry
    public entry fun remove_validator(
        registry: &mut ValidatorRegistry,
        validator_address: address,
        reason: vector<u8>,
        admin_cap: &RegistryAdminCap,
        ctx: &mut TxContext
    ) {
        assert_admin_authority(registry, admin_cap);
        assert!(table::contains(&registry.validators, validator_address), EValidatorNotFound);

        let validator_info = table::remove(&mut registry.validators, validator_address);
        
        // Remove from active validators list
        let (found, index) = vector::index_of(&registry.active_validators, &validator_address);
        if (found) {
            vector::remove(&mut registry.active_validators, index);
        };

        registry.total_validators = registry.total_validators - 1;

        event::emit(ValidatorRemovedEvent {
            validator_address,
            reason: string::utf8(reason),
            epoch: tx_context::epoch(ctx),
        });
    }

    /// Update validator performance metrics
    public entry fun update_validator_performance(
        registry: &mut ValidatorRegistry,
        validator_address: address,
        performance_score: u64,
        uptime_percentage: u64,
        admin_cap: &RegistryAdminCap,
        clock: &Clock
    ) {
        assert_admin_authority(registry, admin_cap);
        assert!(table::contains(&registry.validators, validator_address), EValidatorNotFound);
        assert!(performance_score <= MAX_PERFORMANCE_SCORE, EInvalidPerformanceScore);

        let validator_info = table::borrow_mut(&mut registry.validators, validator_address);
        let old_performance = validator_info.performance_score;
        let old_uptime = validator_info.uptime_percentage;

        validator_info.performance_score = performance_score;
        validator_info.uptime_percentage = uptime_percentage;
        validator_info.last_updated = clock::timestamp_ms(clock);

        // Deactivate validator if uptime is below threshold
        if (uptime_percentage < registry.config.min_uptime_threshold) {
            validator_info.active = false;
            remove_from_active_list(registry, validator_address);
        } else if (!validator_info.active) {
            validator_info.active = true;
            vector::push_back(&mut registry.active_validators, validator_address);
        };

        event::emit(ValidatorUpdatedEvent {
            validator_address,
            old_performance_score: old_performance,
            new_performance_score: performance_score,
            old_uptime,
            new_uptime: uptime_percentage,
        });
    }

    /// Update validator stake allocation
    public entry fun update_stake_allocation(
        registry: &mut ValidatorRegistry,
        validator_address: address,
        new_stake_amount: u64,
        admin_cap: &RegistryAdminCap
    ) {
        assert_admin_authority(registry, admin_cap);
        assert!(table::contains(&registry.validators, validator_address), EValidatorNotFound);

        let validator_info = table::borrow_mut(&mut registry.validators, validator_address);
        let old_weight = validator_info.stake_weight;
        
        validator_info.total_stake = new_stake_amount;
        // Weight calculation would be done by rebalance module
        
        event::emit(StakeRebalancedEvent {
            validator_address,
            old_weight,
            new_weight: validator_info.stake_weight,
            total_stake: new_stake_amount,
        });
    }

    /// Get top performing validators for stake allocation
    public fun get_top_validators(registry: &ValidatorRegistry, count: u64): vector<address> {
        let mut top_validators = vector::empty<address>();
        let mut performance_scores = vector::empty<u64>();
        
        let mut i = 0;
        let active_count = vector::length(&registry.active_validators);
        
        while (i < active_count && vector::length(&top_validators) < count) {
            let validator_addr = *vector::borrow(&registry.active_validators, i);
            let validator_info = table::borrow(&registry.validators, validator_addr);
            
            if (validator_info.active) {
                insert_sorted(&mut top_validators, &mut performance_scores, 
                             validator_addr, validator_info.performance_score);
            };
            i = i + 1;
        };
        
        top_validators
    }

    /// Calculate optimal stake distribution based on performance
    public fun calculate_stake_distribution(
        registry: &ValidatorRegistry, 
        total_stake: u64
    ): vector<u64> {
        let active_count = vector::length(&registry.active_validators);
        let mut distribution = vector::empty<u64>();
        
        if (active_count == 0) {
            return distribution
        };

        let mut total_score = 0u64;
        let mut i = 0;
        
        // Calculate total performance score
        while (i < active_count) {
            let validator_addr = *vector::borrow(&registry.active_validators, i);
            let validator_info = table::borrow(&registry.validators, validator_addr);
            total_score = total_score + validator_info.performance_score;
            i = i + 1;
        };

        // Calculate proportional distribution
        i = 0;
        while (i < active_count) {
            let validator_addr = *vector::borrow(&registry.active_validators, i);
            let validator_info = table::borrow(&registry.validators, validator_addr);
            
            let allocation = if (total_score > 0) {
                (validator_info.performance_score * total_stake) / total_score
            } else {
                total_stake / active_count
            };
            
            // Cap allocation per validator
            let max_allocation = (total_stake * registry.config.max_stake_per_validator) / 100;
            let final_allocation = math::min(allocation, max_allocation);
            
            vector::push_back(&mut distribution, final_allocation);
            i = i + 1;
        };
        
        distribution
    }

    /// Insert validator in performance-sorted order
    fun insert_sorted(
        validators: &mut vector<address>,
        scores: &mut vector<u64>,
        validator: address,
        score: u64
    ) {
        let len = vector::length(validators);
        let mut insert_index = len;
        
        let mut i = 0;
        while (i < len) {
            if (score > *vector::borrow(scores, i)) {
                insert_index = i;
                break
            };
            i = i + 1;
        };
        
        vector::insert(validators, validator, insert_index);
        vector::insert(scores, score, insert_index);
    }

    /// Remove validator from active list
    fun remove_from_active_list(registry: &mut ValidatorRegistry, validator_address: address) {
        let (found, index) = vector::index_of(&registry.active_validators, &validator_address);
        if (found) {
            vector::remove(&mut registry.active_validators, index);
        };
    }

    /// Assert admin authority
    fun assert_admin_authority(registry: &ValidatorRegistry, admin_cap: &RegistryAdminCap) {
        // In production, verify admin_cap belongs to this registry
    }

    // View functions

    /// Get all active validators
    public fun get_active_validators(registry: &ValidatorRegistry): vector<address> {
        registry.active_validators
    }

    /// Get validator information
    public fun get_validator_info(
        registry: &ValidatorRegistry, 
        validator_address: address
    ): (String, u64, u64, u64, u64, bool) {
        assert!(table::contains(&registry.validators, validator_address), EValidatorNotFound);
        let validator_info = table::borrow(&registry.validators, validator_address);
        
        (
            validator_info.name,
            validator_info.performance_score,
            validator_info.uptime_percentage,
            validator_info.stake_weight,
            validator_info.total_stake,
            validator_info.active
        )
    }

    /// Get registry statistics
    public fun get_registry_stats(registry: &ValidatorRegistry): (u64, u64, u64) {
        let active_count = vector::length(&registry.active_validators);
        (registry.total_validators, active_count, registry.config.max_validators)
    }

    /// Check if validator is active
    public fun is_validator_active(registry: &ValidatorRegistry, validator_address: address): bool {
        if (!table::contains(&registry.validators, validator_address)) {
            return false
        };
        
        let validator_info = table::borrow(&registry.validators, validator_address);
        validator_info.active
    }

    #[test_only]
    /// Test helper to create registry
    public fun create_registry_for_testing(ctx: &mut TxContext): ValidatorRegistry {
        ValidatorRegistry {
            id: object::new(ctx),
            validators: table::new(ctx),
            active_validators: vector::empty(),
            total_validators: 0,
            admin_cap: RegistryAdminCap {
                id: object::new(ctx),
            },
            config: RegistryConfig {
                max_validators: MAX_VALIDATORS,
                min_uptime_threshold: MIN_UPTIME_THRESHOLD,
                max_stake_per_validator: MAX_STAKE_PER_VALIDATOR,
                performance_update_interval: 1,
            },
        }
    }
}