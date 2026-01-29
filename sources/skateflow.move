/// SkateFlow Integration Module - Main entry point and integration logic
/// Coordinates interactions between vault, validators, and rebalancing
module skateflow::skateflow {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::Coin;
    use sui::sui::SUI;
    use sui::clock::Clock;
    use sui::event;
    use std::string;

    use skateflow::vault::{Self, Vault, VaultAdminCap};
    use skateflow::validator_registry::{Self, ValidatorRegistry, RegistryAdminCap};
    use skateflow::rebalance::{Self, RebalanceStrategy, RebalanceAdminCap};
    use skateflow::sksui::SKSUI;

    // Error codes
    const EProtocolNotInitialized: u64 = 1;
    const EInvalidConfiguration: u64 = 2;
    const EUnauthorized: u64 = 3;

    /// Main protocol state
    struct ProtocolState has key {
        id: UID,
        vault_id: address,
        registry_id: address,
        strategy_id: address,
        protocol_fee_bps: u64, // Protocol fees in basis points
        treasury: address,
        version: u64,
        paused: bool,
    }

    /// Protocol admin capability
    struct ProtocolAdminCap has key, store {
        id: UID,
    }

    // Events
    struct ProtocolInitializedEvent has copy, drop {
        vault_id: address,
        registry_id: address,
        strategy_id: address,
        admin: address,
    }

    struct ProtocolUpgradedEvent has copy, drop {
        old_version: u64,
        new_version: u64,
        upgrade_time: u64,
    }

    struct ProtocolFeesUpdatedEvent has copy, drop {
        old_fee_bps: u64,
        new_fee_bps: u64,
        treasury: address,
    }

    /// Initialize the complete SkateFlow protocol
    fun init(ctx: &mut TxContext) {
        let protocol_admin = ProtocolAdminCap {
            id: object::new(ctx),
        };

        let protocol_state = ProtocolState {
            id: object::new(ctx),
            vault_id: @0x0, // Will be set after vault creation
            registry_id: @0x0, // Will be set after registry creation
            strategy_id: @0x0, // Will be set after strategy creation
            protocol_fee_bps: 100, // 1% protocol fee
            treasury: tx_context::sender(ctx),
            version: 1,
            paused: false,
        };

        transfer::transfer(protocol_admin, tx_context::sender(ctx));
        transfer::share_object(protocol_state);

        event::emit(ProtocolInitializedEvent {
            vault_id: @0x0,
            registry_id: @0x0,
            strategy_id: @0x0,
            admin: tx_context::sender(ctx),
        });
    }

    /// Complete protocol setup after component initialization
    public entry fun setup_protocol(
        protocol_state: &mut ProtocolState,
        vault_id: address,
        registry_id: address,
        strategy_id: address,
        admin_cap: &ProtocolAdminCap
    ) {
        assert_protocol_admin(admin_cap);
        
        protocol_state.vault_id = vault_id;
        protocol_state.registry_id = registry_id;
        protocol_state.strategy_id = strategy_id;
    }

    /// Stake SUI and receive skSUI tokens (main user entry point)
    public entry fun stake(
        protocol_state: &ProtocolState,
        vault: &mut Vault,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!protocol_state.paused, EProtocolNotInitialized);
        
