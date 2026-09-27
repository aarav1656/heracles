// Hand-kept companions to generated.ts (which carries addresses and the three
// contract ABIs). Regenerate generated.ts with: npm run sync-abi
import { parseAbi } from 'viem';

export { treatyAbi, capacityAbi, pricerAbi } from './generated';
export {
  TREATY_ADDRESS,
  CAPACITY_ADDRESS,
  PRICER_ADDRESS,
  USDG_ADDRESS,
  FEED_ADDRESSES,
  USDG_DECIMALS,
} from './generated';

export const erc20Abi = parseAbi([
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function nonces(address owner) view returns (uint256)',
]);

// depositWithPermit isn't in generated.ts (synced from the currently deployed Capacity, which
// predates it); hand-kept the same way erc20Abi is, for the single call site in useDepositWithPermit.
export const depositWithPermitAbi = parseAbi([
  'function depositWithPermit(uint256 assets, address receiver, uint256 deadline, uint8 v, bytes32 r, bytes32 s) returns (uint256 shares)',
  'error InsufficientAllowance()',
]);

export const aggregatorAbi = parseAbi([
  'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function getRoundData(uint80 roundId) view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function decimals() view returns (uint8)',
]);
