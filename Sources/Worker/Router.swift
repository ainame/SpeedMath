import JavaScriptKit
import ProtocolModels
import RemoteProtocol

/// The Worker's `fetch` for `/api/*` (static assets are served before the Worker runs).
enum Router {
  static func fetch(_ request: JSObject, env: JSObject, ctx: JSObject) -> Deferred<JSValue> {
    guard let href = request.url.string, let url = JS.new("URL", href.jsValue) else {
      return .value(Platform.invalid())
    }
    let path = url.pathname.string ?? ""
    let method = request.method.string ?? ""
    if path == "/api/health" && method == "GET" {
      let body = JS.object()
      body["version"] = Wire.version.jsValue
      return .value(Platform.json(body))
    }
    let hostname = url.hostname.string ?? ""
    let loopback = hostname == "localhost" || hostname == "127.0.0.1" || hostname == "[::1]"
    guard env.REMOTE_ENABLED.boolean == true, (url.search.string ?? "").isEmpty,
      url["protocol"].string == "https:" || loopback,
      let origin = Platform.header(request, "Origin"), origin == url.origin.string
    else { return .value(Platform.invalid()) }
    let client = Platform.header(request, "CF-Connecting-IP") ?? "local"

    if method == "POST" && path == "/api/session" {
      return limited(env, "CREATES", client) { createSession(request, ctx: ctx) }
    }
    if method == "POST" && path == "/api/lookup" {
      return limited(env, "LOOKUPS", client) { lookup(request, ctx: ctx) }
    }
    let socketPrefix = "/api/socket/"
    if method == "GET", path.utf8.starts(with: socketPrefix.utf8),
      Platform.header(request, "Upgrade").map(lowercased) == "websocket"
    {
      let id = String(decoding: path.utf8.dropFirst(socketPrefix.utf8.count), as: UTF8.self)
      guard Wire.isID(id) else { return .value(Platform.invalid()) }
      return limited(env, "CONNECTIONS", client) { connect(request, id: id, ctx: ctx) }
    }
    return .value(Platform.invalid())
  }

  /// Runs `next` unless the per-client rate limiter refuses the request.
  private static func limited(
    _ env: JSObject, _ binding: String, _ client: String, _ next: @escaping () -> Deferred<JSValue>
  ) -> Deferred<JSValue> {
    let options = JS.object()
    options["key"] = client.jsValue
    return Platform.rpc(env[binding].object, "limit", options.jsValue).then { result in
      guard result?.object?.success.boolean == true else { return .value(Platform.error("slow", status: 429)) }
      return next()
    }
  }

  private static func createSession(_ request: JSObject, ctx: JSObject) -> Deferred<JSValue> {
    readControl(request).then { message in
      guard let message, message.type.string == "create", JS.keyCount(message) == 2 else {
        return .value(Platform.invalid())
      }
      let id = JS.randomHex(bytes: 16)
      let secret = JS.randomHex(bytes: 32)
      let hash = Platform.credential(id, 1, secret)
      return Platform.rpc(Platform.session(ctx, id), "create", id.jsValue, hash.jsValue).map { _ in
        let body = JS.object()
        body["id"] = id.jsValue
        body["key"] = secret.jsValue
        return Platform.json(body)
      }
    }
  }

  private static func lookup(_ request: JSObject, ctx: JSObject) -> Deferred<JSValue> {
    readControl(request).then { message in
      guard let message, message.type.string == "lookup",
        let code = message.code.string.flatMap(Wire.normalizeCode)
      else { return .value(Platform.invalid()) }
      let hash = SHA256.hex(code)
      return Platform.rpc(Platform.shard(ctx, hash), "lookup", hash.jsValue).then { entry in
        guard let entry = entry?.object, let id = entry.id.string, let generation = entry.generation.string else {
          return .value(Platform.invalid())
        }
        return Platform.rpc(Platform.session(ctx, id), "validLookup", hash.jsValue, generation.jsValue).map { valid in
          guard valid?.boolean == true else { return Platform.invalid() }
          let body = JS.object()
          body["id"] = id.jsValue
          body["generation"] = generation.jsValue
          return Platform.json(body)
        }
      }
    }
  }

  private static func connect(_ request: JSObject, id: String, ctx: JSObject) -> Deferred<JSValue> {
    let headers = JS.object()
    headers["Upgrade"] = "websocket".jsValue
    let options = JS.object()
    options["headers"] = headers.jsValue
    guard let href = request.url.string, let forwarded = JS.new("Request", href.jsValue, options.jsValue) else {
      return .value(Platform.invalid())
    }
    return Platform.rpc(Platform.session(ctx, id), "fetch", forwarded.jsValue).map { $0 ?? Platform.invalid() }
  }

  /// Reads a small JSON control body (at most `Wire.controlLimit` bytes of valid UTF-8).
  private static func readControl(_ request: JSObject) -> Deferred<JSObject?> {
    guard let body = request.body.object,
      Platform.header(request, "Content-Type")?.utf8.starts(with: "application/json".utf8) == true,
      let reader = JS.call(body, "getReader").object
    else { return .value(nil) }
    return readChunks(reader, into: [])
  }

  /// The body read loop (`for await chunk of body`), one chunk per step.
  private static func readChunks(_ reader: JSObject, into bytes: [UInt8]) -> Deferred<JSObject?> {
    Deferred.promise(JS.call(reader, "read")).then { result -> Deferred<JSObject?> in
      guard let result = result?.object else { return .value(nil) }
      if result.done.boolean == true {
        guard let text = String(validating: bytes, as: UTF8.self) else { return .value(nil) }
        return .value(RemoteWire.frame(text.jsValue))
      }
      guard let chunk = result.value.object else { return .value(nil) }
      let length = Int(chunk.length.number ?? 0)
      guard bytes.count + length <= Wire.controlLimit else {
        JS.call(reader, "cancel")
        return .value(nil)
      }
      var next = bytes
      for i in 0..<length { next.append(UInt8(chunk[i].number ?? 0)) }
      return readChunks(reader, into: next)
    }
  }

  private static func lowercased(_ text: String) -> String {
    String(decoding: text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
  }
}
