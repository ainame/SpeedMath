// Lint for the JavaScript in this repository: the Worker, the Wasm start-up and the test tooling.
// The app itself is Swift (see AGENTS.md); `swift format lint` covers that.
import js from "@eslint/js";
import globals from "globals";

export default [
  { ignores: ["**/*.ts", "dist/**", ".build/**", ".cloudflare/**", "node_modules/**", "worker/generated/**", "public/**"] },
  js.configs.recommended,
  {
    // The Worker runs in workerd: service-worker style globals plus a few Workers extras.
    files: ["worker/**/*.js"],
    languageOptions: {
      globals: { ...globals.serviceworker, WebSocketPair: "readonly" },
    },
  },
  {
    files: ["web/**/*.js"],
    languageOptions: { globals: globals.browser },
  },
  {
    // Node tooling; Playwright tests also run code in the page.
    files: ["Tests/**/*.{js,mjs}", "Scripts/**/*.mjs", "*.config.js"],
    languageOptions: { globals: { ...globals.node, ...globals.browser } },
  },
];
