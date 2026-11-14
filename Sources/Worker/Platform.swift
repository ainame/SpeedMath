import JavaScriptKit
import ProtocolModels
import RemoteProtocol

/// Workers runtime access. Untrusted values are always read optionally: a trap would kill the
/// Wasm instance that the whole isolate shares. Every asynchronous call returns a `Deferred`.
enum Platform {
  static func now() -> Double {
    guard let date = JS.global.Date.object else { return 0 }
    return JS.call(date, "now").number ?? 0
  }

  // MARK: Responses

  static func headerObject() -> JSObject {
    let object = JS.object()
    object["Cache-Control"] = "no-store".jsValue
    object["Referrer-Policy"] = "no-referrer".jsValue
    return object
  }

  static func json(_ body: JSObject, status: Int = 200) -> JSValue {
    let options = JS.object()
    options["headers"] = headerObject().jsValue
    options["status"] = status.jsValue
    guard let response = JS.global.Response.object else { return .undefined }
    return JS.call(response, "json", body.jsValue, options.jsValue)
  }

  static func error(_ text: String, status: Int) -> JSValue {
    let body = JS.object()
    body["error"] = text.jsValue
    return json(body, status: status)
  }

  /// One response for every invalid or unknown input, so callers cannot probe what exists.
  static func invalid() -> JSValue { error("unavailable", status: 404) }

  static func upgrade(_ client: JSObject) -> JSValue {
    let options = JS.object()
    options["status"] = 101.jsValue
    options["webSocket"] = client.jsValue
    options["headers"] = headerObject().jsValue
    return JS.new("Response", .null, options.jsValue)?.jsValue ?? .undefined
  }

  // MARK: Storage

  static func exec(_ ctx: JSObject, _ query: String, _ bindings: JSValue...) -> [JSObject] {
    guard let sql = ctx.storage.object?.sql.object else { return [] }
    var arguments: [JSValue] = [query.jsValue]
    arguments.append(contentsOf: bindings)
    guard let cursor = sql["exec"].function?.callAsFunction(this: sql, arguments: arguments).object,
      let rows = JS.call(cursor, "toArray").object
    else { return [] }
    return list(rows.jsValue)
  }

  /// `ctx.storage.<method>(...)`, waited for (a failure is ignored, as the JS version did not catch it either).
  static func storage(_ ctx: JSObject, _ method: String, _ arguments: JSValue...) -> Deferred<Void> {
    guard let storage = ctx.storage.object,
      let result = storage[method].function?.callAsFunction(this: storage, arguments: arguments)
    else { return .value(()) }
    return Deferred.promise(result).map { _ in () }
  }

  /// Hands best-effort work to `ctx.waitUntil` without waiting for it.
  static func background(_ ctx: JSObject, _ value: JSValue) {
    guard let promise = value.object, let derived = JSPromises.chain(promise, { _ in }, {}) else { return }
    JS.call(ctx, "waitUntil", derived.jsValue)
  }

  // MARK: Durable Object stubs (RPC)

  static func session(_ ctx: JSObject, _ id: String) -> JSObject? {
    guard let namespace = ctx.exports.object?.SessionObject.object else { return nil }
    return JS.call(namespace, "getByName", id.jsValue).object
  }

  static func shard(_ ctx: JSObject, _ hash: String) -> JSObject? {
    guard let namespace = ctx.exports.object?.CodeShard.object else { return nil }
    return JS.call(namespace, "getByName", String(decoding: hash.utf8.prefix(3), as: UTF8.self).jsValue).object
  }

  /// Calls an RPC method on a stub and waits for its result (nil on failure).
  ///
  /// JavaScriptKit invokes functions as `fn.apply(this, args)`, but on a Workers RPC stub every
  /// property, `apply` included, names a remote method. `Reflect.apply` calls the function
  /// without reading that property.
  static func rpc(_ stub: JSObject?, _ method: String, _ arguments: JSValue...) -> Deferred<JSValue?> {
    guard let stub, let reflect = JS.global.Reflect.object, let list = JS.new("Array") else { return .value(nil) }
    let function = stub[method]
    guard function.object != nil else { return .value(nil) }
    for (i, argument) in arguments.enumerated() { list[i] = argument }
    return Deferred.promise(JS.call(reflect, "apply", function, stub.jsValue, list.jsValue))
  }

  // MARK: Values

  /// `sha256("<id>:<role>:<key>")`: a role credential is bound to its session and role.
  static func credential(_ id: String, _ role: Int, _ key: String) -> String {
    SHA256.hex(id + ":" + String(role) + ":" + key)
  }

  static func list(_ value: JSValue) -> [JSObject] {
    guard let array = value.object else { return [] }
    var out: [JSObject] = []
    for i in 0..<Int(array.length.number ?? 0) {
      if let item = array[i].object { out.append(item) }
    }
    return out
  }

  static func header(_ request: JSObject, _ name: String) -> String? {
    guard let headers = request.headers.object else { return nil }
    return JS.call(headers, "get", name.jsValue).string
  }
}
