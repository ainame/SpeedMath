// Worker entry: /api/* (static assets are served before the Worker runs). The Durable Object
// classes live in their own files and are re-exported here for the Workers runtime.
import { CONTROL_LIMIT, frame, logic, normalizeCode } from "./protocol.js";
import { credential, digest, invalid, json, loopback, object, random, shard } from "./shared.js";

export { CodeShard } from "./code-shard.js";
export { SessionObject } from "./session-object.js";

async function readControl(request) {
  if (!request.body || !request.headers.get("Content-Type")?.startsWith("application/json")) return null;
  const reader = request.body.getReader();
  const bytes = new Uint8Array(CONTROL_LIMIT);
  let used = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value.length > bytes.length - used) {
        await reader.cancel();
        return null;
      }
      bytes.set(value, used);
      used += value.length;
    }
    return frame(new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, used)));
  } catch { return null; }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/api/health" && request.method === "GET") {
      return json({ version: logic.protocol_version() });
    }
    if (env.REMOTE_ENABLED !== true || url.search ||
        (url.protocol !== "https:" && !loopback(url.hostname)) ||
        request.headers.get("Origin") !== url.origin) return invalid();
    const key = request.headers.get("CF-Connecting-IP") ?? "local";
    if (request.method === "POST" && url.pathname === "/api/session") {
      if (!(await env.CREATES.limit({ key })).success) return json({ error: "slow" }, 429);
      const message = await readControl(request);
      if (message?.type !== "create" || Object.keys(message).length !== 2) return invalid();
      const id = random(16);
      const secret = random();
      await object(ctx, id).create(id, await credential(id, 1, secret));
      return json({ id, key: secret });
    }
    if (request.method === "POST" && url.pathname === "/api/lookup") {
      if (!(await env.LOOKUPS.limit({ key })).success) return json({ error: "slow" }, 429);
      const message = await readControl(request);
      const code = message?.type === "lookup" && normalizeCode(message.code);
      if (!code) return invalid();
      const hash = await digest(code);
      const entry = await shard(ctx, hash).lookup(hash);
      if (!entry || !(await object(ctx, entry.id).validLookup(hash, entry.generation))) return invalid();
      return json({ id: entry.id, generation: entry.generation });
    }
    const id = /^\/api\/socket\/([\da-f]{32})$/.exec(url.pathname)?.[1];
    if (id && request.method === "GET" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      if (!(await env.CONNECTIONS.limit({ key })).success) return json({ error: "slow" }, 429);
      return object(ctx, id).fetch(new Request(request.url, { headers: { Upgrade: "websocket" } }));
    }
    return invalid();
  },
};
