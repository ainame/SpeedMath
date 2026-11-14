import JavaScriptKit
import RemoteProtocol
import ProtocolModels

/// What the Presenter's pairing panel and the Remote screen render.
struct RemoteModel {
  var status = ""
  var online = false
  var open = false
  var started = false
  var joining = false
  var retry = false
  var paired = false
  var request: String?
  var check: String?
  var code: String?
  var qr: String?
  /// The Presenter's screen and home-screen settings, mirrored on the Remote.
  var screen: Screen = .home
  var settings = WireSettings(deck: 0, includeZero: false, count: 45, showTimer: true)
  var index = 0
  var count = 0
  var elapsed: Double = 0
  /// `Browser.now()` minus the Presenter's elapsed time when the latest snapshot arrived.
  var startedAt: Double = 0
  var question = ""
  var answer = ""
  var notice = ""
  var busy = false
}

enum RemoteRole: Int {
  case presenter = 1
  case remote = 2
}

/// A pairing in progress or an authenticated role. While joining, `generation` is set and `key`
/// is the QR invite key (or `code` is the typed code); once approved, only `id` and `key` remain.
struct RemoteSession {
  var id: String
  var key: String?
  var generation: String?
  var code: String?

  var isJoining: Bool { generation != nil }
  var isAuthenticatedRole: Bool { generation == nil && key != nil }
}

private let issueText = "つなげませんでした。コードを たしかめて、もういちど。"
private let disconnectedText = "せつぞくが きれました"
private let syncedText = "つながりました"
private let connectingText = "つないでいます…"
private let presenterStore = "speedmath.presenter.v1"

/// One side of a pairing: the Presenter (child's screen, role 1) or the Remote (role 2).
/// It owns the WebSocket, reconnects with backoff, and keeps the Remote's view of the
/// Presenter's state ordered. The Presenter stays the source of truth for play.
final class RemoteLink {
  let role: RemoteRole
  private var render: ((RemoteModel) -> Void)?
  private var presenterEvent: ((Command?) -> Void)?
  private(set) var model = RemoteModel()

  private var session: RemoteSession?
  private var socket: JSObject?
  private var socketToken = 0
  private var socketHandlers: [JSClosure] = []
  private var retiredHandlers: [JSClosure] = []
  private var authenticated = false
  private var attempts = 0
  private var inFlight: JSObject?
  private var wantInvite = false
  private var snapshot: Snapshot?
  private var oldEpochs: [String] = []
  private var inFlightCommand: Command?
  private var retries = 0
  private var commandStarted: Double = 0
  private var disposed = false

  private let retryTimer = JSTimer()
  private let probeTimer = JSTimer()
  private let commandTimer = JSTimer()
  private let connectTimer = JSTimer()
  private let beginTimer = JSTimer()
  private var listeners: [JSListener] = []

  init(role: RemoteRole, render: @escaping (RemoteModel) -> Void, presenter: @escaping (Command?) -> Void) {
    self.role = role
    self.render = render
    self.presenterEvent = presenter
    retryTimer.set { [self] in connect() }
    probeTimer.set { [self] in closeSocket() }
    commandTimer.set { [self] in transmit() }
    connectTimer.set { [self] in closeSocket() }
    beginTimer.set { [self] in abortBegin() }
    if let document = JS.global.document.object {
      listeners.append(JSListener(document, "visibilitychange") { [self] _ in visible() })
    }
    listeners.append(JSListener(JS.global, "online") { [self] _ in visible() })
    listeners.append(JSListener(JS.global, "offline") { [self] _ in offline() })

    if role == .presenter, let reload = RemoteLink.reloadSession {
      RemoteLink.reloadSession = nil
      session = RemoteSession(id: reload.id, key: reload.key)
      storePresenter(session)
      update {
        $0.started = true
        $0.status = connectingText
      }
      connect()
    }
    if role == .remote {
      RemoteLink.active = self
      joinInvite()
    }
  }

  // MARK: - Startup state taken from the URL and the previous document

  private struct ReloadSession {
    let id: String
    let key: String
    let route: String
  }

