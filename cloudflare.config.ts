import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig(({ mode }) => {
  const staging = mode !== "production" && mode !== "production-solo";
  const remoteEnabled = mode !== "staging-solo" && mode !== "production-solo";
  const limiter = (id: number, limit: number) =>
    bindings.rateLimit({ namespace: String(id + (staging ? 100 : 0)), simple: { limit, period: 60 } });
  return {
    worker: {
      name: staging ? "speedmath-staging" : "speedmath",
      compatibilityDate: "2026-11-14",
      entrypoint: "./worker/index.js",
      workersDev: true,
      previewUrls: false,
      assets: { notFoundHandling: "single-page-application", runWorkerFirst: ["/api/*"] },
      exports: {
        SessionObject: exports.durableObject({ storage: "sqlite" }),
        CodeShard: exports.durableObject({ storage: "sqlite" }),
      },
      env: {
        LOOKUPS: limiter(1, 5),
        CREATES: limiter(2, 10),
        CONNECTIONS: limiter(3, 45),
        REMOTE_ENABLED: bindings.json(remoteEnabled),
      },
      observability: { enabled: true },
    },
  };
});
