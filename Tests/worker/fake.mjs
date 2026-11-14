// A minimal Durable Object host: SQLite storage, one alarm, hibernatable sockets and RPC stubs.
import { DatabaseSync } from "node:sqlite";

class Storage {
  constructor() {
    this.db = new DatabaseSync(":memory:");
    this.alarm = null;
    this.sql = {
      exec: (query, ...bindings) => {
        const rows = this.db.prepare(query).all(...bindings).map(row => ({ ...row }));
        return { toArray: () => rows, one: () => {
          if (rows.length !== 1) throw new Error(`expected one row, got ${rows.length}`);
          return rows[0];
        } };
      },
    };
  }
  async setAlarm(time) { this.alarm = time; }
  async deleteAlarm() { this.alarm = null; }
  async getAlarm() { return this.alarm; }
  // Like SQLite-backed Durable Objects, deleteAll drops every table and the alarm.
  async deleteAll() {
    const tables = this.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all();
    for (const { name } of tables) this.db.exec(`DROP TABLE "${name}"`);
    this.alarm = null;
  }
}

export class Socket {
  constructor(attachment) {
    this.readyState = 1;
    this.attachment = structuredClone(attachment);
    this.sent = [];
    this.closed = null;
  }
  serializeAttachment(value) { this.attachment = structuredClone(value); }
  deserializeAttachment() { return structuredClone(this.attachment); }
  send(text) { this.sent.push(JSON.parse(text)); }
  close(code, reason) { this.readyState = 3; this.closed = { code, reason }; }
  types() { return this.sent.map(m => m.type); }
}

export function host(classes) {
  const instances = new Map();
  const pending = [];
  const exports = {};
  for (const [name, Class] of Object.entries(classes)) {
    exports[name] = {
      getByName(key) {
        const id = `${name}:${key}`;
        if (!instances.has(id)) {
          const sockets = [];
          const ctx = {
            storage: new Storage(), exports,
            getWebSockets: () => sockets.filter(ws => ws.readyState !== 3),
            acceptWebSocket: ws => sockets.push(ws),
            waitUntil: promise => pending.push(promise),
          };
          instances.set(id, new Class(ctx, {}));
        }
        return instances.get(id);
      },
    };
  }
  return { exports, settle: () => Promise.all(pending.splice(0)) };
}
