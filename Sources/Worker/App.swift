import JavaScriptEventLoop
import JavaScriptKit
import RemoteProtocol

/// Registers the Worker's entry points on `globalThis.speedMathWorker`. The JS shell in
/// `worker/index.js` only forwards Cloudflare's calls here: Workers require the module entry and
/// the Durable Object classes to be JavaScript.
/// Embedded Swift runs Swift concurrency on the JS event loop through this factory. The older
/// `installGlobalExecutor()` hook never runs tasks in Embedded builds.
typealias DefaultExecutorFactory = JavaScriptEventLoop

@main
struct WorkerMain {
  static func main() async {
    let api = JS.object()

    func export(_ name: String, _ body: @escaping ([JSValue]) -> JSValue) {
      api[name] = JSClosure { arguments in body(arguments) }.jsValue
    }
    func arg(_ arguments: [JSValue], _ i: Int) -> JSValue { i < arguments.count ? arguments[i] : .undefined }
    func async(_ body: @escaping () async -> JSValue) -> JSValue {
      JSPromise.async { () async throws(JSException) -> JSValue in await body() }.jsValue
    }
    func done(_ body: @escaping () async -> Void) -> JSValue { async { await body(); return .undefined } }

    export("fetch") { a in
      guard let request = arg(a, 0).object, let env = arg(a, 1).object, let ctx = arg(a, 2).object else {
        return Platform.invalid()
      }
      return async { await Router.fetch(request, env: env, ctx: ctx) }
    }

    // CodeShard(ctx, ...)
    export("shardReserve") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string, let id = arg(a, 2).string,
        let generation = arg(a, 3).string, let expires = arg(a, 4).number
      else { return false.jsValue }
      return async { await CodeShard.reserve(ctx, hash: hash, id: id, generation: generation, expires: expires).jsValue }
    }
    export("shardLookup") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string else { return .undefined }
      return CodeShard.lookup(ctx, hash: hash)
    }
    export("shardRelease") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string, let id = arg(a, 2).string,
        let generation = arg(a, 3).string
      else { return .undefined }
      return done { await CodeShard.release(ctx, hash: hash, id: id, generation: generation) }
    }
    export("shardAlarm") { a in
      guard let ctx = arg(a, 0).object else { return .undefined }
      return done { await CodeShard.alarm(ctx) }
    }

    // SessionObject(ctx, ...)
    export("sessionCreate") { a in
      guard let ctx = arg(a, 0).object, let id = arg(a, 1).string, let hash = arg(a, 2).string else {
        return .undefined
      }
      return done { await SessionObject(ctx: ctx).create(id: id, hash: hash) }
    }
    export("sessionValidLookup") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string, let generation = arg(a, 2).string else {
        return false.jsValue
      }
      return SessionObject(ctx: ctx).validLookup(hash: hash, generation: generation).jsValue
    }
    export("sessionFetch") { a in
      guard let ctx = arg(a, 0).object else { return Platform.invalid() }
      return async { await SessionObject(ctx: ctx).connect() }
    }
    export("sessionMessage") { a in
      guard let ctx = arg(a, 0).object, let ws = arg(a, 1).object else { return .undefined }
      return done { await SessionObject(ctx: ctx).message(ws, arg(a, 2)) }
    }
    export("sessionClose") { a in
      guard let ctx = arg(a, 0).object, let ws = arg(a, 1).object else { return .undefined }
      return done { await SessionObject(ctx: ctx).closed(ws) }
    }
    export("sessionAlarm") { a in
      guard let ctx = arg(a, 0).object else { return .undefined }
      return done { await SessionObject(ctx: ctx).alarm() }
    }

    JS.global["speedMathWorker"] = api.jsValue
    // An async main that returns makes the Wasm reactor call exit(); stay suspended instead.
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
  }
}
