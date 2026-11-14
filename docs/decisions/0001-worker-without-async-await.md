# 0001: Keep the Worker in JavaScript; the Swift Worker waits on a branch

- Status: accepted (2026-11-14)
- Area: `worker/`, `Sources/Worker/Exports.swift`, branch `swift-worker`

## Context

The project's rule is Swift everywhere, with JavaScript only for bridging. The browser side
follows it: the remote-control client is Swift (`Sources/WebApp/RemoteLink.swift`), and
`web/main.js` only bridges calls that can throw. The backend (the Worker and its two Durable
Objects, `SessionObject` and `CodeShard`) was also fully ported to Swift. That port lives on the
**`swift-worker` branch** and passes the same test suites as `main` (see the update below for its
current state).

Cloudflare requires the module entry and the Durable Object classes to be JavaScript, so a Swift
Worker always keeps a short forwarding shell in `worker/index.js`.

### Swift concurrency is not available

We measured both Swift Wasm builds in local workerd with a spike that started a `Task` and
awaited a JS promise:

| Build | Swift `async`/`await` | Worker Wasm | Cold init, local Mac |
| --- | --- | --- | --- |
| Embedded Swift (Swift 6.4.0 and 6.4.2) | Never runs: the global executor from `JavaScriptEventLoop` receives no jobs, so `Task {}` never starts | ~0.1 MB | ~3 ms |
| Regular Swift Wasm (no Foundation) | Works | 3.9 MB (1.4 MB gzipped) | ~15 ms |

The account stays on the Workers Free plan: 10 ms of CPU per request. The Paid plan ($5/month
minimum) allows 30 s by default.

So the branch uses Embedded Swift and returns a `Deferred<Value>` from every asynchronous step
(`Sources/RemoteProtocol/Deferred.swift` on the branch), shaped to convert to `async`/`await`
mechanically:

| Deferred | async/await |
| --- | --- |
| `func f() -> Deferred<T>` | `func f() async -> T` |
| `return .value(x)` | `return x` |
| `f().then { x in g(x) }` | `let x = await f(); return await g(x)` |
| `f().map { x in h(x) }` | `let x = await f(); return h(x)` |
| `Deferred.promise(jsValue)` | `try? await JSPromise(jsValue)!.value` |
| `deferred.jsPromise` at an export | `JSPromise.async { ... }` |

### Even Embedded is too heavy at cold start on the Free plan

CPU time per invocation on staging (Workers Logs), same Playwright suite and smoke test:

| Worker | p50 | p95 | max | > 10 ms |
| --- | --- | --- | --- | --- |
| JavaScript (`main`, 4 versions) | 0 ms | 1 ms | 2–3 ms | 0 of ~1,500 |
| Embedded Swift with `Deferred` (`swift-worker`, 2 versions) | 1 ms | 10–11 ms | 21–25 ms | 21 of 414 |

The slow invocations are the first call into a new Durable Object or isolate, where the 217 KB
Worker Wasm (already `wasm-opt -Os`) is compiled and initialized: `create` for a new session, the
first `reserve` on a code shard, the first WebSocket upgrade, and the first message after a
session wakes from hibernation (exactly when a Remote reconnects). Warm calls stay at 0–2 ms. No
invocation failed in those runs, but the cold path is above the Free plan's nominal 10 ms.

## Decision

`main` keeps the JavaScript Worker. Swift is used in the Worker only where it costs nothing at
cold start: the integer-only rules shared with the Swift client (`WireRules.validCard`,
`WireRules.validSnapshot` and `Role.canRelay` in `Sources/ProtocolModels/Wire.swift`) are compiled
into a tiny import-free Wasm (`Scripts/build-worker-wasm.sh`, exports in
`Sources/Worker/Exports.swift`) that `worker/protocol.js` calls. Anything that needs strings,
arrays or allocation stays in JS, because the freestanding module has no heap.

## Update: the `swift-worker` spike is close (2026-11-14)

Later the same day the branch got much closer to the Free plan (commit `c99077b`):

- **`async`/`await` works in Embedded Swift.** The failed spike above used
  `installGlobalExecutor()` with a non-`async` `main`, which never runs tasks in Embedded. The
  working pattern is an `async` `@main`, a file-level `typealias DefaultExecutorFactory =
  JavaScriptEventLoop`, and `main` kept suspended (`await withUnsafeContinuation { _ in }`),
  because a returning async `main` makes the Wasm reactor call `exit()`. `Deferred` is gone.
- **Swift starts at module load.** Probes showed that module load costs 0 ms of request CPU
  (Cloudflare bills it to isolate start-up), while starting Swift on the first request cost
  6–16 ms, mostly V8 compiling Wasm functions on first call. The shell now starts Swift with
  top-level `await` and calls a synchronous `warmUp()` so the shared helpers are compiled before
  the first request. During start-up only, it gives WASI fixed random bytes (Workers forbid random
  values at global scope) and instantiates the precompiled module synchronously (top-level `await`
  must settle on microtasks).

| Worker on staging | p50 | p95 | p99 | max | > 10 ms |
| --- | --- | --- | --- | --- | --- |
| JavaScript (`main`) | 0 ms | 1 ms | — | 2–3 ms | 0% |
| Swift `async`, started on first request | 1 ms | 11 ms | 20 ms | 22 ms | 7% |
| Swift `async`, started at load + warm-up (`c99077b`) | 1 ms | 7 ms | 10 ms | 16 ms | 1% |

The remaining slow calls (6–16 ms) are the first run of the async Durable Object handlers
(WebSocket messages, `reserve`, `create`), which cannot be warmed up at load. The branch's own
decision record has the full measurements. The branch was forked before `eb55e2b` and `6de5dee`,
so it needs a rebase onto `main` (shared `WireRules`, pairing panel polish) before it can merge.

## When to revisit

Merge or rebase `swift-worker` when any of these becomes true:

1. **The account moves to Workers Paid.** The cold-start CPU stops mattering. Consider also
   moving the Worker to the regular Wasm SDK and real `async`/`await`: give the Worker its own
   build so the browser app stays Embedded, and check cold-start CPU on staging in Workers Logs.
2. **The branch's first-call cost drops reliably under 10 ms**: for example by making the Durable
   Object handlers mostly synchronous so `warmUp()` can compile them, or with a cheaper toolchain
   or runtime. Rerun the staging measurement with the branch; the target is under 10 ms at p99
   with no outliers.

### Interop rules learned on the branch

These apply to any Swift code that talks to the Workers runtime through JavaScriptKit:

- Workers RPC stubs treat every property, `apply` included, as a remote method. JavaScriptKit
  calls functions as `fn.apply(this, args)`, so call RPC methods through `Reflect.apply`.
- RPC results are lazy thenables, not plain promises. Await them through `Promise.resolve`, as JS
  `await` does.
- `JSObject` already has `hash(into:)`, so read a field named `hash` with `object["hash"]`.
- A JS exception inside a JavaScriptKit call unwinds through the Wasm; wrap calls that can throw
  (`JSON.parse`) in a bridge that returns null.
