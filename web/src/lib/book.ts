// A vault book on the six-table pricer, shared by the /sdk page and heracles-sdk: the market order,
// the live quote, and the OIGuard verdict with the numbers its revert carries.
import { BaseError, ContractFunctionRevertedError, type Address, type PublicClient } from 'viem';
import { FEED_ADDRESSES, OIGUARD_ADDRESS, QUOTE_PRICER_ADDRESS, oiGuardAbi, pricerAbi } from '../abi/generated';
import { PRICED_MARKETS } from './quote-core';
import { ERROR_WORDS } from './treaty';
import { fmtUsdg2 } from './format';

export type Ticker = (typeof PRICED_MARKETS)[number]['ticker'];
/** Signed net weekend exposure per market, 6dp. Positive is long (loses when the market falls). */
export type Book = Partial<Record<Ticker, bigint>>;

/** The six-table pricer's markets in table order: book index i prices on table i. */
export const MARKETS: readonly Ticker[] = [...PRICED_MARKETS].sort((a, b) => a.tableId - b.tableId).map((m) => m.ticker);

/** A book as the pricer's six-entry exposure vector. Throws on a market the pricer has no table for. */
export function bookVector(book: Book): bigint[] {
  for (const k of Object.keys(book)) {
    if (!MARKETS.includes(k as Ticker)) throw new Error(`No table for ${k}. Markets: ${MARKETS.join(', ')}`);
  }
  return MARKETS.map((t) => book[t] ?? 0n);
}

const at = async (client: PublicClient, blockNumber?: bigint) => blockNumber ?? (await client.getBlockNumber());

export type Quote = { premium: bigint; el: bigint; tvar95: bigint; blockNumber: bigint; pricer: Address };

/**
 * Weekend-gap cover on a whole book from the six-table Stylus pricer. Arbitrum Sepolia carries one
 * live equity feed, SPY/USD, so it is the volatility feed for every market, as on the quote desk.
 */
export async function quoteBook(
  client: PublicClient,
  { book, retention, limit, blockNumber }: { book: Book; retention: bigint; limit: bigint; blockNumber?: bigint },
): Promise<Quote> {
  const block = await at(client, blockNumber);
  const exposure = bookVector(book);
  const [premium, el, tvar95] = await client.readContract({
    address: QUOTE_PRICER_ADDRESS, abi: pricerAbi, functionName: 'quote',
    args: [exposure, exposure.map(() => FEED_ADDRESSES[0]), retention, limit], blockNumber: block,
  });
  return { premium, el, tvar95, blockNumber: block, pricer: QUOTE_PRICER_ADDRESS };
}

export type GuardCheck = {
  ok: boolean;
  /** Premium for the book after the trade. */
  premium: bigint;
  budget: bigint;
  /** Premium for the book before the trade; priced by the guard only when it refuses. */
  currentPremium?: bigint;
  words?: string;
  blockNumber: bigint;
  guard: Address;
};

/** Asks the OIGuard whether the vault may take `size` more net exposure on `market`. */
export async function guardCheck(
  client: PublicClient,
  { book, market, size, guard = OIGUARD_ADDRESS, blockNumber }:
    { book: Book; market: Ticker; size: bigint; guard?: Address; blockNumber?: bigint },
): Promise<GuardCheck> {
  const block = await at(client, blockNumber);
  const index = MARKETS.indexOf(market);
  if (index < 0) throw new Error(`No table for ${market}. Markets: ${MARKETS.join(', ')}`);
  const budget = await client.readContract({ address: guard, abi: oiGuardAbi, functionName: 'premiumBudget', blockNumber: block });
  try {
    const premium = await client.readContract({
      address: guard, abi: oiGuardAbi, functionName: 'check', args: [bookVector(book), BigInt(index), size], blockNumber: block,
    });
    return { ok: true, premium, budget, blockNumber: block, guard };
  } catch (err) {
    const reverted = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null;
    if (reverted instanceof ContractFunctionRevertedError && reverted.data?.errorName === 'PremiumOverBudget') {
      const [premium, , currentPremium] = reverted.data.args as readonly [bigint, bigint, bigint];
      return { ok: false, premium, budget, currentPremium, words: ERROR_WORDS.PremiumOverBudget, blockNumber: block, guard };
    }
    throw err;
  }
}

const signed = (v: bigint) => `${v < 0n ? 'short' : 'long'} ${fmtUsdg2(v < 0n ? -v : v)}`;

/** The text `heracles-quote` prints: the quote, then the guard's verdict when a position was asked about. */
export function quoteText(
  { quote: q, book, retention, limit, open, guard: g }:
    { quote: Quote; book: Book; retention: bigint; limit: bigint; open?: [Ticker, bigint]; guard?: GuardCheck },
): string {
  const lines = [
    `Heracles weekend-gap quote, Arbitrum Sepolia block ${q.blockNumber}`,
    `  pricer         ${q.pricer} (Stylus, six tables)`,
    `  book           ${MARKETS.filter((t) => book[t]).map((t) => `${t} ${signed(book[t]!)}`).join(', ')}`,
    `  retention      ${fmtUsdg2(retention)}`,
    `  limit          ${fmtUsdg2(limit)}`,
    `  premium        ${fmtUsdg2(q.premium)}`,
    `  expected loss  ${fmtUsdg2(q.el)}`,
    `  worst 5% avg   ${fmtUsdg2(q.tvar95)}`,
  ];
  if (g && open) {
    lines.push(
      '',
      `OIGuard ${g.guard}, open ${open[0]} ${signed(open[1])}`,
      g.ok
        ? `  ACCEPTED       premium after the trade ${fmtUsdg2(g.premium)} within budget ${fmtUsdg2(g.budget)} or below today's`
        : `  REFUSED        PremiumOverBudget: premium after the trade ${fmtUsdg2(g.premium)}, budget ${fmtUsdg2(g.budget)}, book today ${fmtUsdg2(g.currentPremium!)}`,
    );
  }
  return lines.join('\n');
}
