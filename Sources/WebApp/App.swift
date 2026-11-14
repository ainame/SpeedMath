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
  @State var stampBook = StampBook()
  @State var records = TodayRecords()

  var body: some View {
    AppRoutes.RouterView()
      .environment(settings)
      .environment(stampBook)
      .environment(records)
  }
}
