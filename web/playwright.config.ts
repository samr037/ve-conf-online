import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: 'e2e',
  timeout: 120_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:5179/',
    viewport: { width: 1440, height: 960 },
    locale: 'en-US',
    acceptDownloads: true,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 960 }, locale: 'en-US' } }],
  webServer: {
    command: 'npx vite --port 5179 --strictPort --host 127.0.0.1',
    url: 'http://127.0.0.1:5179/app.html',
    reuseExistingServer: true,
    timeout: 60_000,
  },
})
