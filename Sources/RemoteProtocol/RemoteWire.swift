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
    guard JS.keyCount(x) == 13, let epoch = id(x.epoch), let deckVersion = id(x.deckVersion),
      let version = Wire.uint(x.version.number), let rawScreen = Wire.uint(x.screen.number, max: 3),
      let screen = Screen(rawValue: Int32(rawScreen)), let index = Wire.uint(x.index.number, max: 53),
      let elapsed = Wire.uint(x.elapsed.number, max: Wire.maxElapsed),
      let deck = Wire.uint(x.deck.number, max: 3), let zero = Wire.uint(x.zero.number, max: 1),
      let count = Wire.uint(x.count.number, max: 45), let timer = Wire.uint(x.timer.number, max: 1),
      let list = x.cards.object, JS.isArray(list)
    else { return nil }
    let total = Int(list.length.number ?? -1)
    guard total >= 0, total <= Wire.maxCards else { return nil }
    var cards: [WireCard] = []
    for i in 0..<total {
      guard let tuple = list[i].object, JS.isArray(tuple), tuple.length.number == 3,
        let lhs = Wire.uint(tuple[0].number, max: 18), let rhs = Wire.uint(tuple[2].number, max: 9),
        let sign = tuple[1].number, sign == 1 || sign == -1,
        let card = WireCard(lhs: lhs, sign: Int(sign), rhs: rhs)
      else { return nil }
      cards.append(card)
    }
    return Snapshot(
      epoch: epoch, deckVersion: deckVersion, version: version, screen: screen, index: index,
      elapsed: elapsed, cards: cards,
      settings: WireSettings(deck: deck, includeZero: zero == 1, count: count, showTimer: timer == 1))
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
    guard JS.keyCount(x) == 7, let epoch = id(x.epoch), let commandID = id(x.id),
      let baseVersion = Wire.uint(x.baseVersion.number), let rawAction = Wire.uint(x.action.number, max: 10),
      let value = Wire.uint(x.value.number, max: 45),
      WireRules.validCommand(action: rawAction, value: value),
      let action = RemoteAction(rawValue: Int32(rawAction))
    else { return nil }
    return Command(id: commandID, epoch: epoch, baseVersion: baseVersion, action: action, value: value)
  }

  public static func fillCommand(_ object: JSObject, _ command: Command) {
    object["epoch"] = command.epoch.jsValue
    object["id"] = command.id.jsValue
    object["baseVersion"] = command.baseVersion.jsValue
    object["action"] = Int(command.action.rawValue).jsValue
    object["value"] = command.value.jsValue
  }

  public static func isRequestSync(_ x: JSObject) -> Bool { JS.keyCount(x) == 2 }

  public static func fillSnapshot(_ object: JSObject, _ snapshot: Snapshot) {
    object["epoch"] = snapshot.epoch.jsValue
    object["deckVersion"] = snapshot.deckVersion.jsValue
    object["version"] = snapshot.version.jsValue
    object["screen"] = Int(snapshot.screen.rawValue).jsValue
    object["index"] = snapshot.index.jsValue
    object["elapsed"] = snapshot.elapsed.jsValue
    object["deck"] = snapshot.settings.deck.jsValue
    object["zero"] = (snapshot.settings.includeZero ? 1 : 0).jsValue
    object["count"] = snapshot.settings.count.jsValue
    object["timer"] = (snapshot.settings.showTimer ? 1 : 0).jsValue
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
