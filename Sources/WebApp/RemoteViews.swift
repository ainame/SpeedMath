import ElementaryRouter
import ElementaryUI
import JavaScriptKit
import RemoteProtocol

@View
struct RemotePanel {
  let model: RemoteModel
  let link: RemoteLink?

  var body: some View {
    if model.open {
      div(.class("pair-panel")) {
        div(.class("pair-heading")) {
          h2 { "リモコン" }
          button(.type(.button), .class("chip")) { "とじる" }
            .onClick { link?.show() }
        }
        if let request = model.request, let check = model.check {
          p { "リモコンにも おなじ もじが でているかな？" }
          p(.class("pair-code")) { check }
          div(.class("remote-actions")) {
            button(.type(.button), .class("chip")) { "つなぐ" }
              .onClick { decide(true, request: request) }
            button(.type(.button), .class("chip")) { "つながない" }
              .onClick { decide(false, request: request) }
          }
        } else if let code = model.code, let qr = model.qr {
          div(.class("pair-invite")) {
            img(.src(qr), .alt("リモコンを つなぐ QR コード"), .class("pair-qr"))
            div(.class("pair-help")) {
              p { "スマホで QR コードを よむか、リモコンに このコードを いれてね。" }
              p(.class("pair-code")) { code }
              p { "コードは 2ふんで きれるよ。" }
              button(.type(.button), .class("chip")) { "あたらしい コード" }
                .onClick { link?.newInvite() }
            }
          }
        } else {
          p { model.status }
          if model.paired {
            button(.type(.button), .class("chip")) { "リモコンを はずす" }
              .onClick { link?.revoke() }
          } else if model.retry {
            button(.type(.button), .class("chip")) { "つなぎなおす" }
              .onClick { link?.retry() }
          } else if !model.joining {
            button(.type(.button), .class("chip")) { "コードを だす" }
              .onClick {
                if model.started { link?.newInvite() } else { link?.begin() }
              }
          }
        }
      }
    }
  }

  private func decide(_ approved: Bool, request: String) {
    link?.decide(approved, request: request)
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

  /// Paired: a full-screen controller. Landscape puts まえ / つぎ under the thumbs on either
  /// side of the card; portrait stacks the card above two wide buttons.
  private var liveView: some View {
    Group {
      div(.class("remote-bar")) {
        div(.class("progress-side")) {
          if let routes {
            AppRoutes.Link(to: routes.home()) { "✕ やめる" }
          }
        }
        span(.class("remote-count")) {
          if phase == 1 {
            "\(model.index) / \(model.count)"
          }
        }
        div(.class("progress-side progress-timer")) {
          if phase >= 1 { RemoteClock(model: model) }
        }
      }
      div(.class(phase == 1 ? "remote-stage" : "remote-stage remote-stage-idle")) {
        if phase == 1 { moveButton(direction: -1) }
        div(.class("remote-card")) {
          if phase == 1, !model.question.isEmpty {
            p(.class("remote-problem")) { model.question }
            p(.class("remote-answer")) {
              span(.class("remote-answer-label")) { "こたえ" }
              span(.class("remote-answer-value")) { model.answer }
            }
          } else if phase == 2 {
            p(.class("remote-message")) { "おわり！" }
            p(.class("remote-final-time")) { ClockDisplay(milliseconds: model.elapsed) }
          } else {
            p(.class("remote-message")) { "はじまるのを まっています" }
          }
        }
        if phase == 1 { moveButton(direction: 1) }
      }
      div(.class("remote-footer")) {
        if !model.notice.isEmpty {
          p(.class("remote-notice")) { model.notice }
        } else if !model.online {
          // While online the card itself shows the state; the footer only reports trouble.
          p(.class("remote-status remote-offline")) { model.status }
        }
        if model.retry {
          button(.type(.button), .class("chip")) { "つなぎなおす" }
            .onClick { link?.retry() }
        }
      }
    }
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

  private var phase: Int { Int(model.phase.rawValue) }

  private func moveButton(direction: Int) -> some View {
    let enabled = model.online && !model.busy && (direction > 0 || model.index > 1)
    let next = direction > 0
    return button(.type(.button), .class(next ? "remote-move remote-next" : "remote-move remote-previous")) {
      span(.class("remote-move-arrow"), .custom(name: "aria-hidden", value: "true")) { next ? "→" : "←" }
      span(.class("remote-move-label")) { next ? "つぎ" : "まえ" }
    }
    .attributes(.disabled, when: !enabled)
    .onClick {
      link?.move(next ? .next : .previous)
    }
  }
}

/// The Presenter only sends its elapsed time with each state change, so the Remote keeps a local
/// clock from the moment that snapshot arrived and freezes it while the Presenter is unreachable.
@View
struct RemoteClock {
  let model: RemoteModel

  var body: some View {
    if model.phase == .playing, model.online {
      LiveTimer(startedAt: model.startedAt)
    } else {
      ClockDisplay(milliseconds: model.elapsed)
    }
  }
}
