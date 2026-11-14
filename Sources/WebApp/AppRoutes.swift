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

  /// `count: 0` plays the whole deck. `timer: false` hides the running clock; the time is still
  /// measured and shown at the end. `zero: true` includes problems with 0.
  @Route("/play/:deck")
  static func play(
    deck: Deck,
    count: Query<Int> = Query(0),
    timer: Query<Bool> = Query(true),
    zero: Query<Bool> = Query(false)
  ) -> PlayPage {
    PlayPage(deck: deck, count: count.value, showTimer: timer.value, includeZero: zero.value)
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
