import BrowserAPI
import ElementaryUI

/// App-level shortcuts to the browser (through `BrowserAPI`).
enum Browser {
  /// High-resolution timestamp in milliseconds (`performance.now()`).
  static func now() -> Double { BrowserPage.now }
}

/// Random source backed by `crypto.getRandomValues`, avoiding a dependency on WASI randomness.
struct BrowserRandom: RandomNumberGenerator {
  mutating func next() -> UInt64 {
    var value: UInt64 = 0
    for byte in BrowserPage.randomBytes(8) { value = value << 8 | UInt64(byte) }
    return value
  }
}

/// A key the card player reacts to.
enum CardKey {
  case next
  case previous
  /// Esc: leave the play screen, same as the ✕ やめる button.
  case quit
}

/// Owns one browser listener (key presses or an interval) for the lifetime of a mounted view.
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

  /// Listens for →, Space, ← and Esc on the document. Repeats from a held key and shortcuts with
  /// modifier keys are ignored; handled keys call `preventDefault()` so Space does not scroll.
  static func cardKeys(_ handler: @escaping (CardKey) -> Void) -> BrowserListener {
    BrowserListener {
      let subscription = BrowserPage.observeKeyDown { press in
        guard !press.isRepeat, !press.hasModifier else { return }
        let key: CardKey
        switch press.key {
        case "ArrowRight", " ": key = .next
        case "ArrowLeft": key = .previous
        case "Escape": key = .quit
        default: return
        }
        press.preventDefault()
        handler(key)
      }
      return { subscription.cancel() }
    }
  }

  /// Calls `handler` every `milliseconds`.
  static func interval(milliseconds: Int, _ handler: @escaping () -> Void) -> BrowserListener {
    BrowserListener {
      let timer = RepeatingTimer()
      timer.start(every: Double(milliseconds), handler)
      return { timer.stop() }
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
