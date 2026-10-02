import react from '@vitejs/plugin-react';
import fs from 'node:fs';
import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [
    react(),
    {
      name: 'remove-msw-production',
      apply: 'build',
      closeBundle() {
        const mswPath = fileURLToPath(new URL('./dist/mockServiceWorker.js', import.meta.url));
        if (fs.existsSync(mswPath)) {
          fs.unlinkSync(mswPath);
        }
      }
    }
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  server: {
    port: 3001
  },
  build: {
    chunkSizeWarningLimit: 1024
  }
});
