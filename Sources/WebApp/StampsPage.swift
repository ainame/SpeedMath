import ElementaryRouter
import ElementaryUI
import ProtocolModels
import RemoteProtocol
import SessionLogic

/// Today's stamp card: six slots filled in the order the stamps were collected.
@View
struct StampsPage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @Environment(StampBook.self) var stampBook: StampBook

  var body: some View {
    section(.class("stamp-card")) {
      h2(.class("stamp-card-title")) { "きょうの スタンプ" }
      div(.class("stamp-slots")) {
        for slot in 0..<Stamp.allCases.count {
          StampSlot(stamp: slot < stampBook.stamps.count ? stampBook.stamps[slot] : nil, number: slot + 1)
        }
      }
      p(.class("stamp-card-message")) { message }
      div(.class("back")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) { "もどる" }
        }
      }
    }
    .onAppear { stampBook.refresh() }
  }

  private var message: String {
    let remaining = Stamp.allCases.count - stampBook.stamps.count
    if remaining == 0 { return "ぜんぶ あつめたね！ また あした。" }
    if stampBook.stamps.isEmpty { return "さいごまで やると スタンプが もらえるよ" }
    return "あと \(remaining)こ！"
  }
}

@View
struct StampSlot {
  let stamp: Stamp?
  let number: Int

  var body: some View {
    div(.class("stamp-slot")) {
      if let stamp {
        img(
          .src(stamp.path),
          .alt(stamp.label),
          .class("stamp-slot-image"),
          .style(["--tilt": "\(Stamp.slotTilts[(number - 1) % Stamp.slotTilts.count])deg"])
        )
      } else {
        span(.class("stamp-slot-number")) { "\(number)" }
      }
    }
  }
}
