import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./Tests/browser",
  fullyParallel: false,
  workers: 1,
  timeout: 45000,
  use: { baseURL: process.env.SPEEDMATH_TEST_URL || "http://127.0.0.1:4178" },
  webServer: process.env.SPEEDMATH_TEST_URL ? undefined : {
    command: "pnpm exec vite preview --host 127.0.0.1 --port 4178 --strictPort",
    url: "http://127.0.0.1:4178/api/health",
    reuseExistingServer: !process.env.CI,
  },
});
