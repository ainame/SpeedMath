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

  /// Listens for →, Space and ← on the document. Repeats from a held key are ignored, and handled
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

/// Formats milliseconds for kids, e.g. "12.3 びょう" or "1 ぷん 5.3 びょう".
func formatElapsed(_ milliseconds: Double) -> String {
  let tenths = Int(max(0, milliseconds) / 100)
  let minutes = tenths / 600
  let secondsTenths = tenths % 600
  let seconds = "\(secondsTenths / 10).\(secondsTenths % 10) びょう"
  guard minutes > 0 else { return seconds }
  let unit: String
  switch minutes % 10 {
  case 1, 3, 6, 8, 0: unit = "ぷん"
  default: unit = "ふん"
  }
  return "\(minutes) \(unit) \(seconds)"
}
