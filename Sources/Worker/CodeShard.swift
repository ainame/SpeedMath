import JavaScriptKit
import RemoteProtocol

/// Index from a hashed pairing code to its session, sharded by the first three hex digits of the
/// hash. Rows hold only the hash, the session id, the invite generation and an expiry.
enum CodeShard {
  static func prepare(_ ctx: JSObject) {
    _ = Platform.exec(
      ctx, "CREATE TABLE IF NOT EXISTS codes (hash TEXT PRIMARY KEY, id TEXT, generation TEXT, expires INTEGER)")
  }

  /// Reserves `hash` for one session unless another live reservation holds it.
  static func reserve(_ ctx: JSObject, hash: String, id: String, generation: String, expires: Double) async -> Bool {
    prepare(ctx)
    _ = Platform.exec(ctx, "DELETE FROM codes WHERE expires <= ?", Platform.now().jsValue)
    let reserved =
      Platform.exec(
        ctx, "INSERT OR IGNORE INTO codes VALUES (?, ?, ?, ?) RETURNING hash",
        hash.jsValue, id.jsValue, generation.jsValue, expires.jsValue
      ).count == 1
    await schedule(ctx)
    return reserved
  }

  static func lookup(_ ctx: JSObject, hash: String) -> JSValue {
    prepare(ctx)
    let rows = Platform.exec(
      ctx, "SELECT id, generation FROM codes WHERE hash = ? AND expires > ?", hash.jsValue, Platform.now().jsValue)
    return rows.first?.jsValue ?? .undefined
  }

  /// Removes the row only if it still belongs to this session and generation.
  static func release(_ ctx: JSObject, hash: String, id: String, generation: String) async {
    prepare(ctx)
    _ = Platform.exec(
      ctx, "DELETE FROM codes WHERE hash = ? AND id = ? AND generation = ?",
      hash.jsValue, id.jsValue, generation.jsValue)
    return await schedule(ctx)
  }

  static func alarm(_ ctx: JSObject) async {
    prepare(ctx)
    _ = Platform.exec(ctx, "DELETE FROM codes WHERE expires <= ?", Platform.now().jsValue)
    return await schedule(ctx)
  }

  private static func schedule(_ ctx: JSObject) async {
    if let next = Platform.exec(ctx, "SELECT min(expires) AS expires FROM codes").first?.expires.number {
      return await Platform.storage(ctx, "setAlarm", next.jsValue)
    }
    return await Platform.storage(ctx, "deleteAlarm")
  }
}
