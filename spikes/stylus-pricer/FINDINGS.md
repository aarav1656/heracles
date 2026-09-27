Claim: Pricing a weekend-gap cover on-chain from an empirical distribution of 504 weekend
gaps (mean payoff `max(K - S*(1+g), 0)` over 504 stored gaps, plus a Black-Scholes put term
with ln/exp/normal CDF in fixed point) costs at least 5x less gas as a Stylus (Rust) contract
than as the equivalent Solidity contract on Arbitrum.

Verdict: REFUTED, by a narrow margin. Both contracts are deployed and activated live on
Robinhood Chain testnet (46630, Stylus v3, ArbOS 116) with real testnet ETH, all 5 cases
produce bit-identical premiums read live on-chain, and the negative case reverts on both.
Stylus is real and consistently cheaper (about 4x on the standard total-gas measure every
wallet and block explorer uses), but not the >=5x the treaty's gate requires. A secondary
measure that strips the shared 21,000 intrinsic gas (present identically in every EVM tx,
arguably not part of "pricing algorithm cost") lands at 4.7x-5.0x across the 5 estimated cases
and touches 5.01x on the one case backed by a real transaction receipt rather than
`eth_estimateGas`. This is reported below, not used to flip the verdict: the treaty's claim is
naturally read as the call's total gas cost, which a user actually pays, and on that basis it
is under 5x in all 5 cases. This supersedes the prior UNTESTED run below, which was blocked by
no docker and no funded testnet key; both are now resolved.

## What changed since the last run

New fact: Robinhood Chain testnet (chain 46630, `https://rpc.testnet.chain.robinhood.com`) has
Stylus active (`ArbWasm.stylusVersion()` = 3, confirmed live) and the deployer's
funded testnet EOA held 0.0089 testnet ETH. That closed both gaps
(no docker, no funded key) the prior run flagged.

## Deployment (live, real transactions, Robinhood Chain testnet 46630)

