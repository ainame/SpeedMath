import JavaScriptKit
import ProtocolModels

/// Decodes and encodes WebSocket frames. JSON text is parsed by JS (`JSON.parse` through the
/// bridge); every field is then checked here before the client acts on it.
public enum RemoteWire {
  /// A frame within the size limit that parses to `{ v: 1, type: "...", ... }`.
  public static func frame(_ value: JSValue) -> JSObject? {
    guard let text = value.string, text.utf8.count <= Wire.frameLimit,
      let object = JS.parse(text), !JS.isArray(object),
      Wire.uint(object.v.number) == Wire.version, object.type.string != nil
    else { return nil }
    return object
  }

  public static func packet(_ type: String, _ fill: (JSObject) -> Void = { _ in }) -> String {
    let object = JS.object()
    object["v"] = Wire.version.jsValue
    object["type"] = type.jsValue
    fill(object)
    return JS.stringify(object)
  }

  private static func id(_ value: JSValue) -> String? {
    guard let text = value.string, Wire.isID(text) else { return nil }
    return text
  }

  public static func snapshot(_ x: JSObject) -> Snapshot? {
    guard JS.keyCount(x) == 9, let epoch = id(x.epoch), let deckVersion = id(x.deckVersion),
      let version = Wire.uint(x.version.number), let rawPhase = Wire.uint(x.phase.number, max: 2),
      let phase = PlayPhase(rawValue: Int32(rawPhase)), let index = Wire.uint(x.index.number, max: 53),
      let elapsed = Wire.uint(x.elapsed.number, max: Wire.maxElapsed),
      let list = x.cards.object, JS.isArray(list)
    else { return nil }
    let count = Int(list.length.number ?? -1)
    guard count >= 0, count <= Wire.maxCards else { return nil }
    var cards: [WireCard] = []
    for i in 0..<count {
      guard let tuple = list[i].object, JS.isArray(tuple), tuple.length.number == 3,
        let lhs = Wire.uint(tuple[0].number, max: 18), let rhs = Wire.uint(tuple[2].number, max: 9),
        let sign = tuple[1].number, sign == 1 || sign == -1,
        let card = WireCard(lhs: lhs, sign: Int(sign), rhs: rhs)
      else { return nil }
      cards.append(card)
    }
    return Snapshot(
      epoch: epoch, deckVersion: deckVersion, version: version, phase: phase, index: index,
      elapsed: elapsed, cards: cards)
  }

  public struct Ack {
    public let epoch: String
    public let id: String
    public let result: Int
  }

  public static func ack(_ x: JSObject) -> Ack? {
    guard JS.keyCount(x) == 5, let epoch = id(x.epoch), let commandID = id(x.id),
      let result = Wire.uint(x.result.number, max: 4), result > 0
    else { return nil }
    return Ack(epoch: epoch, id: commandID, result: result)
  }

  public static func command(_ x: JSObject) -> Command? {
    guard JS.keyCount(x) == 6, let epoch = id(x.epoch), let commandID = id(x.id),
      let baseVersion = Wire.uint(x.baseVersion.number), let raw = x.direction.number,
      raw == 1 || raw == -1, let direction = Direction(rawValue: Int32(raw))
    else { return nil }
    return Command(id: commandID, epoch: epoch, baseVersion: baseVersion, direction: direction)
  }

  public static func isRequestSync(_ x: JSObject) -> Bool { JS.keyCount(x) == 2 }

  public static func fillSnapshot(_ object: JSObject, _ snapshot: Snapshot) {
    object["epoch"] = snapshot.epoch.jsValue
    object["deckVersion"] = snapshot.deckVersion.jsValue
    object["version"] = snapshot.version.jsValue
    object["phase"] = Int(snapshot.phase.rawValue).jsValue
    object["index"] = snapshot.index.jsValue
    object["elapsed"] = snapshot.elapsed.jsValue
    guard let list = JS.new("Array") else { return }
    for (i, card) in snapshot.cards.enumerated() {
      guard let tuple = JS.new("Array") else { continue }
      tuple[0] = card.lhs.jsValue
      tuple[1] = card.sign.jsValue
      tuple[2] = card.rhs.jsValue
      list[i] = tuple.jsValue
    }
    object["cards"] = list.jsValue
  }
}
