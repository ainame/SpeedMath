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
