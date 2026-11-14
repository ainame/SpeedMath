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

Verified with Swift 6.4.2, JavaScriptKit 0.63.0, local workerd: Worker builds (Worker Wasm 265 KB,
up from 217 KB with `Deferred`), 10 Durable Object tests and 9 browser tests pass.

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

| Worker | p50 | p95 | max | > 10 ms |
| --- | --- | --- | --- | --- |
| JavaScript (`main`, 4 versions) | 0 ms | 1 ms | 2–3 ms | 0 of ~1,500 |
| Embedded Swift with `Deferred` (2 versions) | 1 ms | 10–11 ms | 21–25 ms | 21 of 414 |
| Embedded Swift with `async`/`await` | not measured yet | | | |

The slow invocations are the first call into a new Durable Object or isolate (compiling and
initializing the Wasm): `create` for a new session, the first `reserve` on a code shard, the first
WebSocket upgrade, and the first message after a session wakes from hibernation. Warm calls stay at
0–2 ms. This is why `main` keeps the JavaScript Worker.

## When to merge into `main`

1. The account moves to Workers Paid (30 s CPU), or
2. cold-start CPU on staging drops reliably under 10 ms at p99.