  private static var pendingInvite: RemoteSession?
  private static var reloadSession: ReloadSession?
  private static var active: RemoteLink?
  private static var hashListener: JSListener?

  /// Runs once before the app renders: takes a QR invite out of the URL, restores the
  /// Presenter's session after a reload, and watches for invites that iOS Safari delivers to an
  /// already open tab as a same-document hash change.
  static func startup() {
    pendingInvite = takeInvite()
    reloadSession = readReload()
    hashListener = JSListener(JS.global, "hashchange") { _ in
      guard let invite = takeInvite() else { return }
      pendingInvite = invite
      // A Remote screen that is already mounted joins now; otherwise the next one picks it up.
      active?.joinInvite()
    }
  }

  /// Reads `#/remote?invite=<id>.<generation>.<key>` and removes it from history.
  private static func takeInvite() -> RemoteSession? {
    let hash = JS.hash
    let prefix = "#/remote?"
    guard hash.utf8.starts(with: prefix.utf8),
      let search = JS.new("URLSearchParams", String(hash.utf8.dropFirst(prefix.utf8.count))!.jsValue),
      let value = JS.call(search, "get", "invite".jsValue).string
    else { return nil }
    if let history = JS.global.history.object, let location = JS.global.location.object {
      let path = (location.pathname.string ?? "") + (location.search.string ?? "") + "#/remote"
      JS.call(history, "replaceState", history.state, JSValue.null, path.jsValue)
    }
    let parts = value.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
      .map { String($0)! }
    guard parts.count == 3, Wire.isID(parts[0]), Wire.isID(parts[1]), Wire.isKey(parts[2]) else { return nil }
    return RemoteSession(id: parts[0], key: parts[2], generation: parts[1])
  }

  private static func readReload() -> ReloadSession? {
    let stored = JS.sessionLoad(presenterStore)
    JS.sessionSave(presenterStore, nil)
    guard let stored, let performance = JS.global.performance.object,
      let entries = JS.call(performance, "getEntriesByType", "navigation".jsValue).object,
      entries[0].object?.type.string == "reload", JS.global.opener.object == nil,
      let saved = JS.parse(stored), let id = saved.id.string, let key = saved.key.string,
      let route = saved.route.string, Wire.isID(id), Wire.isKey(key)
    else { return nil }
    return ReloadSession(id: id, key: key, route: route)
  }

  private func storePresenter(_ session: RemoteSession?) {
    guard let session, let key = session.key else {
      JS.sessionSave(presenterStore, nil)
      return
    }
    let value = JS.object()
    value["id"] = session.id.jsValue
    value["key"] = key.jsValue
    value["route"] = JS.hash.jsValue
    JS.sessionSave(presenterStore, JS.stringify(value))
  }

  static func identifier() -> String { JS.randomHex(bytes: 16) }

  // MARK: - Model

  private func update(_ change: (inout RemoteModel) -> Void) {
    guard !disposed else { return }
    change(&model)
    render?(model)
  }

  // MARK: - Browser events

  private func visible() {
    if JS.global.document.visibilityState.string == "hidden" || session == nil { return }
    if isOpen && authenticated { probe() } else if inFlight == nil { retry() }
  }

  private func offline() {
    update {
      $0.online = false
      $0.retry = session?.isAuthenticatedRole == true
      $0.status = disconnectedText
    }
    // A closing handshake can stall on a lost network, so drop the socket immediately.
    let current = socket
    if current != nil && session?.isJoining != true { resetConnection() }
    if let current { JS.call(current, "close") }
  }

  private var isOpen: Bool { socket?.readyState.number == 1 }

  // MARK: - Pairing

