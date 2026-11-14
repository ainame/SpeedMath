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

public struct Command: Equatable {
  public let id: String
  public let epoch: String
  public let baseVersion: Int
  public let direction: Direction

  public init(id: String, epoch: String, baseVersion: Int, direction: Direction) {
    self.id = id
    self.epoch = epoch
    self.baseVersion = baseVersion
    self.direction = direction
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
  public static let maxInteger = 2_147_483_647
  public static let maxCards = 54
  public static let maxElapsed = 86_400_000

  /// `[lhs, sign, rhs]` from the standard 算数セット ranges: lhs 1...18, rhs 0...9, an answer in 0...18.
  public static func validCard(lhs: Int, sign: Int, rhs: Int) -> Bool {
    guard lhs > 0, lhs <= 18, sign == 1 || sign == -1, rhs >= 0, rhs <= 9 else { return false }
    let answer = lhs + sign * rhs
    return answer >= 0 && answer <= 18
  }

  /// The numeric shape of a snapshot: ready has no cards and version 0; playing points at a card;
  /// finished points at the last card.
  public static func validSnapshot(version: Int, phase: Int, index: Int, count: Int, elapsed: Int) -> Bool {
    guard version >= 0, version <= maxInteger, index >= 0, count >= 0, count <= maxCards,
      elapsed >= 0, elapsed <= maxElapsed
    else { return false }
    switch phase {
    case 0: return version == 0 && count == 0 && index == 0 && elapsed == 0
    case 1: return version > 0 && index < count
    case 2: return version > 0 && index < count && index == count - 1
    default: return false
    }
  }
}
