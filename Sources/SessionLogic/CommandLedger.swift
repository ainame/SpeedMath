import ProtocolModels

/// The Presenter's single ordering point for everything the Remote sees: one version that grows
/// with every state change, and the recent Remote commands so a resent command is answered with its
/// first result instead of being applied twice.
public struct CommandLedger {
  /// Identifies this Presenter document. A reload starts a new epoch, so old commands are refused.
  public let epoch: String
  public private(set) var version = 0
  private var history: [Receipt] = []

  private struct Receipt {
    let command: Command
    let result: CommandResult
    let at: Double
  }

  /// How long a command id is remembered; longer than the Remote's resend window (20 s).
  public static let window: Double = 30_000

  public enum Admission: Equatable {
    /// Apply it, then call `record`.
    case apply
    /// Do not apply; answer with this result.
    case answer(CommandResult)
  }

  public init(epoch: String) {
    self.epoch = epoch
  }

  /// Any state change the Remote should see, from either side.
  public mutating func bump() { version += 1 }

  public mutating func admit(_ command: Command, now: Double) -> Admission {
    guard command.epoch == epoch else { return .answer(.resync) }
    history.removeAll { now - $0.at > Self.window }
    if let previous = history.first(where: { $0.command.id == command.id }) {
      return .answer(previous.command == command ? previous.result : .conflict)
    }
    guard command.baseVersion == version, history.count < 512 else { return .answer(.resync) }
    return .apply
  }

  /// Records an applied command. The version moves on even when nothing changed, so a command
  /// evicted from the history can never be applied again.
  public mutating func record(_ command: Command, result: CommandResult, now: Double) {
    history.append(Receipt(command: command, result: result, at: now))
    version += 1
  }
}
