import JavaScriptKit
import RemoteProtocol

/// The one row a session object stores. The JSON shape matches the earlier JavaScript Worker so
/// sessions that are live during a deploy keep working.
struct SessionState {
  struct Principal {
    var hash: String
    var until: Double
    var socket: String?
  }

  struct Invite {
    var generation: String
    var expires: Double
    var codeHash: String
    var inviteHash: String
    var failures: Int
  }

  struct Pending {
    var socket: String
    var request: String
    var check: String
  }

  var id: String
  var expires: Double
  var presenter: Principal
  var remote: Principal?
  var invite: Invite?
  var pending: Pending?
  var issuing: String?

  func principal(_ role: Int) -> Principal? { role == 1 ? presenter : role == 2 ? remote : nil }

  mutating func setPrincipal(_ role: Int, _ value: Principal) {
    if role == 1 { presenter = value } else if role == 2 { remote = value }
  }

  // MARK: JSON

  init(id: String, expires: Double, presenter: Principal) {
    self.id = id
    self.expires = expires
    self.presenter = presenter
  }

  init?(json text: String) {
    guard let o = JS.parse(text), let id = o.id.string, let expires = o.expires.number,
      let presenter = Self.principal(o.presenter)
    else { return nil }
    self.init(id: id, expires: expires, presenter: presenter)
    remote = Self.principal(o.remote)
    if let i = o.invite.object, let generation = i.generation.string, let expires = i.expires.number,
      let codeHash = i.codeHash.string, let inviteHash = i.inviteHash.string
    {
      invite = Invite(
        generation: generation, expires: expires, codeHash: codeHash, inviteHash: inviteHash,
        failures: Int(i.failures.number ?? 0))
    }
    if let p = o.pending.object, let socket = p.socket.string, let request = p.display.object?.request.string,
      let check = p.display.object?.check.string
    {
      pending = Pending(socket: socket, request: request, check: check)
    }
    issuing = o.issuing.string
  }

  private static func principal(_ value: JSValue) -> Principal? {
    guard let o = value.object, let hash = o["hash"].string, let until = o.until.number else { return nil }
    return Principal(hash: hash, until: until, socket: o.socket.string)
  }

  var json: String {
    let o = JS.object()
    o["id"] = id.jsValue
    o["expires"] = expires.jsValue
    o["presenter"] = Self.object(presenter).jsValue
    if let remote { o["remote"] = Self.object(remote).jsValue }
    if let invite {
      let i = JS.object()
      i["generation"] = invite.generation.jsValue
      i["expires"] = invite.expires.jsValue
      i["codeHash"] = invite.codeHash.jsValue
      i["inviteHash"] = invite.inviteHash.jsValue
      i["failures"] = invite.failures.jsValue
      o["invite"] = i.jsValue
    }
    if let pending {
      let p = JS.object()
      p["socket"] = pending.socket.jsValue
      p["display"] = Self.display(pending).jsValue
      o["pending"] = p.jsValue
    }
    if let issuing { o["issuing"] = issuing.jsValue }
    return JS.stringify(o)
  }

  private static func object(_ principal: Principal) -> JSObject {
    let o = JS.object()
    o["hash"] = principal.hash.jsValue
    o["until"] = principal.until.jsValue
    if let socket = principal.socket { o["socket"] = socket.jsValue }
    return o
  }

  /// `{ request, check }`, shown on both screens while a join waits for approval.
  static func display(_ pending: Pending) -> JSObject {
    let d = JS.object()
    d["request"] = pending.request.jsValue
    d["check"] = pending.check.jsValue
    return d
  }
}

/// What a hibernatable WebSocket remembers about itself: role 0 until it authenticates or joins.
struct Attachment {
  var id: String
  var role: Int
  var deadline: Double?
  var pending = false
  var since: Double?
  var messages: Int?

  init(id: String, role: Int, deadline: Double? = nil) {
    self.id = id
    self.role = role
    self.deadline = deadline
  }

  static func read(_ ws: JSObject) -> Attachment? {
    guard let o = JS.call(ws, "deserializeAttachment").object, let id = o.id.string,
      let role = o.role.number
    else { return nil }
    var a = Attachment(id: id, role: Int(role), deadline: o.deadline.number)
    a.pending = o.pending.boolean == true
    a.since = o.since.number
    a.messages = o.messages.number.map { Int($0) }
    return a
  }

  func write(_ ws: JSObject) {
    let o = JS.object()
    o["id"] = id.jsValue
    o["role"] = role.jsValue
    if let deadline { o["deadline"] = deadline.jsValue }
    if pending { o["pending"] = true.jsValue }
    if let since { o["since"] = since.jsValue }
    if let messages { o["messages"] = messages.jsValue }
    JS.call(ws, "serializeAttachment", o.jsValue)
  }
}
