import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

const mode = process.argv[2] ?? "staging";
const output = ".cloudflare/output/v0";
const dir = join(output, "workers/default");
const readJSON = async path => JSON.parse(await readFile(path, "utf8"));
const config = await readJSON(join(output, "config.json"));
assert.equal(config.buildContext.mode, mode);
const worker = await readJSON(join(dir, "worker.config.json"));
assert.equal(worker.name, mode.startsWith("production") ? "speedmath" : "speedmath-staging");
assert.deepEqual(worker.assets.runWorkerFirst, ["/api/*"]);
assert.equal(worker.env.REMOTE_ENABLED.value, !mode.endsWith("-solo"));
for (const name of ["SessionObject", "CodeShard"]) assert.equal(worker.exports[name].storage, "sqlite");
const wasm = Object.entries(worker.manifest.modules).filter(([, m]) => m.type === "wasm").map(([name]) => name);
assert.equal(wasm.length, 1, "one Swift Worker Wasm module");
const bytes = await readFile(join(dir, "bundle", wasm[0]));
const imports = new Set(WebAssembly.Module.imports(new WebAssembly.Module(bytes)).map(i => i.module));
// Embedded Swift with JavaScriptKit: no regular Swift runtime, so the module stays small.
for (const name of imports) assert.ok(["javascript_kit", "bjs", "wasi_snapshot_preview1"].includes(name), name);
assert.ok(bytes.length < 1_000_000, `Worker Wasm is ${bytes.length} B; expected the Embedded build`);
const app = (await readdir(join(dir, "assets/assets"))).find(name => /^WebApp-.*\.wasm$/.test(name));
assert.ok(app);
console.log(`${worker.name} (${mode}): Worker Wasm ${bytes.length} B; browser Wasm ${(await readFile(join(dir, "assets/assets", app))).length} B`);
