import ProtocolModels

/// Lives only in the Presenter document. One event loop applies local and remote input.
public struct PlayState {
  public private(set) var phase: PlayPhase = .ready
  public private(set) var index = 0
  public private(set) var count = 0
  public private(set) var version = 0
  public private(set) var startedAt: Double = 0
  public private(set) var elapsed: Double = 0
  public private(set) var epoch = ""
  private var history: [Receipt] = []

  private struct Receipt {
    let command: Command
    let result: CommandResult
    let at: Double
  }

  public init() {}

  public mutating func start(count: Int, epoch: String, now: Double) {
    guard phase == .ready, count > 0 else { return }
    self.count = count
    self.epoch = epoch
    startedAt = now
    elapsed = 0
    index = 0
    version = 1
    history.removeAll()
    phase = .playing
  }

  public mutating func reset() { self = Self() }

  @discardableResult
  public mutating func move(_ direction: Direction, now: Double) -> CommandResult {
    guard phase == .playing else { return .resync }
    if direction == .previous {
      guard index > 0 else { return .unchanged }
      index -= 1
    } else if index + 1 < count {
      index += 1
    } else {
      elapsed = max(0, now - startedAt)
      phase = .finished
    }
    version += 1
    return .applied
  }

  public mutating func receive(_ command: Command, role: Role, now: Double) -> CommandResult {
    guard role == .remote, command.epoch == epoch else { return .resync }
    history.removeAll { now - $0.at > 30_000 }
    if let previous = history.first(where: { $0.command.id == command.id }) {
      return previous.command == command ? previous.result : .conflict
    }
    guard command.baseVersion == version, phase == .playing, history.count < 512 else { return .resync }
    let result = move(command.direction, now: now)
    // Consume the base version even at a boundary so an evicted no-op cannot be replayed.
    if result == .unchanged { version += 1 }
    history.append(Receipt(command: command, result: result, at: now))
    return result
  }
}
