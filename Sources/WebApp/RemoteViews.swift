import ElementaryRouter
import ElementaryUI
import JavaScriptKit
import ProtocolModels
import RemoteProtocol
import SessionLogic

/// The child's pairing panel, opened from the home screen's リモコン button: a QR code and a typed
/// code, then the approval check. It closes by itself once paired; opened again while paired it
/// offers to end the pairing.
@View
struct RemotePanel {
  let hub: RemoteHub

  var body: some View {
    let model = hub.model
    if model.open {
      div(.class("pair-panel")) {
        div(.class("pair-heading")) {
          h2 { "リモコン" }
          button(.type(.button), .class("chip")) { "とじる" }
            .onClick { hub.togglePanel() }
        }
        if model.paired {
          p { "リモコンと つながっています" }
          button(.type(.button), .class("chip")) { "リモコンを はずす" }
            .onClick { hub.revoke() }
        } else if let request = model.request, let check = model.check {
          p { "リモコンにも おなじ もじが でているかな？" }
          p(.class("pair-code")) { check }
          div(.class("remote-actions")) {
            button(.type(.button), .class("chip")) { "つなぐ" }
              .onClick { hub.decide(true, request: request) }
            button(.type(.button), .class("chip")) { "つながない" }
              .onClick { hub.decide(false, request: request) }
          }
        } else if let code = model.code, let qr = model.qr {
          div(.class("pair-invite")) {
            img(.src(qr), .alt("リモコンを つなぐ QR コード"), .class("pair-qr"))
            div(.class("pair-help")) {
              p { "スマホで QR コードを よむか、リモコンに このコードを いれてね。" }
              p(.class("pair-code")) { code }
              p { "コードは 2ふんで きれるよ。" }
              button(.type(.button), .class("chip")) { "あたらしい コード" }
                .onClick { hub.newInvite() }
            }
          }
        } else {
          p { model.status }
          if model.retry {
            button(.type(.button), .class("chip")) { "つなぎなおす" }
              .onClick { hub.retry() }
          } else if !model.joining {
            button(.type(.button), .class("chip")) { "コードを だす" }
              .onClick {
                if model.started { hub.newInvite() } else { hub.begin() }
              }
          }
        }
      }
    }
  }
}

