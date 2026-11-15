import Reactivity

/// Today's stamp card: every finished run awards one stamp the card does not have yet, in random
/// order, until all six are collected. Stored in localStorage and emptied when the local date
/// changes (midnight).
@Reactive
final class StampBook {
  /// Stamps collected today, in the order they were awarded.
  private(set) var stamps: [Stamp] = []
  private var date: String = ""

  var isComplete: Bool { stamps.count >= Stamp.allCases.count }

  init() {
    load()
  }

  /// Empties the card when it belongs to an earlier day.
  func refresh() {
    let today = DailyStorage.todayKey()
    if date != today {
      date = today
      stamps = []
    }
  }

  /// Awards a stamp for a finished run. Returns the stamp to show and whether it was added to
  /// today's card (false once the card is full, in which case any stamp is shown).
  func award() -> (stamp: Stamp, isNew: Bool) {
    refresh()
    let remaining = Stamp.allCases.filter { !stamps.contains($0) }
    guard !remaining.isEmpty else { return (Stamp.random(), false) }
    let stamp = Stamp.random(from: remaining)
    stamps.append(stamp)
    save()
    return (stamp, true)
  }

  private func load() {
    date = DailyStorage.todayKey()
    stamps = DailyStorage.loadStamps(today: date)
  }

  private func save() { DailyStorage.saveStamps(stamps, date: date) }
}
