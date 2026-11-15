import { test, expect } from "@playwright/test";

const message = (type, fields = {}) => ({ v: 2, type, ...fields });
const P = process.env.SPEEDMATH_TEST_URL || "http://127.0.0.1:4178";

async function post(path, body, origin = P) {
  return fetch(P + "/api/" + path, {
    method: "POST", headers: { Origin: origin, "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
}

async function create() {
  const response = await post("session", message("create"));
  expect(response.status).toBe(200);
  return response.json();
}

async function socket(page, session, initial) {
  return page.evaluate(async ({ session, initial }) => {
    window.sockets ??= [];
    const url = new URL("/api/socket/" + session.id, location.origin);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(url);
    const trace = { ws, messages: [], close: null };
    ws.onmessage = e => trace.messages.push(JSON.parse(e.data));
    ws.onclose = e => { trace.close = e.code; };
    window.sockets.push(trace);
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    ws.send(JSON.stringify(initial));
    return window.sockets.length - 1;
  }, { session, initial });
}
const send = (page, i, body) => page.evaluate(({ i, body }) => window.sockets[i].ws.send(JSON.stringify(body)), { i, body });
const count = (page, i, type) => page.evaluate(({ i, type }) =>
  window.sockets[i].messages.filter(m => m.type === type).length, { i, type });
async function last(page, i, type, n = 1) {
  await expect.poll(() => count(page, i, type)).toBeGreaterThanOrEqual(n);
  return page.evaluate(({ i, type }) => window.sockets[i].messages.filter(m => m.type === type).at(-1), { i, type });
}
const wasClosed = (page, i) => expect.poll(() => page.evaluate(i => window.sockets[i].close, i)).toBe(4001);

test("Worker isolates two rooms, rejects invalid roles, and consumes both invitations", async ({ page }) => {
  await page.goto("/");
  expect(await (await fetch(P + "/api/health")).json()).toEqual({ version: 2 });
  const invalid = await fetch(P + "/api/unknown");
  expect(invalid.status).toBe(404);
  expect(await invalid.json()).toEqual({ error: "unavailable" });
  expect((await post("session", message("create"), "https://example.invalid")).status).toBe(404);
  expect((await post("session", message("create", { padding: "é".repeat(300) }))).status).toBe(404);
  const [a, b] = await Promise.all([create(), create()]);
  const pa = await socket(page, a, message("auth", { role: 1, key: a.key }));
  const pb = await socket(page, b, message("auth", { role: 1, key: b.key }));
  await last(page, pa, "connected");
  await last(page, pb, "connected");
  await send(page, pa, message("invite"));
  await send(page, pb, message("invite"));
  const [invite, otherInvite] = await Promise.all([last(page, pa, "invite"), last(page, pb, "invite")]);
  const otherRoomKey = await socket(page, a, message("auth", { role: 1, key: b.key }));
  await wasClosed(page, otherRoomKey);
  const wrongRole = await socket(page, a, message("auth", { role: 2, key: a.key }));
  await wasClosed(page, wrongRole);

  const remote = await socket(page, a, message("joinQR", { generation: invite.generation, key: invite.key }));
  const waiting = await last(page, remote, "waiting");
  const pending = await last(page, pa, "pending");
  expect(pending).toEqual({ ...waiting, type: "pending" });
  expect(await count(page, pb, "pending")).toBe(0);
  const rival = await socket(page, a, message("joinCode", { generation: invite.generation, key: invite.code }));
  await wasClosed(page, rival);
  expect(await count(page, remote, "sync")).toBe(0);
  await send(page, pa, message("reject", { request: pending.request }));
  await last(page, pa, "reset");
  await wasClosed(page, remote);
  await send(page, pa, message("invite"));
  const updated = await last(page, pa, "invite", 2);
  expect(updated.generation).not.toBe(invite.generation);
  const old = await socket(page, a, message("joinQR", { generation: invite.generation, key: invite.key }));
  await wasClosed(page, old);

  const approved = await socket(page, a, message("joinCode", { generation: updated.generation, key: updated.code }));
  const pending2 = await last(page, pa, "pending", 2);
  await send(page, pa, message("approve", { request: pending2.request }));
  const received = await last(page, approved, "approved");
  expect(received.key).toMatch(/^[0-9a-f]{64}$/);
  const replay = await socket(page, a, message("joinQR", { generation: updated.generation, key: updated.key }));
  await wasClosed(page, replay);

  const state = message("sync", {
    epoch: "1".repeat(32), deckVersion: "2".repeat(32),
    version: 1, screen: 2, index: 0, elapsed: 123, cards: [[1, 1, 2]], deck: 0, zero: 0, count: 45, timer: 1,
  });
  await send(page, pa, state);
  expect(await last(page, approved, "sync")).toEqual(state);
  expect(await count(page, pb, "sync")).toBe(0);
  const remoteB = await socket(page, b, message("joinQR", { generation: otherInvite.generation, key: otherInvite.key }));
  await last(page, remoteB, "waiting");
  await send(page, approved, state);
  await wasClosed(page, approved);
  const reconnected = await socket(page, a, message("auth", { role: 2, key: received.key }));
  await last(page, reconnected, "connected");
  await send(page, pa, message("revoke"));
  await last(page, pa, "reset", 2);
  await wasClosed(page, reconnected);
});
