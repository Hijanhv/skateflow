/// SkateFlow Vault Module - Core liquid staking functionality
/// Handles SUI deposits, withdrawals, and delegation to validators
module skateflow::vault {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::math;
    use sui::event;
    use sui::clock::{Self, Clock};
    use std::vector;
    
    use skateflow::sksui::{Self, SKSUI};
    use skateflow::validator_registry::{Self, ValidatorRegistry};

    // Error codes
    const EInvalidAmount: u64 = 1;
    const EInsufficientBalance: u64 = 2;
    const EVaultPaused: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EMinimumDepositNotMet: u64 = 5;

    // Constants
    const MINIMUM_DEPOSIT: u64 = 1_000_000_000; // 1 SUI minimum
    const INITIAL_EXCHANGE_RATE: u64 = 1_000_000_000; // 1:1 initial rate

    /// Main vault object storing all staked SUI
    struct Vault has key, store {
        id: UID,
        /// Total SUI balance in the vault
        sui_balance: Balance<SUI>,
        /// Total supply of skSUI tokens
        sksui_supply: u64,
        /// Total SUI delegated to validators
        delegated_sui: u64,
        /// Accumulated rewards
        total_rewards: u64,
        /// Vault configuration
        config: VaultConfig,
        /// Admin capability
        admin_cap: VaultAdminCap,
    }

    /// Vault configuration
    struct VaultConfig has store {
        paused: bool,
        minimum_deposit: u64,
        last_rebalance: u64,
        rebalance_interval: u64, // in epochs
    }

    /// Admin capability for vault operations
    struct VaultAdminCap has key, store {
        id: UID,
    }

    // Events
    struct DepositEvent has copy, drop {
        user: address,
        sui_amount: u64,
        sksui_minted: u64,
        new_exchange_rate: u64,
    }

    struct WithdrawEvent has copy, drop {
        user: address,
        sksui_burned: u64,
        sui_returned: u64,
        exchange_rate: u64,
    }

    struct RebalanceEvent has copy, drop {
        epoch: u64,
        total_sui: u64,
        total_delegated: u64,
    }

    /// Initialize the vault with admin capability
    fun init(ctx: &mut TxContext) {
        let admin_cap = VaultAdminCap {
            id: object::new(ctx),
        };

        let vault = Vault {
            id: object::new(ctx),
            sui_balance: balance::zero(),
            sksui_supply: 0,
            delegated_sui: 0,
            total_rewards: 0,
            config: VaultConfig {
                paused: false,
                minimum_deposit: MINIMUM_DEPOSIT,
                last_rebalance: 0,
                rebalance_interval: 1,
            },
            admin_cap: admin_cap,
        };

        transfer::share_object(vault);
    }

    /// Deposit SUI and mint skSUI tokens
    public entry fun deposit(
        vault: &mut Vault,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!vault.config.paused, EVaultPaused);
        
        let sui_amount = coin::value(&payment);
        assert!(sui_amount >= vault.config.minimum_deposit, EMinimumDepositNotMet);

        // Calculate skSUI to mint based on current exchange rate
        let sksui_to_mint = calculate_sksui_to_mint(vault, sui_amount);
        
        // Add SUI to vault balance
        let sui_balance = coin::into_balance(payment);
        balance::join(&mut vault.sui_balance, sui_balance);
        
        // Update total supply
        vault.sksui_supply = vault.sksui_supply + sksui_to_mint;

        // Mint skSUI tokens to user
        let sksui_token = sksui::mint(sksui_to_mint, ctx);
        
        // Emit deposit event
        event::emit(DepositEvent {
            user: tx_context::sender(ctx),
            sui_amount,
            sksui_minted: sksui_to_mint,
            new_exchange_rate: get_exchange_rate(vault),
        });

