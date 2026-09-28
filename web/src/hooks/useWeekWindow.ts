import { useEffect, useState } from 'react';
import type { PublicClient } from 'viem';
import { TREATY_ADDRESS, treatyAbi } from '../abi';

export type WeekWindow = { cutoff: number; expiry: number; ref: number };

/**
 * The week's take cutoff, Friday reference (`fridayCloseOf`), and Monday fixing, all read from
 * the contract's own calendar so the DST-aware close/expiry math is never duplicated here.
 */
export function useWeekWindow(client: PublicClient | undefined, now: number): WeekWindow | undefined {
  const [win, setWin] = useState<WeekWindow>();
  const tick = Math.floor(now / 30);
  useEffect(() => {
    if (!client) return;
    let live = true;
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'weekWindow', args: [BigInt(tick * 30)] })
      .then(async (r) => {
        const [cutoff, expiry] = r as unknown as [bigint, bigint];
        const ref = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fridayCloseOf', args: [cutoff] });
        if (!live) return;
        setWin({ cutoff: Number(cutoff), expiry: Number(expiry), ref: Number(ref as bigint) });
      })
      .catch(() => { if (live) setWin(undefined); });
    return () => { live = false; };
  }, [client, tick]);
  return win;
}

/** Binding reopens at the next ISO week's Monday 00:00 UTC: Friday 19:30 UTC plus 2d 4.5h. */
export const reopensAt = (w: WeekWindow) => w.cutoff + 2 * 86400 + 4.5 * 3600;
