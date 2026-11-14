import { defineConfig } from '@playwright/test'

// Chrome resolution: RIELA_E2E_CHROME pins an explicit binary (e.g. a nix
// profile path); otherwise Playwright launches the locally installed Google
// Chrome through the "chrome" channel.
const chromeExecutable = process.env.RIELA_E2E_CHROME

export default defineConfig({
  testDir: './e2e',
  outputDir: '../tmp/web-dashboard-e2e/playwright-results',
  fullyParallel: false,
  retries: 0,
  reporter: 'line',
  use: {
    baseURL: 'http://127.0.0.1:4174',
    browserName: 'chromium',
    ...(chromeExecutable
      ? { launchOptions: { executablePath: chromeExecutable } }
      : { channel: 'chrome' }),
  },
  webServer: {
    command: 'bun run dev --host 127.0.0.1 --port 4174',
    url: 'http://127.0.0.1:4174',
    reuseExistingServer: false,
  },
})
