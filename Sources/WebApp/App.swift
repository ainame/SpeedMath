import RemoteProtocol
import BrowserAPI
import ElementaryUI

@main
struct App {
  static func main() {
    BrowserPage.installAppGuards()
    // Before the router reads the URL: take a QR invite out of it and restore a reloaded Presenter.
    BrowserRemoteEnvironment.start()
    let app = Application(AppRoot())
    app.mount(in: .body)
  }
}

@View
struct AppRoot {
  @State var settings = PlaySettings()
  @State var stampBook = StampBook()
  @State var records = TodayRecords()
  /// The remote control lives above the router so pairing survives moving between screens.
  @State var hub = RemoteHub()

  var body: some View {
    AppRoutes.RouterView()
      .environment(settings)
      .environment(stampBook)
      .environment(records)
      .environment(hub)
      .onAppear { hub.start(settings: settings) }
  }
}
