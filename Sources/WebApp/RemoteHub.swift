import ProtocolModels
import Reactivity
import RemoteClient
import SessionLogic

/// What the play screen exposes to the hub while it is mounted.
struct PlayHook {
  /// The play screen's current state for a snapshot.
  let state: () -> PlayHookState
  /// Applies begin / next / previous / replay from the Remote.
  let perform: (RemoteAction) -> CommandResult
}

struct PlayHookState {
  let screen: Screen
  let index: Int
  let elapsed: Int
  let cards: [WireCard]
  let deckVersion: String
}

/// The child's device side of the remote control, for the whole app (not one screen): it owns the
/// Presenter's `RemoteLink`, keeps one ordered version of what the Remote sees, and turns Remote
/// commands into navigation, settings changes and play moves. Pairing therefore survives moving
/// between the home, play and finished screens.
@Reactive
final class RemoteHub {
  /// Pairing state for the views (panel, indicator, which controls the child gets).
  private(set) var model = RemoteModel()

  @ReactiveIgnored private var link: AppRemoteLink?
  @ReactiveIgnored private var ledger = CommandLedger(epoch: Browser.identifier())
  @ReactiveIgnored private var screen: Screen = .home
  @ReactiveIgnored private var play: PlayHook?
  @ReactiveIgnored private var settings: PlaySettings?
  @ReactiveIgnored private var navigateHome: (() -> Void)?
  @ReactiveIgnored private var navigatePlay: (() -> Void)?

  var isPaired: Bool { model.paired }

  /// Connects the hub to the app's settings and creates the Presenter link (which restores a
  /// pairing after a reload; it does not touch the network otherwise).
  func start(settings: PlaySettings) {
    guard link == nil else { return }
    self.settings = settings
    link = AppRemoteLink(
      role: .presenter,
      render: { [self] in model = $0 },
      presenter: { [self] in receive($0) })
  }

  /// Set by the app shell, which sits inside the router.
  func attachNavigation(home: @escaping () -> Void, play: @escaping () -> Void) {
    navigateHome = home
    navigatePlay = play
  }

  // MARK: Pairing panel (home screen only)

  func togglePanel() { link?.show() }
  func closePanel() {
    if model.open { link?.show() }
  }
  func newInvite() { link?.newInvite() }
  func retry() { link?.retry() }
  func begin() { link?.begin() }
  func decide(_ approved: Bool, request: String) { link?.decide(approved, request: request) }
  func revoke() { link?.revoke() }

  // MARK: State the Remote sees

  /// Pages report which screen they show; stamp and record pages count as home.
  func show(_ screen: Screen) {
    guard self.screen != screen else { return }
    self.screen = screen
    changed()
  }

  func attachPlay(_ hook: PlayHook) {
    play = hook
    screen = hook.state().screen
    changed()
  }

  func detachPlay() {
    play = nil
    changed()
  }

  /// Any change the Remote should see (a local tap, a new screen, a settings change).
  func changed() {
    ledger.bump()
    publish()
  }

  private func publish() {
    guard model.paired, let link, let settings else { return }
    let state = play?.state()
    let current = state?.screen ?? screen
    let onPlay = current == .playing || current == .finished
    guard
      let snapshot = Snapshot(
        epoch: ledger.epoch, deckVersion: state?.deckVersion ?? ledger.epoch, version: ledger.version,
        screen: current, index: onPlay ? state?.index ?? 0 : 0, elapsed: onPlay ? state?.elapsed ?? 0 : 0,
        cards: onPlay ? state?.cards ?? [] : [], settings: wireSettings(settings))
    else { return }
    link.publish(snapshot)
  }

  // MARK: Remote commands

  /// A Remote command, or nil when the Remote (re)connected and needs the current state.
  private func receive(_ command: Command?) {
    guard let command else { return publish() }
    let now = Browser.now()
    switch ledger.admit(command, now: now) {
    case .answer(let result):
      link?.receipt(epoch: command.epoch, id: command.id, result: result)
      if result == .resync { publish() }
    case .apply:
      let result = perform(command.action, value: command.value)
      ledger.record(command, result: result, now: now)
      link?.receipt(epoch: command.epoch, id: command.id, result: result)
      publish()
    }
  }

  /// Carries out what `RemoteCommandPolicy` decided for this screen.
  private func perform(_ action: RemoteAction, value: Int) -> CommandResult {
    guard let settings else { return .resync }
    let current = play?.state().screen ?? screen
    switch RemoteCommandPolicy.decide(action, value: value, screen: current, settings: wireSettings(settings)) {
    case .answer(let result):
      return result
    case .changeSettings(let updated):
      settings.deck = Deck.allCases[updated.deck]
      settings.includeZero = updated.includeZero
      settings.count = updated.count
      settings.showTimer = updated.showTimer
      return .applied
    case .startPlay:
      guard let navigatePlay else { return .resync }
      navigatePlay()
      return .applied
    case .goHome:
      navigateHome?()
      return .applied
    case .play(let action):
      return play?.perform(action) ?? .resync
    }
  }

  private func wireSettings(_ settings: PlaySettings) -> WireSettings {
    WireSettings(
      deck: Deck.allCases.firstIndex(of: settings.deck) ?? 0, includeZero: settings.includeZero,
      count: settings.count == 45 ? 45 : 0, showTimer: settings.showTimer)
  }
}
