import BrowserAPI
import JavaScriptKit
import SessionLogic

/// localStorage entries that belong to one local calendar day: today's stamps and records. Each is
/// saved as JSON `{ "date": "2026-11-14", ... }`; an entry from an earlier day loads as empty,
/// which gives the midnight reset. Blocked or private-mode storage loads as empty and ignores
/// saves (BridgeJS turns the browser's exception into an error).
///
/// This file is the storage codec: the only place in the app that reads or builds JSON objects.
enum DailyStorage {
  static let stampsKey = "speedmath.stamps.v1"
  static let recordsKey = "speedmath.records.v1"

  // MARK: Stamps

  static func loadStamps(today: String) -> [Stamp] {
    guard let list = entry(stampsKey, today: today)?["stamps"].object else { return [] }
    var stamps: [Stamp] = []
    for index in 0..<length(list) {
      if let raw = list[index].string, let stamp = Stamp(rawValue: raw), !stamps.contains(stamp) {
        stamps.append(stamp)
      }
    }
    return stamps
  }

  static func saveStamps(_ stamps: [Stamp], date: String) {
    save(stampsKey, date: date) { value in
      let list = JS.array()
      for (index, stamp) in stamps.enumerated() { list[index] = stamp.rawValue.jsValue }
      value["stamps"] = list.jsValue
    }
  }

  // MARK: Records

  static func loadRecords(today: String) -> [PlayRecord] {
    guard let list = entry(recordsKey, today: today)?["records"].object else { return [] }
    var records: [PlayRecord] = []
    for index in 0..<length(list) {
      guard let item = list[index].object,
        let deck = item["deck"].string.flatMap(Deck.init(rawValue:)),
        let count = item["count"].number,
        let milliseconds = item["ms"].number
      else { continue }
      records.append(
        PlayRecord(
          deck: deck, count: Int(count), includeZero: item["zero"].boolean ?? false,
          milliseconds: Int(milliseconds), finishedAt: item["at"].string ?? ""))
    }
    return records
  }

  static func saveRecords(_ records: [PlayRecord], date: String) {
    save(recordsKey, date: date) { value in
      let list = JS.array()
      for (index, record) in records.enumerated() {
        let item = JS.object()
        item["deck"] = record.deck.rawValue.jsValue
        item["count"] = record.count.jsValue
        item["zero"] = record.includeZero.jsValue
        item["ms"] = record.milliseconds.jsValue
        item["at"] = record.finishedAt.jsValue
        list[index] = item.jsValue
      }
      value["records"] = list.jsValue
    }
  }

  // MARK: Dates

  /// Local calendar date, e.g. "2026-11-14" (the format already stored in existing entries).
  static func todayKey() -> String {
    let now = BrowserPage.localTime()
    return "\(now.year)-\(now.month)-\(now.day)"
  }

  /// Local time of day, e.g. "9:05".
  static func timeOfDay() -> String {
    let now = BrowserPage.localTime()
    return "\(now.hours):\(now.minutes < 10 ? "0" : "")\(now.minutes)"
  }

  // MARK: JSON entries

  /// Today's parsed entry for `key`, or nil when there is none or it belongs to an earlier day.
  private static func entry(_ key: String, today: String) -> JSObject? {
    guard let text = BrowserPage.localValue(key), let saved = JS.parse(text), saved["date"].string == today
    else { return nil }
    return saved
  }

  private static func save(_ key: String, date: String, fill: (JSObject) -> Void) {
    let value = JS.object()
    value["date"] = date.jsValue
    fill(value)
    BrowserPage.setLocalValue(key, JS.stringify(value))
  }

  private static func length(_ list: JSObject) -> Int { Int(list["length"].number ?? 0) }
}
