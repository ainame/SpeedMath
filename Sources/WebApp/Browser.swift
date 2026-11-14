import ElementaryUI
import JavaScriptKit

/// Small JavaScriptKit helpers for things ElementaryUI does not expose publicly.
enum Browser {
  /// High-resolution timestamp in milliseconds (`performance.now()`).
  static func now() -> Double {
    guard let performance = JSObject.global.performance.object else { return 0 }
    return performance["now"].function?.callAsFunction(this: performance).number ?? 0
  }

  static func random() -> Double {
    guard let math = JSObject.global.Math.object else { return 0 }
    return math["random"].function?.callAsFunction(this: math).number ?? 0
  }
}

/// Random source backed by `Math.random()`, avoiding a dependency on WASI randomness.
struct BrowserRandom: RandomNumberGenerator {
  mutating func next() -> UInt64 {
    let high = UInt64(Browser.random() * 4_294_967_296)
    let low = UInt64(Browser.random() * 4_294_967_296)
    return (high << 32) | low
  }
}

/// A key the card player reacts to.
enum CardKey {
  case next
  case previous
  /// Esc: leave the play screen, same as the ✕ やめる button.
  case quit
}

/// Owns one JS listener (keydown or interval) for the lifetime of a mounted view.
final class BrowserListener {
  private let start: () -> (() -> Void)
  private var stop: (() -> Void)?

  init(start: @escaping () -> (() -> Void)) {
    self.start = start
  }

  func attach() {
    guard stop == nil else { return }
    stop = start()
  }

  func detach() {
    stop?()
    stop = nil
  }

  /// Listens for →, Space, ← and Esc on the document. Repeats from a held key are ignored, and handled
  /// keys call `preventDefault()` so Space does not scroll the page.
  static func cardKeys(_ handler: @escaping (CardKey) -> Void) -> BrowserListener {
    BrowserListener {
      let closure = JSClosure { arguments in
        guard let event = arguments.first?.object else { return .undefined }
        if event.repeat.boolean == true { return .undefined }
        if event.ctrlKey.boolean == true || event.metaKey.boolean == true || event.altKey.boolean == true {
          return .undefined
        }
        let key: CardKey
        switch event.key.string {
        case "ArrowRight", " ": key = .next
        case "ArrowLeft": key = .previous
        case "Escape": key = .quit
        default: return .undefined
        }
        _ = event["preventDefault"].function?.callAsFunction(this: event)
        handler(key)
        return .undefined
      }
      let document = JSObject.global.document
      _ = document.object?["addEventListener"].function?.callAsFunction(
        this: document.object!,
        "keydown",
        closure
      )
      return {
        _ = document.object?["removeEventListener"].function?.callAsFunction(
          this: document.object!,
          "keydown",
          closure
        )
      }
    }
  }

  /// Calls `handler` every `milliseconds` via `setInterval`.
  static func interval(milliseconds: Int, _ handler: @escaping () -> Void) -> BrowserListener {
    BrowserListener {
      let closure = JSClosure { _ in
        handler()
        return .undefined
      }
      let id = JSObject.global["setInterval"].function?.callAsFunction(
        this: JSObject.global,
        closure,
        milliseconds
      )
      return {
        if let id {
          _ = JSObject.global["clearInterval"].function?.callAsFunction(this: JSObject.global, id)
        }
      }
    }
  }
}

extension View {
  /// Attaches `listener` while this view is mounted.
  func attach(_ listener: BrowserListener) -> some View<Tag> {
    self
      .onAppear { listener.attach() }
      .onDisappear { listener.detach() }
  }
}

/// One character cell of the `mm:ss.s` clock.
struct ClockGlyph {
  let text: String
  let isDigit: Bool

  /// Splits milliseconds into `m m : s s . t`, capped at 99:59.9.
  static func glyphs(milliseconds: Double) -> [ClockGlyph] {
    let tenths = min(Int(max(0, milliseconds) / 100), 99 * 600 + 599)
    let minutes = tenths / 600
    let seconds = (tenths % 600) / 10
    func digit(_ value: Int) -> ClockGlyph { ClockGlyph(text: "\(value)", isDigit: true) }
    func separator(_ text: String) -> ClockGlyph { ClockGlyph(text: text, isDigit: false) }
    return [
      digit(minutes / 10), digit(minutes % 10), separator(":"),
      digit(seconds / 10), digit(seconds % 10), separator("."),
      digit(tenths % 10),
    ]
  }
}
