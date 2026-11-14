/// Reward stamps shown on the finished screen. The artwork is original SVG in `public/stamps`.
enum Stamp: CaseIterable {
  case yokuDekimashita
  case hanamaru
  case neko
  case kuma
  case usagi
  case sakura

  var path: String {
    switch self {
    case .yokuDekimashita: "stamps/yoku-dekimashita.svg"
    case .hanamaru: "stamps/hanamaru.svg"
    case .neko: "stamps/neko.svg"
    case .kuma: "stamps/kuma.svg"
    case .usagi: "stamps/usagi.svg"
    case .sakura: "stamps/sakura.svg"
    }
  }

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

  static func random() -> Stamp {
    let all = Stamp.allCases
    return all[min(Int(Browser.random() * Double(all.count)), all.count - 1)]
  }
}
