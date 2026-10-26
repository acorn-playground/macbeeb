// Browser tests of the built demo (npm run build, served by vite preview).
// They choose MacBeeb's own ROMs from Sources/BeebROMs/ROMs as a user would
// choose theirs. PLAYWRIGHT_CHANNEL=chrome uses the installed Google Chrome
// instead of Playwright's Chromium (npx playwright install chromium).

import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "tests",
  testMatch: "*.spec.ts",
  timeout: 120_000,
  fullyParallel: false,
  workers: 1,
  reporter: [["list"]],
  use: {
    baseURL: "http://127.0.0.1:4173",
    channel: process.env.PLAYWRIGHT_CHANNEL || undefined,
    headless: true,
  },
  webServer: {
    command: "npx vite build && npx vite preview --host 127.0.0.1 --port 4173 --strictPort",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
