import ProtocolModels

/// What a Remote command means on the Presenter's current screen. Pure, so every rule is tested
/// without a browser; `RemoteHub` carries out the effect.
public enum RemoteDecision: Equatable {
  /// Nothing to do; answer the Remote with this result.
  case answer(CommandResult)
  /// Store these settings (home screen only).
  case changeSettings(WireSettings)
  /// Home → the play screen's はじめる step with the current settings.
  case startPlay
  /// Back to the home screen.
  case goHome
  /// A play-screen action (begin, next, previous, replay) for the play screen to apply.
  case play(RemoteAction)
}

public enum RemoteCommandPolicy {
  public static let deckCount = 4

  public static func decide(_ action: RemoteAction, value: Int, screen: Screen, settings: WireSettings)
    -> RemoteDecision
  {
    switch action {
    case .deck, .zero, .count, .timer:
      guard screen == .home else { return .answer(.resync) }
      var updated = settings
      switch action {
      case .deck:
        guard value >= 0, value < deckCount else { return .answer(.resync) }
        updated.deck = value
      case .zero: updated.includeZero = value == 1
      case .count: updated.count = value
      default: updated.showTimer = value == 1
      }
      return updated == settings ? .answer(.unchanged) : .changeSettings(updated)
    case .start:
      return screen == .home ? .startPlay : .answer(.resync)
    case .home:
      return screen == .home ? .answer(.unchanged) : .goHome
    case .begin, .next, .previous, .replay:
      return screen == .home ? .answer(.resync) : .play(action)
    }
  }
}
