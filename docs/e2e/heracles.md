# Heracles end-to-end test, Arbitrum Sepolia (421614)

## Deployment of 2026-09-28

Read live on Arbitrum Sepolia (421614), deployer
`0x39ef83fbB0BA61A5b4169fF5ce21Fd89e25aab37`. Machine record:
`contracts/deployments/421614.json`.

| Step | Command | Result |
|---|---|---|
| Deploy Treaty + Capacity | `forge script` broadcast | Treaty [`0x222AFa24403d8118a66C5b2F0f26Aa0ea91Dd794`](https://sepolia.arbiscan.io/address/0x222AFa24403d8118a66C5b2F0f26Aa0ea91Dd794), Capacity [`0x29750a2018934f1Ca52d1F6940d89AAE8E34bd3D`](https://sepolia.arbiscan.io/address/0x29750a2018934f1Ca52d1F6940d89AAE8E34bd3D) (created by the Treaty constructor), one deploy tx [`0xa3583c8b...dba3eb423`](https://sepolia.arbiscan.io/tx/0xa3583c8b74f8fd3b0a5d51491893e14a2e3b888e5b4491eb115c4e2dba3eb423), block 313,708,353, status success |
| Deploy Stylus Pricer | `cargo stylus deploy` | [`0xbe99217180a5fcb83372375b0928c971dfa71f88`](https://sepolia.arbiscan.io/address/0xbe99217180a5fcb83372375b0928c971dfa71f88), deploy tx [`0x01a37192...b4ee945e7d`](https://sepolia.arbiscan.io/tx/0x01a37192c882dc7f856baf81bbee70679267b983723ca20e7b9460b4ee945e7d), block 313,689,917. 25,765 bytes compressed, deployed as two fragments behind a 48-byte root contract, constructed with table ids `[2]` (SPY) |
| Sourcify verification, Treaty | `forge verify-contract --verifier sourcify` | `exact_match` on creation and runtime, matchId 53784936, checked via `GET sourcify.dev/server/v2/contract/421614/0x222AFa24403d8118a66C5b2F0f26Aa0ea91Dd794` |
| Sourcify verification, Capacity | `forge verify-contract --verifier sourcify` | `exact_match` on creation and runtime, matchId 53784937, checked via `GET sourcify.dev/server/v2/contract/421614/0x29750a2018934f1Ca52d1F6940d89AAE8E34bd3D` |
| Sourcify verification, Pricer (Stylus) | `cargo stylus verify` | not verified; Sourcify does not take Stylus/WASM bytecode, and the reproducible-build route needs a Docker daemon that was unavailable |
| Pricer market wiring | `cast call` `tableIdAt` | `tableIdAt(0)` returns `2` (SPY); `tableIdAt(1)` reverts `MissingTable` |
| Treaty wiring | `cast call` `pricer()`, `capacity()`, `usdg()`, `minRateOnLineBps()` | `pricer()` == the Stylus Pricer above, `capacity()` == the Capacity above, `usdg()` == `0xFFC95faa3d63Cde504a05B567C600B78C0b41892`, `minRateOnLineBps()` == 50 |
| Live quote | `cast call` `Pricer.quote`, long 2,000,000 USDG SPY, retention 20,000, limit 60,000 | at block 313,690,038, against live SPY/USD feed [`0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06`](https://sepolia.arbiscan.io/address/0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06), round id `18446744073709553978`: premium 1,676.722158 USDG, EL 1,051.190476 USDG, TVaR95 20,368 USDG |
| Gas comparison, Stylus vs Solidity twin | NodeInterface `gasEstimateComponents`, same call, block 313,704,736 | identical outputs; Solidity twin deployed only for this comparison at [`0x6aAf1b58939d55d1142a34aE02903bB788E9e771`](https://sepolia.arbiscan.io/address/0x6aAf1b58939d55d1142a34aE02903bB788E9e771) (`script/DeployPricerTwin.s.sol`). Stylus 584,865 total gas / 578,444 L2 execution; Solidity 4,639,494 total / 4,632,865 L2 execution. Stylus is 8.01x cheaper on L2 execution, 7.93x cheaper total, single-market call only; see `docs/pricing.md` under "Gas" |
| Full Foundry suite | `forge test` | 120 tests pass across 22 suites, 0 failed, 0 skipped |
| Deposit by permit | `Capacity.depositWithPermit` | not yet run on this deployment; the owner wallet holds 0 USDG, the Paxos testnet faucet has not delivered to it |
| Bind | `Treaty.bind` | not yet run on this deployment; `scripts/monday-bind.sh` points at the new addresses, its small bind layer quotes 890 base units, so the 50 bps floor (0.002 USDG) sets its premium, and the whole deposit plus bind needs under 1 USDG |

Runs against the previous deployment are in this file's git history.
