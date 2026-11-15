import ProtocolModels
import RemoteProtocol

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
private let presenterStore = "speedmath.presenter.v2"

/// One side of a pairing: the Presenter (child's screen, role 1) or the Remote (role 2).
/// It owns the connection, reconnects with backoff, and keeps the Remote's view of the
/// Presenter's state ordered. The Presenter stays the source of truth for play.
///
/// This type is the protocol logic only: the browser is reached through `BrowserSocket`,
/// `BrowserHTTP`, `BrowserPage` and `Timeout`, and messages through `ServerMessage` /
/// `ClientMessage` (all in `RemoteProtocol`).
final class RemoteLink {
  let role: RemoteRole
  private var render: ((RemoteModel) -> Void)?
  private var presenterEvent: ((Command?) -> Void)?
  private(set) var model = RemoteModel()

  private var session: RemoteSession?
  private var socket: BrowserSocket?
  private var authenticated = false
  private var attempts = 0
  private var lookup: BrowserHTTP.Request?
  private var wantInvite = false
  private var snapshot: Snapshot?
  private var oldEpochs: [String] = []
  private var inFlightCommand: Command?
  private var retries = 0
  private var commandStarted: Double = 0
  private var disposed = false

  private let retryTimer = Timeout()
  private let probeTimer = Timeout()
  private let commandTimer = Timeout()
  private let connectTimer = Timeout()
  private let lookupTimer = Timeout()
  private var subscriptions: [BrowserPage.Subscription] = []

