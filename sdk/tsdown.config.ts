import { defineConfig } from 'tsdown';

// The ABIs, addresses, error words and amount parsers come from ../web/src and are bundled in, so
// the published package carries one copy of each and the web app stays the source of truth.
export default defineConfig({
  entry: ['src/index.ts', 'src/cli.ts'],
  format: 'esm',
  platform: 'node',
  dts: true,
});
