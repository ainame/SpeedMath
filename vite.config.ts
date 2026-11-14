import { execFileSync } from "node:child_process";
import { defineConfig } from "vite";
import { cloudflare } from "@cloudflare/vite-plugin";
import swiftWasm from "@elementary-swift/vite-plugin-swift-wasm";

export default defineConfig({
  plugins: [
    {
      name: "speedmath-worker-wasm",
      config() { execFileSync("bash", ["Scripts/build-worker-wasm.sh"], { stdio: "inherit" }); },
    },
    cloudflare(),
    swiftWasm({ useEmbeddedSDK: true }),
  ],
});
