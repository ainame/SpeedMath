# 0001: Swift concurrency in the Embedded Swift Worker

- Status: accepted (2026-11-14), revised the same day
- Area: `Sources/Worker`, `worker/index.js` (branch `swift-worker`)

## Context

The remote-control backend (the Worker and its two Durable Objects, `SessionObject` and
`CodeShard`) was ported from JavaScript to Swift on this branch. Cloudflare requires the module
entry and the Durable Object classes to be JavaScript, so `worker/index.js` stays as a shell that
forwards every call to Swift. The logic has a few asynchronous steps: the rate limiter, reading a
request body, RPC calls between Durable Objects, and storage promises (`setAlarm`, `deleteAll`).

The account is on the Workers Free plan (10 ms of CPU per request), so the Worker uses Embedded
Swift: the regular Swift Wasm runtime is 3.9 MB (1.4 MB gzipped) and took ~15 ms to start locally,
against ~3 ms for Embedded.

## First attempt: no concurrency (`Deferred`)

The first Embedded spike used a non-`async` `@main` with
`JavaScriptEventLoop.installGlobalExecutor()`. In Embedded Swift (6.4.0 and 6.4.2) that hook never
runs jobs: a `Task {}` never starts. The Worker was therefore written with a hand-rolled
`Deferred<Value>` type that chained JS promises with callbacks (commit `33c50d2`).

## Decision: real `async`/`await`

Swift concurrency does work in the Embedded Worker with the custom-executor pattern
([Swift Forums](https://forums.swift.org/t/swift-6-2-async-await-no-longer-works-on-webassembly-with-js-interop-crashes-instantly-on-suspension/82269)).
`Sources/Worker/App.swift`:

```swift
import JavaScriptEventLoop
typealias DefaultExecutorFactory = JavaScriptEventLoop  // not installGlobalExecutor()

@main struct WorkerMain {
  static func main() async {
    // register exports on globalThis.speedMathWorker ...
    // An async main that returns makes the Wasm reactor call exit() ("exit with exit code 0").
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
  }
}
```

Exports return `JSPromise.async { ... }.jsValue`. JS promises are awaited through
`Platform.resolve`, which goes through `Promise.resolve` first (see the interop notes). `Deferred`
is gone; the invite retry and the body read are plain loops again.

Verified with Swift 6.4.2, JavaScriptKit 0.63.0: Worker builds (Worker Wasm 249 KB with `-Osize`;
217 KB with `Deferred`), 10 Durable Object tests and 9 browser tests pass locally and on staging.

## Interop rules

- Workers RPC stubs treat every property, `apply` included, as a remote method. JavaScriptKit
  calls functions as `fn.apply(this, args)`, so RPC methods are called through `Reflect.apply`
  (`Platform.rpc`).
- RPC results are lazy thenables, not plain promises. Await them through `Promise.resolve`, as JS
  `await` does (`Platform.resolve`).
- `JSObject` already has `hash(into:)`, so read a field named `hash` with `object["hash"]`.
- A JS exception inside a JavaScriptKit call unwinds through the Wasm; wrap calls that can throw
  (`JSON.parse`) in a bridge that returns null.

## Cold start on the Free plan

CPU time per invocation on staging (Workers Logs), same Playwright suite and smoke test:

| Worker | p50 | p95 | p99 | max | > 10 ms |
| --- | --- | --- | --- | --- | --- |
| JavaScript (`main`, 4 versions) | 0 ms | 1 ms | — | 2–3 ms | 0 of ~1,500 |
| Embedded Swift with `Deferred` (2 versions) | 1 ms | 10–11 ms | — | 21–25 ms | 21 of 414 |
| Embedded Swift with `async`/`await` (`98e2367b`) | 1 ms | 11 ms | 20 ms | 22 ms | 14 of 198 |
| + Swift started at module load (`352a52a8`) | 2 ms | 7 ms | 11 ms | 15 ms | 3 of 201 |
| + synchronous warm-up at load (`52dd7f28`) | 1 ms | 7 ms | 10 ms | 16 ms | 2 of 202 |

### Where the cold cost went

Probe endpoints on fresh deploys (the first request is always a new isolate) showed that isolate
start, parsing the 76 KB JS bundle and loading the Wasm module cost 0 ms of request CPU; starting
Swift (instantiate, `_initialize`, `main`) cost 6–16 ms. Profiling the same start-up locally in Node
split it into instantiate 0.3 ms, `_initialize` 0.5–1 ms, `main` ~3 ms, JS glue ~1 ms and ~2 ms for
the first request, and forcing eager compilation showed that about 3 of those ~5 ms were V8
compiling Wasm functions on first call (168 functions, ~48 KB of bodies on the cold path:
`dlmalloc`, `Router.fetch`, the concurrency runtime, JavaScriptKit closures, string comparison).

### What `worker/index.js` does about it

Cloudflare bills module top-level work to isolate start-up (a separate 1 s limit), not to the
request. So the shell starts Swift with top-level `await`, then calls the synchronous `warmUp()`
export (`Sources/Worker/WarmUp.swift`) so V8 compiles the shared helpers before the first request.
Two Workers rules shape it:

- **No random values at global scope.** Swift's `_initialize` seeds its hash function from WASI
  `random_get`, so `crypto.getRandomValues` returns fixed bytes during start-up only and is restored
  before any handler runs. Session ids, keys and codes are still drawn per request; Swift's internal
  dictionaries are not keyed by client input.
- **Top-level `await` must settle on microtasks.** `WebAssembly.instantiate` resolves on a task, so
  it is replaced during start-up by the synchronous `new WebAssembly.Instance` (the module is
  already compiled by the bundler import). Async Swift work cannot run at load either: an async
  warm-up (`fetch` of `/api/health`) left top-level await unsettled, and building a `Response` at
  load is not allowed, so the warm-up only calls synchronous helpers.

`-Osize` for the Worker and `RemoteProtocol` targets shaved a further ~7% off the Wasm.

The remaining slow invocations (6–16 ms) are the first run of the async Durable Object handlers
(WebSocket messages, `reserve`, `create`), whose code is only compiled when they first run.

## When to merge into `main`

1. The account moves to Workers Paid (30 s CPU), or
2. cold-start CPU on staging is reliably under 10 ms (currently p99 10 ms, max 16 ms, ~1% over).
