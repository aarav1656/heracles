# Heracles end-to-end test, Arbitrum Sepolia (421614)

## Deployment of 2026-09-28

Read live on Arbitrum Sepolia (421614), deployer
`0x39ef83fbB0BA61A5b4169fF5ce21Fd89e25aab37`. Machine record:
`contracts/deployments/421614.json`.

| Step | Command | Result |
|---|---|---|
| Deploy Treaty + Capacity | `forge script` broadcast | Treaty [`0xA5F3832DBa96e3f13a5B7a4C6179f2451681Ac27`](https://sepolia.arbiscan.io/address/0xA5F3832DBa96e3f13a5B7a4C6179f2451681Ac27), Capacity [`0x9f4dA127f5CA9Ad4b7F4e55BFF0909745DCF6159`](https://sepolia.arbiscan.io/address/0x9f4dA127f5CA9Ad4b7F4e55BFF0909745DCF6159) (created by the Treaty constructor), one deploy tx [`0x7eb7e54a...9369d46d61`](https://sepolia.arbiscan.io/tx/0x7eb7e54ab75b662a0025074f637dad40125960a1bca4abf0bcc0259369d46d61), block 313,869,456, status success |
| Deploy Stylus Pricer | `cargo stylus deploy` | [`0xbe99217180a5fcb83372375b0928c971dfa71f88`](https://sepolia.arbiscan.io/address/0xbe99217180a5fcb83372375b0928c971dfa71f88), deploy tx [`0x01a37192...b4ee945e7d`](https://sepolia.arbiscan.io/tx/0x01a37192c882dc7f856baf81bbee70679267b983723ca20e7b9460b4ee945e7d), block 313,689,917. 25,765 bytes compressed, deployed as two fragments behind a 48-byte root contract, constructed with table ids `[2]` (SPY) |
| Sourcify verification, Treaty | `forge verify-contract --verifier sourcify` | `exact_match` on creation and runtime, matchId 53809711, checked via `GET sourcify.dev/server/v2/contract/421614/0xA5F3832DBa96e3f13a5B7a4C6179f2451681Ac27` |
| Sourcify verification, Capacity | `forge verify-contract --verifier sourcify` | `exact_match` on creation and runtime, matchId 53809724, checked via `GET sourcify.dev/server/v2/contract/421614/0x9f4dA127f5CA9Ad4b7F4e55BFF0909745DCF6159` |
| Sourcify verification, Pricer (Stylus) | `cargo stylus verify` | not verified; Sourcify does not take Stylus/WASM bytecode, and the reproducible-build route needs a Docker daemon that was unavailable |
| Pricer market wiring | `cast call` `tableIdAt` | `tableIdAt(0)` returns `2` (SPY); `tableIdAt(1)` reverts `MissingTable` |
| Treaty wiring | `cast call` `pricer()`, `capacity()`, `usdg()`, `minRateOnLineBps()` | `pricer()` == the Stylus Pricer above, `capacity()` == the Capacity above, `usdg()` == `0xFFC95faa3d63Cde504a05B567C600B78C0b41892`, `minRateOnLineBps()` == 50 |
| Live quote | `cast call` `Pricer.quote`, long 2,000,000 USDG SPY, retention 20,000, limit 60,000 | at block 313,690,038, against live SPY/USD feed [`0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06`](https://sepolia.arbiscan.io/address/0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06), round id `18446744073709553978`: premium 1,676.722158 USDG, EL 1,051.190476 USDG, TVaR95 20,368 USDG |
| Gas comparison, Stylus vs Solidity twin | NodeInterface `gasEstimateComponents`, same call, block 313,704,736 | identical outputs; Solidity twin deployed only for this comparison at [`0x6aAf1b58939d55d1142a34aE02903bB788E9e771`](https://sepolia.arbiscan.io/address/0x6aAf1b58939d55d1142a34aE02903bB788E9e771) (`script/DeployPricerTwin.s.sol`). Stylus 584,865 total gas / 578,444 L2 execution; Solidity 4,639,494 total / 4,632,865 L2 execution. Stylus is 8.01x cheaper on L2 execution, 7.93x cheaper total, single-market call only; see `docs/pricing.md` under "Gas" |
| Full Foundry suite | `forge test` | 120 tests pass across 22 suites, 0 failed, 0 skipped |
| Deposit by permit | `Capacity.depositWithPermit` | not yet run on this deployment; the owner wallet holds 0 USDG, the Paxos testnet faucet has not delivered to it |
| Bind | `Treaty.bind` | not yet run on this deployment; `scripts/monday-bind.sh` points at the new addresses, its small bind layer quotes 890 base units, so the 50 bps floor (0.002 USDG) sets its premium, and the whole deposit plus bind needs under 1 USDG |

Runs against the previous deployment are in this file's git history.

## Full lifecycle on a fork of real Arbitrum One state, weekend of 2026-09-25/28

Loss-audit item 3: a Foundry fork test that binds, sets the Friday reference, fixes the Monday
price, settles and claims, entirely against a real Chainlink round history (not a MockFeed), so
the payout is provably the treaty's own settlement math applied to prices that actually printed.
Test: `contracts/test/GapTreaty.realweekend.fork.t.sol`.

Round data was read live off the Arbitrum One SPY/USD feed
(`0x46306F3795342117721D8DEd50fbcF6DF2b3cc10`) on 2026-09-29:

```
$ SPY=0x46306F3795342117721D8DEd50fbcF6DF2b3cc10; RPC=https://arb1.arbitrum.io/rpc
$ for agground in 358 359 360 361 362; do
    rid=$(python3 -c "print((2<<64) | $agground)")
    cast call $SPY "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)" $rid --rpc-url $RPC
  done
agground=358 answer=76874000000 updatedAt=1790337627 (Fri 2026-09-25 12:00:27 UTC, pre-close)
agground=359 answer=77134250000 updatedAt=1790424033 (Sat 2026-09-26 12:00:33 UTC) <- Friday reference
agground=360 answer=77134250000 updatedAt=1790510439 (Sun 2026-09-27 12:00:39 UTC)
agground=361 answer=77134250000 updatedAt=1790596846 (Mon 2026-09-28 12:00:46 UTC, pre-open)
agground=362 answer=76748000000 updatedAt=1790602546 (Mon 2026-09-28 13:35:46 UTC) <- Monday fix
```

Round 359 is the first round with `updatedAt >= fridayCloseOf` (Fri 20:00 UTC EDT close,
1,790,366,400) whose predecessor (358) is strictly earlier; round 362 is the first round with
`updatedAt >= expiry` (Mon 13:30 UTC EDT open, 1,790,602,200) whose predecessor (361) is strictly
earlier. Both match `Treaty.sol`'s `NotFirstRound` guard exactly. At the pinned fork block
(509,949,410, `cast block-number` on 2026-09-29) round 362 is also the feed's actual
`latestRoundData()`, so `_latestInPhase` accepts both rounds with no phase change involved.

Real gap: `(76748000000 - 77134250000) / 77134250000 = -0.50072%`. Test binds 2,000,000 USDG long
SPY exposure with a 5,000 USDG retention and a 60,000 USDG limit:

```
$ cd contracts && forge test --match-contract GapTreatyRealWeekendForkTest -vv
[PASS] test_realWeekend_bindReferenceFixAndClaim() (gas: 5115069)
Logs:
  real-weekend premium against live SPY vol (USDG, 6dp) 3907493904
[PASS] test_realWeekend_predecessorRoundsAreCorrectlyOrdered() (gas: 36614)
Suite result: ok. 2 passed; 0 failed; 0 skipped
```

`_settle`'s own `(exposure * (monday - friday)) / friday` formula produces a real loss of
10,015.006303 USDG; after the 5,000 USDG retention the layer settles a payout of 5,015.006303
USDG, `claim()` moves exactly that amount of the real forked USDG token to the buyer, and
`capacity.owed()` clears to 0. The test asserts the payout against this exact number, not a
tolerance band.

**Mutation proof (the check can fail):** temporarily replaced `_settle`'s
`int256 p = totalLoss - int256(L.retention);` with `int256 p = totalLoss;` (dropping the
retention deduction) in `contracts/src/Treaty.sol`, re-ran the same test:

```
[FAIL: payout must match _settle's real-price math: 10015006303 != 5015006303]
test_realWeekend_bindReferenceFixAndClaim()
```

Restored `Treaty.sol` from git (`git diff --stat contracts/src/Treaty.sol` empty afterwards),
re-ran: both tests green again (gas 5,115,069 / 36,614, matching the original run above).