- Solidity `Pricer`: `forge create --broadcast` -> deployed at
  `0x3e84597107f22743826745602eB73DFBeD6aA117`,
  tx `0x6e94bac3bae072e7fb20a446e28f755c3a4ab211eedbb83022a40b586ffc166c`
  (https://explorer.testnet.chain.robinhood.com/tx/0x6e94bac3bae072e7fb20a446e28f755c3a4ab211eedbb83022a40b586ffc166c).
  Deploy gas 2,282,144 (`gasUsedForL1` 164,794), cost 0.0000228 ETH at the observed 0.01 gwei
  gas price (balance delta 0.00894225399 -> 0.00891943255 ETH).
- Rust/Stylus `Pricer`: `cargo stylus check --endpoint https://rpc.testnet.chain.robinhood.com`
  passed first (contract size 13.4 KB / 13,417 bytes, wasm data fee 0.000085 ETH), then
  `cargo stylus deploy --endpoint ... --private-key "$PRIVATE_KEY"` deployed and activated at
  `0x3c7940eAd8E2a00020858F008743b07Ee79Bf72D`.
  Deploy tx `0x5a5a3809109fcc353006f584ee8f680507c91944b986c0ef7efe3aba346c1a23`
  (https://explorer.testnet.chain.robinhood.com/tx/0x5a5a3809109fcc353006f584ee8f680507c91944b986c0ef7efe3aba346c1a23),
  gas 3,510,966 (`gasUsedForL1` 556,598).
  Activation tx `0xdba433a7b42f86b0826e5ced393d464e8b85b78d622ad87689924afcddd48d07`
  (https://explorer.testnet.chain.robinhood.com/tx/0xdba433a7b42f86b0826e5ced393d464e8b85b78d622ad87689924afcddd48d07),
  gas 3,674,730 (`gasUsedForL1` 6,324), emits the ArbWasm `ProgramActivated` log.
  Combined deploy+activation cost (balance delta) 0.0001425 ETH, which includes the 0.000085
  ETH wasm data fee paid as part of activation, not just gas.
- Deployer balance: 0.00894225399 ETH start -> 0.00877178738 ETH after both deployments, the
  negative-case check on both, and one real `price()` send per contract. Plenty of testnet ETH
  remained; no funding blocker was hit, matching the instruction to stop and report if it ran low.

## Parity: 5 cases, bit-for-bit on-chain (`cast call`, not a local VM)

| Case | strikeBps | spotE8 | ivE6 | secondsToExpiry | premium (WAD, both contracts) |
|---|---|---|---|---|---|
| 1 | 9700 | 22540000000 | 253400 | 216000 | 514945975301800723 |
| 2 | 9000 | 10000000000 | 400000 | 172800 | 26359988855718630 |
| 3 | 9900 | 50000000000 | 150000 | 259200 | 2779489989248956523 |
| 4 | 8500 | 30000000000 | 600000 | 345600 | 26454276247724370 |
| 5 | 9999 | 100000000000 | 100000 | 86400 | 8789632266397825999 |

## Stylus measured: gas via `eth_estimateGas` (`cast estimate`), all 5 cases

| Case | Solidity gas | Stylus gas | ratio (total gas) | ratio (net of 21,000 intrinsic) |
|---|---|---|---|---|
| 1 | 424,438 | 105,883 | 4.01x | 4.75x |
| 2 | 421,798 | 106,129 | 3.97x | 4.71x |
| 3 | 436,077 | 105,919 | 4.12x | 4.89x |
| 4 | 421,686 | 105,968 | 3.98x | 4.72x |
| 5 | 449,649 | 106,302 | 4.23x | 5.02x |

Average total-gas ratio across the 5 cases: **4.06x**. Only case 5, net of intrinsic, clears
5x on the estimate basis.

## Stylus measured: one real transaction per contract (case 1), receipt ground truth

- Solidity: `cast send` tx `0x43b35bc8bf0214ef33e48cb0aa313b3ad120bcd87a97b5fb22aea1d042cb3a65`
  (https://explorer.testnet.chain.robinhood.com/tx/0x43b35bc8bf0214ef33e48cb0aa313b3ad120bcd87a97b5fb22aea1d042cb3a65).
  Receipt `gasUsed` 417,043 (with 21,000 intrinsic), 396,043 (without), `gasUsedForL1` 9,239.
- Stylus: `cast send` tx `0x7fea45ac04e371f2f02ca17496eed919d3f0babef24ded40a4a14d9e4409970c`
  (https://explorer.testnet.chain.robinhood.com/tx/0x7fea45ac04e371f2f02ca17496eed919d3f0babef24ded40a4a14d9e4409970c).
  Receipt `gasUsed` 99,985 (with intrinsic), 78,985 (without), `gasUsedForL1` 9,486.
- Ratio from real receipts: total gas 417,043 / 99,985 = **4.17x**; net of intrinsic
  396,043 / 78,985 = **5.01x**.
- `estimateGas` vs receipt `gasUsed` agreement (required cross-check): Solidity 424,438 vs
  417,043, 1.77% apart (passes the 5% bar). Stylus 105,883 vs 99,985, 5.90% apart (fails the
  5% bar by 0.9 points; `eth_estimateGas` slightly overstates Stylus call cost relative to the
  receipt, which if anything understates the real ratio rather than overstating it).

## Stylus measured: negative case, live

Both revert on `strikeBps == 0`, read live via `cast call`, not a local test:
- Solidity: `execution reverted`, revert data `0x2bb9acf7` (the `BadInput()` custom-error
  selector).
- Stylus: `execution reverted`, revert data `0x426164496e707574`, which decodes as the ASCII
  string `BadInput`.

## Stylus measured: ArbOS version, portability to Arbitrum One

`ArbSys.arbOSVersion()` (precompile `0x0000...0064`), read live on both chains:
- Robinhood Chain testnet: **116**.
- Arbitrum Sepolia (`https://sepolia-rollup.arbitrum.io/rpc`): **116**.

Same ArbOS version on both. Per Stylus's portability rule, a Stylus program's
activated bytecode is valid across chains that share an ArbOS version; since both read 116,
this result is expected to carry over to Arbitrum Sepolia and, by the same rule, to Arbitrum
One once Arbitrum One is itself on ArbOS 116 (not independently checked here; no call was made
against Arbitrum One mainnet).

## Reading the verdict

The treaty's gate (this product's own win gate ("If Stylus does not beat Solidity by at
least 5x ... the Stylus claim is dropped") is naturally read as the total gas a caller pays for
`price()`, which is what every one of the 5 measured cases shows at 3.97x-4.23x, averaging
4.06x: real, substantial, and short of 5x. A secondary reading that nets out the 21,000
intrinsic (identical on both chains, arguably not part of the pricing algorithm's cost) gets to
4.7x-5.0x across the 5 estimate-based cases and 5.01x on the one case backed by a real receipt
rather than an estimate. That is a genuine near-miss, not a rounding trick, and is reported
here rather than picked to force a verdict either way. If the treaty's gate means total call
gas, the Stylus claim in the pitch should be revised from "at least 5x" to the measured ~4x;
if it means execution-only gas net of the shared intrinsic, the result is a coin-flip-close
pass that should be re-measured on a larger workload (the treaty's real target is 1,000
scenarios x 40 markets, not this spike's 504 x 1) before being relied on either way.

## Tooling

- `cargo stylus --version` -> not installed; installed via `cargo install --force cargo-stylus`, now 0.10.9.
- `rustup target list --installed | grep wasm32` -> `wasm32-unknown-unknown` and `wasm32v1-none` already present, no install needed.
- `docker --version` -> 28.3.2 (Docker Desktop present). `docker info` -> `Cannot connect to the Docker daemon`.
  `open -a Docker` / `open /Applications/Docker.app` launches the app, then `~/Library/Containers/com.docker.docker/Data/log/host/Docker.log`
  logs `AppDelegate: launching...` immediately followed by `AppDelegate: terminating...`, every time, for every date the log covers back to 2026-08-29.
  This is a standing sandbox restriction, not a one-off: the nitro-devnode path (`OffchainLabs/nitro-devnode`, `run_dev_node.sh`) needs a live daemon and never got one across two attempts (~8 min total wait) today.
- `forge --version` -> 1.6.0-nightly (present, no install needed).
- stylus-sdk latest per crates.io: 0.10.9, matched to cargo-stylus 0.10.9 in `rs/Cargo.toml`.
- Generated a throwaway `cast wallet new` keypair for gas-estimation-only calls (0 balance, never funded, never a user secret, discarded after this run: address `0x65C44E5d41ca0841724862bEc6D607F0ff6B9222`).

## What was built

- `spikes/stylus-pricer/nvda_gaps.json`: 504 NVDA Friday-close-to-next-open weekend gaps in
  basis points, fetched 2026-09-26 from
  `https://api.nasdaq.com/api/quote/NVDA/historical?assetclass=stocks&fromdate=2016-09-26&todate=2026-09-26&limit=9999`
  (min -1474 bps, matching the -14.7% worst case cited in this product's own research).
- `spikes/stylus-pricer/sol/src/FixedMath.sol` + `Pricer.sol`: WAD (1e18) fixed-point
  `mulWad/divWad/sqrtWad/lnWad/expNegWad/normalCDF`, then `price(strikeBps, spotE8, ivE6,
  secondsToExpiry)` = mean empirical payoff over the 504 gaps (stored in a `int32[504]`
  contract storage array, set in the constructor) + a Black-Scholes put term (r = 0).
- `spikes/stylus-pricer/rs/src/lib.rs`: the identical algorithm in Rust/Stylus (stylus-sdk
  0.10.9, alloy `I256`/`U256`), with the 504 gaps as a `const [i32; 504]` compiled into the
  WASM binary (no storage), matching the architecture in `heracles.md` ("scenario table ...
  compiled into the WASM binary").

## Measured, with commands

Solidity, real Foundry/EVM gas (`cd sol && forge test --match-path test/Pricer.t.sol -vv --gas-report`):

| Case | strikeBps | spotE8 | ivE6 | secondsToExpiry | premium (WAD) | gas |
|---|---|---|---|---|---|---|
| 1 | 9700 | 22540000000 | 253400 | 216000 | 514945975301800723 | 397598 |
| 2 | 9000 | 10000000000 | 400000 | 172800 | 26359988855718630 | 395034 |
| 3 | 9900 | 50000000000 | 150000 | 259200 | 2779489989248956523 | 409188 |
| 4 | 8500 | 30000000000 | 600000 | 345600 | 26454276247724370 | 394878 |
| 5 | 9999 | 100000000000 | 100000 | 86400 | 8789632266397825999 | 422471 |

Solidity deploy: 2,117,350 gas; deployed (runtime) bytecode 2,433 bytes; creation (initcode) 6,877 bytes.

Rust/Stylus, functional + parity only (`cd rs && cargo test --release parity_test -- --nocapture`,
`stylus-sdk`'s `TestVM`, which runs the real Rust logic natively but does not meter WASM gas):
identical 5 cases produce premiums `514945975301800723`, `26359988855718630`,
`2779489989248956523`, `26454276247724370`, `8789632266397825999` -> **bit-for-bit identical**
to Solidity, not merely within 1e-6 relative.

Stylus, real live read against Arbitrum Sepolia, no funds needed
(`cargo stylus check --endpoint https://sepolia-rollup.arbitrum.io/rpc`):
`contract size: 13.4 KB (13393 bytes)`; `wasm data fee: 0.000085 ETH (originally 0.000071 ETH with 20% bump)`.
This is a real number read from the live chain (L1 calldata-based activation fee, not a
guess), but it is a deploy-time number, not the `price()` call gas the claim is about.

`price()` call gas on Stylus: **not obtained**. `cargo stylus deploy --estimate-gas` against
the same Sepolia endpoint with the throwaway zero-balance key returned a non-physical
`deployment tx gas: 84741516242044` (84.7 trillion; Arbitrum's per-block gas limit is ~32M),
i.e. the RPC will not produce a trustworthy `eth_estimateGas` for an unfunded sender, and
`price()` cannot be called at all without the contract first being deployed. With no docker
(devnode) and no Sepolia ETH, there is no path from here to a real on-chain gas number for the
Stylus `price()` call.

## Negative case

Both revert on `strikeBps == 0`: Solidity `test_negative_strike_zero_reverts` passes (gas
8772, `BadInput()` revert); Rust `test_zero_strike_reverts` passes (`Err(b"BadInput")`). Also
checked `spotE8 == 0` on the Solidity side (`test_negative_spot_zero_reverts`, gas 8618). Same
revert condition, same input, in both languages.

## Caveat

The one number the claim needs, Stylus `price()` call gas, is exactly the one number that
could not be produced without either a running node or a funded testnet key, and both were
genuinely unavailable, not skipped. Everything else here is real: real NVDA gap data, a real
identical algorithm bit-exact across languages, real Solidity EVM gas, and a real (if partial)
Sepolia read for the Stylus side. Foundry's `via_ir = true` was required to compile
`Pricer.sol` (stack-too-deep otherwise); this is a legitimate, commonly-used optimizer setting,
not a thumb on the scale, but it does mean the Solidity gas numbers above reflect the IR
optimizer pipeline, not the legacy codegen path.

## Blocks product

Resolved (superseded by the "Stylus measured" sections above). The Heracles pitch's Stylus
claim (this product's own win gate ("If Stylus does not beat Solidity by at least 5x ... the
Stylus claim is dropped") is now measured, live, on Robinhood Chain testnet: REFUTED on the
total-gas basis (~4.06x average, 3.97x-4.23x range), a near-miss on the intrinsic-excluded
basis (4.7x-5.0x, one real receipt at 5.01x). Per the treaty's own rule, the pitch should drop
"at least 5x" and either state the measured ~4x, or re-run this spike at the treaty's real
scale (1,000 scenarios x 40 markets) before repeating any 5x claim.
