import { defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "speedmath",
    compatibilityDate: "2026-11-14",
    assets: { notFoundHandling: "single-page-application" },
  },
});
