import JavaScriptKit

/// A value that becomes available later: the Worker's stand-in for `async`/`await`.
///
/// Embedded Swift cannot run Swift concurrency jobs inside a Cloudflare Worker (checked with
/// Swift 6.4.0 and 6.4.2: a `Task` never starts), and the regular Wasm runtime is too heavy for
/// the Workers Free plan's 10 ms CPU budget. So asynchronous steps return a `Deferred` instead.
///
/// It is shaped so that moving back to `async`/`await` is mechanical:
///
/// | Deferred                               | async/await                          |
/// | -------------------------------------- | ------------------------------------ |
/// | `func f() -> Deferred<T>`              | `func f() async -> T`                |
/// | `return .value(x)`                     | `return x`                           |
/// | `f().then { x in g(x) }`               | `let x = await f(); return await g(x)` |
/// | `f().map { x in h(x) }`                | `let x = await f(); return h(x)`     |
/// | `Deferred.promise(jsValue)`            | `try? await JSPromise(jsValue)!.value` |
/// | `deferred.jsPromise` at an export      | `JSPromise.async { await ... }`      |
///
/// Every code path must return a `Deferred`, so the compiler rejects a branch that would
/// otherwise never answer (which a raw callback API cannot catch, and which the Workers
/// runtime reports as a hung request).
public final class Deferred<Value> {
  private var done = false
  private var stored: Value?
  private var callbacks: [(Value) -> Void] = []

  /// Starts work that calls `resolve` once; later calls are ignored.
  public init(_ start: (@escaping (Value) -> Void) -> Void) {
    start { [self] value in resolve(value) }
  }

  private init(resolved value: Value) {
    done = true
    stored = value
  }

  /// An already available value (`return x` in an async function).
  public static func value(_ value: Value) -> Deferred<Value> { Deferred(resolved: value) }

  private func resolve(_ value: Value) {
    guard !done else { return }
    done = true
    stored = value
    let pending = callbacks
    callbacks.removeAll()
    for callback in pending { callback(value) }
  }

  /// Calls `body` with the value once it is available (immediately if it already is).
  public func whenDone(_ body: @escaping (Value) -> Void) {
    if done, let stored { body(stored) } else { callbacks.append(body) }
  }

  /// The next asynchronous step (`let x = await self; return await next(x)`).
  public func then<Next>(_ next: @escaping (Value) -> Deferred<Next>) -> Deferred<Next> {
    Deferred<Next> { resolve in whenDone { value in next(value).whenDone(resolve) } }
  }

  /// A synchronous transformation (`let x = await self; return transform(x)`).
  public func map<Next>(_ transform: @escaping (Value) -> Next) -> Deferred<Next> {
    then { .value(transform($0)) }
  }
}

extension Deferred where Value == JSValue? {
  /// Waits for a JS value that may be a promise. A rejected promise becomes nil.
  ///
  /// Like JS `await`, any object goes through `Promise.resolve`, so thenables that are not plain
  /// promises (Workers RPC results are lazy proxies) are awaited too.
  public static func promise(_ value: JSValue) -> Deferred<JSValue?> {
    guard value.object != nil, let promiseClass = JS.global.Promise.object,
      let promise = JS.call(promiseClass, "resolve", value).object
    else { return .value(value) }
    return Deferred { resolve in JSPromises.then(promise, { resolve($0) }, { resolve(nil) }) }
  }
}

extension Deferred where Value == JSValue {
  /// A JS promise for this value, handed back to JS at an exported entry point.
  public var jsPromise: JSValue { JSPromises.make { resolve in whenDone(resolve) } }
}
