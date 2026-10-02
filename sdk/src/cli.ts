#!/usr/bin/env node
// heracles-quote --exposure NVDA=1000000,EUR=-400000 --retention 20000 --limit 200000 [--open NVDA=600000] [--json]
import { parseArgs } from 'node:util';
import { MARKETS, guardCheck, heraclesClient, parseExposure, parseUsdg, quote, quoteText, type Book, type Ticker } from './index';

const USAGE = `heracles-quote: live weekend-gap cover quote from the Heracles Stylus pricer on Arbitrum Sepolia

  --exposure  signed USD per market, comma separated: NVDA=1000000,EUR=-400000 (markets: ${MARKETS.join(', ')})
  --retention USD of weekend-gap loss the vault keeps
  --limit     USD of cover above the retention
  --open      also ask the OIGuard about one more position: NVDA=600000
  --block     price at this block instead of the latest
  --rpc       Arbitrum Sepolia RPC URL
  --json      machine-readable output`;

function pairs(s: string): [Ticker, bigint][] {
  return s.split(',').filter(Boolean).map((kv) => {
    const [k, v] = kv.split('=');
    const t = k?.trim().toUpperCase() as Ticker;
    if (!MARKETS.includes(t) || v === undefined) throw new Error(`Bad market entry "${kv}". Use TICKER=amount with ${MARKETS.join(', ')}.`);
    return [t, parseExposure(v)];
  });
}

async function main() {
  const { values } = parseArgs({
    options: {
      exposure: { type: 'string' }, retention: { type: 'string' }, limit: { type: 'string' }, open: { type: 'string' },
      block: { type: 'string' }, rpc: { type: 'string' }, json: { type: 'boolean' }, help: { type: 'boolean', short: 'h' },
    },
  });
  if (values.help || !values.exposure || !values.retention || !values.limit) {
    console.log(USAGE);
    process.exit(values.help ? 0 : 2);
  }
  const book: Book = Object.fromEntries(pairs(values.exposure));
  const retention = parseUsdg(values.retention);
  const limit = parseUsdg(values.limit);
  const client = heraclesClient(values.rpc);
  const blockNumber = values.block ? BigInt(values.block) : await client.getBlockNumber();
  const q = await quote(client, { book, retention, limit, blockNumber });

  let open: [Ticker, bigint] | undefined;
  if (values.open) {
    const p = pairs(values.open);
    if (p.length !== 1) throw new Error('--open takes one TICKER=amount');
    open = p[0];
  }
  const g = open ? await guardCheck(client, { book, market: open[0], size: open[1], blockNumber }) : undefined;

  if (values.json) {
    console.log(JSON.stringify({ chainId: 421614, quote: q, book, retention, limit, open, guard: g }, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
    return;
  }
  console.log(quoteText({ quote: q, book, retention, limit, open, guard: g }));
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
