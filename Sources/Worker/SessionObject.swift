import JavaScriptKit
import ProtocolModels
import RemoteProtocol

private let minute = 60_000.0
private let sessionLifetime = 120 * minute
private let inviteLifetime = 2 * minute
private let reconnectWindow = 10 * minute
private let authWait = 10_000.0

/// One pairing session: authenticates the Presenter and the Remote, runs the invite and approval
/// flow, and relays play messages between the two sockets. It stores only credentials, expiry and
/// socket identifiers; cards, answers, timing and records never reach it.
///
/// Each entry point receives the Durable Object's `ctx` from the JS class and keeps no state of
/// its own between calls (the Wasm instance is shared by every object in the isolate).
struct SessionObject {
  let ctx: JSObject

  // MARK: State

  private func prepare() {
    _ = Platform.exec(ctx, "CREATE TABLE IF NOT EXISTS session (singleton INTEGER PRIMARY KEY, state TEXT NOT NULL)")
  }

  private func load() -> SessionState? {
    prepare()
    guard let text = Platform.exec(ctx, "SELECT state FROM session WHERE singleton = 1").first?.state.string else {
      return nil
    }
    return SessionState(json: text)
  }

  private func save(_ state: SessionState) {
    _ = Platform.exec(ctx, "INSERT OR REPLACE INTO session VALUES (1, ?)", state.json.jsValue)
  }

  /// `deleteAll` drops the SQLite table too, but this instance may still receive a duplicate
  /// alarm, a stale lookup or a reconnect before it is evicted, so the table is recreated.
  private func erase() -> Deferred<Void> {
    Platform.storage(ctx, "deleteAll").map { prepare() }
  }

  private func live(_ state: SessionState?) -> Bool {
    guard let state else { return false }
    let now = Platform.now()
    return state.expires > now && state.presenter.until > now
  }

  private func validInvite(_ state: SessionState, _ generation: String?) -> Bool {
    guard let invite = state.invite, let generation else { return false }
    return invite.generation == generation && invite.expires > Platform.now()
  }

  // MARK: Sockets

  private var sockets: [JSObject] { Platform.list(JS.call(ctx, "getWebSockets")) }

  private func isOpen(_ ws: JSObject?) -> Bool { ws?.readyState.number == 1 }

  private func active(_ state: SessionState, _ ws: JSObject, _ role: Int) -> Bool {
    guard let a = Attachment.read(ws), a.role == role, let principal = state.principal(role) else { return false }
    return principal.socket == a.id && principal.until > Platform.now()
  }

  private func peer(_ state: SessionState, _ role: Int) -> JSObject? {
    sockets.first { isOpen($0) && active(state, $0, role) }
  }

  private func pendingSocket(_ state: SessionState) -> JSObject? {
    guard let id = state.pending?.socket else { return nil }
    return sockets.first { isOpen($0) && Attachment.read($0)?.id == id }
  }

  private func send(_ ws: JSObject?, _ type: String, _ fill: (JSObject) -> Void = { _ in }) {
    guard let ws, isOpen(ws) else { return }
    JS.call(ws, "send", RemoteWire.packet(type, fill).jsValue)
  }

  private func send(_ ws: JSObject?, _ type: String, display pending: SessionState.Pending) {
    send(ws, type) {
      $0["request"] = pending.request.jsValue
      $0["check"] = pending.check.jsValue
    }
  }

  private func close(_ ws: JSObject?, _ reason: String = "unavailable") {
    guard let ws, isOpen(ws) else { return }
    JS.call(ws, "close", 4001.jsValue, reason.jsValue)
  }

  /// Ends the invite generation. The code index row is released in the background; a stale row
  /// also fails `validLookup` and expires on its own.
  private func clearInvite(_ state: inout SessionState) {
    let invite = state.invite
    close(pendingSocket(state), "invite-ended")
    state.pending = nil
    state.invite = nil
    if let invite {
      let release = Platform.rpc(
        Platform.shard(ctx, invite.codeHash), "release",
        invite.codeHash.jsValue, state.id.jsValue, invite.generation.jsValue)
      Platform.background(ctx, release.map { _ in JSValue.undefined }.jsPromise)
    }
  }

