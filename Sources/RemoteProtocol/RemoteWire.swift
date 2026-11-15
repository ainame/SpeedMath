import BrowserAPI
import JavaScriptKit
import ProtocolModels

/// A message the server (or the peer, through the server) sends to this client.
public enum ServerMessage {
  case connected(paired: Bool, peer: Bool)
  /// The Remote's own credential after the Presenter approved it.
  case approved(key: String)
  /// Remote: waiting for approval; both screens show `check`.
  case waiting(check: String)
  /// Presenter: a join request to approve or reject.
  case pending(request: String, check: String)
  case pendingGone
  case invite(generation: String, code: String, key: String)
  case inviteMissing
  case reset
  case peerUp
  case peerDown
  case pong
  case sync(Snapshot)
  case ack(RemoteWire.Ack)
  case command(Command)
  case requestSync
}

/// A message this client sends.
public enum ClientMessage {
  case auth(role: Int, key: String)
  case joinCode(generation: String, code: String)
  case joinQR(generation: String, key: String)
  case invite
  case approve(request: String)
  case reject(request: String)
  case revoke
  case end
  case ping
  case requestSync
  case sync(Snapshot)
  case ack(epoch: String, id: String, result: CommandResult)
  case command(Command)
}

/// Decodes and encodes the remote control's JSON messages. JSON text is parsed by JS
/// (`JSON.parse` through the bridge); every field is then checked here, so the rest of the app
/// only sees validated Swift values.
public enum RemoteWire {
  // MARK: Messages

  public static func decode(_ text: String) -> ServerMessage? {
    guard let x = frame(text.jsValue), let type = x.type.string else { return nil }
    switch type {
    case "connected": return .connected(paired: x.paired.boolean == true, peer: x.peer.boolean == true)
    case "approved":
      guard let key = x.key.string, Wire.isKey(key) else { return nil }
      return .approved(key: key)
    case "waiting":
      guard let check = x.check.string else { return nil }
      return .waiting(check: check)
    case "pending":
      guard let request = x.request.string, let check = x.check.string else { return nil }
      return .pending(request: request, check: check)
    case "pendingGone": return .pendingGone
    case "invite":
      guard let generation = x.generation.string, Wire.isID(generation), let key = x.key.string, Wire.isKey(key),
        let code = x.code.string.flatMap(Wire.normalizeCode)
      else { return nil }
      return .invite(generation: generation, code: code, key: key)
    case "inviteMissing": return .inviteMissing
    case "reset": return .reset
    case "peerUp": return .peerUp
    case "peerDown": return .peerDown
    case "pong": return .pong
    case "sync": return snapshot(x).map { .sync($0) }
    case "ack": return ack(x).map { .ack($0) }
    case "command": return command(x).map { .command($0) }
    case "requestSync": return isRequestSync(x) ? .requestSync : nil
    default: return nil
    }
  }

  public static func encode(_ message: ClientMessage) -> String {
    switch message {
    case .auth(let role, let key):
      return packet("auth") {
        $0["role"] = role.jsValue
        $0["key"] = key.jsValue
      }
    case .joinCode(let generation, let code):
      return packet("joinCode") {
        $0["generation"] = generation.jsValue
        $0["key"] = code.jsValue
      }
    case .joinQR(let generation, let key):
      return packet("joinQR") {
        $0["generation"] = generation.jsValue
        $0["key"] = key.jsValue
      }
    case .invite: return packet("invite")
    case .approve(let request): return packet("approve") { $0["request"] = request.jsValue }
    case .reject(let request): return packet("reject") { $0["request"] = request.jsValue }
    case .revoke: return packet("revoke")
    case .end: return packet("end")
    case .ping: return packet("ping")
    case .requestSync: return packet("requestSync")
    case .sync(let snapshot): return packet("sync") { fillSnapshot($0, snapshot) }
    case .ack(let epoch, let id, let result):
      return packet("ack") {
        $0["epoch"] = epoch.jsValue
        $0["id"] = id.jsValue
        $0["result"] = Int(result.rawValue).jsValue
      }
    case .command(let command): return packet("command") { fillCommand($0, command) }
    }
  }

  // MARK: HTTP control bodies

  public static func createRequest() -> String { packet("create") }

  public static func lookupRequest(code: String) -> String { packet("lookup") { $0["code"] = code.jsValue } }

  /// `POST /api/session` → the new session and the Presenter's credential.
  public static func createdSession(_ text: String) -> (id: String, key: String)? {
    guard let x = JS.parse(text), let id = x.id.string, let key = x.key.string, Wire.isID(id), Wire.isKey(key)
    else { return nil }
    return (id, key)
  }

  /// `POST /api/lookup` → the session and invite generation for a typed code.
  public static func foundSession(_ text: String) -> (id: String, generation: String)? {
    guard let x = JS.parse(text), let id = x.id.string, let generation = x.generation.string, Wire.isID(id),
      Wire.isID(generation)
    else { return nil }
    return (id, generation)
  }

  // MARK: Fields

  /// A frame within the size limit that parses to `{ v: <version>, type: "...", ... }`.
  static func frame(_ value: JSValue) -> JSObject? {
    guard let text = value.string, text.utf8.count <= Wire.frameLimit,
      let object = JS.parse(text), !JS.isArray(object),
      Wire.uint(object.v.number) == Wire.version, object.type.string != nil
    else { return nil }
    return object
  }

  static func packet(_ type: String, _ fill: (JSObject) -> Void = { _ in }) -> String {
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

  static func snapshot(_ x: JSObject) -> Snapshot? {
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

  static func ack(_ x: JSObject) -> Ack? {
    guard JS.keyCount(x) == 5, let epoch = id(x.epoch), let commandID = id(x.id),
      let result = Wire.uint(x.result.number, max: 4), result > 0
    else { return nil }
    return Ack(epoch: epoch, id: commandID, result: result)
  }

  static func command(_ x: JSObject) -> Command? {
    guard JS.keyCount(x) == 7, let epoch = id(x.epoch), let commandID = id(x.id),
      let baseVersion = Wire.uint(x.baseVersion.number), let rawAction = Wire.uint(x.action.number, max: 10),
      let value = Wire.uint(x.value.number, max: 45),
      WireRules.validCommand(action: rawAction, value: value),
      let action = RemoteAction(rawValue: Int32(rawAction))
    else { return nil }
    return Command(id: commandID, epoch: epoch, baseVersion: baseVersion, action: action, value: value)
  }

  static func fillCommand(_ object: JSObject, _ command: Command) {
    object["epoch"] = command.epoch.jsValue
    object["id"] = command.id.jsValue
    object["baseVersion"] = command.baseVersion.jsValue
    object["action"] = Int(command.action.rawValue).jsValue
    object["value"] = command.value.jsValue
  }

  static func isRequestSync(_ x: JSObject) -> Bool { JS.keyCount(x) == 2 }

  static func fillSnapshot(_ object: JSObject, _ snapshot: Snapshot) {
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
