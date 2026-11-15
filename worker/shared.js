// Constants and helpers shared by the Worker entry and the Durable Objects.
export const MINUTE = 60_000;
export const SESSION = 120 * MINUTE;
export const INVITE = 2 * MINUTE;
export const RECONNECT = 10 * MINUTE;
export const AUTH_WAIT = 10_000;
export const headers = { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" };
export const json = (body, status = 200) => Response.json(body, { headers, status });
export const invalid = () => json({ error: "unavailable" }, 404);
export const random = (size = 32) => crypto.getRandomValues(new Uint8Array(size)).toHex();
export const digest = async value => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).toHex();
export const matches = (actual, saved) => typeof saved === "string" &&
  crypto.subtle.timingSafeEqual(Uint8Array.fromHex(actual), Uint8Array.fromHex(saved));
export const credential = (id, role, key) => digest(`${id}:${role}:${key}`);
export const loopback = hostname => ["localhost", "127.0.0.1", "[::1]"].includes(hostname);
export const object = (ctx, id) => ctx.exports.SessionObject.getByName(id);
export const shard = (ctx, hash) => ctx.exports.CodeShard.getByName(hash.slice(0, 3));
