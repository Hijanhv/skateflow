# SkateFlow - Advanced Liquid Staking Protocol on Sui

SkateFlow brings auto-rebalancing liquid staking to Sui — maximizing yield while keeping capital fully liquid across DeFi.

## 🚀 Features

- **Liquid Staking**: Stake SUI and receive skSUI tokens that remain fully liquid
- **Auto-Rebalancing**: Automated stake distribution based on validator performance
- **Maximum Yield**: Optimized validator selection for highest returns
- **DeFi Ready**: skSUI tokens are fully composable across Sui DeFi protocols
- **Performance Tracking**: Real-time validator monitoring and scoring
- **Emergency Controls**: Built-in safety mechanisms and admin controls

## 🏗️ Architecture

SkateFlow consists of five core modules:

### 1. Vault Module (`vault.move`)
- Core liquid staking functionality
- Handles SUI deposits and withdrawals
- Mints/burns skSUI tokens using share-based accounting
- Manages delegation to validators

### 2. skSUI Token Module (`sksui.move`)
- Liquid staking token implementation
- Auto-compounding rewards through exchange rate
- Fully fungible and DeFi-compatible

### 3. Validator Registry (`validator_registry.move`)
- Tracks validator performance metrics
- Maintains uptime and commission data
- Handles validator additions/removals

### 4. Rebalancing Engine (`rebalance.move`)
- Automated performance-based rebalancing
- Deterministic allocation algorithms
- Penalty mechanisms for underperformers

### 5. Protocol Integration (`skateflow.move`)
- Main user interface and coordination
- Admin controls and emergency functions
- Protocol-wide statistics and configuration

## 📊 Key Metrics Tracked

- **Performance Score**: 0-1000 scale based on rewards generated
- **Uptime Percentage**: Validator availability and reliability
- **Commission Rate**: Validator fees in basis points
- **Stake Weight**: Current allocation percentage
- **Total Value Locked (TVL)**: Protocol-wide SUI staked

## 🔧 Configuration

### Rebalancing Parameters
- **Performance Threshold**: Minimum score to receive stake (default: 400/1000)
- **Uptime Threshold**: Minimum uptime required (default: 95%)
- **Rebalancing Frequency**: Epochs between rebalancing (default: 1 epoch)
- **Max Deviation**: Trigger threshold for rebalancing (default: 5%)

### Security Controls
- **Minimum Deposit**: 1 SUI minimum stake
- **Emergency Pause**: Admin-controlled protocol halt
- **Max Validator Exposure**: 20% max stake per validator
- **Admin Capabilities**: Upgrade-ready governance structure

## 🛠️ Development

### Prerequisites
- Sui CLI installed
- Move language support
- Git for version control

### Building
```bash
sui move build
```

### Testing
```bash
sui move test
```

### Deployment
```bash
sui client publish --gas-budget 100000000
```

## 🔐 Security Features

- **Share-based Accounting**: Prevents inflation attacks
- **Performance Monitoring**: Continuous validator health checks
- **Emergency Controls**: Pause functionality for critical situations
- **Admin Separation**: Modular admin capabilities
- **Event Logging**: Comprehensive audit trail

## 📈 Economics

### Exchange Rate Calculation
```
Exchange Rate = (Total SUI + Delegated SUI + Rewards) / Total skSUI Supply
```

### Performance Scoring
```
Weighted Score = (Performance Score × 70%) + (Uptime × 30%)
```

### Stake Allocation
```
Validator Allocation = (Weighted Score / Total Score) × Available Stake
```

## 🌐 Integration

SkateFlow is designed for seamless integration with Sui DeFi protocols:

- **DEXs**: Trade skSUI across all major exchanges
- **Lending**: Use skSUI as collateral
- **Yield Farming**: Compound returns through DeFi strategies
- **Cross-chain**: Bridge skSUI to other networks

## 📋 Roadmap

### Phase 1 (Current)
- [x] Core liquid staking functionality
- [x] Auto-rebalancing engine
- [x] Validator registry and monitoring
- [x] Basic admin controls

### Phase 2 (Planned)
- [ ] Governance token and DAO
- [ ] Advanced strategy adapters
- [ ] Cross-chain integration
- [ ] Insurance mechanisms

### Phase 3 (Future)
- [ ] MEV protection
- [ ] Liquid staking derivatives
- [ ] Institutional features
- [ ] Analytics dashboard

## 🤝 Contributing

We welcome contributions from the community! Please see our contributing guidelines and code of conduct.

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## ⚠️ Disclaimer

This is experimental software. Users should understand the risks involved in DeFi protocols and liquid staking before participating. Always do your own research and consider the potential for smart contract bugs, validator slashing, and other risks.

## 📞 Contact

- Website: [skateflow.finance](https://skateflow.finance)
- Twitter: [@SkateFlowSui](https://twitter.com/SkateFlowSui)
- Discord: [Join our community](https://discord.gg/skateflow)
- Documentation: [docs.skateflow.finance](https://docs.skateflow.finance)

---

Built with ❤️ on Sui Network