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

/// Shows elapsed time as 「x ふん y びょう」 in whole seconds. Every digit sits in a fixed-width
/// cell, so the clock does not jitter as it ticks, regardless of whether the font has tabular
/// figures.
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
    func digit(_ value: Int) -> ClockGlyph { ClockGlyph(text: "\(value)", isDigit: true) }
    var glyphs: [ClockGlyph] = []
    if time.minutes >= 10 { glyphs.append(digit(time.minutes / 10)) }
    glyphs.append(digit(time.minutes % 10))
    glyphs.append(ClockGlyph(text: "ふん", isDigit: false))
    if time.seconds >= 10 { glyphs.append(digit(time.seconds / 10)) }
    glyphs.append(digit(time.seconds % 10))
    glyphs.append(ClockGlyph(text: "びょう", isDigit: false))
    return glyphs
  }
}