  private func schedule(_ state: SessionState) -> Deferred<Void> {
    let now = Platform.now()
    var next = min(state.expires, state.presenter.until)
    if let remote = state.remote { next = min(next, remote.until) }
    if let invite = state.invite { next = min(next, invite.expires) }
    for ws in sockets {
      if let a = Attachment.read(ws), a.role == 0, !a.pending, let deadline = a.deadline, deadline > now {
        next = min(next, deadline)
      }
    }
    return Platform.storage(ctx, "setAlarm", next.jsValue)
  }

  // MARK: RPC from the Worker

  func create(id: String, hash: String) -> Deferred<Void> {
    if load() != nil { return .value(()) }
    let now = Platform.now()
    save(
      SessionState(
        id: id, expires: now + sessionLifetime, presenter: .init(hash: hash, until: now + reconnectWindow)))
    return Platform.storage(ctx, "setAlarm", (now + reconnectWindow).jsValue)
  }

  func validLookup(hash: String, generation: String) -> Bool {
    guard let state = load(), live(state), validInvite(state, generation), let invite = state.invite else {
      return false
    }
    return SHA256.matches(hash, invite.codeHash)
  }

  /// Accepts a WebSocket that must authenticate or join within `authWait`.
  func connect() -> Deferred<JSValue> {
    guard let state = load(), live(state), sockets.count < 8, let pair = JS.new("WebSocketPair"),
      let values = JS.global.Object.object.map({ JS.call($0, "values", pair.jsValue) }),
      let client = values[0].object, let server = values[1].object
    else { return .value(Platform.invalid()) }
    JS.call(ctx, "acceptWebSocket", server.jsValue)
    Attachment(id: JS.randomHex(bytes: 16), role: 0, deadline: Platform.now() + authWait).write(server)
    return schedule(state).map { Platform.upgrade(client) }
  }

  // MARK: Socket events

  func message(_ ws: JSObject, _ text: JSValue) -> Deferred<Void> {
    guard var a = Attachment.read(ws), var state = load(), live(state) else {
      close(ws)
      return .value(())
    }
    let now = Platform.now()
    if now - (a.since ?? 0) >= 10_000 {
      a.since = now
      a.messages = 0
    }
    let count = (a.messages ?? 0) + 1
    a.messages = count
    if count > (a.role != 0 ? 100 : 4) {
      close(ws, "slow")
      return .value(())
    }
    a.write(ws)
    guard let message = RemoteWire.frame(text), let type = message.type.string else {
      close(ws)
      return .value(())
    }
    if a.role == 0, !a.pending, let deadline = a.deadline, deadline > now,
      let raw = text.string, raw.utf8.count <= Wire.controlLimit
    {
      if type == "auth" { return authenticate(ws, a, message) }
      if type == "joinCode" || type == "joinQR" { return join(ws, a, message) }
    }
    guard a.role != 0, active(state, ws, a.role) else {
      close(ws)
      return .value(())
    }
    if type == "ping" {
      send(ws, "pong")
      return .value(())
    }
    if a.role == 1 {
      switch type {
      case "invite":
        return invite(ws)
      case "approve":
        return approve(ws, message.request.string)
      case "reject", "revoke", "end":
        if type == "reject" && state.pending?.request != message.request.string { return .value(()) }
        clearInvite(&state)
        state.issuing = nil
        if type != "reject" {
          close(peer(state, 2), "revoked")
          state.remote = nil
        }
        if type == "end" {
          close(ws, "ended")
          return erase()
        }
        save(state)
        send(ws, "reset")
        return schedule(state)
      default:
        break
      }
    }
    guard let kind = relayKind(message), a.role == 1 || a.role == 2,
      let role = Role(rawValue: Int32(a.role)), role.canRelay(kind)
    else {
      close(ws)
      return .value(())
    }
    if let other = peer(state, a.role == 1 ? 2 : 1) {
      JS.call(other, "send", text)
    } else {
      send(ws, "peerDown")
    }
    return .value(())
  }

  /// Only well-formed play messages are relayed, each in its role's direction.
  private func relayKind(_ message: JSObject) -> RelayKind? {
    switch message.type.string {
    case "sync": return RemoteWire.snapshot(message) != nil ? .sync : nil
    case "ack": return RemoteWire.ack(message) != nil ? .ack : nil
    case "command": return RemoteWire.command(message) != nil ? .command : nil
    case "requestSync": return RemoteWire.isRequestSync(message) ? .requestSync : nil
    default: return nil
    }
  }

