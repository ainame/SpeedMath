import ProtocolModels

/// Lives only in the Presenter document. One event loop applies local and remote input.
public struct PlayState {
  public private(set) var phase: PlayPhase = .ready
  public private(set) var index = 0
  public private(set) var count = 0
  public private(set) var version = 0
  public private(set) var startedAt: Double = 0
  public private(set) var elapsed: Double = 0
  /// Identifies this shuffle; the Remote uses it to tell decks apart.
  public private(set) var epoch = ""

  public init() {}

  public mutating func start(count: Int, epoch: String, now: Double) {
    guard phase == .ready, count > 0 else { return }
    self.count = count
    self.epoch = epoch
    startedAt = now
    elapsed = 0
    index = 0
    version = 1
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
}
