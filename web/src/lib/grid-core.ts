// Payout grid: retention on one axis, limit on the other, five steps each around the user's terms.

/** Multipliers in quarters: 0.5x, 0.75x, 1x, 1.25x, 1.5x. The middle step is the user's own value. */
export const GRID_STEPS = [2n, 3n, 4n, 5n, 6n] as const;
export const CURRENT = 2;

export type GridAxes = { retentions: bigint[]; limits: bigint[] };
export type GridCell = {
  retention: bigint; limit: bigint;
  premium: bigint; el: bigint;
  /** premium over limit in basis points */
  rateBps: bigint;
  current: boolean;
};

export function gridAxes(retention: bigint, limit: bigint): GridAxes {
  return {
    retentions: GRID_STEPS.map((q) => (retention * q) / 4n),
    limits: GRID_STEPS.map((q) => (limit * q) / 4n),
  };
}

/**
 * `quotes[r][l]` is the pricer's [premium, expectedLoss] for retentions[r] and limits[l].
 * The treaty's minimum rate lifts any premium below `limit * minRateBps / 10000`, so the
 * grid shows the charge a bind would carry.
 */
export function buildGrid(axes: GridAxes, quotes: readonly (readonly (readonly [bigint, bigint])[])[], minRateBps: bigint): GridCell[][] {
  return axes.retentions.map((retention, r) =>
    axes.limits.map((limit, l) => {
      const [raw, el] = quotes[r][l];
      const floor = (limit * minRateBps) / 10000n;
      const premium = raw >= floor ? raw : floor;
      return { retention, limit, premium, el, rateBps: limit === 0n ? 0n : (premium * 10000n) / limit, current: r === CURRENT && l === CURRENT };
    }),
  );
}
