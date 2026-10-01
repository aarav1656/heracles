/**
 * The curated browser-wallet allowlist, in menu order.
 * rdns values come from the EIP-6963 announcement (`info.rdns`).
 */
export const WALLET_ALLOWLIST = [
  { rdns: 'io.rabby', label: 'Rabby' },
  { rdns: 'io.metamask', label: 'MetaMask' },
  { rdns: 'com.coinbase.wallet', label: 'Coinbase Wallet' },
  { rdns: 'app.phantom', label: 'Phantom' },
] as const;

export type AllowedRdns = (typeof WALLET_ALLOWLIST)[number]['rdns'];

/** The smallest shape the filter needs. wagmi connectors satisfy this. */
export type MinimalConnector = {
  id?: string;
  rdns?: string | readonly string[] | null;
};

const order = new Map<string, number>(WALLET_ALLOWLIST.map((w, i) => [w.rdns, i]));

const rdnsOf = (c: MinimalConnector): string[] => {
  // wagmi's EIP-6963 connectors carry the wallet's rdns as `id` (createConfig: id: info.rdns) and expose no `rdns`.
  if (!c) return [];
  if (c.rdns == null) return c.id ? [c.id] : [];
  return typeof c.rdns === 'string' ? [c.rdns] : [...c.rdns];
};

/**
 * Keep only connectors whose EIP-6963 rdns is on the allowlist,
 * sorted by allowlist order rather than discovery order.
 */
export function filterAllowedConnectors<T extends MinimalConnector>(
  connectors: readonly T[],
): T[] {
  return connectors
    .filter((c) => rdnsOf(c).some((r) => order.has(r)))
    .sort(
      (a, b) =>
        Math.min(...rdnsOf(a).map((r) => order.get(r) ?? Infinity)) -
        Math.min(...rdnsOf(b).map((r) => order.get(r) ?? Infinity)),
    );
}

/** Display name for an allowed connector: the curated label, never the raw id. */
export function walletLabel(rdns: string, fallback: string): string {
  return WALLET_ALLOWLIST.find((w) => w.rdns === rdns)?.label ?? fallback;
}
