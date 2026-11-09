import { svelte } from '@sveltejs/vite-plugin-svelte'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  base: './',
  plugins: [svelte()],
  // Victron's assistant library ships with the site as a hashed asset.
  assetsInclude: ['**/*.vfp'],
  build: {
    rollupOptions: { input: { index: 'index.html', app: 'app.html' } },
  },
  test: {
    include: ['test/**/*.test.ts'],
    testTimeout: 120_000,
  },
})
