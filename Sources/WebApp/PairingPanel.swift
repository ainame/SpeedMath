import ElementaryRouter
import ElementaryUI
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
