import JavaScriptKit
import Reactivity

/// Today's stamp card: every finished run awards one stamp the card does not have yet, in random
/// order, until all six are collected. Stored in localStorage and emptied when the local date
/// changes (midnight).
@Reactive
final class StampBook {
  static let storageKey = "speedmath.stamps.v1"

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
    guard let saved = DailyStorage.load(Self.storageKey, today: date),
      let list = saved["stamps"].object
    else { return }
    let count = Int(list["length"].number ?? 0)
    var loaded: [Stamp] = []
    for index in 0..<count {
      if let raw = list[index].string, let stamp = Stamp(rawValue: raw), !loaded.contains(stamp) {
        loaded.append(stamp)
      }
    }
    stamps = loaded
  }

  private func save() {
    let stamps = self.stamps
    DailyStorage.save(Self.storageKey, date: date) { value in
      guard let list = DailyStorage.makeArray() else { return }
      for (index, stamp) in stamps.enumerated() {
        list[index] = stamp.rawValue.jsValue
      }
      value["stamps"] = list.jsValue
    }
  }
}
