import BrowserAPI
import ElementaryUI
import SessionLogic

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
        ticker.repeatEvery(milliseconds: 200) { now = Browser.now() }
      }
      .onDisappear { ticker.detach() }
  }
}

/// Shows elapsed time as 「x ふん y びょう」 in whole seconds. Minutes and seconds always take two
/// fixed-width digit cells (a one-digit value leaves the first cell blank instead of showing a
/// leading zero), so the clock keeps the same width from 0ふん 0びょう to 99ふん 59びょう.
@View
struct ClockDisplay {
  let milliseconds: Double

  var body: some View {
    span(.class("clock")) {
      for glyph in ClockGlyph.glyphs(ClockTime(milliseconds: milliseconds)) {
        span(.class(glyph.isDigit ? "clock-digit" : "clock-unit")) { glyph.text }
      }
    }
  }
}

/// One cell of the 「x ふん y びょう」 clock.
struct ClockGlyph {
  let text: String
  let isDigit: Bool

  static func glyphs(_ time: ClockTime) -> [ClockGlyph] {
    /// Two digit cells; the tens cell stays empty (but keeps its width) below 10.
    func twoCells(_ value: Int) -> [ClockGlyph] {
      [
        ClockGlyph(text: value >= 10 ? "\(value / 10)" : "", isDigit: true),
        ClockGlyph(text: "\(value % 10)", isDigit: true),
      ]
    }
    return twoCells(time.minutes) + [ClockGlyph(text: "ふん", isDigit: false)]
      + twoCells(time.seconds) + [ClockGlyph(text: "びょう", isDigit: false)]
  }
}