  /// Presenter: create a session and show an invite. Remote: look up a typed code and join.
  func begin(_ input: String = "") {
    if disposed || session != nil || inFlight != nil { return }
    let code: String?
    if role == .remote {
      code = Wire.normalizeCode(input)
      guard code != nil else {
        update { $0.status = issueText }
        return
      }
    } else {
      code = nil
    }
    guard let controller = JS.new("AbortController") else { return }
    inFlight = controller
    beginTimer.start(8000)
    update {
      $0.status = connectingText
      $0.joining = true
    }
    let body = role == .presenter
      ? RemoteWire.packet("create")
      : RemoteWire.packet("lookup") { $0["code"] = code!.jsValue }
    post(role == .presenter ? "session" : "lookup", body: body, signal: controller) { [self] result in
      beginTimer.cancel()
      inFlight = nil
      if disposed { return }
      guard case .success(let value) = result else {
        // A scanned invite may have taken over while the request was running.
        if session != nil { return }
        update {
          $0.joining = false
          $0.status = result.isSlow ? "すこし まってから ためしてね" : issueText
        }
        return
      }
      if session != nil { return }
      if role == .presenter {
        guard let id = value.id.string, let key = value.key.string, Wire.isID(id), Wire.isKey(key) else {
          update {
            $0.joining = false
            $0.status = issueText
          }
          return
        }
        session = RemoteSession(id: id, key: key)
        storePresenter(session)
        wantInvite = true
        update {
          $0.started = true
          $0.open = true
        }
      } else {
        guard let id = value.id.string, let generation = value.generation.string,
          Wire.isID(id), Wire.isID(generation)
        else {
          update {
            $0.joining = false
            $0.status = issueText
          }
          return
        }
        session = RemoteSession(id: id, generation: generation, code: code)
      }
      connect()
    }
  }

  private func abortBegin() {
    if let inFlight { JS.call(inFlight, "abort") }
  }

  private enum PostResult {
    case success(JSObject)
    case failure(slow: Bool)

    var isSlow: Bool {
      if case .failure(let slow) = self { return slow }
      return false
    }
  }

  private func post(_ path: String, body: String, signal: JSObject, done: @escaping (PostResult) -> Void) {
    let headers = JS.object()
    headers["Content-Type"] = "application/json".jsValue
    let options = JS.object()
    options["method"] = "POST".jsValue
    options["headers"] = headers.jsValue
    options["body"] = body.jsValue
    options["signal"] = signal.signal
    guard let request = JS.call(JS.global, "fetch", ("/api/" + path).jsValue, options.jsValue).object else {
      done(.failure(slow: false))
      return
    }
    JSPromises.then(request, { response in
      guard let response = response.object, response.ok.boolean == true,
        let json = JS.call(response, "json").object
      else {
        done(.failure(slow: response.object?.status.number == 429))
        return
      }
      JSPromises.then(json, { value in
        if let value = value.object { done(.success(value)) } else { done(.failure(slow: false)) }
      }, { done(.failure(slow: false)) })
    }, { done(.failure(slow: false)) })
  }

  /// Presenter: open or close the pairing panel, starting a session when needed.
  func show() {
    update { $0.open.toggle() }
    guard model.open else { return }
    if session == nil {
      begin()
    } else if !authenticated {
      retry()
    } else if model.code == nil && !model.paired && model.request == nil {
      newInvite()
    }
  }

  func newInvite() {
    if model.paired { return }
    if send("invite") {
      update {
        $0.code = nil
        $0.qr = nil
        $0.request = nil
        $0.check = nil
        $0.status = "コードを つくっています…"
      }
    }
  }

  /// Presenter: end the pairing with the current Remote. The session stays for a new invite.
  func revoke() { send("revoke") }

  func decide(_ approved: Bool, request: String) {
    if request == model.request {
      send(approved ? "approve" : "reject") { $0["request"] = request.jsValue }
    }
  }

  /// Remote: join with a scanned invite. It replaces a half-finished code join, but never an
  /// approved pairing.
  func joinInvite() {
    guard !disposed, role == .remote, let invite = RemoteLink.pendingInvite else { return }
    RemoteLink.pendingInvite = nil
    if session?.isAuthenticatedRole == true { return }
    abortBegin()
    if let current = socket {
      resetConnection()
      JS.call(current, "close")
    }
    session = invite
    update {
      $0.status = connectingText
      $0.joining = true
      $0.check = nil
    }
    connect()
  }