  private func authenticate(_ ws: JSObject, _ a: Attachment, _ message: JSObject) -> Deferred<Void> {
    guard let rawRole = message.role.number, rawRole == 1 || rawRole == 2,
      let key = message.key.string, Wire.isKey(key)
    else {
      close(ws)
      return .value(())
    }
    let role = Int(rawRole)
    guard var state = load(), live(state), let deadline = a.deadline, deadline > Platform.now(), isOpen(ws),
      let current = Attachment.read(ws), current.role == 0, !current.pending,
      var principal = state.principal(role), principal.until > Platform.now(),
      SHA256.matches(Platform.credential(state.id, role, key), principal.hash)
    else {
      close(ws)
      return .value(())
    }
    let other = role == 1 ? 2 : 1
    let old = peer(state, role)
    let wasDisconnected = old == nil && principal.until < state.expires
    principal.socket = a.id
    principal.until = state.expires
    state.setPrincipal(role, principal)
    save(state)
    Attachment(id: a.id, role: role).write(ws)
    close(old, "replaced")
    let peerOnline = peer(state, other) != nil
    send(ws, "connected") {
      $0["paired"] = (state.remote != nil).jsValue
      $0["peer"] = peerOnline.jsValue
    }
    if role == 1, let pending = state.pending { send(ws, "pending", display: pending) }
    if role == 1, state.invite != nil, state.pending == nil { send(ws, "inviteMissing") }
    if role == 2 || wasDisconnected || old != nil { send(peer(state, other), "peerUp") }
    return schedule(state)
  }

  /// Issues a new invite generation: a typed code (reserved in the code index) and a QR key.
  private func invite(_ ws: JSObject) -> Deferred<Void> {
    guard var state = load(), live(state), active(state, ws, 1) else { return .value(()) }
    if let remote = state.remote, remote.until > Platform.now() { return .value(()) }
    clearInvite(&state)
    let attempt = JS.randomHex(bytes: 16)
    state.issuing = attempt
    state.remote = nil
    save(state)
    return reserveInvite(ws, sessionID: state.id, attempt: attempt, tries: 5)
  }

  /// The retry loop of `invite`: draws a code until the index accepts one (`for _ in 0..<5`).
  private func reserveInvite(_ ws: JSObject, sessionID: String, attempt: String, tries: Int) -> Deferred<Void> {
    guard tries > 0 else {
      send(ws, "inviteMissing")
      return .value(())
    }
    let code = randomCode()
    let key = JS.randomHex(bytes: 32)
    let codeHash = SHA256.hex(code)
    let inviteHash = SHA256.hex(key)
    let index = Platform.shard(ctx, codeHash)
    let expires = Platform.now() + inviteLifetime
    return Platform.rpc(
      index, "reserve", codeHash.jsValue, sessionID.jsValue, attempt.jsValue, expires.jsValue
    ).then { reserved -> Deferred<Void> in
      guard reserved?.boolean == true else {
        return reserveInvite(ws, sessionID: sessionID, attempt: attempt, tries: tries - 1)
      }
      // Another event may have run while the index answered: re-check before using the code.
      guard var latest = load(), live(latest), active(latest, ws, 1), latest.issuing == attempt,
        expires > Platform.now()
      else {
        return Platform.rpc(index, "release", codeHash.jsValue, sessionID.jsValue, attempt.jsValue).map { _ in () }
      }
      latest.invite = .init(
        generation: attempt, expires: expires, codeHash: codeHash, inviteHash: inviteHash, failures: 0)
      latest.issuing = nil
      save(latest)
      send(ws, "invite") {
        $0["generation"] = attempt.jsValue
        $0["code"] = code.jsValue
        $0["key"] = key.jsValue
        $0["expires"] = expires.jsValue
      }
      return schedule(latest)
    }
  }

