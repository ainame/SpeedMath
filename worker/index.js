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

let ready;
const swift = () => (ready ??= init().then(() => globalThis.speedMathWorker));

export default {
  async fetch(request, env, ctx) { return (await swift()).fetch(request, env, ctx); },
};

export class CodeShard extends DurableObject {
  async reserve(hash, id, generation, expires) { return (await swift()).shardReserve(this.ctx, hash, id, generation, expires); }
  async lookup(hash) { return (await swift()).shardLookup(this.ctx, hash); }
  async release(hash, id, generation) { return (await swift()).shardRelease(this.ctx, hash, id, generation); }
  async alarm() { return (await swift()).shardAlarm(this.ctx); }
}

export class SessionObject extends DurableObject {
  async create(id, hash) { return (await swift()).sessionCreate(this.ctx, id, hash); }
  async validLookup(hash, generation) { return (await swift()).sessionValidLookup(this.ctx, hash, generation); }
  async fetch() { return (await swift()).sessionFetch(this.ctx); }
  async webSocketMessage(ws, text) { return (await swift()).sessionMessage(this.ctx, ws, text); }
  async webSocketClose(ws) { return (await swift()).sessionClose(this.ctx, ws); }
  async webSocketError(ws) { return (await swift()).sessionClose(this.ctx, ws); }
  async alarm() { return (await swift()).sessionAlarm(this.ctx); }
}
