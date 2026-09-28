import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: { target: 'es2022' },
  // The pricing tables live in ../evidence/gap-tables and are imported, not copied.
  server: { fs: { allow: ['..'] } },
});
