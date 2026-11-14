# Repository Guidelines

SpeedMath（スピードけいさん）は小学生向けの計算カードアプリです。Swift で書かれ、WebAssembly としてブラウザで動きます。公開先は https://ainame.github.io/SpeedMath/ です。

## Stack

- [ElementaryUI](https://github.com/elementary-swift/elementary-ui) 0.9.x for views and reactivity (`@View`, `@State`, `@Environment`, `@Reactive` from `Reactivity`).
- [elementary-router](https://github.com/ainame/elementary-router) (`main` branch, pinned in `Package.resolved`) for typed routes via `@Routes`.
- JavaScriptKit for the few browser APIs ElementaryUI does not expose.
- Vite + `@elementary-swift/vite-plugin-swift-wasm`. `npm run build` uses the Embedded Swift SDK (`useEmbeddedSDK: true`); `npm run dev` uses the regular WASM SDK.
- Swift 6.4.2 toolchain (pinned in `.swift-version`, same as CI) with matching `swift-6.4.2-RELEASE_wasm` / `_wasm-embedded` SDKs.

## Layout

- `Sources/WebApp/App.swift`: entry point. `AppRoot` owns app-wide state (`PlaySettings`, `StampBook`, `TodayRecords`) above `AppRoutes.RouterView()` and passes it through `.environment`.
- `AppRoutes.swift`: the route tree (`/`, `/play/:deck`, `/stamps`, `/records`, fallbacks).
- `AppShell.swift`: the layout around every route (title header).
- `Pages.swift`: all screens and their small views (home, play session, finished screen, stamp card, records).
- `Deck.swift`: the four 計算カード decks and their exact card ranges. `Stamp.swift`: reward stamps.
- `StampBook.swift`, `TodayRecords.swift`, `DailyStorage.swift`: per-day data in localStorage, reset at local midnight.
- `RemoteLink.swift`: the remote-control client for both roles (WebSocket, reconnect, pairing, ordered sync, command resend). `RemoteWire.swift` validates frames; `RemoteJS.swift` holds timer/listener/promise helpers; `RemoteViews.swift` renders the pairing panel and the Remote screen. Pure wire checks live in `Sources/ProtocolModels`.
- `Sources/Worker`: the remote-control backend in Swift (Embedded): `Router` (`/api/*`), `SessionObject` and `CodeShard` (Durable Objects), `Platform` (Workers runtime access). `worker/index.js` only forwards Cloudflare's calls to it, because Workers require the entry and Durable Object classes to be JavaScript. It uses Swift concurrency through `typealias DefaultExecutorFactory = JavaScriptEventLoop` and an `async` `main` that stays suspended; see [docs/decisions/0001-worker-without-async-await.md](docs/decisions/0001-worker-without-async-await.md) before changing that.
- `Sources/RemoteProtocol`: shared by the browser and the Worker: JS helpers (`JSBridge.swift`), and frame validation (`RemoteWire.swift`).
- `web/main.js`: only bridges (`window.speedMathBridge`: non-throwing `JSON.parse`, the QR library, sessionStorage). Do not add app logic in JS.
- `Browser.swift`: JavaScriptKit helpers (time, random, key/interval listeners) and the clock formatting.
- `index.html`: the whole stylesheet, plus `window.speedMathStorage` (localStorage wrapper with try/catch).
- `public/stamps/*.svg`: original stamp artwork (part of this repo, MIT). `public/favicon.svg`: original app icon; regenerate `favicon-32.png` and the square, unrounded `apple-touch-icon.png` (180px) from it with `rsvg-convert`. `public/licenses.html`: generated third-party license page.
- `Scripts/generate-licenses.py`: regenerates `public/licenses.html` from the dependency license files.

## Implementation Constraints

- Do not import Foundation. Keep code Embedded Swift compatible: no `Codable`/JSON in Swift, no `Character`-level string parsing, no existential-heavy designs. Parse and build JSON on the JS side (`JSON.parse`/`stringify` via `window.speedMathStorage`) and read fields through `JSObject`.
- Call browser APIs through JavaScriptKit (`JSObject.global...`). Do not depend on ElementaryUI internals such as `BrowserInterop`.
- Global keyboard and timers use `BrowserListener` attached with `.attach(...)` so they are removed on unmount. Use `ElementaryUI`'s `.id(...)` when a view must restart with new parameters (see `PlayPage` keying `PlaySession`).
- Routing uses `@Routes(mode: .hash)` on purpose: GitHub Pages serves the app under `/SpeedMath/`, elementary-router has no base path option yet, and hash mode needs no link-interception script. Do not switch to path mode until elementary-router supports a base path.
- Card data is fixed, not randomly generated: decks enumerate the standard 算数セット card ranges and are shuffled per session. "0 problems" means an operand or the answer is 0.
- localStorage access must go through `DailyStorage` / `window.speedMathStorage` so private mode or blocked storage never crashes the app.

## Design Rules

- App-style full screen: the page never scrolls. Every screen fills the viewport and splits it into regions with flex ratios. Only inner lists (records) may scroll.
- Sizes are proportional: root font size follows `vmin`; cards, stamps, deck text and stamp slots size from their region with container query units. Container units resolve against an ancestor container, so set `container-type` on the parent of the element that uses `cq*` units.
- The app is used as a home-screen web app: respect safe-area insets through the `--safe-*` variables in `index.html` (they wrap `env(safe-area-inset-*)`). Setting them on `document.documentElement` in the browser simulates a notch and home indicator for testing.
- Primary target is a phone in landscape (tap left/right half of the screen to go back/forward); portrait phones and desktop must still fit without scrolling. Check at least 812×375, 667×320, 375×812 and a desktop window.
- Use the theme variables in `index.html` (`--bg`, `--surface`, `--line`, `--accent`, ...) instead of new hard-coded colors. The four deck colors (`.deck-red` etc.) and the stamp ink are fixed.
- Keep the look simple and kid-friendly: outlined, rounded components (radio-card style selection, outlined list items). Avoid colored edge accents (thick left/bottom highlight bars) and hard drop shadows under buttons.
- Text is in hiragana for first graders.

## Build and Verify

```sh
npm install
npm run dev                                        # dev server with hot reload
swift build --swift-sdk swift-6.4.0-RELEASE_wasm   # quick type check (use your installed SDK name)
npm run build                                      # release (Embedded) bundle in dist/
npm run preview                                    # serve dist/ locally
```

- Run `npm run build` before committing UI or Swift changes; Embedded Swift can reject code that the regular SDK accepts.
- Verify UI changes in a browser at the sizes listed above, including the play flow with keyboard (→/Space/←) and taps.
- After changing dependencies, run `python3 Scripts/generate-licenses.py` and commit `public/licenses.html`.

## Deploy and Git

- Pushing to `main` deploys to GitHub Pages via `.github/workflows/deploy.yml` (builds inside the `swift:6.4.2` container; do not use `swift-actions/setup-swift@v2`). Add `[skip ci]` to the commit message when a push should not deploy.
- Commit each meaningful change separately. Version tags have no `v` prefix.
