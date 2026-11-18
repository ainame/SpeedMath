import ElementaryRouter
import ElementaryUI
import ProtocolModels
import RemoteClient
import RemoteProtocol
import SessionLogic

/// The child's pairing panel, opened from the home screen's リモコン button: a QR code and a typed
/// code, then the approval check. It closes by itself once paired; opened again while paired it
/// offers to end the pairing.
@View
struct RemotePanel {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  let hub: RemoteHub

  var body: some View {
    let model = hub.model
    if model.open {
      div(.class("pair-panel")) {
        div(.class("pair-heading")) {
          h2 { "リモコン" }
          button(.type(.button), .class("chip pair-close")) { "とじる" }
            .onClick { hub.togglePanel() }
        }
        div(.class("pair-content")) { content(model) }
        if !model.paired, model.request == nil, let routes {
          div(.class("pair-fallback")) {
            div(.class("pair-fallback-copy")) {
              p(.class("pair-fallback-title")) { "この スマホを リモコンにする" }
              p { "QRが よめないときは、こどもの がめんの コードで つなげるよ。" }
            }
            AppRoutes.Link(to: routes.remote()) { "コードを いれる" }
          }
        }
      }
    }
  }

  private func content(_ model: RemoteModel) -> some View {
    Group {
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
      } else if (model.joining && !model.retry) || model.code != nil {
        div(.class("pair-invite")) {
          div(.class("pair-qr-slot")) {
            if let qr = model.qr {
              img(.src(qr), .alt("リモコンを つなぐ QR コード"), .class("pair-qr"))
            } else if model.joining {
              div(.class("pair-loading"), .custom(name: "role", value: "status")) {
                span(.class("pair-spinner"), .custom(name: "aria-hidden", value: "true")) {}
                "コードを よみこみちゅう"
              }
            } else {
              p { "QR コードを ひょうじできません" }
            }
          }
          div(.class("pair-help")) {
            p { "おうちの ひとに QR コードを よんでもらってね。" }
            p(.class(model.code == nil ? "pair-code pair-reserved" : "pair-code")) { model.code ?? "XXXX-XXXX-XXXX" }
            p { "コードは 2ふんで きれるよ。" }
            button(.type(.button), .class(model.code == nil ? "chip pair-reserved" : "chip")) { "あたらしい コード" }
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