@View
struct RemotePage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @State var link: RemoteLink?
  @State var model = RemoteModel()
  @State var code = ""

  var body: some View {
    let paired = model.paired
    section(.class(paired ? "remote-page remote-live" : "remote-page remote-pairing")) {
      if paired { liveView } else { pairingView }
    }
    .onAppear { link = RemoteLink(role: .remote, render: { model = $0 }, presenter: { _ in }) }
    .onDisappear {
      link?.dispose()
      link = nil
    }
  }

  /// Paired: a full-screen controller that follows the child's screen. The parent chooses the
  /// cards, starts, moves through them, and picks what comes next.
  private var liveView: some View {
    Group {
      div(.class("remote-bar")) {
        div(.class("progress-side")) {
          if model.screen == .playing {
            actionButton("✕ やめる", .home, style: "remote-small")
          }
        }
        span(.class("remote-count")) {
          if model.screen == .playing { "\(model.index) / \(model.count)" }
        }
        div(.class("progress-side progress-timer")) {
          if model.screen == .playing || model.screen == .finished { RemoteClock(model: model) }
        }
      }
      switch model.screen {
      case .home: homeControls
      case .ready: readyControls
      case .playing: playingControls
      case .finished: finishedControls
      }
      div(.class("remote-footer")) {
        if !model.notice.isEmpty {
          p(.class("remote-notice")) { model.notice }
        } else if !model.online {
          // While online the screen itself shows the state; the footer only reports trouble.
          p(.class("remote-status remote-offline")) { model.status }
        }
        if model.retry {
          button(.type(.button), .class("chip")) { "つなぎなおす" }
            .onClick { link?.retry() }
        }
      }
    }
  }

  /// The child's home screen: choose the deck and options, then スタート！
  private var homeControls: some View {
    div(.class("remote-home")) {
      div(.class("remote-decks")) {
        for deck in Deck.allCases {
          RemoteDeckButton(
            deck: deck, isSelected: selectedDeck == deck, isEnabled: canSend
          ) { link?.command(.deck, value: Deck.allCases.firstIndex(of: deck) ?? 0) }
        }
      }
      div(.class("remote-options")) {
        optionChips(
          "0の けいさん", [("いれない", 0), ("いれる", 1)], selected: model.settings.includeZero ? 1 : 0, action: .zero)
        optionChips("なんまい", countChoices, selected: selectedCount, action: .count)
        optionChips(
          "タイマー", [("みせる", 1), ("かくす", 0)], selected: model.settings.showTimer ? 1 : 0, action: .timer)
      }
      actionButton("スタート！", .start, style: "remote-primary remote-start")
    }
  }

  private var readyControls: some View {
    div(.class("remote-stage remote-stage-idle remote-ready")) {
      div(.class("remote-card")) {
        p(.class("remote-message")) { "\(selectedDeck.title)（\(selectedDeck.subtitle)）" }
        p(.class("remote-sub")) { "\(drawCount)まい" }
      }
      div(.class("remote-row")) {
        actionButton("えらびなおす", .home, style: "remote-secondary")
        actionButton("はじめる", .begin, style: "remote-primary")
      }
    }
  }

  private var playingControls: some View {
    div(.class("remote-stage")) {
      actionButton("まえ", .previous, style: "remote-move remote-previous", arrow: "←", enabled: model.index > 1)
      div(.class("remote-card")) {
        if !model.question.isEmpty {
          p(.class("remote-problem")) { model.question }
          p(.class("remote-answer")) {
            span(.class("remote-answer-label")) { "こたえ" }
            span(.class("remote-answer-value")) { model.answer }
          }
        }
      }
      actionButton("つぎ", .next, style: "remote-move remote-next", arrow: "→")
    }
  }

  private var finishedControls: some View {
    div(.class("remote-stage remote-stage-idle remote-ready")) {
      div(.class("remote-card")) {
        p(.class("remote-message")) { "おわり！" }
        p(.class("remote-final-time")) { ClockDisplay(milliseconds: model.elapsed) }
      }
      div(.class("remote-row")) {
        actionButton("えらびなおす", .home, style: "remote-secondary")
        actionButton("もういちど", .replay, style: "remote-primary")
      }
    }
  }

  private var canSend: Bool { model.online && !model.busy }

  private var selectedDeck: Deck {
    Deck.allCases.indices.contains(model.settings.deck) ? Deck.allCases[model.settings.deck] : .additionNoCarry
  }

  private var deckSize: Int { selectedDeck.cards(includeZero: model.settings.includeZero).count }

  /// 45 is offered only for decks larger than that, as on the child's screen.
  private var countChoices: [(String, Int)] { deckSize > 45 ? [("45まい", 45), ("ぜんぶ", 0)] : [("ぜんぶ", 0)] }

  private var selectedCount: Int { model.settings.count == 45 && deckSize > 45 ? 45 : 0 }

  private var drawCount: Int { model.settings.count == 45 && deckSize > 45 ? 45 : deckSize }

  private func optionChips(_ title: String, _ choices: [(String, Int)], selected: Int, action: RemoteAction)
    -> some View
  {
    div(.class("remote-option")) {
      span(.class("remote-option-title")) { title }
      div(.class("chips")) {
        for choice in choices {
          Chip(label: choice.0, isSelected: selected == choice.1, isLocked: !canSend) {
            link?.command(action, value: choice.1)
          }
        }
      }
    }
  }

  private func actionButton(
    _ title: String, _ action: RemoteAction, style: String, arrow: String? = nil, enabled: Bool = true
  ) -> some View {
    button(.type(.button), .class(style)) {
      if let arrow {
        span(.class("remote-move-arrow"), .custom(name: "aria-hidden", value: "true")) { arrow }
        span(.class("remote-move-label")) { title }
      } else {
        span { title }
      }
    }
    .attributes(.disabled, when: !canSend || !enabled)
    .onClick { link?.command(action) }
  }

  private var pairingView: some View {
    Group {
      if let check = model.check {
        p(.class("remote-lead")) { "こどもの がめんと おなじ もじか たしかめてね。" }
        p(.class("pair-code remote-check")) { check }
        p(.class("remote-status")) { model.status }
      } else if model.joining {
        p(.class("remote-status")) { model.status }
      } else {
        p(.class("remote-lead")) { "こどもの がめんに でている コードを いれてね。" }
        label(.class("remote-code-field")) {
          span(.class("remote-code-label")) { "コード" }
          input(
            .type(.text), .placeholder("XXXX-XXXX-XXXX"), .class("remote-code-input"),
            .custom(name: "autocapitalize", value: "characters"),
            .custom(name: "autocomplete", value: "off"), .custom(name: "spellcheck", value: "false")
          )
          .bindValue($code)
        }
        button(.type(.button), .class("big-button")) { "コードで つなぐ" }
          .onClick {
            link?.begin(code)
          }
        if !model.status.isEmpty {
          p(.class("remote-status")) { model.status }
        }
      }
      if model.retry {
        button(.type(.button), .class("chip")) { "つなぎなおす" }
          .onClick { link?.retry() }
      }
      div(.class("back")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) { "もどる" }
        }
      }
    }
  }
}

/// A deck choice on the Remote's home controls.
@View
struct RemoteDeckButton {
  let deck: Deck
  let isSelected: Bool
  let isEnabled: Bool
  let onSelect: () -> Void

  var body: some View {
    button(.type(.button), .class("remote-deck \(deck.colorClass)\(isSelected ? " selected" : "")")) {
      span(.class("deck-title")) { deck.title }
      span(.class("deck-subtitle")) { deck.subtitle }
    }
    .attributes(.disabled, when: !isEnabled)
    .onClick { if isEnabled { onSelect() } }
  }
}

@View
struct RemoteClock {
  let model: RemoteModel

  var body: some View {
    if model.screen == .playing, model.online {
      LiveTimer(startedAt: model.startedAt)
    } else {
      ClockDisplay(milliseconds: model.elapsed)
    }
  }
}
