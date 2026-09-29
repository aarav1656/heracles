import { useEffect, useState } from 'react';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { quoteLive } from './useBook';
import { explainError } from '../lib/revert';

export type Terms = { exp: bigint[]; ret: bigint; lim: bigint };
export type LiveQuote = { premium: bigint; el: bigint; tvar: bigint; block: bigint; terms: Terms };

export const termsKey = (t: Terms | undefined) => (t ? `${t.exp.join(',')}|${t.ret}|${t.lim}` : '');

/**
 * Re-quotes `terms` from the deployed Stylus pricer after `delay` ms of quiet. The block is read
 * first and the quote is made at that block, so the block shown is the one the price came from.
 * A newer input cancels an older in-flight quote; the last good quote stays on screen, marked
 * `quoting`, until the new one lands.
 */
export function useLiveQuote(terms: Terms | undefined, delay = 350) {
  const client = usePublicClient() as PublicClient | undefined;
  const [quote, setQuote] = useState<LiveQuote>();
  const [error, setError] = useState<string>();
  const [quoting, setQuoting] = useState(false);
  const key = termsKey(terms);

  useEffect(() => {
    if (!client || !terms) {
      setQuoting(false);
      return;
    }
    let live = true;
    setQuoting(true);
    const t = setTimeout(async () => {
      try {
        const block = await client.getBlockNumber();
        const [premium, el, tvar] = (await quoteLive(client, terms.exp, terms.ret, terms.lim, block)) as unknown as [bigint, bigint, bigint];
        if (!live) return;
        setQuote({ premium, el, tvar, block, terms });
        setError(undefined);
      } catch (e) {
        if (!live) return;
        setError(explainError(e).words);
      } finally {
        if (live) setQuoting(false);
      }
    }, delay);
    return () => { live = false; clearTimeout(t); };
  }, [client, key, delay]);

  return { quote, error, quoting };
}
