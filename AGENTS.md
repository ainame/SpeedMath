# Repository Guidelines

SpeedMath（スピードけいさん）は小学生向けの計算カードアプリです。Swift で書かれ、WebAssembly としてブラウザで動きます。公開先は https://speedmath.ainame-apps.workers.dev （Cloudflare Workers）です。旧 GitHub Pages 版（https://ainame.github.io/SpeedMath/）は最後のビルドのまま残っていますが、更新されません。

How the pieces fit together (app, remote control protocol, Worker and Durable Objects, build and deploy) is in [docs/architecture.md](docs/architecture.md). Read it before changing the remote control or the Worker.

## Stack

- [ElementaryUI](https://github.com/elementary-swift/elementary-ui) 0.9.x for views and reactivity (`@View`, `@State`, `@Environment`, `@Reactive` from `Reactivity`).
- [elementary-router](https://github.com/ainame/elementary-router) (`main` branch, pinned in `Package.resolved`) for typed routes via `@Routes`.
- JavaScriptKit for the browser APIs ElementaryUI does not expose, preferably through typed BridgeJS bindings (`@JSClass`, `@JSFunction`, `@JSGetter`; the `BridgeJS` build plugin on `Sources/RemoteProtocol`).
- Vite + `@elementary-swift/vite-plugin-swift-wasm` + `@cloudflare/vite-plugin`, driven by the Cloudflare CLI (`cf`, config in `cloudflare.config.ts`). Builds use the Embedded Swift SDK (`useEmbeddedSDK: true`); `pnpm run dev` uses the regular Wasm SDK.
- Cloudflare Workers (static assets + `/api/*`) with SQLite-backed Durable Objects for the remote control.
- Swift 6.4.2 (pinned in `.swift-version`, same as CI) with matching `swift-6.4.2-RELEASE_wasm` / `_wasm-embedded` SDKs. pnpm 10.34.9 (`packageManager`); `pnpm install` fetches the pinned Node.js.

## Layout

- `Sources/WebApp/App.swift`: entry point. `AppRoot` owns app-wide state (`PlaySettings`, `StampBook`, `TodayRecords`, `RemoteHub`) above `AppRoutes.RouterView()` and passes it through `.environment`.
- `AppRoutes.swift`: the route tree (`/`, `/play/:deck`, `/remote`, `/stamps`, `/records`, fallbacks).
- `AppShell.swift`: the layout around every route: the title header, the home-screen-only リモコン button / 「リモコン ✓」 indicator, and the pairing panel.
- `Pages.swift`: all screens and their small views (home, play session, finished screen, stamp card, records).
- `Sources/SessionLogic/Deck.swift`: the four 計算カード decks and their exact card ranges (`Sources/WebApp/Deck.swift` adds view helpers). `Stamp.swift`: reward stamps.
- `StampBook.swift`, `TodayRecords.swift`, `DailyStorage.swift`: per-day data in localStorage, reset at local midnight.
- `RemoteHub.swift`: the child's side of the remote control for the whole app. It owns the Presenter `RemoteLink`, a `CommandLedger` (`Sources/SessionLogic`) that orders every state change and answers resent commands once, and turns Remote commands into settings changes, navigation and play moves. While paired, navigation (choosing, スタート, はじめる, もういちど, えらびなおす, やめる) is the parent's; card taps work on both sides; records and stamps stay on the child's device.
- `RemoteLink.swift`: the remote-control client for both roles (connection, reconnect, pairing, ordered sync, command resend). It is protocol logic only: no JavaScriptKit, just the `RemoteProtocol` wrappers and typed messages. `RemoteViews.swift` renders the child's pairing panel and the Remote's screens (home, ready, playing, finished).
- `Sources/ProtocolModels`: wire types and checks shared by every side. Keep `Wire.swift` integer-only (it is also compiled into the heap-free `logic.wasm`); string checks go in `Validation.swift`. `WireRules.protocolVersion` is the single protocol version.
- `Sources/RemoteProtocol`: `WebBindings.swift` (BridgeJS bindings for WebSocket, fetch, AbortController, location, history, storage, JSON, crypto), `BrowserServices.swift` (the Swift-facing `BrowserSocket`, `BrowserHTTP`, `BrowserPage`, `Timeout`), `RemoteWire.swift` (the `ServerMessage` / `ClientMessage` codec, the only place that reads JSON fields) and `JSBridge.swift` (the few untyped JavaScriptKit calls the codec needs).
- `worker/index.js`, `worker/protocol.js`: the remote-control backend (Worker, `SessionObject` and `CodeShard` Durable Objects) in JavaScript. Integer rules shared with the client come from `worker/generated/logic.wasm`, built by `Scripts/build-worker-wasm.sh` from `Sources/Worker/Exports.swift` and `Wire.swift`. A full Swift Worker is on the `swift-worker` branch; see [docs/decisions/0001-worker-without-async-await.md](docs/decisions/0001-worker-without-async-await.md) for why `main` keeps the JS Worker.
- `web/main.js`: starts the Wasm and injects the bundled QR library (`qrCodeDataURL`) through BridgeJS `getImports()`. Nothing else.
- `Browser.swift`: JavaScriptKit helpers (time, random, key/interval listeners) and the clock formatting.
- `index.html`: the whole stylesheet, plus `window.speedMathStorage` (localStorage wrapper with try/catch).
- `public/stamps/*.svg`: original stamp artwork (part of this repo, MIT). `public/favicon.svg`: original app icon; regenerate `favicon-32.png` and the square, unrounded `apple-touch-icon.png` (180px) from it with `rsvg-convert`. `public/licenses.html`: generated third-party license page.
- `Scripts/generate-licenses.py`: regenerates `public/licenses.html` from the dependency license files. `Scripts/check-build.mjs`: checks the `cf build` output.
- `Tests/SessionLogicTests` (Swift), `Tests/worker` (Durable Objects on a fake host), `Tests/browser` (Playwright end-to-end, plus `live-smoke.mjs` for staging).
- `docs/`: [architecture](docs/architecture.md) and [decision records](docs/decisions/). `REMOTE-VERIFICATION.md` records what was verified and what is still open; `TODO.md` is the original remote-control plan.

## Implementation Constraints

- Do not import Foundation. Keep code Embedded Swift compatible: no `Codable`/JSON in Swift, no `Character`-level string parsing, no existential-heavy designs. Parse and build JSON with the browser's `JSON` (through the BridgeJS binding in `JS.parse` / `JS.stringify`) and read fields through `JSObject`, inside `RemoteWire` only.
- Write app logic in Swift. JavaScript is only for injecting third-party JS libraries and for the Worker, which stays in JS by decision 0001. Bind new browser APIs in `WebBindings.swift` with BridgeJS: every member is `throws(JSException)`, so a JS exception becomes a Swift error instead of trapping the Wasm (a raw JavaScriptKit call that throws traps). A `@JSClass` with a constructor needs `from: .global`, or BridgeJS expects it in `getImports()`; check `Imports` in the generated `bridge-js.d.ts`. Pass Swift callbacks as `JSTypedClosure` and `release()` them when unregistered.
- Do not depend on ElementaryUI internals such as `BrowserInterop`. For raw JavaScriptKit calls in Embedded Swift pass arguments as `[JSValue]`; read a JS field named `hash` with `object["hash"]` (it clashes with `Hashable`). Timers use JavaScriptKit's `JSTimer` (wrapped by `Timeout`).
- Global keyboard and timers use `BrowserListener` attached with `.attach(...)` so they are removed on unmount. Use `ElementaryUI`'s `.id(...)` when a view must restart with new parameters (see `PlayPage` keying `PlaySession`). Inside a result builder, loop over small `@View` structs rather than buttons with modifiers (type inference fails otherwise).
- Routing uses `@Routes(mode: .hash)` on purpose: QR invites travel in the fragment (`#/remote?invite=…`), which never reaches the server, and hash mode needs no link-interception script.
- Card data is fixed, not randomly generated: decks enumerate the standard 算数セット card ranges and are shuffled per session. "0 problems" means an operand or the answer is 0.
- localStorage access must go through `DailyStorage` / `window.speedMathStorage` so private mode or blocked storage never crashes the app.
- Changing the wire format: update `Wire.swift`/`Validation.swift`, `RemoteWire.swift`, `worker/protocol.js` and the exports in `Sources/Worker/Exports.swift` (and `Scripts/build-worker-wasm.sh`) together, and bump `WireRules.protocolVersion` when old clients cannot understand the new messages.

## Design Rules

- App-style full screen: the page never scrolls. Every screen fills the viewport and splits it into regions with flex ratios. Only inner lists (records) may scroll.
- Sizes are proportional: root font size follows `vmin`; cards, stamps, deck text and stamp slots size from their region with container query units. Container units resolve against an ancestor container, so set `container-type` on the parent of the element that uses `cq*` units.
- The app is used as a home-screen web app: respect safe-area insets through the `--safe-*` variables in `index.html` (they wrap `env(safe-area-inset-*)`). Setting them on `document.documentElement` in the browser simulates a notch and home indicator for testing.
- Primary target is a phone in landscape (tap left/right half of the screen to go back/forward); portrait phones and desktop must still fit without scrolling. Check at least 812×375, 667×320, 375×812 and a desktop window, for both the child's screens and the Remote's screens.
- Use the theme variables in `index.html` (`--bg`, `--surface`, `--line`, `--accent`, ...) instead of new hard-coded colors. The four deck colors (`.deck-red` etc.) and the stamp ink are fixed.
- Keep the look simple and kid-friendly: outlined, rounded components (radio-card style selection, outlined list items). Avoid colored edge accents (thick left/bottom highlight bars) and hard drop shadows under buttons.
- Text is in hiragana for first graders.

## Build and Verify

```sh
pnpm install --frozen-lockfile
pnpm run dev                                              # dev server with hot reload (regular Wasm SDK)
swift build --swift-sdk swift-6.4.2-RELEASE_wasm --product WebApp   # quick type check
swift test                                                # Swift unit tests
pnpm exec cf build --mode staging                         # release build (Embedded Swift) + Worker
pnpm exec node Scripts/check-build.mjs staging            # check the build output
pnpm run test:worker                                      # Durable Object tests (needs the build)
pnpm exec playwright test                                 # browser tests against local workerd
pnpm exec vite preview                                    # serve the build locally
```

- Run `pnpm exec cf build` before committing UI or Swift changes; Embedded Swift can reject code that the regular SDK accepts. After a rebuild, restart a running `vite preview` (file names change).
- Verify UI changes in a browser at the sizes listed above, including the play flow with keyboard (→/Space/←) and taps, and the remote flow when it is affected.
- After changing dependencies, run `python3 Scripts/generate-licenses.py` and commit `public/licenses.html`.
- The local rate limiter keeps counting across runs: back-to-back full Playwright runs within a minute can hit it.

## Deploy and Git

- Pushing to `main` builds and tests in GitHub Actions (`swift:6.4.2` container; do not use `swift-actions/setup-swift@v2`) and deploys production with `cf deploy --prebuilt --mode production`. Pushing `staging` deploys staging. Add `[skip ci]` to the commit message when a push should not deploy.
- Staging can also be deployed locally: `pnpm exec cf deploy --prebuilt --mode staging`, then run the browser tests with `SPEEDMATH_TEST_URL=https://speedmath-staging.ainame-apps.workers.dev`.
- Commit each meaningful change separately. Version tags have no `v` prefix.
