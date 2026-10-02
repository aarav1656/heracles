// Hand-kept companions to generated.ts (which carries addresses, the books and the three
// contract ABIs). Regenerate generated.ts with: npm run sync-abi
import { parseAbi } from 'viem';

export { treatyAbi, capacityAbi, pricerAbi, oiGuardAbi } from './generated';
export { TREATY_ADDRESS, PRICER_ADDRESS, QUOTE_PRICER_ADDRESS, OIGUARD_ADDRESS, FEED_ADDRESSES, BOOKS } from './generated';
export type { BookConfig } from './generated';

export const erc20Abi = parseAbi([
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function nonces(address owner) view returns (uint256)',
]);

export const aggregatorAbi = parseAbi([
  'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function getRoundData(uint80 roundId) view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function decimals() view returns (uint8)',
]);
