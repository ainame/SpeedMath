import ProtocolModels

private let issueText = "つなげませんでした。コードを たしかめて、もういちど。"
private let disconnectedText = "せつぞくが きれました"
private let syncedText = "つながりました"
private let connectingText = "つないでいます…"

/// One side of a pairing: the Presenter (child's screen, role 1) or the Remote (role 2).
/// It owns the connection, reconnects with backoff, and keeps the Remote's view of the
/// Presenter's state ordered. The Presenter stays the source of truth for play.
///
/// This type is the protocol logic only. Everything outside (sockets, HTTP, timers, page events,
/// storage, the clock) comes from `Environment`: the browser in the app, a fake in tests.
public final class RemoteLink<Environment: RemoteEnvironment> {
  public let role: RemoteRole
  private let environment: Environment
  private let inbox: InviteInbox
  private var render: ((RemoteModel) -> Void)?
  private var presenterEvent: ((Command?) -> Void)?
  public private(set) var model = RemoteModel()

  private var session: RemoteSession?
  private var socket: Environment.Socket?
  private var authenticated = false
  private var attempts = 0
  private var lookup: Environment.Request?
  private var wantInvite = false
  private var snapshot: Snapshot?
  private var oldEpochs: [String] = []
  private var inFlightCommand: Command?
  private var retries = 0
  private var commandStarted: Double = 0
  private var disposed = false

  private let retryTimer: Environment.Timer
  private let probeTimer: Environment.Timer
  private let commandTimer: Environment.Timer
  private let connectTimer: Environment.Timer
  private let lookupTimer: Environment.Timer
  private var subscriptions: [Environment.Subscription] = []

  public init(
    role: RemoteRole, environment: Environment, inbox: InviteInbox,
    render: @escaping (RemoteModel) -> Void, presenter: @escaping (Command?) -> Void
  ) {
    self.role = role
    self.environment = environment
    self.inbox = inbox
    self.render = render
    self.presenterEvent = presenter
    retryTimer = environment.makeTimer()
    probeTimer = environment.makeTimer()
    commandTimer = environment.makeTimer()
    connectTimer = environment.makeTimer()
    lookupTimer = environment.makeTimer()
    subscriptions = [
      environment.observe(.visibilityChange) { [self] in visible() },
      environment.observe(.online) { [self] in visible() },
      environment.observe(.offline) { [self] in offline() },
    ]
    if role == .presenter, let restored = inbox.restoredPresenter {
      inbox.restoredPresenter = nil
      session = restored
      storePresenter(session)
      update {
        $0.started = true
        $0.status = connectingText
      }
      connect()
    }
    if role == .remote {
      inbox.onInvite = { [self] in joinInvite() }
      joinInvite()
    }
  }

  private func storePresenter(_ session: RemoteSession?) {
    environment.storePresenter(session?.storedValue)
  }

  // MARK: - Model

  private func update(_ change: (inout RemoteModel) -> Void) {
    guard !disposed else { return }
    change(&model)
    render?(model)
  }

  // MARK: - Page events

  private func visible() {
    if environment.isHidden || session == nil { return }
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
  public func begin(_ input: String = "") {
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
    let request = environment.post(code.map { .lookup(code: $0) } ?? .create) { [self] result in
      lookupTimer.cancel()
      lookup = nil
      began(result, code: code)
    }
    lookup = request
    lookupTimer.start(8000) { request.abort() }
  }

  private func began(_ result: Result<ControlResponse, ControlFailure>, code: String?) {
    // A scanned invite may have taken over while the request was running.
    if disposed || session != nil { return }
    let found: RemoteSession? =
      switch result {
      case .success(.created(let id, let key)) where code == nil: RemoteSession(id: id, key: key)
      case .success(.found(let id, let generation)) where code != nil:
        RemoteSession(id: id, generation: generation, code: code)
      default: nil
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
  public func show() {
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

  public func newInvite() {
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
  public func revoke() { send(.revoke) }

  public func decide(_ approved: Bool, request: String) {
    guard request == model.request else { return }
    send(approved ? .approve(request: request) : .reject(request: request))
  }

  /// Remote: join with a scanned invite. It replaces a half-finished code join, but never an
  /// approved pairing.
  public func joinInvite() {
    guard !disposed, role == .remote, let invite = inbox.pendingInvite else { return }
    inbox.pendingInvite = nil
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
    guard environment.isOnline, authenticated, let socket, socket.isOpen else { return false }
    socket.send(message)
    return true
  }

  private func connect() {
    guard !disposed, let session, socket == nil, environment.isOnline,
      let socket = environment.openSocket(sessionID: session.id)
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
      socket.send(first)
    }
    socket.onMessage = { [self] message in receive(message) }
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
    if environment.isOnline && attempts < 6 {
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

  public func retry() {
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
    let qr = environment.inviteQRCode(session.id + "." + generation + "." + key)
    update {
      $0.code = Wire.formatCode(code)
      $0.qr = qr
      $0.status = ""
    }
  }

  // MARK: - Presenter → Remote state

  public func publish(_ state: Snapshot) { send(.sync(state)) }

  public func receipt(epoch: String, id: String, result: CommandResult) {
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
    let now = environment.now
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
  public func command(_ action: RemoteAction, value: Int = 0) {
    guard inFlightCommand == nil, model.online, let snapshot else { return }
    inFlightCommand = Command(
      id: environment.randomID(), epoch: snapshot.epoch, baseVersion: snapshot.version, action: action,
      value: value)
    retries = 0
    commandStarted = environment.now
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
    if attempt >= 4 || environment.now - commandStarted >= 20_000 { return uncertain() }
    if send(.command(command)) { commandTimer.start(900) { [self] in transmit() } }
  }

  private func ack(_ ack: Ack) {
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

  public func dispose() {
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
    if role == .remote { inbox.onInvite = nil }
    presenterEvent = nil
    render = nil
  }
}
