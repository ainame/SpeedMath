// Run with: pnpm exec node --import ./Tests/worker/register.mjs --test Tests/worker/
// Requires worker/generated/logic.wasm (produced by `pnpm exec cf build`).
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { CodeShard, SessionObject } from "../../worker/index.js";
import { host, Socket } from "./fake.mjs";

const MINUTE = 60_000;
const realNow = Date.now;
let now;
beforeEach(() => { now = 1_800_000_000_000; Date.now = () => now; });
afterEach(() => { Date.now = realNow; });

const hex = (char, length = 32) => char.repeat(length);

// A session with its Presenter authenticated on one socket.
async function session(env = host({ CodeShard, SessionObject }), id = hex("a")) {
  const object = env.exports.SessionObject.getByName(id);
  await object.create(id, hex("0", 64));
  const presenter = new Socket({ id: hex("1"), role: 1 });
  object.ctx.acceptWebSocket(presenter);
  const state = object.load();
  state.presenter.socket = hex("1");
  state.presenter.until = state.expires;
  object.save(state);
  return { env, id, object, presenter };
}

test("a code shard keeps the first reservation of a hash and ignores a colliding one", async () => {
  const { exports } = host({ CodeShard, SessionObject });
  const shard = exports.CodeShard.getByName("abc");
  assert.equal(await shard.reserve("abc1", hex("a"), hex("1"), now + MINUTE), true);
  assert.equal(await shard.reserve("abc1", hex("b"), hex("2"), now + MINUTE), false);
  assert.deepEqual(shard.lookup("abc1"), { id: hex("a"), generation: hex("1") });
  // Releasing with the losing owner's identity must not remove the winner's row.
  await shard.release("abc1", hex("b"), hex("2"));
  assert.deepEqual(shard.lookup("abc1"), { id: hex("a"), generation: hex("1") });
  // Once expired, the same hash can be reserved again by someone else.
  now += MINUTE;
  assert.equal(shard.lookup("abc1"), undefined);
  assert.equal(await shard.reserve("abc1", hex("b"), hex("2"), now + MINUTE), true);
  assert.deepEqual(shard.lookup("abc1"), { id: hex("b"), generation: hex("2") });
});

test("an invite retries with a new code after a shard collision", async () => {
  const { env, object, presenter } = await session();
  const attempts = [];
  const original = CodeShard.prototype.reserve;
  CodeShard.prototype.reserve = async function (hash, ...rest) {
    attempts.push(hash);
    return attempts.length <= 2 ? false : original.call(this, hash, ...rest);
  };
  try {
    await object.invite(presenter, presenter.deserializeAttachment());
  } finally {
    CodeShard.prototype.reserve = original;
  }
  assert.equal(attempts.length, 3);
  assert.equal(new Set(attempts).size, 3, "each attempt draws a new code");
  const invite = presenter.sent.find(m => m.type === "invite");
  assert.ok(invite, "the Presenter receives the invite from the third attempt");
  const state = object.load();
  assert.equal(state.invite.generation, invite.generation);
  assert.equal(state.issuing, undefined);
  assert.equal(object.validLookup(attempts[2], invite.generation), true);
  assert.equal(object.validLookup(attempts[0], invite.generation), false);
  const entry = env.exports.CodeShard.getByName(attempts[2].slice(0, 3)).lookup(attempts[2]);
  assert.deepEqual(entry, { id: state.id, generation: invite.generation });
});

test("an invite gives up after five collisions without showing a code", async () => {
  const { object, presenter } = await session();
  const original = CodeShard.prototype.reserve;
  let attempts = 0;
  CodeShard.prototype.reserve = async () => { attempts++; return false; };
  try {
    await object.invite(presenter, presenter.deserializeAttachment());
  } finally {
    CodeShard.prototype.reserve = original;
  }
  assert.equal(attempts, 5);
  assert.deepEqual(presenter.types(), ["inviteMissing"]);
  assert.equal(object.load().invite, undefined);
});

