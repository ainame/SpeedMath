// Index from a hashed pairing code to its session, sharded by the first three hex digits.
import { DurableObject } from "cloudflare:workers";

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
