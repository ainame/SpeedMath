import { DurableObject } from "cloudflare:workers";
import logicModule from "./generated/logic.wasm";
import { VERSION, CONTROL_LIMIT, alphabet, frame, normalizeCode, relayKind, sessionPattern, tokenPattern } from "./protocol.js";

const logic = new WebAssembly.Instance(logicModule).exports;
const MINUTE = 60_000;
const SESSION = 120 * MINUTE;
const INVITE = 2 * MINUTE;
const RECONNECT = 10 * MINUTE;
const AUTH_WAIT = 10_000;
const headers = { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" };
const json = (body, status = 200) => Response.json(body, { headers, status });
const invalid = () => json({ error: "unavailable" }, 404);
const random = (size = 32) => crypto.getRandomValues(new Uint8Array(size)).toHex();
const digest = async value => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).toHex();
const matches = (actual, saved) => typeof saved === "string" &&
  crypto.subtle.timingSafeEqual(Uint8Array.fromHex(actual), Uint8Array.fromHex(saved));
const credential = (id, role, key) => digest(`${id}:${role}:${key}`);
const loopback = hostname => ["localhost", "127.0.0.1", "[::1]"].includes(hostname);
const object = (ctx, id) => ctx.exports.SessionObject.getByName(id);
const shard = (ctx, hash) => ctx.exports.CodeShard.getByName(hash.slice(0, 3));

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

export class CodeShard extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS codes (hash TEXT PRIMARY KEY, id TEXT, generation TEXT, expires INTEGER)");
  }

  async reserve(hash, id, generation, expires) {
    this.sql.exec("DELETE FROM codes WHERE expires <= ?", Date.now());
    const reserved = this.sql.exec("INSERT OR IGNORE INTO codes VALUES (?, ?, ?, ?) RETURNING hash",
      hash, id, generation, expires).toArray().length === 1;
    await this.schedule();
    return reserved;
  }

  lookup(hash) {
    return this.sql.exec("SELECT id, generation FROM codes WHERE hash = ? AND expires > ?", hash, Date.now()).toArray()[0];
  }

  async release(hash, id, generation) {
    this.sql.exec("DELETE FROM codes WHERE hash = ? AND id = ? AND generation = ?", hash, id, generation);
    await this.schedule();
  }

  async schedule() {
    const next = this.sql.exec("SELECT min(expires) AS expires FROM codes").one().expires;
    if (next === null) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(next);
  }

  async alarm() {
    this.sql.exec("DELETE FROM codes WHERE expires <= ?", Date.now());
    await this.schedule();
  }
}

