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
    let today = Self.todayKey()
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
    let today = Self.todayKey()
    date = today
    guard let storage = JSObject.global.speedMathStorage.object,
      let saved = storage["load"].function?.callAsFunction(this: storage, Self.storageKey).object,
      saved["date"].string == today,
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
    guard let storage = JSObject.global.speedMathStorage.object,
      let makeObject = JSObject.global.Object.function,
      let makeArray = JSObject.global.Array.function
    else { return }
    let list = makeArray.new()
    for (index, stamp) in stamps.enumerated() {
      list[index] = stamp.rawValue.jsValue
    }
    let value = makeObject.new()
    value["date"] = date.jsValue
    value["stamps"] = list.jsValue
    _ = storage["save"].function?.callAsFunction(this: storage, Self.storageKey, value)
  }

  /// Local calendar date, e.g. "2026-11-14".
  static func todayKey() -> String {
    guard let makeDate = JSObject.global.Date.function else { return "" }
    let now = makeDate.new()
    func part(_ name: String) -> Int {
      Int(now[name].function?.callAsFunction(this: now).number ?? 0)
    }
    return "\(part("getFullYear"))-\(part("getMonth") + 1)-\(part("getDate"))"
  }
}
