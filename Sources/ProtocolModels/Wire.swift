public enum Role: Int32 {
  case presenter = 1
  case remote = 2

  public func canRelay(_ kind: RelayKind) -> Bool {
    switch (self, kind) {
    case (.presenter, .sync), (.presenter, .ack), (.remote, .command), (.remote, .requestSync): true
    default: false
    }
  }
}

public enum RelayKind: Int32 {
  case sync = 1
  case ack = 2
  case command = 3
  case requestSync = 4
}

public enum PlayPhase: Int32 {
  case ready = 0
  case playing = 1
  case finished = 2
}

public enum Direction: Int32 {
  case previous = -1
  case next = 1
}

/// Which screen the Presenter (child's device) shows. The Remote mirrors it.
public enum Screen: Int32 {
  /// Choosing cards and options (also reported from the stamp and record pages).
  case home = 0
  /// Deck chosen, waiting for はじめる.
  case ready = 1
  case playing = 2
  case finished = 3
}

/// What the Remote asks the Presenter to do. Settings actions carry their value; the others send 0.
public enum RemoteAction: Int32 {
  case next = 1
  case previous = 2
  /// Home → ready with the chosen settings (スタート！).
  case start = 3
  /// Ready → playing (はじめる).
  case begin = 4
  /// Finished → ready with a new shuffle (もういちど).
  case replay = 5
  /// Any screen → home (えらびなおす / やめる).
  case home = 6
  /// Deck index in `Deck.allCases` order, 0...3.
  case deck = 7
  /// Include problems with 0: 0 or 1.
  case zero = 8
  /// Card count: 0 (the whole deck) or 45.
  case count = 9
  /// Show the running timer: 0 or 1.
  case timer = 10
}

public struct Command: Equatable {
  public let id: String
  public let epoch: String
  public let baseVersion: Int
  public let action: RemoteAction
  public let value: Int

  public init(id: String, epoch: String, baseVersion: Int, action: RemoteAction, value: Int = 0) {
    self.id = id
    self.epoch = epoch
    self.baseVersion = baseVersion
    self.action = action
    self.value = value
  }
}

public enum CommandResult: Int32 {
  case applied = 1
  case unchanged = 2
  case resync = 3
  case conflict = 4
}

/// Integer-only play rules shared by the browser (Swift) and the Worker (through the tiny
/// import-free `logic.wasm` built from this file and `Sources/Worker/Exports.swift`). Keep this
/// free of strings, arrays and allocation so it links without a heap.
public enum WireRules {
  /// The wire protocol version. The browser (`Wire.version`), the JS Worker (`VERSION` in
  /// worker/protocol.js) and `/api/health` all read this one value.
  public static let protocolVersion = 2
  public static let maxInteger = 2_147_483_647
  public static let maxCards = 54
  public static let maxElapsed = 86_400_000

  /// `[lhs, sign, rhs]` from the standard 算数セット ranges: lhs 1...18, rhs 0...9, an answer in 0...18.
  public static func validCard(lhs: Int, sign: Int, rhs: Int) -> Bool {
    guard lhs > 0, lhs <= 18, sign == 1 || sign == -1, rhs >= 0, rhs <= 9 else { return false }
    let answer = lhs + sign * rhs
    return answer >= 0 && answer <= 18
  }

  /// The numeric shape of a snapshot. Home and ready carry no cards; playing points at a card;
  /// finished points at the last card. Settings are always present.
  public static func validSnapshot(
    version: Int, screen: Int, index: Int, cards: Int, elapsed: Int,
    deck: Int, zero: Int, count: Int, timer: Int
  ) -> Bool {
    guard version >= 0, version <= maxInteger, index >= 0, cards >= 0, cards <= maxCards,
      elapsed >= 0, elapsed <= maxElapsed, validSetting(.deck, deck), validSetting(.zero, zero),
      validSetting(.count, count), validSetting(.timer, timer)
    else { return false }
    switch screen {
    case 0, 1: return cards == 0 && index == 0 && elapsed == 0
    case 2: return index < cards
    case 3: return index < cards && index == cards - 1
    default: return false
    }
  }

  /// A Remote command: settings actions with a valid value, the others with 0.
  public static func validCommand(action: Int, value: Int) -> Bool {
    guard let kind = RemoteAction(rawValue: Int32(truncatingIfNeeded: action)), action >= 1, action <= 10 else {
      return false
    }
    switch kind {
    case .deck, .zero, .count, .timer: return validSetting(kind, value)
    default: return value == 0
    }
  }

  private static func validSetting(_ kind: RemoteAction, _ value: Int) -> Bool {
    switch kind {
    case .deck: return value >= 0 && value <= 3
    case .zero, .timer: return value == 0 || value == 1
    case .count: return value == 0 || value == 45
    default: return false
    }
  }
}
