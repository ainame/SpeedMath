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
    section(.class("remote-page")) {
      h2 { "リモコン" }
      p(.class("remote-status")) { model?["status"].string ?? "" }
      if model?["paired"].boolean == true {
        if let question = model?["question"].string, !question.isEmpty {
          p(.class("remote-count")) {
            "\(Int(model?["index"].number ?? 0)) / \(Int(model?["count"].number ?? 0))"
          }
          p(.class("remote-problem")) { question }
          p(.class("remote-answer")) { "こたえ：\(model?["answer"].string ?? "")" }
          div(.class("remote-actions")) {
            moveButton("← まえ", direction: -1)
            moveButton("つぎ →", direction: 1)
          }
        } else if model?["phase"].number == 2 {
          p(.class("remote-problem")) { "おわり！" }
          ClockDisplay(milliseconds: model?["elapsed"].number ?? 0)
        }
        if let notice = model?["notice"].string, !notice.isEmpty {
          p(.class("remote-notice")) { notice }
        }
      } else if let check = model?["check"].string {
        p { "こどもの がめんと おなじ もじか たしかめてね。" }
        p(.class("pair-code")) { check }
      } else if model?["joining"].boolean != true {
        p { "こどもの がめんに でている コードを いれてね。" }
        label {
          "コード "
          input(.type(.text), .placeholder("XXXX-XXXX-XXXX"), .class("remote-code-input"))
            .bindValue($code)
        }
        button(.type(.button), .class("chip")) { "コードで つなぐ" }
          .onClick {
            if let link { _ = link.begin.function?.callAsFunction(this: link, code) }
          }
      }
      if model?["retry"].boolean == true {
        button(.type(.button), .class("chip")) { "つなぎなおす" }
          .onClick {
            if let link { _ = link.retry.function?.callAsFunction(this: link) }
          }
      }
      div(.class("back")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) { "もどる" }
        }
      }
    }
    .onAppear { link = RemoteBrowser.mount(role: 2) { model = $0 } }
    .onDisappear {
      if let link { _ = link.dispose.function?.callAsFunction(this: link) }
      link = nil
    }
  }

  private func moveButton(_ title: String, direction: Int) -> some View {
    let enabled = model?["online"].boolean == true && model?["busy"].boolean != true &&
      (direction > 0 || (model?["index"].number ?? 0) > 1)
    return button(.type(.button), .class("chip")) { title }
      .attributes(.disabled, when: !enabled)
      .onClick {
        if let link { _ = link.move.function?.callAsFunction(this: link, direction) }
      }
  }
}