test("expired invite alarms release the code once and can run again", async () => {
  const { env, object, presenter } = await session();
  await object.invite(presenter, presenter.deserializeAttachment());
  const invite = presenter.sent.find(m => m.type === "invite");
  const { codeHash } = object.load().invite;
  const shard = env.exports.CodeShard.getByName(codeHash.slice(0, 3));
  assert.equal(object.ctx.storage.alarm, now + 2 * MINUTE);

  now += 2 * MINUTE;
  await object.alarm();
  await env.settle();
  await object.alarm(); // a retried or duplicate delivery
  await env.settle();
  assert.equal(presenter.sent.filter(m => m.type === "inviteMissing").length, 1);
  assert.equal(object.load().invite, undefined);
  assert.equal(shard.lookup(codeHash), undefined);
  assert.ok(!object.validLookup(codeHash, invite.generation));
  assert.equal(presenter.readyState, 1, "the Presenter stays connected");
  assert.equal(object.ctx.storage.alarm, object.load().expires);
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
  assert.deepEqual(shard.sql.exec("SELECT hash FROM codes").toArray(), [{ hash: "abc2" }]);
  assert.equal(shard.ctx.storage.alarm, now + MINUTE);
  now += MINUTE;
  await shard.alarm();
  await shard.alarm();
  assert.deepEqual(shard.sql.exec("SELECT hash FROM codes").toArray(), []);
  assert.equal(shard.ctx.storage.alarm, null);
});

test("unauthenticated sockets are closed by the alarm after their deadline", async () => {
  const { object, presenter } = await session();
  const stranger = new Socket({ id: hex("2"), role: 0, deadline: now + 10_000 });
  object.ctx.acceptWebSocket(stranger);
  await object.schedule(object.load());
  assert.equal(object.ctx.storage.alarm, now + 10_000);
  now += 10_000;
  await object.alarm();
  await object.alarm();
  assert.deepEqual(stranger.closed, { code: 4001, reason: "unavailable" });
  assert.equal(presenter.readyState, 1);
  assert.equal(object.ctx.storage.alarm, object.load().expires);
});

test("a disconnected Remote is revoked by the alarm once its reconnect window passes", async () => {
  const { object, presenter } = await session();
  const state = object.load();
  state.remote = { hash: hex("9", 64), until: now + 10 * MINUTE };
  object.save(state);
  now += 10 * MINUTE;
  await object.alarm();
  await object.alarm();
  assert.equal(object.load().remote, undefined);
  assert.equal(presenter.sent.filter(m => m.type === "reset").length, 1);
});

test("session expiry closes sockets, deletes storage, and tolerates repeated alarms and late calls", async () => {
  const { env, object, presenter } = await session();
  await object.invite(presenter, presenter.deserializeAttachment());
  const invite = presenter.sent.find(m => m.type === "invite");
  const { codeHash } = object.load().invite;
  const remote = new Socket({ id: hex("3"), role: 2 });
  object.ctx.acceptWebSocket(remote);

  now = object.load().expires;
  await object.alarm();
  await env.settle();
  assert.deepEqual(presenter.closed, { code: 4001, reason: "ended" });
  assert.deepEqual(remote.closed, { code: 4001, reason: "ended" });
  assert.equal(object.ctx.storage.alarm, null);
  assert.equal(env.exports.CodeShard.getByName(codeHash.slice(0, 3)).lookup(codeHash), undefined);

  // The same instance may still receive a duplicate alarm, a stale lookup or a reconnect.
  await object.alarm();
  assert.equal(object.load(), null);
  assert.ok(!object.validLookup(codeHash, invite.generation));
  const response = await object.fetch();
  assert.equal(response.status, 404);
  // A new session id is unrelated; creating on an emptied object still works.
  await object.create(hex("a"), hex("0", 64));
  assert.ok(object.load());
});

test("ending a session from the Presenter leaves the object usable for late calls", async () => {
  const { object, presenter } = await session();
  await object.webSocketMessage(presenter, JSON.stringify({ v: 2, type: "end" }));
  assert.deepEqual(presenter.closed, { code: 4001, reason: "ended" });
  assert.equal(object.load(), null);
  await object.alarm();
  assert.equal((await object.fetch()).status, 404);
});
