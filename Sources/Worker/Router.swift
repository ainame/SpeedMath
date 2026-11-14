import JavaScriptKit
import ProtocolModels
import RemoteProtocol

/// The Worker's `fetch` for `/api/*` (static assets are served before the Worker runs).
enum Router {
  static func fetch(_ request: JSObject, env: JSObject, ctx: JSObject) async -> JSValue {
    guard let href = request.url.string, let url = JS.new("URL", href.jsValue) else {
      return Platform.invalid()
    }
    let path = url.pathname.string ?? ""
    let method = request.method.string ?? ""
    if path == "/api/health" && method == "GET" {
      let body = JS.object()
      body["version"] = Wire.version.jsValue
      return Platform.json(body)
    }
    let hostname = url.hostname.string ?? ""
    let loopback = hostname == "localhost" || hostname == "127.0.0.1" || hostname == "[::1]"
    guard env.REMOTE_ENABLED.boolean == true, (url.search.string ?? "").isEmpty,
      url["protocol"].string == "https:" || loopback,
      let origin = Platform.header(request, "Origin"), origin == url.origin.string
    else { return Platform.invalid() }
    let client = Platform.header(request, "CF-Connecting-IP") ?? "local"

    if method == "POST" && path == "/api/session" {
      return await limited(env, "CREATES", client) { await createSession(request, ctx: ctx) }
    }
    if method == "POST" && path == "/api/lookup" {
      return await limited(env, "LOOKUPS", client) { await lookup(request, ctx: ctx) }
    }
    let socketPrefix = "/api/socket/"
    if method == "GET", path.utf8.starts(with: socketPrefix.utf8),
      Platform.header(request, "Upgrade").map(lowercased) == "websocket"
    {
      let id = String(decoding: path.utf8.dropFirst(socketPrefix.utf8.count), as: UTF8.self)
      guard Wire.isID(id) else { return Platform.invalid() }
      return await limited(env, "CONNECTIONS", client) { await connect(request, id: id, ctx: ctx) }
    }
    return Platform.invalid()
  }

  /// Runs `next` unless the per-client rate limiter refuses the request.
  private static func limited(
    _ env: JSObject, _ binding: String, _ client: String, _ next: () async -> JSValue
  ) async -> JSValue {
    let options = JS.object()
    options["key"] = client.jsValue
    let result = await Platform.rpc(env[binding].object, "limit", options.jsValue)
    guard result?.object?.success.boolean == true else { return Platform.error("slow", status: 429) }
    return await next()
  }

  private static func createSession(_ request: JSObject, ctx: JSObject) async -> JSValue {
    guard let message = await readControl(request), message.type.string == "create", JS.keyCount(message) == 2 else {
      return Platform.invalid()
    }
    let id = JS.randomHex(bytes: 16)
    let secret = JS.randomHex(bytes: 32)
    let hash = Platform.credential(id, 1, secret)
    _ = await Platform.rpc(Platform.session(ctx, id), "create", id.jsValue, hash.jsValue)
    let body = JS.object()
    body["id"] = id.jsValue
    body["key"] = secret.jsValue
    return Platform.json(body)
  }

  private static func lookup(_ request: JSObject, ctx: JSObject) async -> JSValue {
    guard let message = await readControl(request), message.type.string == "lookup",
      let code = message.code.string.flatMap(Wire.normalizeCode)
    else { return Platform.invalid() }
    let hash = SHA256.hex(code)
    guard let entry = await Platform.rpc(Platform.shard(ctx, hash), "lookup", hash.jsValue)?.object,
      let id = entry.id.string, let generation = entry.generation.string,
      await Platform.rpc(Platform.session(ctx, id), "validLookup", hash.jsValue, generation.jsValue)?.boolean == true
    else { return Platform.invalid() }
    let body = JS.object()
    body["id"] = id.jsValue
    body["generation"] = generation.jsValue
    return Platform.json(body)
  }

  private static func connect(_ request: JSObject, id: String, ctx: JSObject) async -> JSValue {
    let headers = JS.object()
    headers["Upgrade"] = "websocket".jsValue
    let options = JS.object()
    options["headers"] = headers.jsValue
    guard let href = request.url.string, let forwarded = JS.new("Request", href.jsValue, options.jsValue) else {
      return Platform.invalid()
    }
    return await Platform.rpc(Platform.session(ctx, id), "fetch", forwarded.jsValue) ?? Platform.invalid()
  }

  /// Reads a small JSON control body (at most `Wire.controlLimit` bytes of valid UTF-8).
  private static func readControl(_ request: JSObject) async -> JSObject? {
    guard let body = request.body.object,
      Platform.header(request, "Content-Type")?.utf8.starts(with: "application/json".utf8) == true,
      let reader = JS.call(body, "getReader").object
    else { return nil }
    var bytes: [UInt8] = []
    while true {
      guard let result = await Platform.resolve(JS.call(reader, "read"))?.object else { return nil }
      if result.done.boolean == true { break }
      guard let chunk = result.value.object else { return nil }
      let length = Int(chunk.length.number ?? 0)
      guard bytes.count + length <= Wire.controlLimit else {
        JS.call(reader, "cancel")
        return nil
      }
      for i in 0..<length { bytes.append(UInt8(chunk[i].number ?? 0)) }
    }
    guard let text = String(validating: bytes, as: UTF8.self) else { return nil }
    return RemoteWire.frame(text.jsValue)
  }

  private static func lowercased(_ text: String) -> String {
    String(decoding: text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
  }
}
