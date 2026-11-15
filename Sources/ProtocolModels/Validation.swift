// Wire limits and value checks shared by the Presenter, the Remote and (later) the Worker.
// Byte-level string handling keeps this Embedded Swift friendly: no Foundation, no Character parsing.

public enum Wire {
  public static let version = WireRules.protocolVersion
  public static let frameLimit = 8192
  public static let controlLimit = 512
  public static let maxCards = WireRules.maxCards
  public static let maxElapsed = WireRules.maxElapsed
  public static let maxInteger = WireRules.maxInteger

  /// Crockford-style Base32 alphabet used for the hand-typed pairing code.
  public static let codeAlphabet: [UInt8] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

  /// Normalizes a typed pairing code: drops spaces and hyphens, upper-cases ASCII, and reads
  /// O as 0 and I/L as 1. Returns the 12-character code, or nil when it cannot be one.
  public static func normalizeCode(_ input: String) -> String? {
    guard input.utf8.count <= 32 else { return nil }
    var out: [UInt8] = []
    for byte in input.utf8 {
      if byte == 0x20 || byte == 0x2D { continue }
      var c = byte
      if c >= 0x61 && c <= 0x7A { c -= 0x20 }
      if c == 0x4F { c = 0x30 }
      if c == 0x49 || c == 0x4C { c = 0x31 }
      guard codeAlphabet.contains(c) else { return nil }
      out.append(c)
    }
    return out.count == 12 ? String(decoding: out, as: UTF8.self) : nil
  }

  /// `XXXX-XXXX-XXXX` for display.
  public static func formatCode(_ code: String) -> String {
    var out: [UInt8] = []
    for (i, byte) in code.utf8.enumerated() {
      if i > 0 && i % 4 == 0 { out.append(0x2D) }
      out.append(byte)
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Lower-case hex of exactly `count` characters (32 for ids, 64 for keys).
  public static func isHex(_ value: String, count: Int) -> Bool {
    var n = 0
    for byte in value.utf8 {
      guard (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) else { return false }
      n += 1
    }
    return n == count
  }

  public static func isID(_ value: String) -> Bool { isHex(value, count: 32) }
  public static func isKey(_ value: String) -> Bool { isHex(value, count: 64) }

  public static func hex(_ bytes: [UInt8]) -> String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      out.append(digits[Int(byte >> 4)])
      out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// A non-negative integer no larger than `max`, as JS `Number.isSafeInteger` would accept.
  public static func uint(_ value: Double?, max: Int = maxInteger) -> Int? {
    guard let value, value >= 0, value <= Double(max), value == value.rounded(.towardZero) else { return nil }
    return Int(value)
  }
}

/// One card on the wire: `[lhs, sign, rhs]` with sign 1 for + and -1 for −. Answers are derived
/// only by the Remote, so they are never sent.
public struct WireCard: Equatable, Sendable {
  public let lhs: Int
  public let sign: Int
  public let rhs: Int

  public init?(lhs: Int, sign: Int, rhs: Int) {
    guard WireRules.validCard(lhs: lhs, sign: sign, rhs: rhs) else { return nil }
    self.lhs = lhs
    self.sign = sign
    self.rhs = rhs
  }

  public var answer: Int { lhs + sign * rhs }
}

/// The settings chosen on the home screen, as sent on the wire.
public struct WireSettings: Equatable, Sendable {
  /// Index in `Deck.allCases`.
  public var deck: Int
  public var includeZero: Bool
  /// 0 plays the whole deck.
  public var count: Int
  public var showTimer: Bool

  public init(deck: Int, includeZero: Bool, count: Int, showTimer: Bool) {
    self.deck = deck
    self.includeZero = includeZero
    self.count = count
    self.showTimer = showTimer
  }
}

/// The Presenter's state as relayed to the Remote.
public struct Snapshot: Equatable, Sendable {
  public let epoch: String
  public let deckVersion: String
  public let version: Int
  public let screen: Screen
  public let index: Int
  public let elapsed: Int
  public let cards: [WireCard]
  public let settings: WireSettings

  public init?(
    epoch: String, deckVersion: String, version: Int, screen: Screen, index: Int, elapsed: Int,
    cards: [WireCard], settings: WireSettings
  ) {
    guard Wire.isID(epoch), Wire.isID(deckVersion),
      WireRules.validSnapshot(
        version: version, screen: Int(screen.rawValue), index: index, cards: cards.count, elapsed: elapsed,
        deck: settings.deck, zero: settings.includeZero ? 1 : 0, count: settings.count,
        timer: settings.showTimer ? 1 : 0)
    else { return nil }
    self.epoch = epoch
    self.deckVersion = deckVersion
    self.version = version
    self.screen = screen
    self.index = index
    self.elapsed = elapsed
    self.cards = cards
    self.settings = settings
  }
}
