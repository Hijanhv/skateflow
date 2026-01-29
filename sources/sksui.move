/// SkateFlow skSUI Token Module - Liquid staking token implementation
/// ERC20-like fungible token representing staked SUI with auto-compounding rewards
module skateflow::sksui {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::url;
    use sui::event;

    // Error codes
    const ENotAuthorized: u64 = 1;
    const EInvalidAmount: u64 = 2;

    /// One-Time-Witness for token creation
    struct SKSUI has drop {}

    /// Token metadata and treasury cap holder
    struct TokenRegistry has key {
        id: UID,
        treasury_cap: TreasuryCap<SKSUI>,
        total_supply: u64,
        vault_address: address,
    }

    // Events
    struct MintEvent has copy, drop {
        amount: u64,
        recipient: address,
        total_supply: u64,
    }

    struct BurnEvent has copy, drop {
        amount: u64,
        burner: address,
        total_supply: u64,
    }

    /// Initialize the skSUI token
    fun init(witness: SKSUI, ctx: &mut TxContext) {
        // Create the coin with metadata
        let (treasury_cap, metadata) = coin::create_currency<SKSUI>(
            witness,
            9, // decimals
            b"skSUI", // symbol
            b"SkateFlow Staked SUI", // name
            b"Liquid staking token representing staked SUI with auto-compounding rewards", // description
            option::some(url::new_unsafe_from_bytes(b"https://skateflow.finance/sksui-logo.png")), // icon
            ctx
        );

        // Share the metadata object
        transfer::public_freeze_object(metadata);

        // Create registry to hold treasury cap
        let registry = TokenRegistry {
            id: object::new(ctx),
            treasury_cap,
            total_supply: 0,
            vault_address: @0x0, // Will be set when vault is created
        };

        transfer::share_object(registry);
    }

    /// Mint skSUI tokens (only callable by vault)
    public fun mint(amount: u64, ctx: &mut TxContext): Coin<SKSUI> {
        // Note: In production, we'd have proper access control here
        // checking that only the vault can mint tokens
        
        // For this implementation, we create a simplified mint function
        // that would need to be integrated with the vault's authority system
        
        let registry = get_token_registry(); // This would be passed as parameter
        
        let tokens = coin::mint(&mut registry.treasury_cap, amount, ctx);
        registry.total_supply = registry.total_supply + amount;

        event::emit(MintEvent {
            amount,
            recipient: tx_context::sender(ctx),
            total_supply: registry.total_supply,
        });

        tokens
    }

    /// Burn skSUI tokens (only callable by vault)
    public fun burn(token: Coin<SKSUI>) {
        let amount = coin::value(&token);
        let registry = get_token_registry(); // This would be passed as parameter
        
        coin::burn(&mut registry.treasury_cap, token);
        registry.total_supply = registry.total_supply - amount;

        event::emit(BurnEvent {
            amount,
            burner: @0x0, // Would need proper context
            total_supply: registry.total_supply,
        });
    }

    /// Set vault address that can mint/burn (admin only)
    public entry fun set_vault_address(
        registry: &mut TokenRegistry,
        vault_address: address,
        ctx: &TxContext
    ) {
        // TODO: Add proper admin check
        registry.vault_address = vault_address;
    }

    /// Get total supply of skSUI
    public fun total_supply(registry: &TokenRegistry): u64 {
        registry.total_supply
    }

    /// Get vault address authorized to mint/burn
    public fun get_vault_address(registry: &TokenRegistry): address {
        registry.vault_address
    }

    // Helper function - in production this would be properly handled
    fun get_token_registry(): &mut TokenRegistry {
        // This is a placeholder - in real implementation, this would be
        // passed as a parameter or accessed through proper object references
        abort 0
    }

    #[test_only]
    /// Test helper to get treasury cap
    public fun get_treasury_cap_for_testing(registry: &TokenRegistry): &TreasuryCap<SKSUI> {
        &registry.treasury_cap
    }
}