  init(role: RemoteRole, render: @escaping (RemoteModel) -> Void, presenter: @escaping (Command?) -> Void) {
    self.role = role
    self.render = render
    self.presenterEvent = presenter
    subscriptions = [
      BrowserPage.observe(.visibilityChange) { [self] in visible() },
      BrowserPage.observe(.online) { [self] in visible() },
      BrowserPage.observe(.offline) { [self] in offline() },
    ]
    if role == .presenter, let restored = RemoteLink.restoredSession {
      RemoteLink.restoredSession = nil
      session = restored
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

  private static var pendingInvite: RemoteSession?
  private static var restoredSession: RemoteSession?
  private static var active: RemoteLink?
  private static var hashSubscription: BrowserPage.Subscription?

  /// Runs once before the app renders: takes a QR invite out of the URL, restores the
  /// Presenter's session after a reload, and watches for invites that iOS Safari delivers to an
  /// already open tab as a same-document hash change.
  static func startup() {
    pendingInvite = takeInvite()
    restoredSession = readStoredPresenter()
    hashSubscription = BrowserPage.observe(.hashChange) {
      guard let invite = takeInvite() else { return }
      pendingInvite = invite
      // A Remote screen that is already mounted joins now; otherwise the next one picks it up.
      active?.joinInvite()
    }
  }

  /// Reads `#/remote?invite=<id>.<generation>.<key>` and removes it from history.
  private static func takeInvite() -> RemoteSession? {
    guard let value = BrowserPage.hashQuery(route: "#/remote", name: "invite") else { return nil }
    BrowserPage.replaceHash("#/remote")
    let parts = split(value, ".")
    guard parts.count == 3, Wire.isID(parts[0]), Wire.isID(parts[1]), Wire.isKey(parts[2]) else { return nil }
    return RemoteSession(id: parts[0], key: parts[2], generation: parts[1])
  }

  /// The Presenter's `id.key`, kept in this tab's storage so a reload resumes the pairing.
  private static func readStoredPresenter() -> RemoteSession? {
    let stored = BrowserPage.sessionValue(presenterStore)
    BrowserPage.setSessionValue(presenterStore, nil)
    guard let stored, BrowserPage.wasReloaded else { return nil }
    let parts = split(stored, ".")
    guard parts.count == 2, Wire.isID(parts[0]), Wire.isKey(parts[1]) else { return nil }
    return RemoteSession(id: parts[0], key: parts[1])
  }

  private func storePresenter(_ session: RemoteSession?) {
    guard let session, let key = session.key, !session.isJoining else {
      return BrowserPage.setSessionValue(presenterStore, nil)
    }
    BrowserPage.setSessionValue(presenterStore, session.id + "." + key)
  }

  private static func split(_ text: String, _ separator: String) -> [String] {
    let mark = separator.utf8.first ?? 0
    return text.utf8.split(separator: mark, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
  }

  static func identifier() -> String { BrowserPage.randomHex(bytes: 16) }

  // MARK: - Model

  private func update(_ change: (inout RemoteModel) -> Void) {
    guard !disposed else { return }
    change(&model)
    render?(model)
  }

  // MARK: - Page events

  private func visible() {
    if BrowserPage.isHidden || session == nil { return }
    if socket?.isOpen == true && authenticated { probe() } else if lookup == nil { retry() }
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
    current?.close()
  }

  // MARK: - Pairing

  /// Presenter: create a session and show an invite. Remote: look up a typed code and join.
  func begin(_ input: String = "") {
    if disposed || session != nil || lookup != nil { return }
    var code: String?
    if role == .remote {
      code = Wire.normalizeCode(input)
      guard code != nil else { return update { $0.status = issueText } }
    }
    update {
      $0.status = connectingText
      $0.joining = true
    }
    let body = code.map { RemoteWire.lookupRequest(code: $0) } ?? RemoteWire.createRequest()
    let request = BrowserHTTP.post(role == .presenter ? "session" : "lookup", body: body) { [self] result in
      lookupTimer.cancel()
      lookup = nil
      began(result, code: code)
    }
    lookup = request
    lookupTimer.start(8000) { request.abort() }
  }

  private func began(_ result: Result<String, BrowserHTTP.Failure>, code: String?) {
    // A scanned invite may have taken over while the request was running.
    if disposed || session != nil { return }
    let found: RemoteSession? =
      switch result {
      case .success(let text):
        if let code {
          RemoteWire.foundSession(text).map { RemoteSession(id: $0.id, generation: $0.generation, code: code) }
        } else {
          RemoteWire.createdSession(text).map { RemoteSession(id: $0.id, key: $0.key) }
        }
      case .failure: nil
      }
    guard let found else {
      var slow = false
      if case .failure(.slow) = result { slow = true }
      return update {
        $0.joining = false
        $0.status = slow ? "すこし まってから ためしてね" : issueText
      }
    }
    session = found
    if role == .presenter {
      storePresenter(found)
      wantInvite = true
      update {
        $0.started = true
        $0.open = true
      }
    }
    connect()
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
    if send(.invite) {
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
  func revoke() { send(.revoke) }

  func decide(_ approved: Bool, request: String) {
    guard request == model.request else { return }
    send(approved ? .approve(request: request) : .reject(request: request))
  }

  /// Remote: join with a scanned invite. It replaces a half-finished code join, but never an
  /// approved pairing.
  func joinInvite() {
    guard !disposed, role == .remote, let invite = RemoteLink.pendingInvite else { return }
    RemoteLink.pendingInvite = nil
    if session?.isAuthenticatedRole == true { return }
    lookup?.abort()
    if let current = socket {
      resetConnection()
      current.close()
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
  private func send(_ message: ClientMessage) -> Bool {
    guard BrowserPage.isOnline, authenticated, let socket, socket.isOpen else { return false }
    socket.send(RemoteWire.encode(message))
    return true
  }

  private func connect() {
    guard !disposed, let session, socket == nil, BrowserPage.isOnline,
      let socket = BrowserSocket(path: "/api/socket/" + session.id)
    else { return }
    self.socket = socket
    connectTimer.start(8000) { socket.close() }
    socket.onOpen = { [self] in
      let first: ClientMessage
      if let generation = session.generation {
        first = session.code.map { .joinCode(generation: generation, code: $0) }
          ?? .joinQR(generation: generation, key: session.key ?? "")
      } else {
        first = .auth(role: role.rawValue, key: session.key ?? "")
      }
      socket.send(RemoteWire.encode(first))
    }
    socket.onMessage = { [self] text in
      if let message = RemoteWire.decode(text) { receive(message) }
    }
    socket.onClose = { [self] code, reason in
      if !disposed { closed(code: code, reason: reason) }
    }
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
      return update {
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
    }
    update {
      $0.retry = true
      $0.status = disconnectedText
    }
    if BrowserPage.isOnline && attempts < 6 {
      var delay = 250.0
      for _ in 0..<attempts { delay *= 2 }
      attempts += 1
      retryTimer.start(min(8000, delay)) { [self] in connect() }
    }
  }

  /// Forgets the current socket; a late event from it can no longer arrive.
  private func resetConnection() {
    socket?.detach()
    socket = nil
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
    if send(.ping) { probeTimer.start(3500) { [self] in socket?.close() } }
  }

  // MARK: - Messages

  private func receive(_ message: ServerMessage) {
    switch message {
    case .connected(let paired, let peer):
      authenticated(paired: role == .remote || paired, peer: peer)
    case .approved(let key):
      guard role == .remote, let current = session else { return }
      session = RemoteSession(id: current.id, key: key)
      snapshot = nil
      oldEpochs.removeAll()
      authenticated(paired: true, peer: false)
    case .waiting(let check):
      connectTimer.cancel()
      update {
        $0.check = check
        $0.status = "しょうにんを まっています"
      }
    case .pending(let request, let check):
      update {
        $0.request = request
        $0.check = check
        $0.open = true
      }
    case .pendingGone:
      update {
        $0.request = nil
        $0.check = nil
      }
    case .invite(let generation, let code, let key):
      showInvite(generation: generation, code: code, key: key)
    case .inviteMissing:
      update {
        $0.request = nil
        $0.check = nil
        $0.code = nil
        $0.qr = nil
        $0.status = "あたらしい コードを だしてね"
      }
    case .reset:
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
    case .peerUp:
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
        send(.requestSync)
      }
    case .peerDown:
      commandTimer.cancel()
      update {
        $0.online = false
        $0.status = role == .remote ? "こどもの がめんを まっています" : "リモコンを まっています"
      }
    case .pong:
      probeTimer.cancel()
      if role == .remote { send(.requestSync) }
    case .command(let command):
      if authenticated && role == .presenter { presenterEvent?(command) }
    case .requestSync:
      if authenticated && role == .presenter { presenterEvent?(nil) }
    case .sync(let state):
      if authenticated && role == .remote { sync(state) }
    case .ack(let ack):
      if authenticated && role == .remote { self.ack(ack) }
    }
  }

  private func authenticated(paired: Bool, peer: Bool) {
    authenticated = true
    attempts = 0
    connectTimer.cancel()
    update {
      $0.joining = false
      $0.retry = false
      $0.check = nil
      $0.paired = paired
      $0.status = role == .presenter ? (peer ? syncedText : "") : "どうきしています…"
    }
    if role == .presenter {
      if peer { presenterEvent?(nil) }
      if wantInvite {
        wantInvite = false
        newInvite()
      }
    } else {
      send(.requestSync)
    }
  }

  private func showInvite(generation: String, code: String, key: String) {
    guard let session else { return }
    let link = BrowserPage.url(withHash: "/remote?invite=" + session.id + "." + generation + "." + key)
    let qr = BrowserPage.qrCode(link)
    update {
      $0.code = Wire.formatCode(code)
      $0.qr = qr
      $0.status = ""
    }
  }

  // MARK: - Presenter → Remote state

  func publish(_ state: Snapshot) { send(.sync(state)) }

  func receipt(epoch: String, id: String, result: CommandResult) {
    send(.ack(epoch: epoch, id: id, result: result))
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
    if send(.command(command)) { commandTimer.start(900) { [self] in transmit() } }
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
    send(.requestSync)
  }

  // MARK: - Teardown

  func dispose() {
    if disposed { return }
    if role == .presenter {
      send(.end)
      storePresenter(nil)
    }
    disposed = true
    let current = socket
    resetConnection()
    current?.close()
    lookup?.abort()
    lookup = nil
    for timer in [retryTimer, probeTimer, commandTimer, connectTimer, lookupTimer] { timer.cancel() }
    for subscription in subscriptions { subscription.cancel() }
    subscriptions.removeAll()
    if RemoteLink.active === self { RemoteLink.active = nil }
    presenterEvent = nil
    render = nil
  }
}