  // MARK: - Transport

  @discardableResult
  private func send(_ type: String, _ fill: (JSObject) -> Void = { _ in }) -> Bool {
    guard JS.online, authenticated, isOpen, let socket else { return false }
    JS.call(socket, "send", RemoteWire.packet(type, fill).jsValue)
    return true
  }

  private func closeSocket() {
    if let socket { JS.call(socket, "close") }
  }

  private func connect() {
    guard !disposed, let session, socket == nil, JS.online,
      let location = JS.global.location.object, let origin = location.origin.string,
      let url = JS.new("URL", ("/api/socket/" + session.id).jsValue, origin.jsValue)
    else { return }
    url["protocol"] = (location["protocol"].string == "https:" ? "wss:" : "ws:").jsValue
    guard let ws = JS.new("WebSocket", url.href) else { return }
    releaseRetired()
    socket = ws
    socketToken += 1
    let token = socketToken
    connectTimer.start(8000)
    let onOpen = JSClosure { [self] _ in
      guard token == socketToken else { return .undefined }
      let text: String
      if let generation = session.generation {
        text = RemoteWire.packet(session.code != nil ? "joinCode" : "joinQR") {
          $0["generation"] = generation.jsValue
          $0["key"] = (session.code ?? session.key ?? "").jsValue
        }
      } else {
        text = RemoteWire.packet("auth") {
          $0["role"] = role.rawValue.jsValue
          $0["key"] = (session.key ?? "").jsValue
        }
      }
      JS.call(ws, "send", text.jsValue)
      return .undefined
    }
    let onMessage = JSClosure { [self] arguments in
      guard token == socketToken, let event = arguments.first?.object,
        let value = RemoteWire.frame(event.data)
      else { return .undefined }
      message(value)
      return .undefined
    }
    let onClose = JSClosure { [self] arguments in
      guard token == socketToken, !disposed else { return .undefined }
      let event = arguments.first?.object
      closed(code: Int(event?.code.number ?? 0), reason: event?.reason.string ?? "")
      return .undefined
    }
    ws["onopen"] = onOpen.jsValue
    ws["onmessage"] = onMessage.jsValue
    ws["onclose"] = onClose.jsValue
    socketHandlers = [onOpen, onMessage, onClose]
  }

  private func closed(code: Int, reason: String) {
    resetConnection()
    let definitive = code == 4001 &&
      (reason == "unavailable" || reason == "invite-ended" || reason == "revoked" || reason == "ended" ||
        reason == "replaced")
    let wasJoining = session?.isJoining == true
    if wasJoining || definitive {
      session = nil
      inFlightCommand = nil
      snapshot = nil
      oldEpochs.removeAll()
      if role == .presenter { storePresenter(nil) }
      update {
        $0.started = false
        $0.paired = false
        $0.joining = false
        $0.retry = false
        $0.request = nil
        $0.code = nil
        $0.qr = nil
        $0.check = nil
        $0.busy = false
        $0.status = wasJoining ? issueText : "せつぞくが おわりました"
      }
      return
    }
    update {
      $0.retry = true
      $0.status = disconnectedText
    }
    if JS.online && attempts < 6 {
      var delay = 250.0
      for _ in 0..<attempts { delay *= 2 }
      attempts += 1
      retryTimer.start(min(8000, delay))
    }
  }

  /// Forgets the current socket. Its handlers are detached at once so a late event from it can
  /// never reach a released closure; the closures themselves are released on the next connect.
  private func detachSocket() {
    if let socket {
      socket["onopen"] = .null
      socket["onmessage"] = .null
      socket["onclose"] = .null
    }
    retiredHandlers.append(contentsOf: socketHandlers)
    socketHandlers.removeAll()
    socket = nil
    socketToken += 1
  }

  private func releaseRetired() {
    for closure in retiredHandlers { closure.release() }
    retiredHandlers.removeAll()
  }

