import SessionLogic
import JavaScriptKit
import Reactivity

/// One finished run.
struct PlayRecord: Equatable {
  let deck: Deck
  let count: Int
  let includeZero: Bool
  let milliseconds: Int
  /// Local time the run finished, e.g. "9:05".
  let finishedAt: String
}

/// Today's finished runs, newest last. Stored in localStorage and emptied at local midnight.
@Reactive
final class TodayRecords {
  static let storageKey = "speedmath.records.v1"

  private(set) var records: [PlayRecord] = []
  private var date: String = ""

  init() {
    load()
  }

  /// Empties the list when it belongs to an earlier day.
  func refresh() {
    let today = DailyStorage.todayKey()
    if date != today {
      date = today
      records = []
    }
  }

  func add(deck: Deck, count: Int, includeZero: Bool, milliseconds: Double) {
    refresh()
    records.append(
      PlayRecord(
        deck: deck,
        count: count,
        includeZero: includeZero,
        milliseconds: Int(milliseconds),
        finishedAt: DailyStorage.timeOfDay()
      )
    )
    save()
  }

  private func load() {
    date = DailyStorage.todayKey()
    guard let saved = DailyStorage.load(Self.storageKey, today: date),
      let list = saved["records"].object
    else { return }
    let length = Int(list["length"].number ?? 0)
    var loaded: [PlayRecord] = []
    for index in 0..<length {
      guard let item = list[index].object,
        let deck = item["deck"].string.flatMap(Deck.init(rawValue:)),
        let count = item["count"].number,
        let milliseconds = item["ms"].number
      else { continue }
      loaded.append(
        PlayRecord(
          deck: deck,
          count: Int(count),
          includeZero: item["zero"].boolean ?? false,
          milliseconds: Int(milliseconds),
          finishedAt: item["at"].string ?? ""
        )
      )
    }
    records = loaded
  }

  private func save() {
    let records = self.records
    DailyStorage.save(Self.storageKey, date: date) { value in
      guard let list = DailyStorage.makeArray() else { return }
      for (index, record) in records.enumerated() {
        guard let item = DailyStorage.makeObject() else { continue }
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
}
