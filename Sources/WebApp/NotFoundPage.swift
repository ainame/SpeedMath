import ElementaryRouter
import ElementaryUI
import ProtocolModels
import RemoteProtocol
import SessionLogic

@View
struct NotFoundPage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes

  var body: some View {
    section(.class("not-found")) {
      h2 { "ページが みつかりません" }
      if let routes {
        AppRoutes.Link(to: routes.home()) { "トップへ もどる" }
      }
    }
  }
}
