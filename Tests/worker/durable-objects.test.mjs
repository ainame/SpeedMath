// Runs the built Worker bundle (the JS shell plus the Swift Worker Wasm) against a fake Durable
// Object host. Build first with `pnpm exec cf build --mode staging`; then `pnpm run test:worker`.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { host, Socket } from "./fake.mjs";

const { CodeShard, SessionObject } = await import("../../.cloudflare/output/v0/workers/default/bundle/index.js");

const MINUTE = 60_000;
const realNow = Date.now;
let now;
beforeEach(() => { now = 1_800_000_000_000; Date.now = () => now; });
afterEach(() => { Date.now = realNow; });

const hex = (char, length = 32) => char.repeat(length);
const sha = text => createHash("sha256").update(text).digest("hex");
const packet = (type, fields = {}) => JSON.stringify({ v: 1, type, ...fields });
const state = object => {
  const row = object.ctx.storage.sql.exec("SELECT state FROM session WHERE singleton = 1").toArray()[0];
  return row ? JSON.parse(row.state) : null;
};
const writeState = (object, value) =>
  object.ctx.storage.sql.exec("INSERT OR REPLACE INTO session VALUES (1, ?)", JSON.stringify(value));

// A session whose Presenter authenticated on one socket with a real role credential.
async function session(env = host({ CodeShard, SessionObject }), id = hex("a")) {
  const key = hex("b", 64);
  const object = env.exports.SessionObject.getByName(id);
  await object.create(id, sha(`${id}:1:${key}`));
  const presenter = new Socket({ id: hex("1"), role: 0, deadline: now + 10_000 });
  object.ctx.acceptWebSocket(presenter);
  await object.webSocketMessage(presenter, packet("auth", { role: 1, key }));
  assert.deepEqual(presenter.types(), ["connected"]);
  presenter.sent.length = 0;
  return { env, id, object, presenter };
}

async function withReserve(replacement, body) {
  const original = CodeShard.prototype.reserve;
  CodeShard.prototype.reserve = replacement(original);
  try { await body(); } finally { CodeShard.prototype.reserve = original; }
}

test("a code shard keeps the first reservation of a hash and ignores a colliding one", async () => {
  const { exports } = host({ CodeShard, SessionObject });
  const shard = exports.CodeShard.getByName("abc");
  assert.equal(await shard.reserve("abc1", hex("a"), hex("1"), now + MINUTE), true);
  assert.equal(await shard.reserve("abc1", hex("b"), hex("2"), now + MINUTE), false);
  assert.deepEqual({ ...(await shard.lookup("abc1")) }, { id: hex("a"), generation: hex("1") });
  // Releasing with the losing owner's identity must not remove the winner's row.
  await shard.release("abc1", hex("b"), hex("2"));
  assert.deepEqual({ ...(await shard.lookup("abc1")) }, { id: hex("a"), generation: hex("1") });
  // Once expired, the same hash can be reserved again by someone else.
  now += MINUTE;
  assert.equal(await shard.lookup("abc1"), undefined);
  assert.equal(await shard.reserve("abc1", hex("b"), hex("2"), now + MINUTE), true);
  assert.deepEqual({ ...(await shard.lookup("abc1")) }, { id: hex("b"), generation: hex("2") });
});

test("an invite retries with a new code after a shard collision", async () => {
  const { env, object, presenter } = await session();
  const attempts = [];
  await withReserve(original => async function (hash, ...rest) {
    attempts.push(hash);
    return attempts.length <= 2 ? false : original.call(this, hash, ...rest);
  }, () => object.webSocketMessage(presenter, packet("invite")));
  assert.equal(attempts.length, 3);
  assert.equal(new Set(attempts).size, 3, "each attempt draws a new code");
  const invite = presenter.sent.find(m => m.type === "invite");
  assert.ok(invite, "the Presenter receives the invite from the third attempt");
  assert.equal(sha(invite.code), attempts[2]);
  const saved = state(object);
  assert.equal(saved.invite.generation, invite.generation);
  assert.equal(saved.issuing, undefined);
  assert.equal(await object.validLookup(attempts[2], invite.generation), true);
  assert.equal(await object.validLookup(attempts[0], invite.generation), false);
  const entry = await env.exports.CodeShard.getByName(attempts[2].slice(0, 3)).lookup(attempts[2]);
  assert.deepEqual({ ...entry }, { id: saved.id, generation: invite.generation });
});

test("an invite gives up after five collisions without showing a code", async () => {
  const { object, presenter } = await session();
  let attempts = 0;
  await withReserve(() => async () => { attempts++; return false; },
    () => object.webSocketMessage(presenter, packet("invite")));
  assert.equal(attempts, 5);
  assert.deepEqual(presenter.types(), ["inviteMissing"]);
  assert.equal(state(object).invite, undefined);
});