        // Delegate to vault deposit function
        vault::deposit(vault, payment, ctx);
    }

    /// Unstake skSUI and receive SUI (main user exit point)
    public entry fun unstake(
        protocol_state: &ProtocolState,
        vault: &mut Vault,
        sksui_token: Coin<SKSUI>,
        ctx: &mut TxContext
    ) {
        assert!(!protocol_state.paused, EProtocolNotInitialized);
        
        // Delegate to vault withdraw function
        vault::withdraw(vault, sksui_token, ctx);
    }

    /// Execute automatic rebalancing (can be called by anyone)
    public entry fun rebalance(
        protocol_state: &ProtocolState,
        vault: &mut Vault,
        registry: &mut ValidatorRegistry,
        strategy: &RebalanceStrategy,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!protocol_state.paused, EProtocolNotInitialized);
        
        // Execute rebalancing through rebalance module
        rebalance::execute_rebalance(strategy, vault, registry, clock, ctx);
    }

    /// Add validator to the system (admin only)
    public entry fun add_validator(
        protocol_state: &ProtocolState,
        registry: &mut ValidatorRegistry,
        validator_address: address,
        name: vector<u8>,
        commission_rate: u64,
        registry_admin_cap: &RegistryAdminCap,
        clock: &Clock,
        admin_cap: &ProtocolAdminCap,
        ctx: &mut TxContext
    ) {
        assert_protocol_admin(admin_cap);
        assert!(!protocol_state.paused, EProtocolNotInitialized);
        
        validator_registry::add_validator(
            registry,
            validator_address,
            name,
            commission_rate,
            registry_admin_cap,
            clock,
            ctx
        );
    }

    /// Update validator performance metrics (admin only)
    public entry fun update_validator_performance(
        protocol_state: &ProtocolState,
        registry: &mut ValidatorRegistry,
        validator_address: address,
        performance_score: u64,
        uptime_percentage: u64,
        registry_admin_cap: &RegistryAdminCap,
        admin_cap: &ProtocolAdminCap,
        clock: &Clock
    ) {
        assert_protocol_admin(admin_cap);
        
        validator_registry::update_validator_performance(
            registry,
            validator_address,
            performance_score,
            uptime_percentage,
            registry_admin_cap,
            clock
        );
    }

    /// Emergency pause protocol (admin only)
    public entry fun emergency_pause(
        protocol_state: &mut ProtocolState,
        vault: &mut Vault,
        vault_admin_cap: &VaultAdminCap,
        admin_cap: &ProtocolAdminCap
    ) {
        assert_protocol_admin(admin_cap);
        
        protocol_state.paused = true;
        vault::set_pause_status(vault, true, vault_admin_cap);
    }

    /// Unpause protocol (admin only)
    public entry fun unpause_protocol(
        protocol_state: &mut ProtocolState,
        vault: &mut Vault,
        vault_admin_cap: &VaultAdminCap,
        admin_cap: &ProtocolAdminCap
    ) {
        assert_protocol_admin(admin_cap);
        
        protocol_state.paused = false;
        vault::set_pause_status(vault, false, vault_admin_cap);
    }

    /// Update protocol fees (admin only)
    public entry fun update_protocol_fees(
        protocol_state: &mut ProtocolState,
        new_fee_bps: u64,
        new_treasury: address,
        admin_cap: &ProtocolAdminCap
    ) {
        assert_protocol_admin(admin_cap);
        
        let old_fee = protocol_state.protocol_fee_bps;
        protocol_state.protocol_fee_bps = new_fee_bps;
        protocol_state.treasury = new_treasury;

        event::emit(ProtocolFeesUpdatedEvent {
            old_fee_bps: old_fee,
            new_fee_bps,
            treasury: new_treasury,
        });
    }

    /// Upgrade protocol version (admin only)
    public entry fun upgrade_protocol(
        protocol_state: &mut ProtocolState,
        new_version: u64,
        admin_cap: &ProtocolAdminCap,
        clock: &Clock
    ) {
        assert_protocol_admin(admin_cap);
        
        let old_version = protocol_state.version;
        protocol_state.version = new_version;

        event::emit(ProtocolUpgradedEvent {
            old_version,
            new_version,
            upgrade_time: sui::clock::timestamp_ms(clock),
        });
    }

    /// Assert protocol admin authority
    fun assert_protocol_admin(admin_cap: &ProtocolAdminCap) {
        // In production, verify admin_cap belongs to protocol
    }

    // View functions

    /// Get protocol statistics
    public fun get_protocol_stats(
        protocol_state: &ProtocolState,
        vault: &Vault,
        registry: &ValidatorRegistry
    ): (u64, u64, u64, u64, bool) {
        let (total_validators, active_validators, max_validators) = 
            validator_registry::get_registry_stats(registry);
        let tvl = vault::get_tvl(vault);
        
        (
            tvl,
            total_validators,
            active_validators,
            protocol_state.protocol_fee_bps,
            protocol_state.paused
        )
    }

    /// Get protocol configuration
    public fun get_protocol_config(protocol_state: &ProtocolState): (u64, address, u64, bool) {
        (
            protocol_state.protocol_fee_bps,
            protocol_state.treasury,
            protocol_state.version,
            protocol_state.paused
        )
    }

    /// Get protocol component addresses
    public fun get_protocol_addresses(protocol_state: &ProtocolState): (address, address, address) {
        (
            protocol_state.vault_id,
            protocol_state.registry_id,
            protocol_state.strategy_id
        )
    }

    /// Calculate current APY based on rewards
    public fun get_current_apy(vault: &Vault): u64 {
        let (balance, supply, delegated, rewards) = vault::get_vault_stats(vault);
        let total_value = balance + delegated + rewards;
        
        if (delegated == 0) {
            return 0
        };
        
        // Simple APY calculation (rewards / delegated * 365 days)
        // This is a simplified calculation for demonstration
        (rewards * 365 * 100) / delegated
    }

    /// Check if rebalancing is recommended
    public fun should_rebalance_now(
        vault: &Vault,
        registry: &ValidatorRegistry,
        strategy: &RebalanceStrategy,
        clock: &Clock
    ): bool {
        rebalance::should_rebalance(vault, registry, strategy, clock)
    }

    /// Get exchange rate (SUI per skSUI)
    public fun get_exchange_rate(vault: &Vault): u64 {
        vault::get_exchange_rate(vault)
    }

    #[test_only]
    /// Test helper to create protocol state
    public fun create_protocol_for_testing(ctx: &mut TxContext): ProtocolState {
        ProtocolState {
            id: object::new(ctx),
            vault_id: @0x1,
            registry_id: @0x2,
            strategy_id: @0x3,
            protocol_fee_bps: 100,
            treasury: @0x4,
            version: 1,
            paused: false,
        }
    }
}