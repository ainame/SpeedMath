/// Reward stamps shown on the finished screen. The artwork is original SVG in `public/stamps`.
enum Stamp: String, CaseIterable {
  case yokuDekimashita = "yoku-dekimashita"
  case hanamaru
  case neko
  case kuma
  case usagi
  case sakura

  var path: String { "stamps/\(rawValue).svg" }

  var label: String {
    switch self {
    case .yokuDekimashita: "よくできました"
    case .hanamaru: "はなまる"
    case .neko: "すごい！"
    case .kuma: "がんばったね"
    case .usagi: "えらい！"
    case .sakura: "できたね！"
    }
  }

  static func random(from stamps: [Stamp] = Stamp.allCases) -> Stamp {
    var rng = BrowserRandom()
    return stamps.randomElement(using: &rng) ?? .yokuDekimashita
  }

  /// A slight tilt to the left or right, 5–13 degrees, like a hand-pressed stamp.
  static func randomTilt() -> Int {
    var rng = BrowserRandom()
    let magnitude = Int.random(in: 5...13, using: &rng)
    return Bool.random(using: &rng) ? -magnitude : magnitude
  }

  /// Fixed per-slot tilts for the stamp card, so the layout does not jitter between renders.
  static let slotTilts = [-9, 7, -5, 11, -12, 6]
}
