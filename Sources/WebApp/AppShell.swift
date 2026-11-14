import ElementaryRouter
import ElementaryUI

@View
struct AppShell<Content: View> {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes

  let outlet: Outlet<Content>

  var body: some View {
    div(.class("app")) {
      header(.class("app-header")) {
        if let routes {
          AppRoutes.Link(to: routes.home()) {
            h1 { "スピードけいさん" }
          }
        } else {
          h1 { "スピードけいさん" }
        }
      }
      main(.class("app-main")) {
        outlet
      }
    }
  }
}