  private func resetConnection() {
    detachSocket()
    authenticated = false
    connectTimer.cancel()
    probeTimer.cancel()
    commandTimer.cancel()
    update { $0.online = false }
  }

  func retry() {
    guard session != nil, !disposed else { return }
    attempts = 0
    retryTimer.cancel()
    if socket == nil { connect() } else if authenticated { probe() }
  }

  private func probe() {
    probeTimer.cancel()
    // On background restore, pause controls until the server answers and the Presenter resyncs.
    if role == .remote { update { $0.online = false } }
    if send("ping") { probeTimer.start(3500) }
  }

  // MARK: - Messages

  private func message(_ value: JSObject) {
    let type = value.type.string ?? ""
    switch type {
    case "connected", "approved":
      if type == "approved" {
        guard role == .remote, let key = value.key.string, Wire.isKey(key), let current = session else { return }
        session = RemoteSession(id: current.id, key: key)
        snapshot = nil
        oldEpochs.removeAll()
      }
      authenticated = true
      attempts = 0
      connectTimer.cancel()
      let peer = value.peer.boolean == true
      update {
        $0.joining = false
        $0.retry = false
        $0.check = nil
        $0.paired = role == .remote || value.paired.boolean == true
        $0.status = role == .presenter ? (peer ? syncedText : "") : "どうきしています…"
      }
      if role == .presenter {
        if peer { presenterEvent?(nil) }
        if wantInvite {
          wantInvite = false
          newInvite()
        }
      } else {
        send("requestSync")
      }
    case "waiting":
      connectTimer.cancel()
      update {
        $0.check = value.check.string
        $0.status = "しょうにんを まっています"
      }
    case "pending":
      update {
        $0.request = value.request.string
        $0.check = value.check.string
        $0.open = true
      }
    case "pendingGone":
      update {
        $0.request = nil
        $0.check = nil
      }
    case "invite":
      showInvite(value)
    case "inviteMissing":
      update {
        $0.request = nil
        $0.check = nil
        $0.code = nil
        $0.qr = nil
        $0.status = "あたらしい コードを だしてね"
      }
    case "reset":
      snapshot = nil
      inFlightCommand = nil
      update {
        $0.online = false
        $0.paired = false
        $0.busy = false
        $0.screen = .home
        $0.question = ""
        $0.answer = ""
        $0.request = nil
        $0.check = nil
        $0.code = nil
        $0.qr = nil
        $0.status = ""
      }
    case "peerUp":
      if role == .presenter {
        // Paired: close the panel and go back to the screen it was opened from.
        update {
          $0.paired = true
          $0.open = false
          $0.request = nil
          $0.check = nil
          $0.code = nil
          $0.qr = nil
          $0.status = syncedText
        }
        presenterEvent?(nil)
      } else {
        update { $0.status = "どうきしています…" }
        send("requestSync")
      }
    case "peerDown":
      commandTimer.cancel()
      update {
        $0.online = false
        $0.status = role == .remote ? "こどもの がめんを まっています" : "リモコンを まっています"
      }
    case "pong":
      probeTimer.cancel()
      if role == .remote { send("requestSync") }
    default:
      guard authenticated else { return }
      switch (role, type) {
      case (.presenter, "command"):
        if let command = RemoteWire.command(value) { presenterEvent?(command) }
      case (.presenter, "requestSync"):
        if RemoteWire.isRequestSync(value) { presenterEvent?(nil) }
      case (.remote, "sync"):
        if let state = RemoteWire.snapshot(value) { sync(state) }
      case (.remote, "ack"):
        if let ack = RemoteWire.ack(value) { self.ack(ack) }
      default:
        break
      }
    }
  }

  private func showInvite(_ value: JSObject) {
    guard let session, let generation = value.generation.string, let key = value.key.string,
      let rawCode = value.code.string, Wire.isID(generation), Wire.isKey(key),
      let code = Wire.normalizeCode(rawCode),
      let link = JS.new("URL", JS.global.location.href)
    else { return }
    link["hash"] = ("/remote?invite=" + session.id + "." + generation + "." + key).jsValue
    let qr = JS.qrDataURL(link.href.string ?? "")
    update {
      $0.code = Wire.formatCode(code)
      $0.qr = qr
      $0.status = ""
    }
  }

