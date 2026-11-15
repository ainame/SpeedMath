import ElementaryRouter
import ElementaryUI
import ProtocolModels
import RemoteProtocol
import SessionLogic

@View
struct PlayPage {
  let deck: Deck
  let count: Int
  let showTimer: Bool
  let includeZero: Bool

  var body: some View {
    // Keyed by the route values so a new deck/count/timer setting starts a fresh session, with
    // fresh state and a key listener that sees the new values.
    PlaySession(deck: deck, count: count, showTimer: showTimer, includeZero: includeZero)
      .id("\(deck.rawValue)/\(count)/\(showTimer)/\(includeZero)")
  }
}

/// One play of a deck. While a Remote is paired, the parent moves between screens (はじめる,
/// もういちど, えらびなおす, やめる) and the child's screen hides those buttons; card taps and the
/// arrow keys still work on both sides. Records and stamps are always kept on this device.
@View
struct PlaySession {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @Environment(AppRoutes._routerEnvironmentKey) var router

  let deck: Deck
  let count: Int
  let showTimer: Bool
  let includeZero: Bool

  @State var play = PlayState()
  @State var cards: [Card] = []
  /// Identifies the current shuffle for the Remote (a new one for each はじめる).
  @State var deckID = ""
  @State var stamp: Stamp = .yokuDekimashita
  @State var isNewStamp: Bool = false
  @State var stampTilt: Int = -8
  @Environment(StampBook.self) var stampBook: StampBook
  @Environment(TodayRecords.self) var records: TodayRecords
  @Environment(RemoteHub.self) var hub: RemoteHub

  var body: some View {
    section(.class("play")) {
      switch play.phase {
      case .ready:
        div(.class("ready")) {
          p(.class("ready-deck")) { "\(deck.title)（\(deck.subtitle)）" }
          p(.class("ready-count")) { "\(drawCount)まい" }
          if hub.isPaired {
            p(.class("remote-wait")) { "リモコンで はじめてね" }
          } else {
            button(.type(.button), .class("big-button")) { "はじめる" }
              .onClick { start() }
            p(.class("hint hint-keys")) { "スペース か → で はじまるよ" }
          }
        }
        backLink

      case .playing:
        div(.class("progress")) {
          div(.class("progress-side")) {
            if let routes, !hub.isPaired {
              AppRoutes.Link(to: routes.home()) { "✕ やめる" }
            }
          }
          span(.class("progress-count")) { "\(play.index + 1) / \(cards.count)" }
          div(.class("progress-side progress-timer")) {
            if showTimer {
              LiveTimer(startedAt: play.startedAt)
            }
          }
        }
        if play.index < cards.count {
          div(.class("card-area")) {
            div(.class("card \(deck.colorClass)")) {
              cards[play.index].question
              if play.index > 0 {
                span(.class("card-arrow card-arrow-previous")) {}
              }
              span(.class("card-arrow card-arrow-next")) {}
            }
            // The screen is split into two invisible tap zones: left goes back, right goes forward.
            div(.class("tap-zone tap-previous")) {}
              .onClick { goBack() }
            div(.class("tap-zone tap-next")) {}
              .onClick { advance() }
          }
        }
        if hub.isPaired {
          p(.class("hint hint-keys")) { "← まえ ／ → か スペース で つぎ" }
        } else {
          p(.class("hint hint-keys")) { "← まえ ／ → か スペース で つぎ ／ esc で やめる" }
        }
        p(.class("hint hint-touch")) { "ひだりを タップで まえ ／ みぎを タップで つぎ" }

      case .finished:
        div(.class("finished")) {
          img(.src(stamp.path), .alt(stamp.label), .class("stamp"), .style(["--tilt": "\(stampTilt)deg"]))
          div(.class("finished-info")) {
            p(.class("finished-title")) { "おわり！" }
            p(.class("finished-time")) { ClockDisplay(milliseconds: play.elapsed) }
            p(.class("finished-count")) { "\(cards.count)まい できたね" }
            p(.class("finished-stamp")) { stampMessage }
            if hub.isPaired {
              p(.class("remote-wait")) { "リモコンで つぎを えらんでね" }
            } else {
              button(.type(.button), .class("big-button")) { "もういちど" }
                .onClick { replay() }
            }
          }
        }
        backLink
      }
    }
    .attach(BrowserListener.cardKeys { key in handle(key) })
    .onAppear {
      deckID = Browser.identifier()
      hub.attachPlay(PlayHook(state: { hookState }, perform: { perform($0) }))
    }
    .onDisappear { hub.detachPlay() }
  }

