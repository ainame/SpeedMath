import BrowserAPI
import ElementaryUI

/// Visible running clock. The measurement itself lives in `PlayPage`, so hiding this view does
/// not stop the timer.
@View
struct LiveTimer {
  let startedAt: Double
  @State var now: Double = 0
  @State var ticker = BrowserListener()

  var body: some View {
    ClockDisplay(milliseconds: now - startedAt)
      .onAppear {
        now = Browser.now()
        ticker.repeatEvery(milliseconds: 100) { now = Browser.now() }
      }
      .onDisappear { ticker.detach() }
  }
}

/// Shows elapsed time as `mm:ss.s`. Every glyph sits in a fixed-width cell, so the layout never
/// shifts as digits change, regardless of whether the font has tabular figures.
@View
struct ClockDisplay {
  let milliseconds: Double

  var body: some View {
    span(.class("clock")) {
      for glyph in ClockGlyph.glyphs(milliseconds: milliseconds) {
        span(.class(glyph.isDigit ? "clock-digit" : "clock-separator")) { glyph.text }
      }
    }
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
