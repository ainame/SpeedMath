import JavaScriptKit
import ProtocolModels

/// Thin JavaScriptKit wrappers used by the remote client. Calls that can throw in JS (JSON.parse,
/// sessionStorage) go through `window.speedMathBridge`, because a JS exception inside a
/// JavaScriptKit call would trap the whole app.
public enum JS {
  public static var global: JSObject { JSObject.global }

  @discardableResult
  public static func call(_ object: JSObject, _ name: String, _ arguments: JSValue...) -> JSValue {
    object[name].function?.callAsFunction(this: object, arguments: arguments) ?? .undefined
  }

  public static func new(_ constructor: String, _ arguments: JSValue...) -> JSObject? {
    global[constructor].function?.new(arguments: arguments)
  }

  public static func object() -> JSObject { new("Object")! }

  public static var bridge: JSObject? { global.speedMathBridge.object }

  /// `JSON.parse` that returns nil instead of throwing.
  public static func parse(_ text: String) -> JSObject? {
    guard let bridge else { return nil }
    return call(bridge, "parse", text.jsValue).object
  }

  public static func stringify(_ value: JSObject) -> String {
    guard let json = global.JSON.object else { return "" }
    return call(json, "stringify", value.jsValue).string ?? ""
  }

  /// Own enumerable property count, used to reject messages with unexpected fields.
  public static func keyCount(_ value: JSObject) -> Int {
    guard let object = global.Object.object, let keys = call(object, "keys", value.jsValue).object else { return -1 }
    return Int(keys.length.number ?? -1)
  }

  public static func isArray(_ value: JSObject) -> Bool {
    guard let array = global.Array.object else { return false }
    return call(array, "isArray", value.jsValue).boolean == true
  }

  public static func randomHex(bytes: Int) -> String {
    guard let crypto = global.crypto.object, let buffer = new("Uint8Array", bytes.jsValue) else { return "" }
    _ = call(crypto, "getRandomValues", buffer.jsValue)
    var out: [UInt8] = []
    for i in 0..<bytes { out.append(UInt8(buffer[i].number ?? 0)) }
    return Wire.hex(out)
  }

  /// Random pairing-code characters are drawn on the server; this is only for ids.
  public static var online: Bool { global.navigator.onLine.boolean ?? true }
  public static var hash: String { global.location.hash.string ?? "" }

  public static func sessionLoad(_ key: String) -> String? {
    guard let bridge else { return nil }
    return call(bridge, "sessionLoad", key.jsValue).string
  }

  public static func sessionSave(_ key: String, _ value: String?) {
    guard let bridge else { return }
    call(bridge, "sessionSave", key.jsValue, value?.jsValue ?? .null)
  }

  public static func qrDataURL(_ text: String) -> String? {
    guard let bridge else { return nil }
    return call(bridge, "qr", text.jsValue).string
  }
}

/// One restartable `setTimeout`. The JS closure lives until `release()`.
public final class JSTimer {
  private var closure: JSClosure?
  private var id: JSValue?
  private var action: (() -> Void)?

  public init() {}

  public func set(_ action: @escaping () -> Void) {
    self.action = action
  }

  public var isActive: Bool { id != nil }

  public func start(_ milliseconds: Double) {
    cancel()
    if closure == nil {
      closure = JSClosure { [self] _ in
        id = nil
        action?()
        return .undefined
      }
    }
    id = JS.call(JS.global, "setTimeout", closure!.jsValue, milliseconds.jsValue)
  }

  public func cancel() {
    if let id { JS.call(JS.global, "clearTimeout", id) }
    id = nil
  }

  /// Breaks the closure → timer → owner cycle.
  public func release() {
    cancel()
    closure?.release()
    closure = nil
    action = nil
  }
}

/// An `addEventListener` registration that can be removed and released.
public final class JSListener {
  private let target: JSObject
  private let type: String
  private var closure: JSClosure?

  public init(_ target: JSObject, _ type: String, _ handler: @escaping (JSObject?) -> Void) {
    self.target = target
    self.type = type
    let closure = JSClosure { arguments in
      handler(arguments.first?.object)
      return .undefined
    }
    self.closure = closure
    JS.call(target, "addEventListener", type.jsValue, closure.jsValue)
  }

  public func remove() {
    guard let closure else { return }
    JS.call(target, "removeEventListener", type.jsValue, closure.jsValue)
    closure.release()
    self.closure = nil
  }
}

public enum JSPromises {
  /// `promise.then(success, failure)`; both closures are released once either runs.
  public static func then(
    _ promise: JSObject, _ success: @escaping (JSValue) -> Void, _ failure: @escaping () -> Void
  ) {
    _ = chain(promise, success, failure)
  }

  /// Like `then`, returning the derived promise (which settles after the handler ran).
  @discardableResult
  public static func chain(
    _ promise: JSObject, _ success: @escaping (JSValue) -> Void, _ failure: @escaping () -> Void
  ) -> JSObject? {
    var ok: JSClosure?
    var fail: JSClosure?
    let finish = {
      ok?.release()
      fail?.release()
      ok = nil
      fail = nil
    }
    ok = JSClosure { arguments in
      finish()
      success(arguments.first ?? .undefined)
      return .undefined
    }
    fail = JSClosure { _ in
      finish()
      failure()
      return .undefined
    }
    return JS.call(promise, "then", ok!.jsValue, fail!.jsValue).object
  }

  /// A JS promise that `body` resolves by calling its argument exactly once.
  public static func make(_ body: (@escaping (JSValue) -> Void) -> Void) -> JSValue {
    var settle: ((JSValue) -> Void)?
    let promise = JSPromise { resolver in
      settle = { resolver(.success($0)) }
    }
    if let settle { body(settle) }
    return promise.jsValue
  }

  /// An already resolved promise.
  public static func resolved(_ value: JSValue = .undefined) -> JSValue {
    make { $0(value) }
  }
}