  @ContentBuilder private var backLink: some View {
    if !hub.isPaired {
      div(.class("back")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) { "カードを えらびなおす" }
        }
      }
    }
  }

  private var stampMessage: String {
    let total = Stamp.allCases.count
    if !isNewStamp { return "きょうの スタンプは ぜんぶ あつめたよ！" }
    if stampBook.isComplete { return "スタンプ ゲット！ ぜんぶ そろった！" }
    return "スタンプ ゲット！（\(stampBook.stamps.count)/\(total)）"
  }

  private var drawCount: Int {
    let size = deck.cards(includeZero: includeZero).count
    return count <= 0 || count > size ? size : count
  }

  private func handle(_ key: CardKey) {
    switch (play.phase, key) {
    case (.ready, .next):
      if !hub.isPaired { start() }
    case (.playing, .next):
      advance()
    case (.playing, .previous):
      goBack()
    case (_, .quit):
      if !hub.isPaired { quit() }
    default:
      break
    }
  }

  /// Back to the home screen, like the ✕ やめる button.
  private func quit() {
    guard let routes, let router else { return }
    try? router.navigate(to: routes.home())
  }

  @discardableResult
  private func start() -> CommandResult {
    guard play.phase == .ready else { return .resync }
    var rng = BrowserRandom()
    cards = deck.draw(count: count, includeZero: includeZero, using: &rng)
    deckID = Browser.identifier()
    play.start(count: cards.count, epoch: deckID, now: Browser.now())
    hub.changed()
    return .applied
  }

  @discardableResult
  private func replay() -> CommandResult {
    guard play.phase == .finished else { return .resync }
    deckID = Browser.identifier()
    play.reset()
    cards = []
    hub.changed()
    return .applied
  }

  private func goBack() { move(.previous) }
  private func advance() { move(.next) }

  @discardableResult
  private func move(_ direction: Direction) -> CommandResult {
    let before = play.phase
    let result = play.move(direction, now: Browser.now())
    afterMove(from: before)
    hub.changed()
    return result
  }

  /// Begin / next / previous / replay sent by the Remote through the hub.
  private func perform(_ action: RemoteAction) -> CommandResult {
    switch action {
    case .begin: start()
    case .next: move(.next)
    case .previous: move(.previous)
    case .replay: replay()
    default: .resync
    }
  }

  private func afterMove(from before: PlayPhase) {
    guard before == .playing, play.phase == .finished else { return }
    records.add(deck: deck, count: cards.count, includeZero: includeZero, milliseconds: play.elapsed)
    let award = stampBook.award()
    stamp = award.stamp
    isNewStamp = award.isNew
    stampTilt = Stamp.randomTilt()
  }

  private var hookState: PlayHookState {
    let screen: Screen =
      switch play.phase {
      case .ready: .ready
      case .playing: .playing
      case .finished: .finished
      }
    let elapsed: Double =
      switch play.phase {
      case .ready: 0
      case .playing: max(0, Browser.now() - play.startedAt)
      case .finished: play.elapsed
      }
    var wire: [WireCard] = []
    if play.phase != .ready {
      for card in cards {
        if let value = WireCard(lhs: card.lhs, sign: card.op == .plus ? 1 : -1, rhs: card.rhs) { wire.append(value) }
      }
    }
    return PlayHookState(
      screen: screen, index: play.index, elapsed: Int(min(Double(Wire.maxElapsed), elapsed)), cards: wire,
      deckVersion: deckID)
  }
}
