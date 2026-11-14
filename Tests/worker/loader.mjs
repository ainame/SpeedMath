// Node module hooks that let worker/index.js load outside workerd.
const STUB = "speedmath-stub:cloudflare-workers";

export async function resolve(specifier, context, next) {
  if (specifier === "cloudflare:workers") return { url: STUB, shortCircuit: true };
  return next(specifier, context);
}

export async function load(url, context, next) {
  if (url === STUB) {
    return {
      format: "module", shortCircuit: true,
      source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }",
    };
  }
  if (url.endsWith(".wasm")) {
    return {
      format: "module", shortCircuit: true,
      source: `import { readFileSync } from "node:fs";
export default new WebAssembly.Module(readFileSync(new URL(${JSON.stringify(url)})));`,
    };
  }
  return next(url, context);
}
