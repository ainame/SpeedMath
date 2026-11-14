import ElementaryRouter
import ElementaryUI
import JavaScriptKit

enum RemoteBrowser {
  static func identifier() -> String {
    guard let bridge = JSObject.global.speedMathRemote.object else { return "" }
    return bridge.id.function?.callAsFunction(this: bridge).string ?? ""
  }

  static func mount(
    role: Int, render: @escaping (JSObject) -> Void,
    presenter: @escaping (JSObject?) -> Void = { _ in }
  ) -> JSObject? {
    guard let bridge = JSObject.global.speedMathRemote.object else { return nil }
    let update = JSClosure { args in
      if let model = args.first?.object { render(model) }
      return .undefined
    }
    let event = JSClosure { args in
      presenter(args.first?.object)
      return .undefined
    }
    return bridge.mount.function?.callAsFunction(this: bridge, role, update, event).object
  }
}

@View
struct RemotePanel {
  let model: JSObject?
  let link: JSObject?

  var body: some View {
    if model?["open"].boolean == true {
      div(.class("pair-panel")) {
        div(.class("pair-heading")) {
          h2 { "リモコン" }
          button(.type(.button), .class("chip")) { "とじる" }
            .onClick { call("show") }
        }
        if let request = model?["request"].string, let check = model?["check"].string {
          p { "リモコンにも おなじ もじが でているかな？" }
          p(.class("pair-code")) { check }
          div(.class("remote-actions")) {
            button(.type(.button), .class("chip")) { "つなぐ" }
              .onClick { decide(true, request: request) }
            button(.type(.button), .class("chip")) { "つながない" }
              .onClick { decide(false, request: request) }
          }
        } else if let code = model?["code"].string, let qr = model?["qr"].string {
          div(.class("pair-invite")) {
            img(.src(qr), .alt("リモコンを つなぐ QR コード"), .class("pair-qr"))
            div(.class("pair-help")) {
              p { "スマホで QR コードを よむか、リモコンに このコードを いれてね。" }
              p(.class("pair-code")) { code }
              p { "コードは 2ふんで きれるよ。" }
              button(.type(.button), .class("chip")) { "あたらしい コード" }
                .onClick { call("newInvite") }
            }
          }
        } else {
          p { model?["status"].string ?? "" }
          if model?["paired"].boolean == true {
            button(.type(.button), .class("chip")) { "リモコンを はずす" }
              .onClick { call("revoke") }
          } else if model?["retry"].boolean == true {
            button(.type(.button), .class("chip")) { "つなぎなおす" }
              .onClick { call("retry") }
          } else if model?["joining"].boolean != true {
            button(.type(.button), .class("chip")) { "コードを だす" }
              .onClick {
                if model?["started"].boolean == true { call("newInvite") }
                else { call("begin") }
              }
          }
        }
      }
    }
  }

  private func call(_ method: String) {
    guard let link else { return }
    _ = link[method].function?.callAsFunction(this: link)
  }

  private func decide(_ approved: Bool, request: String) {
    guard let link else { return }
    _ = link["decide"].function?.callAsFunction(this: link, approved, request)
  }
}

@View
struct RemotePage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @State var link: JSObject?
  @State var model: JSObject?
  @State var code = ""

  var body: some View {
    let paired = model?["paired"].boolean == true
    section(.class(paired ? "remote-page remote-live" : "remote-page remote-pairing")) {
      if paired { liveView } else { pairingView }
    }
    .onAppear { link = RemoteBrowser.mount(role: 2) { model = $0 } }
    .onDisappear {
      if let link { _ = link.dispose.function?.callAsFunction(this: link) }
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
            "\(Int(model?["index"].number ?? 0)) / \(Int(model?["count"].number ?? 0))"
          }
        }
        div(.class("progress-side progress-timer")) {
          if phase >= 1 { RemoteClock(model: model) }
        }
      }
      div(.class(phase == 1 ? "remote-stage" : "remote-stage remote-stage-idle")) {
        if phase == 1 { moveButton(direction: -1) }
        div(.class("remote-card")) {
          if phase == 1, let question = model?["question"].string, !question.isEmpty {
            p(.class("remote-problem")) { question }
            p(.class("remote-answer")) {
              span(.class("remote-answer-label")) { "こたえ" }
              span(.class("remote-answer-value")) { model?["answer"].string ?? "" }
            }
          } else if phase == 2 {
            p(.class("remote-message")) { "おわり！" }
            p(.class("remote-final-time")) { ClockDisplay(milliseconds: model?["elapsed"].number ?? 0) }
          } else {
            p(.class("remote-message")) { "はじまるのを まっています" }
          }
        }
        if phase == 1 { moveButton(direction: 1) }
      }
      div(.class("remote-footer")) {
        if let notice = model?["notice"].string, !notice.isEmpty {
          p(.class("remote-notice")) { notice }
        } else if model?["online"].boolean != true {
          // While online the card itself shows the state; the footer only reports trouble.
          p(.class("remote-status remote-offline")) { model?["status"].string ?? "" }
        }
        if model?["retry"].boolean == true {
          button(.type(.button), .class("chip")) { "つなぎなおす" }
            .onClick { call("retry") }
        }
      }
    }
  }

  private var pairingView: some View {
    Group {
      if let check = model?["check"].string {
        p(.class("remote-lead")) { "こどもの がめんと おなじ もじか たしかめてね。" }
        p(.class("pair-code remote-check")) { check }
        p(.class("remote-status")) { model?["status"].string ?? "" }
      } else if model?["joining"].boolean == true {
        p(.class("remote-status")) { model?["status"].string ?? "" }
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
            if let link { _ = link.begin.function?.callAsFunction(this: link, code) }
          }
        if let status = model?["status"].string, !status.isEmpty {
          p(.class("remote-status")) { status }
        }
      }
      if model?["retry"].boolean == true {
        button(.type(.button), .class("chip")) { "つなぎなおす" }
          .onClick { call("retry") }
      }
      div(.class("back")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) { "もどる" }
        }
      }
    }
  }

  private var phase: Int { Int(model?["phase"].number ?? 0) }

  private func call(_ method: String) {
    if let link { _ = link[method].function?.callAsFunction(this: link) }
  }

  private func moveButton(direction: Int) -> some View {
    let enabled = model?["online"].boolean == true && model?["busy"].boolean != true &&
      (direction > 0 || (model?["index"].number ?? 0) > 1)
    let next = direction > 0
    return button(.type(.button), .class(next ? "remote-move remote-next" : "remote-move remote-previous")) {
      span(.class("remote-move-arrow"), .custom(name: "aria-hidden", value: "true")) { next ? "→" : "←" }
      span(.class("remote-move-label")) { next ? "つぎ" : "まえ" }
    }
    .attributes(.disabled, when: !enabled)
    .onClick {
      if let link { _ = link.move.function?.callAsFunction(this: link, direction) }
    }
  }
}

/// The Presenter only sends its elapsed time with each state change, so the Remote keeps a local
/// clock from the moment that snapshot arrived and freezes it while the Presenter is unreachable.
@View
struct RemoteClock {
  let model: JSObject?

  var body: some View {
    if model?["phase"].number == 1, model?["online"].boolean == true,
      let startedAt = model?["startedAt"].number
    {
      LiveTimer(startedAt: startedAt)
    } else {
      ClockDisplay(milliseconds: model?["elapsed"].number ?? 0)
    }
  }
}