  // MARK: - Presenter → Remote state

  func publish(_ state: Snapshot) {
    send("sync") { RemoteWire.fillSnapshot($0, state) }
  }

  func receipt(epoch: String, id: String, result: CommandResult) {
    send("ack") {
      $0["epoch"] = epoch.jsValue
      $0["id"] = id.jsValue
      $0["result"] = Int(result.rawValue).jsValue
    }
  }

  private func sync(_ state: Snapshot) {
    // Within one Presenter document (epoch) the version orders snapshots; decks change within it.
    if let previous = snapshot, previous.epoch == state.epoch, state.version < previous.version { return }
    if oldEpochs.contains(state.epoch) { return }
    if let previous = snapshot, previous.epoch != state.epoch {
      oldEpochs.append(previous.epoch)
      if oldEpochs.count > 32 { oldEpochs.removeFirst() }
    }
    snapshot = state
    let card = state.screen == .playing ? state.cards[state.index] : nil
    if let command = inFlightCommand, command.epoch != state.epoch { uncertain() }
    let now = Browser.now()
    update {
      $0.online = true
      $0.status = syncedText
      $0.screen = state.screen
      $0.settings = state.settings
      $0.index = state.index + 1
      $0.count = state.cards.count
      $0.elapsed = Double(state.elapsed)
      // The Remote counts on locally from here until the next snapshot.
      $0.startedAt = now - Double(state.elapsed)
      if let card {
        $0.question = "\(card.lhs) \(card.sign == 1 ? "+" : "−") \(card.rhs)"
        $0.answer = "\(card.answer)"
      } else {
        $0.question = ""
        $0.answer = ""
      }
    }
    if inFlightCommand != nil && !commandTimer.isActive { transmit() }
  }

  // MARK: - Remote → Presenter commands

  /// Asks the Presenter to do something; one command is in flight at a time.
  func command(_ action: RemoteAction, value: Int = 0) {
    guard inFlightCommand == nil, model.online, let snapshot else { return }
    inFlightCommand = Command(
      id: RemoteLink.identifier(), epoch: snapshot.epoch, baseVersion: snapshot.version, action: action,
      value: value)
    retries = 0
    commandStarted = Browser.now()
    update {
      $0.busy = true
      $0.notice = ""
    }
    transmit()
  }

  /// Sends the one in-flight command, resending with the same id until it is acknowledged.
  private func transmit() {
    commandTimer.cancel()
    guard let command = inFlightCommand, model.online else { return }
    let attempt = retries
    retries += 1
    if attempt >= 4 || Browser.now() - commandStarted >= 20_000 { return uncertain() }
    let sent = send("command") { RemoteWire.fillCommand($0, command) }
    if sent { commandTimer.start(900) }
  }

  private func ack(_ ack: RemoteWire.Ack) {
    guard let command = inFlightCommand, command.id == ack.id, command.epoch == ack.epoch else { return }
    if ack.result >= 3 { return uncertain() }
    commandTimer.cancel()
    inFlightCommand = nil
    update { $0.busy = false }
  }

  private func uncertain() {
    commandTimer.cancel()
    inFlightCommand = nil
    update {
      $0.busy = false
      $0.notice = "まえの そうさは かくにんできませんでした"
    }
    send("requestSync")
  }

  // MARK: - Teardown

  func dispose() {
    if disposed { return }
    if role == .presenter {
      send("end")
      storePresenter(nil)
    }
    disposed = true
    let current = socket
    detachSocket()
    if let current { JS.call(current, "close") }
    abortBegin()
    inFlight = nil
    for timer in [retryTimer, probeTimer, commandTimer, connectTimer, beginTimer] { timer.release() }
    for listener in listeners { listener.remove() }
    listeners.removeAll()
    releaseRetired()
    if RemoteLink.active === self { RemoteLink.active = nil }
    presenterEvent = nil
    render = nil
  }
}
