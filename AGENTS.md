# Repository Guidelines

SpeedMath（スピードけいさん）は小学生向けの計算カードアプリです。Swift で書かれ、WebAssembly としてブラウザで動きます。公開先は https://speedmath.ainame-apps.workers.dev （Cloudflare Workers）です。旧 GitHub Pages 版（https://ainame.github.io/SpeedMath/）は最後のビルドのまま残っていますが、更新されません。

How the pieces fit together (app, remote control protocol, Worker and Durable Objects, build and deploy) is in [docs/architecture.md](docs/architecture.md). Read it before changing the remote control or the Worker.

## Stack

- [ElementaryUI](https://github.com/elementary-swift/elementary-ui) 0.9.x for views and reactivity (`@View`, `@State`, `@Environment`, `@Reactive` from `Reactivity`).
- [elementary-router](https://github.com/ainame/elementary-router) (`main` branch, pinned in `Package.resolved`) for typed routes via `@Routes`.
- JavaScriptKit for the browser APIs ElementaryUI does not expose, through typed BridgeJS bindings (`@JSClass`, `@JSFunction`, `@JSGetter`; the `BridgeJS` build plugin on `Sources/BrowserAPI`).
- Vite + `@elementary-swift/vite-plugin-swift-wasm` + `@cloudflare/vite-plugin`, driven by the Cloudflare CLI (`cf`, config in `cloudflare.config.ts`). Builds use the Embedded Swift SDK (`useEmbeddedSDK: true`); `pnpm run dev` uses the regular Wasm SDK.
- Cloudflare Workers (static assets + `/api/*`) with SQLite-backed Durable Objects for the remote control.
- Swift 6.4.2 (pinned in `.swift-version`, same as CI) with matching `swift-6.4.2-RELEASE_wasm` / `_wasm-embedded` SDKs. pnpm 10.34.9 (`packageManager`); `pnpm install` fetches the pinned Node.js.

## Layout

- `Sources/WebApp/App.swift`: entry point. `AppRoot` owns app-wide state (`PlaySettings`, `StampBook`, `TodayRecords`, `RemoteHub`) above `AppRoutes.RouterView()` and passes it through `.environment`.
- `AppRoutes.swift`: the route tree (`/`, `/play/:deck`, `/remote`, `/stamps`, `/records`, fallbacks).
- `AppShell.swift`: the layout around every route: the title header, the home-screen-only リモコン button / 「リモコン ✓」 indicator, and the pairing panel.
- One file per screen: `HomePage.swift` (with `DeckButton`, `Chip`), `PlayPage.swift` (play session and finished screen), `StampsPage.swift`, `RecordsPage.swift`, `NotFoundPage.swift`. `ClockViews.swift`: `LiveTimer`, `ClockDisplay`, `ClockGlyph`.
- `Sources/SessionLogic/Deck.swift`: the four 計算カード decks and their exact card ranges (`Sources/WebApp/Deck.swift` adds view helpers). `Stamp.swift`: reward stamps.
- `StampBook.swift`, `TodayRecords.swift`: today's stamps and records, reset at local midnight. `DailyStorage.swift` is their localStorage codec (typed `loadStamps`/`saveRecords`…; the app's only other JSON code besides `RemoteWire`).
- `RemoteHub.swift`: the child's side of the remote control for the whole app. It owns the Presenter `RemoteLink`, a `CommandLedger` (`Sources/SessionLogic`) that orders every state change and answers resent commands once, and carries out `RemoteCommandPolicy` (also in `SessionLogic`), which decides what each Remote command means on the current screen. While paired, navigation (choosing, スタート, はじめる, もういちど, えらびなおす, やめる) is the parent's; card taps work on both sides; records and stamps stay on the child's device.
- `Sources/RemoteClient`: the remote-control client logic, free of JavaScriptKit so it runs in `swift test`. `RemoteLink` (both roles: connection, reconnect, pairing, ordered sync, command resend) is generic over a `RemoteEnvironment` (sockets, HTTP, timers, page events, storage, clock); `InviteInbox` carries a QR invite or a restored Presenter from start-up. `Sources/RemoteProtocol/BrowserRemoteEnvironment.swift` is the browser implementation (`AppRemoteLink` in the app). `PairingPanel.swift` is the child's pairing panel; `RemotePage.swift` the Remote's screens (home, ready, playing, finished).
- `Sources/ProtocolModels`: wire types and checks shared by every side. Keep `Wire.swift` integer-only (it is also compiled into the heap-free `logic.wasm`); string checks go in `Validation.swift`. `WireRules.protocolVersion` is the single protocol version.
- `Sources/BrowserAPI`: every browser API the app uses. `WebBindings.swift` holds the BridgeJS bindings (WebSocket, fetch, AbortController, location, history, local/session storage, keyboard events, performance, JSON, crypto); one file each wraps them as `BrowserSocket`, `BrowserHTTP`, `BrowserPage` (storage, events, key presses, time, random, page guards) and `Timeout` / `RepeatingTimer` (`Timers.swift`); `JSBridge.swift` has the few untyped calls the JSON codecs need.
- `Sources/RemoteProtocol`: `RemoteWire.swift`, the JSON codec for the messages in `Sources/ProtocolModels/Messages.swift` (`ServerMessage`, `ClientMessage`, `ControlRequest` / `ControlResponse`), and `BrowserRemoteEnvironment.swift`.
- `worker/`: the remote-control backend in JavaScript: `index.js` (the Worker's `/api/*`), `session-object.js` and `code-shard.js` (the Durable Objects), `shared.js` (constants and helpers), `protocol.js` (message checks). Integer rules shared with the client come from `worker/generated/logic.wasm`, built by `Scripts/build-worker-wasm.sh` from `Sources/Worker/Exports.swift` and `Wire.swift`. A full Swift Worker is on the `swift-worker` branch; see [docs/decisions/0001-worker-without-async-await.md](docs/decisions/0001-worker-without-async-await.md) for why `main` keeps the JS Worker.
- `web/main.js`: starts the Wasm and injects the bundled QR library (`qrCodeDataURL`) through BridgeJS `getImports()`. Nothing else.
- `Browser.swift`: `Browser.now()`, the crypto-backed `BrowserRandom`, `BrowserListener` (card keys, intervals) and the clock formatting, all on `BrowserAPI`.
- `styles.css`: the whole stylesheet (linked from `index.html`, bundled by Vite). `index.html` has no inline script: the page guards (scroll reset on resize, no pinch or double-tap zoom) are installed from Swift at start-up (`BrowserPage.installAppGuards()`).
- `public/stamps/*.svg`: original stamp artwork (part of this repo, MIT). `public/favicon.svg`: original app icon; regenerate `favicon-32.png` and the square, unrounded `apple-touch-icon.png` (180px) from it with `rsvg-convert`. `public/licenses.html`: generated third-party license page.
- `Scripts/generate-licenses.py`: regenerates `public/licenses.html` from the dependency license files. `Scripts/check-build.mjs`: checks the `cf build` output.
- `Tests/SessionLogicTests` and `Tests/RemoteClientTests` (Swift, native: decks, play and ledger rules, command policy, and `RemoteLink` driven by a fake environment with a manual clock), `Tests/worker` (Durable Objects on a fake host), `Tests/browser` (Playwright end-to-end, plus `live-smoke.mjs` for staging). Put new remote-control logic where `swift test` reaches it (`SessionLogic`, `RemoteClient`) and cover it there; keep the browser tests for end-to-end flows.
- `docs/`: [architecture](docs/architecture.md), [decision records](docs/decisions/), and `docs/history/` (the original remote-control plan and the first verification record, kept as history).

## Implementation Constraints

- Do not import Foundation. Keep code Embedded Swift compatible: no `Codable`/JSON in Swift, no `Character`-level string parsing, no existential-heavy designs. Parse and build JSON with the browser's `JSON` (through the BridgeJS binding in `JS.parse` / `JS.stringify`) and read fields through `JSObject`, inside `RemoteWire` only.
- Write app logic in Swift. JavaScript is only for injecting third-party JS libraries and for the Worker, which stays in JS by decision 0001. Bind new browser APIs in `WebBindings.swift` with BridgeJS: every member is `throws(JSException)`, so a JS exception becomes a Swift error instead of trapping the Wasm (a raw JavaScriptKit call that throws traps). A `@JSClass` with a constructor needs `from: .global`, or BridgeJS expects it in `getImports()`; check `Imports` in the generated `bridge-js.d.ts`. Pass Swift callbacks as `JSTypedClosure` and `release()` them when unregistered.
- Do not depend on ElementaryUI internals such as `BrowserInterop`. Only `BrowserAPI` and the two JSON codecs import JavaScriptKit. For raw JavaScriptKit calls in Embedded Swift pass arguments as `[JSValue]`; read a JS field named `hash` with `object["hash"]` (it clashes with `Hashable`). Timers use JavaScriptKit's `JSTimer` (wrapped by `Timeout` / `RepeatingTimer`), dates its `JSDate`.
- Global keyboard and timers use `BrowserListener` attached with `.attach(...)` so they are removed on unmount. Use `ElementaryUI`'s `.id(...)` when a view must restart with new parameters (see `PlayPage` keying `PlaySession`). Inside a result builder, loop over small `@View` structs rather than buttons with modifiers (type inference fails otherwise).
- Routing uses `@Routes(mode: .hash)` on purpose: QR invites travel in the fragment (`#/remote?invite=…`), which never reaches the server, and hash mode needs no link-interception script.
- Card data is fixed, not randomly generated: decks enumerate the standard 算数セット card ranges and are shuffled per session. "0 problems" means an operand or the answer is 0.
- localStorage access goes through `DailyStorage` and `BrowserPage.localValue` / `setLocalValue`, so private mode or blocked storage loads as empty instead of crashing the app.
- Changing the wire format: update `Wire.swift`/`Validation.swift`, `RemoteWire.swift`, `worker/protocol.js` and the exports in `Sources/Worker/Exports.swift` (and `Scripts/build-worker-wasm.sh`) together, and bump `WireRules.protocolVersion` when old clients cannot understand the new messages.

## Design Rules

- App-style full screen: the page never scrolls. Every screen fills the viewport and splits it into regions with flex ratios. Only inner lists (records) may scroll.
- Sizes are proportional: root font size follows `vmin`; cards, stamps, deck text and stamp slots size from their region with container query units. Container units resolve against an ancestor container, so set `container-type` on the parent of the element that uses `cq*` units.
- The app is used as a home-screen web app: respect safe-area insets through the `--safe-*` variables in `styles.css` (they wrap `env(safe-area-inset-*)`). Setting them on `document.documentElement` in the browser simulates a notch and home indicator for testing.
- Primary target is a phone in landscape (tap left/right half of the screen to go back/forward); portrait phones and desktop must still fit without scrolling. Check at least 812×375, 667×320, 375×812 and a desktop window, for both the child's screens and the Remote's screens.
- Use the theme variables in `styles.css` (`--bg`, `--surface`, `--line`, `--accent`, ...) instead of new hard-coded colors. The four deck colors (`.deck-red` etc.) and the stamp ink are fixed.
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

- Run `pnpm run lint` (`swift format lint --strict` and ESLint; CI runs it too) and `pnpm run format` to fix Swift formatting (config in `.swift-format`).
- Run `pnpm exec cf build` before committing UI or Swift changes; Embedded Swift can reject code that the regular SDK accepts. After a rebuild, restart a running `vite preview` (file names change).
- Verify UI changes in a browser at the sizes listed above, including the play flow with keyboard (→/Space/←) and taps, and the remote flow when it is affected.
- After changing dependencies, run `python3 Scripts/generate-licenses.py` and commit `public/licenses.html`.
- The local rate limiter keeps counting across runs: back-to-back full Playwright runs within a minute can hit it.

## Deploy and Git

- Pushing to `main` builds and tests in GitHub Actions (`swift:6.4.2` container; do not use `swift-actions/setup-swift@v2`) and deploys production with `cf deploy --prebuilt --mode production`. Pushing `staging` deploys staging. Add `[skip ci]` to the commit message when a push should not deploy.
- Staging can also be deployed locally: `pnpm exec cf deploy --prebuilt --mode staging`, then run the browser tests with `SPEEDMATH_TEST_URL=https://speedmath-staging.ainame-apps.workers.dev`.
- Commit each meaningful change separately. Version tags have no `v` prefix.
