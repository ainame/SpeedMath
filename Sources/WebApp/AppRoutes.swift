import ElementaryRouter
import ElementaryUI

/// Hash routing keeps the app deployable as plain static files (e.g. GitHub Pages)
/// and needs no click-interception script in `index.html`.
@Routes(mode: .hash)
struct AppRoutes {
  @Layout("/")
  static func appShell<Content: View>(outlet: Outlet<Content>) -> AppShell<Content> {
    AppShell(outlet: outlet)
  }

  @Route("/")
  static func home() -> HomePage {
    HomePage()
  }

  @Route("/play/:operation")
  static func play(operation: Operation, count: Query<Int> = Query(10)) -> PlayPage {
    PlayPage(operation: operation, count: count.value)
  }

  @NotFound
  static func notFound(context: RouteNotFoundContext) -> NotFoundPage {
    NotFoundPage()
  }

  @RouteError
  static func routeError(context: RouteErrorContext) -> NotFoundPage {
    NotFoundPage()
  }
}
