import { defineConfig } from "vite";
import { cloudflare } from "@cloudflare/vite-plugin";
import swiftWasm from "@elementary-swift/vite-plugin-swift-wasm";

export default defineConfig({
  server: { watch: { ignored: ["**/.cloudflare/**"] } },
  plugins: [
    cloudflare(),
    swiftWasm({ useEmbeddedSDK: true }),
  ],
});
