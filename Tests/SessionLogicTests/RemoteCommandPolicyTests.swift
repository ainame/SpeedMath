import ProtocolModels
import SessionLogic
import Testing

private let settings = WireSettings(deck: 0, includeZero: false, count: 45, showTimer: true)

private func decide(_ action: RemoteAction, _ value: Int = 0, on screen: Screen) -> RemoteDecision {
  RemoteCommandPolicy.decide(action, value: value, screen: screen, settings: settings)
}

@Test func settingsChangeOnlyOnTheHomeScreen() {
  var changed = settings
  changed.deck = 3
  #expect(decide(.deck, 3, on: .home) == .changeSettings(changed))
  #expect(decide(.deck, 0, on: .home) == .answer(.unchanged), "choosing the current deck changes nothing")
  #expect(decide(.deck, 4, on: .home) == .answer(.resync))
  for screen in [Screen.ready, .playing, .finished] {
    #expect(decide(.deck, 3, on: screen) == .answer(.resync), "no choosing during a game")
  }
  changed = settings
  changed.includeZero = true
  #expect(decide(.zero, 1, on: .home) == .changeSettings(changed))
  changed = settings
  changed.count = 0
  #expect(decide(.count, 0, on: .home) == .changeSettings(changed))
  changed = settings
  changed.showTimer = false
  #expect(decide(.timer, 0, on: .home) == .changeSettings(changed))
  #expect(decide(.timer, 1, on: .home) == .answer(.unchanged))
}

@Test func navigationFollowsTheScreen() {
  #expect(decide(.start, on: .home) == .startPlay)
  #expect(decide(.start, on: .ready) == .answer(.resync))
  #expect(decide(.home, on: .home) == .answer(.unchanged))
  for screen in [Screen.ready, .playing, .finished] {
    #expect(decide(.home, on: screen) == .goHome, "えらびなおす / やめる from \(screen)")
  }
}

@Test func playActionsGoToThePlayScreen() {
  for action in [RemoteAction.begin, .next, .previous, .replay] {
    #expect(decide(action, on: .home) == .answer(.resync))
    #expect(decide(action, on: .playing) == .play(action))
  }
}
