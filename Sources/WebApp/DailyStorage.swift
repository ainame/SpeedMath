import JavaScriptKit

/// localStorage entries that belong to one local calendar day. Each entry is saved as
/// `{ date: "2026-11-14", ... }`; entries from an earlier day load as empty, which gives the
/// midnight reset. Storage access goes through `window.speedMathStorage` (see index.html), which
/// swallows errors when localStorage is unavailable.
enum DailyStorage {
  /// Today's entry for `key`, or nil when there is none or it belongs to an earlier day.
  static func load(_ key: String, today: String) -> JSObject? {
    guard let storage = JSObject.global.speedMathStorage.object,
      let saved = storage["load"].function?.callAsFunction(this: storage, key).object,
      saved["date"].string == today
    else { return nil }
    return saved
  }

  /// Saves an entry for `date`; `fill` adds the entry's own fields.
  static func save(_ key: String, date: String, fill: (JSObject) -> Void) {
    guard let storage = JSObject.global.speedMathStorage.object,
      let makeObject = JSObject.global.Object.function
    else { return }
    let value = makeObject.new()
    value["date"] = date.jsValue
    fill(value)
    _ = storage["save"].function?.callAsFunction(this: storage, key, value)
  }

  static func makeArray() -> JSObject? {
    JSObject.global.Array.function?.new()
  }

  static func makeObject() -> JSObject? {
    JSObject.global.Object.function?.new()
  }

  /// Local calendar date, e.g. "2026-11-14".
  static func todayKey() -> String {
    let now = Now()
    return "\(now.part("getFullYear"))-\(now.part("getMonth") + 1)-\(now.part("getDate"))"
  }

  /// Local time of day, e.g. "9:05".
  static func timeOfDay() -> String {
    let now = Now()
    let minutes = now.part("getMinutes")
    return "\(now.part("getHours")):\(minutes < 10 ? "0" : "")\(minutes)"
  }

  private struct Now {
    let date: JSObject?

    init() {
      date = JSObject.global.Date.function?.new()
    }

    func part(_ name: String) -> Int {
      guard let date else { return 0 }
      return Int(date[name].function?.callAsFunction(this: date).number ?? 0)
    }
  }
}
