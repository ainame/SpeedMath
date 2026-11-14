import Reactivity

/// Choices made on the home screen. Lives above the router so they survive navigation.
@Reactive
final class PlaySettings {
  /// Card counts offered on the home screen; `0` means the whole deck.
  static let countOptions = [45, 0]

  var deck: Deck = .additionNoCarry
  var count: Int = 45
  var showTimer: Bool = true
}
