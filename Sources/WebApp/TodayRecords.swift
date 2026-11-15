import Reactivity
import SessionLogic

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
    records = DailyStorage.loadRecords(today: date)
  }

  private func save() { DailyStorage.saveRecords(records, date: date) }
}
