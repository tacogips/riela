import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  outputDir: '../tmp/web-dashboard-e2e/playwright-results',
  fullyParallel: false,
  retries: 0,
  reporter: 'line',
  use: {
    baseURL: 'http://127.0.0.1:4174',
    browserName: 'chromium',
    launchOptions: { executablePath: '/etc/profiles/per-user/taco/bin/google-chrome' },
  },
  webServer: {
    command: 'bun run dev --host 127.0.0.1 --port 4174',
    url: 'http://127.0.0.1:4174',
    reuseExistingServer: false,
  },
})
