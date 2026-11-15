import JavaScriptKit
import ProtocolModels

/// Untyped JavaScriptKit access for the JSON codecs (`RemoteWire`, `DailyStorage`), which read and
/// build fields of parsed JSON objects. Everything else goes through the typed BridgeJS bindings.
public enum JS {
  public static var global: JSObject { JSObject.global }

  public static func new(_ constructor: String, _ arguments: JSValue...) -> JSObject? {
    global[constructor].function?.new(arguments: arguments)
  }

  public static func object() -> JSObject { new("Object")! }

  public static func array() -> JSObject { new("Array")! }

  /// `JSON.parse`, or nil for malformed text (the exception is caught by BridgeJS).
  public static func parse(_ text: String) -> JSObject? {
    (try? json.parse(text))?.object
  }

  public static func stringify(_ value: JSObject) -> String {
    (try? json.stringify(value.jsValue)) ?? ""
  }

  /// Own enumerable property count, used to reject messages with unexpected fields.
  public static func keyCount(_ value: JSObject) -> Int {
    guard let object = global.Object.object,
      let keys = object["keys"].function?.callAsFunction(this: object, arguments: [value.jsValue]).object
    else { return -1 }
    return Int(keys.length.number ?? -1)
  }

  public static func isArray(_ value: JSObject) -> Bool {
    guard let array = global.Array.object else { return false }
    return array["isArray"].function?.callAsFunction(this: array, arguments: [value.jsValue]).boolean == true
  }

  /// Waits for a JS promise; `failure` runs on rejection or when `value` is not a promise.
  static func then(_ value: JSValue, _ success: @escaping (JSValue) -> Void, _ failure: @escaping () -> Void) {
    guard let promise = JSPromise(from: value) else { return failure() }
    promise.then(
      success: { success($0); return .undefined },
      failure: { _ in failure(); return .undefined })
  }
}