export class SessionObject extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.prepare();
  }

  prepare() {
    this.sql.exec("CREATE TABLE IF NOT EXISTS session (singleton INTEGER PRIMARY KEY, state TEXT NOT NULL)");
  }

  // deleteAll drops the SQLite tables too, but this instance may still receive a duplicate
  // alarm, a stale lookup or a reconnect before it is evicted.
  async erase() {
    await this.ctx.storage.deleteAll();
    this.prepare();
  }

  load() {
    const row = this.sql.exec("SELECT state FROM session WHERE singleton = 1").toArray()[0];
    return row ? JSON.parse(row.state) : null;
  }

  save(state) {
    this.sql.exec("INSERT OR REPLACE INTO session VALUES (1, ?)", JSON.stringify(state));
  }

  async create(id, hash) {
    if (this.load()) return;
    const expires = Date.now() + SESSION;
    this.save({ id, expires, presenter: { hash, until: Date.now() + RECONNECT } });
    await this.ctx.storage.setAlarm(Date.now() + RECONNECT);
  }

  validLookup(hash, generation) {
    const state = this.load();
    return this.live(state) && this.validInvite(state, generation) && matches(hash, state.invite.codeHash);
  }

  live(state) { return state && state.expires > Date.now() && state.presenter.until > Date.now(); }
  validInvite(state, generation) {
    return !!state.invite && state.invite.generation === generation && state.invite.expires > Date.now();
  }

  active(state, ws, role) {
    const principal = role === 1 ? state.presenter : state.remote;
    const attachment = ws.deserializeAttachment();
    return attachment?.role === role && principal?.socket === attachment.id && principal.until > Date.now();
  }

  peer(state, role) {
    return this.ctx.getWebSockets().find(ws => ws.readyState === 1 && this.active(state, ws, role));
  }

  send(ws, type, fields = {}) {
    if (ws?.readyState === 1) ws.send(JSON.stringify({ v: VERSION, type, ...fields }));
  }

  close(ws, reason = "unavailable") {
    if (ws?.readyState === 1) ws.close(4001, reason);
  }

  pending(state) {
    return this.ctx.getWebSockets().find(ws => ws.readyState === 1 &&
      ws.deserializeAttachment()?.id === state.pending?.socket);
  }

  clearInvite(state) {
    const invite = state.invite;
    this.close(this.pending(state), "invite-ended");
    delete state.pending;
    delete state.invite;
    // Cross-object cleanup is conditional; a stale row also fails validLookup and expires.
    if (invite) this.ctx.waitUntil(shard(this.ctx, invite.codeHash)
      .release(invite.codeHash, state.id, invite.generation).catch(() => {}));
  }

  async schedule(state) {
    const unauth = this.ctx.getWebSockets().map(ws => ws.deserializeAttachment())
      .filter(a => a?.role === 0 && !a.pending && a.deadline > Date.now()).map(a => a.deadline);
    await this.ctx.storage.setAlarm(Math.min(state.expires, state.presenter.until,
      state.remote?.until ?? Infinity, state.invite?.expires ?? Infinity, ...unauth));
  }

  async fetch() {
    const state = this.load();
    if (!this.live(state) || this.ctx.getWebSockets().length >= 8) return invalid();
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ id: random(16), role: 0, deadline: Date.now() + AUTH_WAIT });
    await this.schedule(state);
    return new Response(null, { status: 101, webSocket: client, headers });
  }

  async authenticate(ws, a, message) {
    const role = message.role;
    if ((role !== 1 && role !== 2) || typeof message.key !== "string" || !tokenPattern.test(message.key)) {
      return this.close(ws);
    }
    const initial = this.load();
    if (!this.live(initial)) return this.close(ws);
    const hash = await credential(initial.id, role, message.key);
    const state = this.load();
    const principal = role === 1 ? state?.presenter : state?.remote;
    if (!this.live(state) || a.deadline <= Date.now() || ws.readyState !== 1 ||
        ws.deserializeAttachment()?.role !== 0 || ws.deserializeAttachment()?.pending ||
        !principal || principal.until <= Date.now() || !matches(hash, principal.hash)) return this.close(ws);
    const old = this.peer(state, role);
    const wasDisconnected = !old && principal.until < state.expires;
    principal.socket = a.id;
    principal.until = state.expires;
    this.save(state);
    ws.serializeAttachment({ id: a.id, role });
    this.close(old, "replaced");
    this.send(ws, "connected", { paired: !!state.remote, peer: !!this.peer(state, role === 1 ? 2 : 1) });
    if (role === 1 && state.pending) this.send(ws, "pending", state.pending.display);
    if (role === 1 && state.invite && !state.pending) this.send(ws, "inviteMissing");
    if (role === 2 || wasDisconnected || old) {
      this.send(this.peer(state, role === 1 ? 2 : 1), "peerUp");
    }
    await this.schedule(state);
  }

  async invite(ws, a) {
    let state = this.load();
    if (!this.live(state) || !this.active(state, ws, 1)) return;
    if (state.remote && state.remote.until > Date.now()) return;
    this.clearInvite(state);
    const attempt = random(16);
    state.issuing = attempt;
    delete state.remote;
    this.save(state);
    for (let i = 0; i < 5; i++) {
      const code = Array.from(crypto.getRandomValues(new Uint8Array(12)), b => alphabet[b & 31]).join("");
      const key = random();
      const [codeHash, inviteHash] = await Promise.all([digest(code), digest(key)]);
      const index = shard(this.ctx, codeHash);
      const expires = Date.now() + INVITE;
      if (!(await index.reserve(codeHash, state.id, attempt, expires))) continue;
      const latest = this.load();
      if (!this.live(latest) || !this.active(latest, ws, 1) || latest.issuing !== attempt || expires <= Date.now()) {
        await index.release(codeHash, state.id, attempt);
        return;
      }
      latest.invite = { generation: attempt, expires, codeHash, inviteHash, failures: 0 };
      delete latest.issuing;
      this.save(latest);
      this.send(ws, "invite", { generation: attempt, code, key, expires });
      await this.schedule(latest);
      return;
    }
    this.send(ws, "inviteMissing");
  }

  async join(ws, a, message) {
    const generation = message.generation;
    const code = message.type === "joinCode" ? normalizeCode(message.key) : null;
    const key = message.type === "joinCode" ? code :
      typeof message.key === "string" && tokenPattern.test(message.key) ? message.key : null;
    if (!key || typeof generation !== "string" || !sessionPattern.test(generation)) return this.close(ws);
    const hash = await digest(key);
    const state = this.load();
    if (!this.live(state) || a.deadline <= Date.now() || ws.readyState !== 1 ||
        ws.deserializeAttachment()?.role !== 0 || ws.deserializeAttachment()?.pending ||
        !this.validInvite(state, generation)) return this.close(ws);
    if (!matches(hash, code ? state.invite.codeHash : state.invite.inviteHash)) {
      if (++state.invite.failures >= 5) {
        this.clearInvite(state);
        this.send(this.peer(state, 1), "inviteMissing");
      }
      this.save(state);
      return this.close(ws);
    }
    if (state.remote || this.pending(state) || !this.peer(state, 1)) return this.close(ws);
    const display = { request: random(16), check: random(3).toUpperCase() };
    state.pending = { socket: a.id, display };
    this.save(state);
    ws.serializeAttachment({ ...a, pending: true });
    this.send(ws, "waiting", display);
    this.send(this.peer(state, 1), "pending", display);
    await this.schedule(state);
  }

  async approve(ws, request) {
    const initial = this.load();
    if (!this.live(initial)) return;
    const key = random();
    const hash = await credential(initial.id, 2, key);
    const state = this.load();
    if (!this.live(state) || !this.active(state, ws, 1) || !state.pending ||
        state.pending.display.request !== request || !this.validInvite(state, state.invite?.generation)) return;
    const remote = this.pending(state);
    if (!remote) return;
    const remoteId = state.pending.socket;
    delete state.pending; // Clear the invite without closing the approved socket.
    this.clearInvite(state);
    state.remote = { hash, socket: remoteId, until: state.expires };
    this.save(state);
    remote.serializeAttachment({ id: remoteId, role: 2 });
    this.send(remote, "approved", { key });
    this.send(ws, "peerUp");
    await this.schedule(state);
  }

  async webSocketMessage(ws, text) {
    const a = ws.deserializeAttachment();
    const state = this.load();
    if (!a || !this.live(state)) return this.close(ws);
    const now = Date.now();
    if (now - (a.since ?? 0) >= 10_000) { a.since = now; a.messages = 0; }
    if ((a.messages = (a.messages ?? 0) + 1) > (a.role ? 100 : 4)) return this.close(ws, "slow");
    ws.serializeAttachment(a);
    const message = frame(text);
    if (!message) return this.close(ws);
    if (!a.role && !a.pending && a.deadline > now && typeof text === "string" && text.length <= CONTROL_LIMIT) {
      if (message.type === "auth") return this.authenticate(ws, a, message);
      if (message.type === "joinCode" || message.type === "joinQR") return this.join(ws, a, message);
    }
    if (!a.role || !this.active(state, ws, a.role)) return this.close(ws);
    if (message.type === "ping") return this.send(ws, "pong");
    if (a.role === 1) {
      if (message.type === "invite") return this.invite(ws, a);
      if (message.type === "approve") return this.approve(ws, message.request);
      if (message.type === "reject" && state.pending?.display.request !== message.request) return;
      if (message.type === "reject" || message.type === "revoke" || message.type === "end") {
        this.clearInvite(state);
        delete state.issuing;
        if (message.type !== "reject") {
          this.close(this.peer(state, 2), "revoked");
          delete state.remote;
        }
        if (message.type === "end") {
          this.close(ws, "ended");
          await this.erase();
        } else {
          this.save(state);
          this.send(ws, "reset");
          await this.schedule(state);
        }
        return;
      }
    }
    if (!logic.can_relay(a.role, relayKind(message))) return this.close(ws);
    const peer = this.peer(state, a.role === 1 ? 2 : 1);
    if (peer) peer.send(text);
    else this.send(ws, "peerDown");
  }

  async webSocketClose(ws) {
    const a = ws.deserializeAttachment();
    const state = this.load();
    if (!a || !this.live(state)) return;
    if (a.pending && a.id === state.pending?.socket) {
      delete state.pending;
      this.save(state);
      this.send(this.peer(state, 1), "pendingGone");
    }
    const principal = a.role === 1 ? state.presenter : a.role === 2 ? state.remote : null;
    if (!principal || principal.socket !== a.id) return;
    delete principal.socket;
    principal.until = Math.min(state.expires, Date.now() + RECONNECT);
    this.save(state);
    this.send(this.peer(state, a.role === 1 ? 2 : 1), "peerDown");
    await this.schedule(state);
  }

  webSocketError(ws) { return this.webSocketClose(ws); }

  async alarm() {
    const state = this.load();
    if (!this.live(state)) {
      if (state) this.clearInvite(state);
      for (const ws of this.ctx.getWebSockets()) this.close(ws, "ended");
      await this.erase();
      return;
    }
    const now = Date.now();
    if (state.invite?.expires <= now) {
      this.clearInvite(state);
      this.send(this.peer(state, 1), "inviteMissing");
    }
    if (state.remote?.until <= now) {
      this.close(this.ctx.getWebSockets().find(ws => ws.deserializeAttachment()?.id === state.remote.socket), "revoked");
      delete state.remote;
      this.send(this.peer(state, 1), "reset");
    }
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a?.role === 0 && !a.pending && a.deadline <= now) this.close(ws);
    }
    this.save(state);
    await this.schedule(state);
  }
}