test("expired invite alarms release the code once and can run again", async () => {
  const { env, object, presenter } = await session();
  await object.webSocketMessage(presenter, packet("invite"));
  const invite = presenter.sent.find(m => m.type === "invite");
  const { codeHash } = state(object).invite;
  const shard = env.exports.CodeShard.getByName(codeHash.slice(0, 3));
  assert.equal(object.ctx.storage.alarm, now + 2 * MINUTE);

  now += 2 * MINUTE;
  await object.alarm();
  await env.settle();
  await object.alarm(); // a retried or duplicate delivery
  await env.settle();
  assert.equal(presenter.sent.filter(m => m.type === "inviteMissing").length, 1);
  assert.equal(state(object).invite, undefined);
  assert.equal(await shard.lookup(codeHash), undefined);
  assert.equal(await object.validLookup(codeHash, invite.generation), false);
  assert.equal(presenter.readyState, 1, "the Presenter stays connected");
  assert.equal(object.ctx.storage.alarm, state(object).expires);
});

test("code shard alarms delete only expired rows, reschedule, and are safe to repeat", async () => {
  const { exports } = host({ CodeShard, SessionObject });
  const shard = exports.CodeShard.getByName("abc");
  await shard.reserve("abc1", hex("a"), hex("1"), now + MINUTE);
  await shard.reserve("abc2", hex("b"), hex("2"), now + 2 * MINUTE);
  assert.equal(shard.ctx.storage.alarm, now + MINUTE);
  now += MINUTE;
  await shard.alarm();
  await shard.alarm();
  assert.deepEqual(shard.ctx.storage.sql.exec("SELECT hash FROM codes").toArray(), [{ hash: "abc2" }]);
  assert.equal(shard.ctx.storage.alarm, now + MINUTE);
  now += MINUTE;
  await shard.alarm();
  await shard.alarm();
  assert.deepEqual(shard.ctx.storage.sql.exec("SELECT hash FROM codes").toArray(), []);
  assert.equal(shard.ctx.storage.alarm, null);
});

test("unauthenticated sockets are closed by the alarm after their deadline", async () => {
  const { object, presenter } = await session();
  const stranger = new Socket({ id: hex("2"), role: 0, deadline: now + 10_000 });
  object.ctx.acceptWebSocket(stranger);
  await object.alarm(); // nothing is due yet; the next alarm follows the stranger's deadline
  assert.equal(object.ctx.storage.alarm, now + 10_000);
  now += 10_000;
  await object.alarm();
  await object.alarm();
  assert.deepEqual(stranger.closed, { code: 4001, reason: "unavailable" });
  assert.equal(presenter.readyState, 1);
  assert.equal(object.ctx.storage.alarm, state(object).expires);
});

test("a disconnected Remote is revoked by the alarm once its reconnect window passes", async () => {
  const { object, presenter } = await session();
  writeState(object, { ...state(object), remote: { hash: hex("9", 64), until: now + 10 * MINUTE } });
  now += 10 * MINUTE;
  await object.alarm();
  await object.alarm();
  assert.equal(state(object).remote, undefined);
  assert.equal(presenter.sent.filter(m => m.type === "reset").length, 1);
});

test("session expiry closes sockets, deletes storage, and tolerates repeated alarms and late calls", async () => {
  const { env, object, presenter } = await session();
  await object.webSocketMessage(presenter, packet("invite"));
  const invite = presenter.sent.find(m => m.type === "invite");
  const { codeHash } = state(object).invite;
  const remote = new Socket({ id: hex("3"), role: 2 });
  object.ctx.acceptWebSocket(remote);

  now = state(object).expires;
  await object.alarm();
  await env.settle();
  assert.deepEqual(presenter.closed, { code: 4001, reason: "ended" });
  assert.deepEqual(remote.closed, { code: 4001, reason: "ended" });
  assert.equal(object.ctx.storage.alarm, null);
  assert.equal(await env.exports.CodeShard.getByName(codeHash.slice(0, 3)).lookup(codeHash), undefined);

  // The same instance may still receive a duplicate alarm, a stale lookup or a reconnect.
  await object.alarm();
  assert.equal(state(object), null);
  assert.equal(await object.validLookup(codeHash, invite.generation), false);
  assert.equal((await object.fetch()).status, 404);
  // Creating on an emptied object still works.
  await object.create(hex("a"), hex("0", 64));
  assert.ok(state(object));
});

test("ending a session from the Presenter leaves the object usable for late calls", async () => {
  const { object, presenter } = await session();
  await object.webSocketMessage(presenter, packet("end"));
  assert.deepEqual(presenter.closed, { code: 4001, reason: "ended" });
  assert.equal(state(object), null);
  await object.alarm();
  assert.equal((await object.fetch()).status, 404);
});

test("a frame over the size limit or with the wrong version closes the socket", async () => {
  const { object, presenter } = await session();
  const other = new Socket({ id: hex("4"), role: 0, deadline: now + 10_000 });
  object.ctx.acceptWebSocket(other);
  await object.webSocketMessage(other, JSON.stringify({ v: 2, type: "auth", role: 1, key: hex("b", 64) }));
  assert.deepEqual(other.closed, { code: 4001, reason: "unavailable" });
  await object.webSocketMessage(presenter, packet("sync", { padding: "x".repeat(9000) }));
  assert.deepEqual(presenter.closed, { code: 4001, reason: "unavailable" });
});
