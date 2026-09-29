/** A money figure with its decimals set small on a raised baseline (Mercury's "$5,144,707.08"). */
export function Money({ v, dp = 2 }: { v: number; dp?: number }) {
  const [whole, frac] = v.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp }).split('.');
  return <span className="money">{whole}{frac && <span className="dec">.{frac}</span>}</span>;
}
