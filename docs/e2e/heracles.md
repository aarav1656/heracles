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

Sections below record runs against the previous deployment.

Run date: 2026-09-26 (Saturday), contracts superseded 2026-09-27 (see redeploy section at the
end of this file). Contracts as tested this run: Treaty `0xEE1374852327Da76Fd04CA5f681C875E3e8e9cf4`,
Capacity `0x738992Fa482369D4f53811d12b1DDFdA63E94644`, Stylus Pricer
`0x0202D849Dc7CC7b643ff62Cf3E81130EA30D95da`, USDG `0xFFC95faa3d63Cde504a05B567C600B78C0b41892`.
Deployer/EOA under test: this product's own funded testnet account.

The Treaty's own calendar closes binding at Friday 19:30 UTC and does not reopen it until the
next ISO week begins (Monday 00:00 UTC); fixing opens separately at Monday 13:30 UTC. Today
(Saturday) sits inside the closed window on the live chain, which cannot be warped. Every
settlement-path feature (setReference, fix, settle, claim, cancel) is therefore proved on a
Foundry fork of live Sepolia state with `vm.warp`, labeled **fork** below, never on the real
chain today.

## Feature matrix

| Feature | Path | Method | Evidence | Result |
|---|---|---|---|---|
| Writer deposit | Capacity.deposit | live testnet | tx [0x2a15f427...b992ebe](https://sepolia.arbiscan.io/tx/0x2a15f4270a6e4b343e289db946e479a8bd52f8e5b00170c05ce644284b992ebe), block 312982676. Post-condition: `totalAssets()` 45.0->46.0 USDG, `balanceOf(deployer)` 45.0->46.0 shares | PASS |
| Writer withdraw (free capital) | Capacity.withdraw | live testnet | tx [0x55dcf0b0...4185dbd8](https://sepolia.arbiscan.io/tx/0x55dcf0b050793c5aace560b79b31617d125b426c9d77779fde34a96f4185dbd8), block 312982773. Post-condition: USDG balance 3.072->4.072, `totalAssets()` 46.0->45.0 | PASS |
| Free/locked/liabilities accounting | Capacity reads + web `/write` | live testnet | `cast call` and UI both show free 45.00, locked 0.00, owed unclaimed 0.00 at block #312,982,881 | PASS |
| Bind: zero exposure | Treaty.bind | live testnet | tx [0xa62082fd...a53d61b](https://sepolia.arbiscan.io/tx/0xa62082fd9050a8b184e3b667ee4a824174e5a1b05f7a656f63078af00a53d61b), block 312982852, status 0. Replay-decoded revert data `0x019af637` = `BadParams()` | PASS |
| Bind: zero limit | Treaty.bind | live testnet | tx [0x162136bd...29f9c8566](https://sepolia.arbiscan.io/tx/0x162136bde3112c2b29fb6b231af4ba938880a0759be7991681c084029f9c8566), block 312982863, status 0. Decoded `0x019af637` = `BadParams()` | PASS |
| Bind: after Friday cutoff | Treaty.bind | live testnet | tx [0xc4da80b2...a825aafaa8](https://sepolia.arbiscan.io/tx/0xc4da80b243fbcd5769c662f42a79e161bf21f4282c2d7cef987f93a825aafaa8), block 312982881, status 0. Decoded `0x276d5598` = `BadTiming()` | PASS |
| Bind: premium from Stylus pricer vs 0.5% floor | Bind.tsx live quote + Pricer.quote | live testnet | UI quote panel reads `minRateBps()==50` and the pricer's live premium each keystroke, taking the greater; verified by code path (`Bind.tsx:102-107`) since the take window is closed today | PASS (code-verified; live UI quote path is exercised only when the window is open) |
| setReference | Treaty.setReference | fork | `test_forkLifecycle_bindReferenceFixSettleAndClaim`, `GapTreatyFork.lifecycle.t.sol:109` | PASS (fork) |
| fix | Treaty.fix | fork | same test, line 113; asserts `State.Settled` | PASS (fork) |
| Payout clamp at limit | Treaty._settle | fork | same test, line 116-118: real loss 180,000 USDG clamped to the layer's 60,000 USDG limit | PASS (fork) |
| claim | Treaty.claim | fork | same test, line 120-124: buyer USDG balance delta == LIMIT, `capacity.locked()` 60,000->0 | PASS (fork) |
| claimTo | Treaty.claimTo | unit | `Treaty.t.sol` (part of the 15-test TreatyTest suite) | PASS (unit) |
| cancel on phase change (grace expiry) | Treaty.cancel | fork | `test_forkLifecycle_cancelAfterGraceRefundsPremium`, line 130-151: premium refunded to buyer, `locked()` -> 0 | PASS (fork) |
| Sequencer check disabled on testnet | Treaty constructor | live testnet | `sequencerUptimeFeed()` reads `0x0000...0000` live via `cast call`; fork test passes `address(0)` explicitly (line 53) matching the live deploy | PASS |
| Stylus pricer parity, 5 cases | Pricer.quote (Stylus) vs Pricer.sol (Solidity twin) | live testnet (Stylus side) vs unit (Solidity side) | 5/5 bit-for-bit identical: case1 (28974083332,4641666666,46344000000), case2 (37846626983,7237301587,57600000000), case3 (5039806547,2031845238,5000000000), case4 (62624255951,10699404761,98500000000), case5 (0,0,0) | PASS |
| Web `/` (Overview / book) | UI | live testnet | renders live pool state, block stamp; screenshot `docs/screenshots/heracles/overview.png` | PASS |
| Web `/bind`, closed-window message | UI | live testnet | screenshot `docs/screenshots/heracles/bind-closed-window.png`; message read live: "Cover for next week opens Monday 00:00 UTC, in 1d 07h ..." | PASS (bug fixed, see below) |
| Web `/write` | UI | live testnet | pool state free 45.00 / locked 0.00 / owed 0.00, read at block #312,982,191; screenshot `docs/screenshots/heracles/write.png` | PASS |
| Settlement panel | UI | live testnet | idle state correct (no live layer needs settling, none can exist until Monday); component code (`SettlePanel.tsx`) drives the same fork-proved `fix`/settle path once a layer exists | PASS (idle state only; active-layer rendering unproven live until Monday, proved instead by fork test) |
| Decoded errors in UI | `lib/revert.ts` explainError/explainReceipt | code-verified | `ERROR_WORDS` maps all 18 custom errors including `BadParams`/`BadTiming`/`SequencerDown`; `explainReceipt` replays a mined-reverted tx at its block and decodes via `decodeErrorResult` against the ABI, the exact mechanism used above to decode the 3 live reverts | PASS |
| Block numbers shown | UI | live testnet | `/write` shows "read at block #312,982,191"; `/bind` shows "quoted at block #..." | PASS |
| Mobile width (390px) | UI | live testnet | CDP `Emulation.setDeviceMetricsOverride(390,844)`; `/`, `/bind`, `/write` all `scrollWidth == clientWidth == 390`, no horizontal overflow; screenshot `docs/screenshots/heracles/bind-mobile-390.png` | PASS |
| Full Foundry suite | contracts | unit + fork | `forge test --summary`: **50 passed, 0 failed, 0 skipped** across 9 suites (AttackTest 5, AttackReviewTest 11, GapTreatyForkTest 3, GapTreatyForkLifecycleTest 2, PricerTest 6, PricerParityTest 1, SolvencyTest 1 incl. 256-run fuzz, TreatyTest 15, WeekWindowTest 6) | PASS |
| Full Rust pricer suite | pricer | unit | `cargo test --lib`: **5 passed, 0 failed** | PASS |

## Bugs found and fixed

1. **UI bug, `Bind.tsx` (fixed).** The closed-window message said cover reopens "Monday 13:30
   UTC" using `win.expiry - now` as the countdown. The contract's own `weekWindow` reopens
   binding at Monday **00:00 UTC** (13.5 hours earlier); Monday 13:30 UTC is the *fixing*
   expiry for the prior week's layers, not the bind reopen time. Fixed by adding a derived
   `reopensAt = win.cutoff + 2 days + 4.5 hours` and using it in the message and countdown.
   Re-verified live: message now reads "Cover for next week opens Monday 00:00 UTC, in 1d
   07h ...". This is the same imprecision present in the task brief itself ("binds reopen
   Monday 13:30 UTC"), which this fix corrects at the source.
2. **Build metadata bug, `web/package.json` (fixed).** `@fontsource/ibm-plex-serif` was listed
   twice under `dependencies`. Removed the duplicate key.
3. **Test-harness limitation (not a contract bug, documented).** revm cannot execute the
   deployed Stylus WASM program under `vm.createSelectFork` (`OpcodeNotFound`). The new fork
   lifecycle test deploys a fresh `Pricer.sol` (Solidity twin) instead; the 5-case parity
   table above independently proves that number equals what the live Stylus contract returns.
4. **New test file added:** `contracts/test/GapTreatyFork.lifecycle.t.sol`, forking live
   Sepolia state and warping into next week to prove the full bind -> setReference -> fix ->
   settle -> claim path and the cancel-after-grace path, which the live chain cannot exercise
   today. Caught a real bug during development (wrong exposure sign made the position profit
   instead of lose, payout asserted 0 when it should have been the clamped limit); fixed and
   both tests now pass, with the logged premium cross-validating against the README's
   independently-cited example for the same inputs.

## What stays unproven live until Monday

Everything gated by the Treaty's own calendar past the Friday cutoff cannot be exercised on
the real chain today, only on the fork above or the pre-existing unit suite: **live
setReference, live fix, live settle (including the payout clamp), live claim/claimTo, live
cancel-after-grace, and a live bind at a real non-floor premium** (today's bind attempts all
correctly revert `BadTiming`, so no live layer exists to settle). The settlement panel's
active-layer UI states are likewise unproven live for the same reason.

## 2026-09-27 redeploy (Capacity permit fix)

Resolution 4, commit 3f19b79: full suite 76 passed, 0
failed, 16 suites, testnet verdict DEPLOY. Treaty and Capacity redeployed against the same
live Paxos USDG, SPY feed and sequencer args as the run above; the Stylus Pricer is reused
unchanged (its bytecode and `quote()` output were re-confirmed live and are bit-for-bit
identical to the value already recorded). New addresses: Treaty
`0x889F1fA08DE3d280511432893A1D7e5DB66d3252`, Capacity `0xe645d83EA67ca1ECC7689f48Eb65eB2dE2e8933D`.
Deploy tx [`0xf31eb6b7...c90fcb37`](https://sepolia.arbiscan.io/tx/0xf31eb6b7b46fa224b3f73bd40d8f6b14e9967aa863abbff3b2a126b2c90fcb37),
block 313182718, status success.

Deployer USDG balance before this cycle: 2,072,032 base units (2.072032 USDG), read via
`balanceOf` at block 313172467.

| Step | Method | Evidence | Result |
|---|---|---|---|
| Deposit by permit | Capacity.depositWithPermit, EIP-2612 domain "Global Dollar" v"1" | tx [`0x748cc1db...c2e7078`](https://sepolia.arbiscan.io/tx/0x748cc1dbe9b5a6296d5fe29878822130808f70ee521baf0d57ae11912c2e7078), block 313183084, status success. Input selector `0x50921b23` matches `cast sig "depositWithPermit(uint256,address,uint256,uint8,bytes32,bytes32)"` exactly. Deposit 2,000,000 base units (2.0 USDG). Post-state: `totalAssets()` 0->2000000, `locked()` 0, `owed()` 0, `balanceOf(deployer)` 2,000,000 shares, deployer USDG 2,072,032->72,032 | PASS |
| Second-writer deposit by permit | Capacity.depositWithPermit, distinct wallet | documented wallet `contracts/testnet/.taker.env` (`TAKER_ADDRESS`) holds 0 ETH and 0 USDG at block 313172467, cannot pay gas or deposit | BLOCKED on funding, not on code |
| Bind one layer | Treaty.bind, exposure 1e6 / retention 1e12 / limit 1e6 (well inside the 2.0 USDG deposited capacity) | tx [`0x87b25006...d425f06`](https://sepolia.arbiscan.io/tx/0x87b25006ebd751fda0ef5f1107a22bd9e8b4e7fe53420314341b2dd70d425f06), block 313183289, mined, status reverted. Replayed at that block: revert data `0x276d5598` = `BadTiming()` (`cast sig "BadTiming()"` == `0x276d5598`) | PASS (gate enforced as designed; real chain time (Sunday) is already past this ISO week's Friday 19:30 UTC cutoff, and `weekWindow` does not roll forward mid-week; reopens Monday 2026-09-28 00:00 UTC against the following Friday 2026-10-02 19:30 UTC cutoff. No `vm.warp` exists on a live chain, so a live `Bound` event cannot be produced before that real time passes) |
| Sourcify verification, Treaty | `forge verify-contract --verifier sourcify` | matchId 53330627, `exact_match` (creation and runtime), verified 2026-09-27T06:51:35Z, confirmed live via `GET sourcify.dev/server/v2/contract/421614/0x889F1fA08DE3d280511432893A1D7e5DB66d3252` | PASS |
| Sourcify verification, Capacity | `forge verify-contract --verifier sourcify --creation-transaction-hash 0xf31eb6b7...` | matchId 53330691, `exact_match` (creation and runtime), verified 2026-09-27T06:51:53Z, confirmed live via `GET sourcify.dev/server/v2/contract/421614/0xe645d83EA67ca1ECC7689f48Eb65eB2dE2e8933D` | PASS |
| Sourcify verification, Pricer (Stylus) | `cargo stylus verify` | needs a running Docker daemon for its reproducible-build container; Docker was not running in this environment and did not come up within 200s after `open -a Docker` | BLOCKED on Docker; substituted live re-confirmation of bytecode (`codesize` 13333) and `quote()` output bit-for-bit identical to the recorded value |
| Web build against new addresses | `npm run sync-abi` then `npm run build` in `web` | see command output pasted in the commit report | PASS |

Remaining deployer USDG after this cycle: 72,032 base units (0.072032 USDG), reserved for a
future premium payment once bind succeeds after the Monday reopen (the floor premium for the
bound limit above, `limit * 50 / 1e4` = 5,000 base units = 0.005 USDG, fits comfortably inside
this remainder).

Blocked items carried forward from this cycle: (1) second-writer deposit blocked on funding of
the documented taker wallet; (2) a live `Bound` event blocked until real chain time reaches
Monday 2026-09-28 00:00 UTC; (3) Pricer Sourcify/Stylus verification blocked on an unavailable
Docker daemon in this sandbox.
