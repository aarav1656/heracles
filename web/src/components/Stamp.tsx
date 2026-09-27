import { explorer } from '../chain';

/** "read at block 312,904,417". Every on-chain number on screen sits next to one of these. */
export function Stamp({ block, label = 'read at block' }: { block: bigint; label?: string }) {
  return (
    <span className="stamp">
      {label} <a className="num" href={explorer.block(block)} target="_blank" rel="noreferrer">#{block.toLocaleString('en-US')}</a>
    </span>
  );
}
