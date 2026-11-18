import ElementaryRouter
import ElementaryUI

@View
struct AppShell<Content: View> {
  @Environment(AppRoutes._routeSetEnvironmentKey) var routes
  @Environment(AppRoutes._routerEnvironmentKey) var router
  @Environment(PlaySettings.self) var settings: PlaySettings
  @Environment(RemoteHub.self) var hub: RemoteHub

  let outlet: Outlet<Content>

  var body: some View {
    div(.class("app")) {
      header(.class("app-header")) {
        if let routes {
          // Pairing starts from the home screen only (CSS hides this elsewhere).
          div(.class("header-remote")) {
            if hub.isPaired {
              button(.type(.button), .class("chip selected remote-indicator")) { "リモコン ✓" }
                .onClick { hub.togglePanel() }
            } else {
              button(.type(.button), .class("chip remote-toggle")) { "リモコン" }
                .onClick { hub.togglePanel() }
              AppRoutes.Link(to: routes.remote()) { "コードを いれる" }
            }
          }
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
      RemotePanel(hub: hub)
    }
    .onAppear {
      hub.attachNavigation(
        home: {
          guard let routes, let router else { return }
          try? router.navigate(to: routes.home())
        },
        play: {
          guard let routes, let router,
            let destination = try? routes.play(
              deck: settings.deck, count: settings.count, timer: settings.showTimer, zero: settings.includeZero)
          else { return }
          try? router.navigate(to: destination)
        })
    }
  }
}