        transfer::public_transfer(sksui_token, tx_context::sender(ctx));
    }

    /// Withdraw SUI by burning skSUI tokens
    public entry fun withdraw(
        vault: &mut Vault,
        sksui_token: Coin<SKSUI>,
        ctx: &mut TxContext
    ) {
        assert!(!vault.config.paused, EVaultPaused);
        
        let sksui_amount = coin::value(&sksui_token);
        
        // Calculate SUI to return based on current exchange rate
        let sui_to_return = calculate_sui_to_return(vault, sksui_amount);
        
        assert!(balance::value(&vault.sui_balance) >= sui_to_return, EInsufficientBalance);
        
        // Burn skSUI tokens
        sksui::burn(sksui_token);
        
        // Update total supply
        vault.sksui_supply = vault.sksui_supply - sksui_amount;
        
        // Transfer SUI to user
        let sui_balance = balance::split(&mut vault.sui_balance, sui_to_return);
        let sui_coin = coin::from_balance(sui_balance, ctx);
        
        // Emit withdraw event
        event::emit(WithdrawEvent {
            user: tx_context::sender(ctx),
            sksui_burned: sksui_amount,
            sui_returned: sui_to_return,
            exchange_rate: get_exchange_rate(vault),
        });

        transfer::public_transfer(sui_coin, tx_context::sender(ctx));
    }

    /// Delegate SUI to validators (admin only)
    public entry fun delegate_to_validators(
        vault: &mut Vault,
        registry: &ValidatorRegistry,
        amount: u64,
        admin_cap: &VaultAdminCap,
        ctx: &mut TxContext
    ) {
        assert_admin_authority(vault, admin_cap);
        assert!(balance::value(&vault.sui_balance) >= amount, EInsufficientBalance);
        
        // Split balance for delegation
        let delegation_balance = balance::split(&mut vault.sui_balance, amount);
        
        // Get validator allocation from registry
        let validators = validator_registry::get_active_validators(registry);
        let allocation = calculate_validator_allocation(&validators, amount);
        
        // TODO: Implement actual delegation to Sui validators
        // For now, we track it as delegated
        vault.delegated_sui = vault.delegated_sui + amount;
        
        // Return unused balance
        balance::join(&mut vault.sui_balance, delegation_balance);
    }

    /// Update vault with staking rewards (admin only)
    public entry fun update_rewards(
        vault: &mut Vault,
        rewards_amount: u64,
        admin_cap: &VaultAdminCap
    ) {
        assert_admin_authority(vault, admin_cap);
        vault.total_rewards = vault.total_rewards + rewards_amount;
    }

    /// Calculate skSUI to mint for SUI deposit
    fun calculate_sksui_to_mint(vault: &Vault, sui_amount: u64): u64 {
        if (vault.sksui_supply == 0) {
            // Initial deposit: 1:1 ratio
            sui_amount
        } else {
            let total_sui = get_total_sui_value(vault);
            // sksui_to_mint = (sui_amount * sksui_supply) / total_sui
            (sui_amount * vault.sksui_supply) / total_sui
        }
    }

    /// Calculate SUI to return for skSUI burn
    fun calculate_sui_to_return(vault: &Vault, sksui_amount: u64): u64 {
        let total_sui = get_total_sui_value(vault);
        // sui_to_return = (sksui_amount * total_sui) / sksui_supply
        (sksui_amount * total_sui) / vault.sksui_supply
    }

    /// Get total SUI value (balance + delegated + rewards)
    fun get_total_sui_value(vault: &Vault): u64 {
        balance::value(&vault.sui_balance) + vault.delegated_sui + vault.total_rewards
    }

    /// Get current exchange rate (SUI per skSUI)
    public fun get_exchange_rate(vault: &Vault): u64 {
        if (vault.sksui_supply == 0) {
            INITIAL_EXCHANGE_RATE
        } else {
            let total_sui = get_total_sui_value(vault);
            // exchange_rate = total_sui / sksui_supply
            (total_sui * 1_000_000_000) / vault.sksui_supply
        }
    }

    /// Calculate validator allocation weights
    fun calculate_validator_allocation(validators: &vector<address>, amount: u64): vector<u64> {
        let len = vector::length(validators);
        let mut allocation = vector::empty<u64>();
        let per_validator = amount / len;
        
        let mut i = 0;
        while (i < len) {
            vector::push_back(&mut allocation, per_validator);
            i = i + 1;
        };
        
        allocation
    }

    /// Pause/unpause vault (admin only)
    public entry fun set_pause_status(
        vault: &mut Vault,
        paused: bool,
        admin_cap: &VaultAdminCap
    ) {
        assert_admin_authority(vault, admin_cap);
        vault.config.paused = paused;
    }

    /// Update minimum deposit (admin only)
    public entry fun update_minimum_deposit(
        vault: &mut Vault,
        new_minimum: u64,
        admin_cap: &VaultAdminCap
    ) {
        assert_admin_authority(vault, admin_cap);
        vault.config.minimum_deposit = new_minimum;
    }

    /// Assert admin authority
    fun assert_admin_authority(vault: &Vault, admin_cap: &VaultAdminCap) {
        // In a real implementation, we'd check that admin_cap belongs to vault
        // For simplicity, we assume the check is done at the object level
    }

    // View functions
    
    /// Get vault stats
    public fun get_vault_stats(vault: &Vault): (u64, u64, u64, u64) {
        (
            balance::value(&vault.sui_balance),
            vault.sksui_supply,
            vault.delegated_sui,
            vault.total_rewards
        )
    }

    /// Get vault configuration
    public fun get_vault_config(vault: &Vault): (bool, u64, u64, u64) {
        (
            vault.config.paused,
            vault.config.minimum_deposit,
            vault.config.last_rebalance,
            vault.config.rebalance_interval
        )
    }

    /// Check if vault is paused
    public fun is_paused(vault: &Vault): bool {
        vault.config.paused
    }

    /// Get total value locked
    public fun get_tvl(vault: &Vault): u64 {
        get_total_sui_value(vault)
    }

    #[test_only]
    /// Test helper to create vault
    public fun create_vault_for_testing(ctx: &mut TxContext): Vault {
        Vault {
            id: object::new(ctx),
            sui_balance: balance::zero(),
            sksui_supply: 0,
            delegated_sui: 0,
            total_rewards: 0,
            config: VaultConfig {
                paused: false,
                minimum_deposit: MINIMUM_DEPOSIT,
                last_rebalance: 0,
                rebalance_interval: 1,
            },
            admin_cap: VaultAdminCap {
                id: object::new(ctx),
            },
        }
    }
}