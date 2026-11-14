import ElementaryRouter
import ElementaryUI

@View
struct HomePage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @Environment(PlaySettings.self) var settings: PlaySettings

  var body: some View {
    section(.class("home")) {
      h2(.class("step")) { "1. カードを えらぼう" }
      div(.class("deck-grid")) {
        for deck in Deck.allCases {
          DeckButton(deck: deck, isSelected: settings.deck == deck) { settings.deck = deck }
        }
      }

      h2(.class("step")) { "2. なんまい やる？" }
      div(.class("chips")) {
        // 45 is offered only for decks larger than that; on the 36-card decks it equals "all".
        if settings.deck.cards.count > 45 {
          Chip(label: "45まい", isSelected: settings.count == 45) { settings.count = 45 }
        }
        Chip(
          label: "ぜんぶ（\(settings.deck.cards.count)まい）",
          isSelected: settings.count <= 0 || settings.count >= settings.deck.cards.count
        ) { settings.count = 0 }
      }

      h2(.class("step")) { "3. タイマー" }
      div(.class("chips")) {
        Chip(label: "みせる", isSelected: settings.showTimer) { settings.showTimer = true }
        Chip(label: "かくす", isSelected: !settings.showTimer) { settings.showTimer = false }
      }

      div(.class("start")) {
        if let routes,
          let destination = try? routes.play(
            deck: settings.deck,
            count: settings.count,
            timer: settings.showTimer
          )
        {
          AppRoutes.Link(to: destination) { "スタート！" }
        }
      }
    }
  }
}

@View
struct DeckButton {
  let deck: Deck
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    button(.type(.button), .class("deck \(deck.colorClass)\(isSelected ? " selected" : "")")) {
      span(.class("deck-title")) { deck.title }
      span(.class("deck-subtitle")) { deck.subtitle }
      span(.class("deck-size")) { "\(deck.cards.count)まい" }
    }
    .onClick { onSelect() }
  }
}

@View
struct Chip {
  let label: String
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    button(.type(.button), .class(isSelected ? "chip selected" : "chip")) { label }
      .onClick { onSelect() }
  }
}

@View
struct PlayPage {
  let deck: Deck
  let count: Int
  let showTimer: Bool

  var body: some View {
    // Keyed by the route values so a new deck/count/timer setting starts a fresh session, with
    // fresh state and a key listener that sees the new values.
    PlaySession(deck: deck, count: count, showTimer: showTimer)
      .id("\(deck.rawValue)/\(count)/\(showTimer)")
  }
}

@View
struct PlaySession {
  enum Phase {
    case ready
    case playing
    case finished
  }

  @Environment(AppRoutes._routeSetEnvironmentKey) var routes

  let deck: Deck
  let count: Int
  let showTimer: Bool

  @State var phase: Phase = .ready
  @State var cards: [Card] = []
  @State var index: Int = 0
  @State var startedAt: Double = 0
  @State var elapsed: Double = 0

  var body: some View {
    section(.class("play")) {
      switch phase {
      case .ready:
        div(.class("ready")) {
          p(.class("ready-deck")) { "\(deck.title)（\(deck.subtitle)）" }
          p(.class("ready-count")) { "\(drawCount)まい" }
          button(.type(.button), .class("big-button")) { "はじめる" }
            .onClick { start() }
          p(.class("hint")) { "スペース か → で はじまるよ" }
        }

      case .playing:
        div(.class("progress")) {
          span { "\(index + 1) / \(cards.count)" }
          if showTimer {
            LiveTimer(startedAt: startedAt)
          }
        }
        if index < cards.count {
          div(.class("card \(deck.colorClass)")) {
            cards[index].question
          }
          .onClick { advance() }
        }
        p(.class("hint")) { "← まえ ／ → か スペース で つぎ" }

      case .finished:
        div(.class("finished")) {
          p(.class("finished-title")) { "おわり！" }
          p(.class("finished-time")) { ClockDisplay(milliseconds: elapsed) }
          p { "\(cards.count)まい できたね" }
          button(.type(.button), .class("big-button")) { "もういちど" }
            .onClick { phase = .ready }
        }
      }

      if let routes {
        div(.class("back")) {
          AppRoutes.Link(to: routes.home()) { "← カードを えらびなおす" }
        }
      }
    }
    .attach(BrowserListener.cardKeys { key in handle(key) })
  }

  private var drawCount: Int {
    let size = deck.cards.count
    return count <= 0 || count > size ? size : count
  }

  private func handle(_ key: CardKey) {
    switch (phase, key) {
    case (.ready, .next):
      start()
    case (.playing, .next):
      advance()
    case (.playing, .previous):
      if index > 0 { index -= 1 }
    default:
      break
    }
  }

  private func start() {
    cards = deck.draw(count: count)
    index = 0
    elapsed = 0
    startedAt = Browser.now()
    phase = .playing
  }

  private func advance() {
    if index + 1 < cards.count {
      index += 1
    } else {
      elapsed = Browser.now() - startedAt
      phase = .finished
    }
  }
}

/// Visible running clock. The measurement itself lives in `PlayPage`, so hiding this view does
/// not stop the timer.
@View
struct LiveTimer {
  let startedAt: Double
  @State var now: Double = 0

  var body: some View {
    ClockDisplay(milliseconds: now - startedAt)
      .attach(BrowserListener.interval(milliseconds: 100) { now = Browser.now() })
  }
}

@View
struct NotFoundPage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes

  var body: some View {
    section {
      h2 { "ページが みつかりません" }
      if let routes {
        AppRoutes.Link(to: routes.home()) { "トップへ もどる" }
      }
    }
  }
}

/// Shows elapsed time as `mm:ss.s`. Every glyph sits in a fixed-width cell, so the layout never
/// shifts as digits change, regardless of whether the font has tabular figures.
@View
struct ClockDisplay {
  let milliseconds: Double

  var body: some View {
    span(.class("clock")) {
      for glyph in ClockGlyph.glyphs(milliseconds: milliseconds) {
        span(.class(glyph.isDigit ? "clock-digit" : "clock-separator")) { glyph.text }
      }
    }
  }
}

