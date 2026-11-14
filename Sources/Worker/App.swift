import JavaScriptKit
import RemoteProtocol

/// Registers the Worker's entry points on `globalThis.speedMathWorker`. The JS shell in
/// `worker/index.js` only forwards Cloudflare's calls here: Workers require the module entry and
/// the Durable Object classes to be JavaScript.
@main
struct WorkerMain {
  static func main() {
    let api = JS.object()

    func export(_ name: String, _ body: @escaping ([JSValue]) -> JSValue) {
      api[name] = JSClosure { arguments in body(arguments) }.jsValue
    }
    func arg(_ arguments: [JSValue], _ i: Int) -> JSValue { i < arguments.count ? arguments[i] : .undefined }
    func done(_ deferred: Deferred<Void>) -> JSValue { deferred.map { JSValue.undefined }.jsPromise }

    export("fetch") { a in
      guard let request = arg(a, 0).object, let env = arg(a, 1).object, let ctx = arg(a, 2).object else {
        return Deferred.value(Platform.invalid()).jsPromise
      }
      return Router.fetch(request, env: env, ctx: ctx).jsPromise
    }

    // CodeShard(ctx, ...)
    export("shardReserve") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string, let id = arg(a, 2).string,
        let generation = arg(a, 3).string, let expires = arg(a, 4).number
      else { return Deferred.value(false.jsValue).jsPromise }
      return CodeShard.reserve(ctx, hash: hash, id: id, generation: generation, expires: expires)
        .map { $0.jsValue }.jsPromise
    }
    export("shardLookup") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string else { return .undefined }
      return CodeShard.lookup(ctx, hash: hash)
    }
    export("shardRelease") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string, let id = arg(a, 2).string,
        let generation = arg(a, 3).string
      else { return .undefined }
      return done(CodeShard.release(ctx, hash: hash, id: id, generation: generation))
    }
    export("shardAlarm") { a in
      guard let ctx = arg(a, 0).object else { return .undefined }
      return done(CodeShard.alarm(ctx))
    }

    // SessionObject(ctx, ...)
    export("sessionCreate") { a in
      guard let ctx = arg(a, 0).object, let id = arg(a, 1).string, let hash = arg(a, 2).string else {
        return .undefined
      }
      return done(SessionObject(ctx: ctx).create(id: id, hash: hash))
    }
    export("sessionValidLookup") { a in
      guard let ctx = arg(a, 0).object, let hash = arg(a, 1).string, let generation = arg(a, 2).string else {
        return false.jsValue
      }
      return SessionObject(ctx: ctx).validLookup(hash: hash, generation: generation).jsValue
    }
    export("sessionFetch") { a in
      guard let ctx = arg(a, 0).object else { return Deferred.value(Platform.invalid()).jsPromise }
      return SessionObject(ctx: ctx).connect().jsPromise
    }
    export("sessionMessage") { a in
      guard let ctx = arg(a, 0).object, let ws = arg(a, 1).object else { return .undefined }
      return done(SessionObject(ctx: ctx).message(ws, arg(a, 2)))
    }
    export("sessionClose") { a in
      guard let ctx = arg(a, 0).object, let ws = arg(a, 1).object else { return .undefined }
      return done(SessionObject(ctx: ctx).closed(ws))
    }
    export("sessionAlarm") { a in
      guard let ctx = arg(a, 0).object else { return .undefined }
      return done(SessionObject(ctx: ctx).alarm())
    }

    JS.global["speedMathWorker"] = api.jsValue
  }
}
