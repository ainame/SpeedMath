# 0001: The Swift Worker uses `Deferred`, not `async`/`await`

- Status: accepted (2026-11-14)
- Area: `Sources/Worker`, `Sources/RemoteProtocol/Deferred.swift`, `worker/index.js`

## Context

The remote-control backend (the Worker and its two Durable Objects, `SessionObject` and
`CodeShard`) was ported from JavaScript to Swift. Cloudflare requires the module entry and the
Durable Object classes to be JavaScript, so `worker/index.js` stays as a shell that forwards every
call to Swift. The logic needs a few asynchronous steps: the rate limiter, reading a request body,
RPC calls between Durable Objects, and storage promises (`setAlarm`, `deleteAll`).

We measured two ways to build the Worker Wasm in local workerd (`vite preview`), each with a
spike that started a `Task` and awaited a JS promise:

| Build | Swift `async`/`await` | Worker Wasm | Cold init, local Mac |
| --- | --- | --- | --- |
| Embedded Swift (Swift 6.4.0 and 6.4.2) | Never runs: the global executor installed by `JavaScriptEventLoop` receives no jobs, so a `Task {}` never starts | ~0.1 MB (0.2 MB with the full Worker) | ~3 ms |
| Regular Swift Wasm (no Foundation) | Works | 3.9 MB (1.4 MB gzipped) | ~15 ms |

The project stays on the Workers Free plan, which allows 10 ms of CPU per request. A cold start of
the regular build (a new isolate, or a Durable Object waking up when a Remote reconnects) would
likely exceed that on Cloudflare's servers. The Paid plan ($5/month minimum, 30 s CPU per request
by default) removes that limit.

## Decision

Build the Worker with Embedded Swift and do not use Swift concurrency in it. Every asynchronous
step returns a `Deferred<Value>` (`Sources/RemoteProtocol/Deferred.swift`), which mirrors `async`:

| Deferred | async/await |
| --- | --- |
| `func f() -> Deferred<T>` | `func f() async -> T` |
| `return .value(x)` | `return x` |
| `f().then { x in g(x) }` | `let x = await f(); return await g(x)` |
| `f().map { x in h(x) }` | `let x = await f(); return h(x)` |
| `Deferred.promise(jsValue)` | `try? await JSPromise(jsValue)!.value` |
| `deferred.jsPromise` at an export | `JSPromise.async { ... }` |

Most of the Worker is synchronous anyway (SQLite and WebSocket sends), so `Deferred` appears in a
handful of places: `Router` (rate limit, body, RPC), `SessionObject.invite`/`reserveInvite` (the
code retry loop), and storage calls in `Platform`.

## Consequences

- Small, fast Worker that fits the Free plan.
- Loops become recursion (`reserveInvite`, `Router.readChunks`); each is commented with the loop it
  stands for.
- Every code path must return a `Deferred`, so the compiler rejects a branch that would never
  answer. Workers otherwise report such a branch as a hung request.

Two interop rules learned during the port apply whichever style is used:

- Workers RPC stubs treat every property, `apply` included, as a remote method. JavaScriptKit calls
  functions as `fn.apply(this, args)`, so RPC methods are called through `Reflect.apply`
  (`Platform.rpc`).
- RPC results are lazy thenables, not plain promises. They are awaited through `Promise.resolve`
  (`Deferred.promise`), as JS `await` does.

## Measured on staging (Cloudflare, 2026-11-14)

CPU time per invocation from Workers Logs, same Playwright suite and smoke test:

| Worker | p50 | p95 | max | > 10 ms |
| --- | --- | --- | --- | --- |
| JavaScript (before the port, 4 versions) | 0 ms | 1 ms | 2–3 ms | 0 of ~1,500 |
| Embedded Swift with `Deferred` (2 versions) | 1 ms | 10–11 ms | 21–25 ms | 21 of 414 |

The slow invocations are the first call into a new Durable Object or isolate, where the Worker
Wasm (217 KB after `wasm-opt -Os`) is compiled and initialized: `create` for a new session, the
first `reserve` on a code shard, the first WebSocket upgrade, and the first message after a session
wakes from hibernation. Warm calls stay at 0–2 ms. No invocation failed in these runs (outcomes
were only `ok` and client `canceled`), but the cold path is above the Free plan's nominal 10 ms.

## When to revisit

Switch to `async`/`await` when either becomes true:

1. **The account moves to Workers Paid.** Then use the regular Wasm SDK for the Worker only
   (`swiftWasm({ useEmbeddedSDK: false })` would affect the browser app too; give the Worker its own
   build or plugin instance). Measure cold-start CPU on staging in Workers Logs before production.
2. **Embedded Swift can run concurrency in a Worker.** Retest with a new toolchain or JavaScriptKit
   release: a Worker export that runs `Task { }` and awaits `JSPromise(...).value` must resolve.
   The spike from this decision is easy to recreate: `JavaScriptEventLoop.installGlobalExecutor()`
   in `main`, then a `JSClosure` that returns `JSPromise.async { ... }.jsValue`.

The migration is mechanical with the table above: convert `Deferred` functions to `async`, starting
at the leaves (`Platform.rpc`, `Platform.storage`), then the callers, and finally replace
`.jsPromise` at the exports in `Sources/Worker/App.swift`.
