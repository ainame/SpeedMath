// Cloudflare requires the Worker entry and Durable Object classes to be JavaScript. This file only
// forwards each call to the Swift Worker (Sources/Worker); no app logic lives here.
import { DurableObject } from "cloudflare:workers";
import { init } from "virtual:swift-wasm?js&module&product=Worker";

// Bridge for the Swift side: JSON.parse throws on bad input, and a JS exception inside a
// JavaScriptKit call would trap the Wasm instance the whole isolate shares.
globalThis.speedMathBridge = {
  parse(text) {
    try { return JSON.parse(text); } catch { return null; }
  },
};

// Start Swift while the isolate starts up, so its cost falls on startup rather than on the first
// request, and run Swift's shared helpers once so V8 compiles them ahead of time.
// Workers forbid random values at global scope, but Swift's start-up seeds its hash function from
// WASI random_get. Give it fixed bytes during start-up only; handlers get real randomness (session
// ids, keys and codes are drawn per request), and Swift's internal dictionaries are not keyed by
// client input.
// Top-level await only settles on microtasks, so instantiate the precompiled module synchronously.
const getRandomValues = crypto.getRandomValues;
const instantiate = WebAssembly.instantiate;
crypto.getRandomValues = array => array.fill(7);
WebAssembly.instantiate = async (module, imports) => new WebAssembly.Instance(module, imports);
let api;
try {
  api = await init().then(() => globalThis.speedMathWorker);
  api.warmUp();
} finally {
  crypto.getRandomValues = getRandomValues;
  WebAssembly.instantiate = instantiate;
}

export default {
  async fetch(request, env, ctx) { return api.fetch(request, env, ctx); },
};

export class CodeShard extends DurableObject {
  async reserve(hash, id, generation, expires) { return api.shardReserve(this.ctx, hash, id, generation, expires); }
  async lookup(hash) { return api.shardLookup(this.ctx, hash); }
  async release(hash, id, generation) { return api.shardRelease(this.ctx, hash, id, generation); }
  async alarm() { return api.shardAlarm(this.ctx); }
}

export class SessionObject extends DurableObject {
  async create(id, hash) { return api.sessionCreate(this.ctx, id, hash); }
  async validLookup(hash, generation) { return api.sessionValidLookup(this.ctx, hash, generation); }
  async fetch() { return api.sessionFetch(this.ctx); }
  async webSocketMessage(ws, text) { return api.sessionMessage(this.ctx, ws, text); }
  async webSocketClose(ws) { return api.sessionClose(this.ctx, ws); }
  async webSocketError(ws) { return api.sessionClose(this.ctx, ws); }
  async alarm() { return api.sessionAlarm(this.ctx); }
}
