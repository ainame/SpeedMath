import ElementaryUI

@main
struct App {
  static func main() {
    let app = Application(AppRoot())
    app.mount(in: .body)
  }
}

@View
struct AppRoot {
  @State var settings = PlaySettings()

  var body: some View {
    AppRoutes.RouterView()
      .environment(settings)
  }
}