  private func randomCode() -> String {
    let hex = Array(JS.randomHex(bytes: 12).utf8)
    var out: [UInt8] = []
    for i in 0..<12 {
      let byte = hexValue(hex[i * 2]) << 4 | hexValue(hex[i * 2 + 1])
      out.append(Wire.codeAlphabet[Int(byte & 31)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  private func hexValue(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : c - 0x61 + 10 }

  private func join(_ ws: JSObject, _ a: Attachment, _ message: JSObject) -> Deferred<Void> {
    let isCode = message.type.string == "joinCode"
    let code = isCode ? message.key.string.flatMap(Wire.normalizeCode) : nil
    let key: String? = isCode ? code : message.key.string.flatMap { Wire.isKey($0) ? $0 : nil }
    guard let key, let generation = message.generation.string, Wire.isID(generation) else {
      close(ws)
      return .value(())
    }
    let hash = SHA256.hex(key)
    guard var state = load(), live(state), let deadline = a.deadline, deadline > Platform.now(), isOpen(ws),
      let current = Attachment.read(ws), current.role == 0, !current.pending,
      validInvite(state, generation), var invite = state.invite
    else {
      close(ws)
      return .value(())
    }
    guard SHA256.matches(hash, code != nil ? invite.codeHash : invite.inviteHash) else {
      invite.failures += 1
      state.invite = invite
      if invite.failures >= 5 {
        clearInvite(&state)
        send(peer(state, 1), "inviteMissing")
      }
      save(state)
      close(ws)
      return .value(())
    }
    if state.remote != nil || pendingSocket(state) != nil || peer(state, 1) == nil {
      close(ws)
      return .value(())
    }
    let pending = SessionState.Pending(
      socket: a.id, request: JS.randomHex(bytes: 16), check: upper(JS.randomHex(bytes: 3)))
    state.pending = pending
    save(state)
    var waiting = a
    waiting.pending = true
    waiting.write(ws)
    send(ws, "waiting", display: pending)
    send(peer(state, 1), "pending", display: pending)
    return schedule(state)
  }

  private func upper(_ hex: String) -> String {
    String(decoding: hex.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }, as: UTF8.self)
  }

  private func approve(_ ws: JSObject, _ request: String?) -> Deferred<Void> {
    guard var state = load(), live(state), active(state, ws, 1), let pending = state.pending,
      pending.request == request, validInvite(state, state.invite?.generation),
      let remote = pendingSocket(state)
    else { return .value(()) }
    let key = JS.randomHex(bytes: 32)
    let hash = Platform.credential(state.id, 2, key)
    state.pending = nil  // Clear the invite without closing the approved socket.
    clearInvite(&state)
    state.remote = .init(hash: hash, until: state.expires, socket: pending.socket)
    save(state)
    Attachment(id: pending.socket, role: 2).write(remote)
    send(remote, "approved") { $0["key"] = key.jsValue }
    send(ws, "peerUp")
    return schedule(state)
  }

  func closed(_ ws: JSObject) -> Deferred<Void> {
    guard let a = Attachment.read(ws), var state = load(), live(state) else { return .value(()) }
    if a.pending, a.id == state.pending?.socket {
      state.pending = nil
      save(state)
      send(peer(state, 1), "pendingGone")
    }
    guard var principal = state.principal(a.role), principal.socket == a.id else { return .value(()) }
    principal.socket = nil
    principal.until = min(state.expires, Platform.now() + reconnectWindow)
    state.setPrincipal(a.role, principal)
    save(state)
    send(peer(state, a.role == 1 ? 2 : 1), "peerDown")
    return schedule(state)
  }

  /// Expires invites, reconnect windows and unauthenticated sockets; ends the session at its
  /// deadline. Safe to run again after a delay, a duplicate or a retry.
  func alarm() -> Deferred<Void> {
    guard var state = load(), live(state) else {
      if var stale = load() { clearInvite(&stale) }
      for ws in sockets { close(ws, "ended") }
      return erase()
    }
    let now = Platform.now()
    if let invite = state.invite, invite.expires <= now {
      clearInvite(&state)
      send(peer(state, 1), "inviteMissing")
    }
    if let remote = state.remote, remote.until <= now {
      close(sockets.first { Attachment.read($0)?.id == remote.socket }, "revoked")
      state.remote = nil
      send(peer(state, 1), "reset")
    }
    for ws in sockets {
      if let a = Attachment.read(ws), a.role == 0, !a.pending, let deadline = a.deadline, deadline <= now {
        close(ws)
      }
    }
    save(state)
    return schedule(state)
  }
}
