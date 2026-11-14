import ElementaryRouter
import ElementaryUI

@View
struct HomePage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes

  var body: some View {
    section {
      p(.class("lead")) { "どの けいさんに チャレンジする？" }
      div(.class("operation-grid")) {
        if let routes {
          for operation in Operation.allCases {
            if let destination = try? routes.play(operation: operation) {
              AppRoutes.Link(to: destination) {
                span(.class("operation-symbol")) { operation.symbol }
                span { operation.title }
              }
            }
          }
        }
      }
    }
  }
}

@View
struct PlayPage {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes

  let operation: Operation
  let count: Int

  var body: some View {
    section {
      h2 { "\(operation.title)（\(count)もん）" }
      p { "じゅんびちゅう…" }
      if let routes {
        AppRoutes.Link(to: routes.home()) { "もどる" }
      }
    }
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
