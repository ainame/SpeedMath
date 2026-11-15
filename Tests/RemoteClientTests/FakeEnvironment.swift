import ProtocolModels
@testable import RemoteClient

/// A deterministic environment: a manual clock, timers that fire on `advance`, sockets and HTTP
/// requests the test drives by hand.
final class FakeEnvironment: RemoteEnvironment {
  var now: Double = 1_000
  var isOnline = true
  var isHidden = false
  var stored: String?
  var opened: [FakeSocket] = []
  var requests: [(request: ControlRequest, completion: (Result<ControlResponse, ControlFailure>) -> Void, handle: FakeRequest)] = []
  private var timers: [FakeTimer] = []
  private var handlers: [(RemoteEvent, () -> Void, FakeSubscription)] = []
  private var nextID = 0

  func makeTimer() -> FakeTimer {
    let timer = FakeTimer(environment: self)
    timers.append(timer)
    return timer
  }

  func openSocket(sessionID: String) -> FakeSocket? {
    guard isOnline else { return nil }
    let socket = FakeSocket(sessionID: sessionID)
    opened.append(socket)
    return socket
  }

  func post(_ request: ControlRequest, completion: @escaping (Result<ControlResponse, ControlFailure>) -> Void)
    -> FakeRequest
  {
    let handle = FakeRequest()
    requests.append((request, completion, handle))
    return handle
  }

  func observe(_ event: RemoteEvent, _ handler: @escaping () -> Void) -> FakeSubscription {
    let subscription = FakeSubscription()
    handlers.append((event, handler, subscription))
    return subscription
  }

  func storePresenter(_ value: String?) { stored = value }

  func randomID() -> String {
    nextID += 1
    let digits = String(nextID)
    return String(repeating: "0", count: 32 - digits.utf8.count) + digits
  }

  func inviteQRCode(_ invite: String) -> String? { "qr:" + invite }

  // MARK: Driving

  var socket: FakeSocket { opened.last! }

  /// Moves the clock on and fires every timer that comes due, in order.
  func advance(_ milliseconds: Double) {
    let end = now + milliseconds
    while let next = timers.filter({ $0.due != nil && $0.due! <= end }).min(by: { $0.due! < $1.due! }) {
      now = next.due!
      next.fire()
    }
    now = end
  }

  func send(_ event: RemoteEvent) {
    for (kind, handler, subscription) in handlers where kind == event && !subscription.cancelled { handler() }
  }

  /// Answers the oldest pending HTTP request.
  func respond(_ result: Result<ControlResponse, ControlFailure>) {
    let pending = requests.removeFirst()
    pending.completion(result)
  }
}

final class FakeTimer: RemoteTimer {
  private unowned let environment: FakeEnvironment
  private var action: (() -> Void)?
  var due: Double?

  init(environment: FakeEnvironment) { self.environment = environment }

  var isActive: Bool { due != nil }

  func start(_ milliseconds: Double, _ action: @escaping () -> Void) {
    self.action = action
    due = environment.now + milliseconds
  }

  func cancel() {
    due = nil
    action = nil
  }

  func fire() {
    let action = self.action
    cancel()
    action?()
  }
}

final class FakeSocket: RemoteSocket {
  let sessionID: String
  var onOpen: (() -> Void)?
  var onMessage: ((ServerMessage) -> Void)?
  var onClose: ((_ code: Int, _ reason: String) -> Void)?
  var isOpen = false
  var sent: [ClientMessage] = []
  var closed = false
  var detached = false

  init(sessionID: String) { self.sessionID = sessionID }

  func send(_ message: ClientMessage) { if isOpen { sent.append(message) } }
  func close() { closed = true }
  func detach() {
    detached = true
    onOpen = nil
    onMessage = nil
    onClose = nil
  }

  // MARK: Driving

  func open() {
    isOpen = true
    onOpen?()
  }

  func receive(_ message: ServerMessage) { onMessage?(message) }

  /// The server (or network) closed the socket.
  func drop(code: Int = 1006, reason: String = "") {
    isOpen = false
    onClose?(code, reason)
  }

  var commands: [Command] {
    sent.compactMap { if case .command(let command) = $0 { command } else { nil } }
  }

  func count(_ message: ClientMessage) -> Int { sent.filter { $0 == message }.count }
}

final class FakeRequest: RemoteRequest {
  var aborted = false
  func abort() { aborted = true }
}

final class FakeSubscription: RemoteSubscription {
  var cancelled = false
  func cancel() { cancelled = true }
}

// MARK: Fixtures

let sessionID = String(repeating: "a", count: 32)
let presenterKey = String(repeating: "b", count: 64)
let remoteKey = String(repeating: "c", count: 64)
let generation = String(repeating: "d", count: 32)
let epoch = String(repeating: "e", count: 32)
var homeSettings: WireSettings { WireSettings(deck: 0, includeZero: false, count: 45, showTimer: true) }

func snapshot(version: Int, screen: Screen = .playing, index: Int = 0, epoch: String = epoch) -> Snapshot {
  let cards = screen == .playing || screen == .finished
    ? [WireCard(lhs: 1, sign: 1, rhs: 2)!, WireCard(lhs: 3, sign: -1, rhs: 1)!] : []
  return Snapshot(
    epoch: epoch, deckVersion: epoch, version: version, screen: screen,
    index: screen == .finished ? 1 : index, elapsed: 0, cards: cards, settings: homeSettings)!
}

/// A Remote that joined with a QR invite and was approved, with the first snapshot applied.
func pairedRemote(_ environment: FakeEnvironment, inbox: InviteInbox = InviteInbox(), version: Int = 1)
  -> RemoteLink<FakeEnvironment>
{
  inbox.pendingInvite = RemoteSession(id: sessionID, key: presenterKey, generation: generation)
  let link = RemoteLink(role: .remote, environment: environment, inbox: inbox, render: { _ in }, presenter: { _ in })
  environment.socket.open()
  environment.socket.receive(.approved(key: remoteKey))
  environment.socket.receive(.sync(snapshot(version: version)))
  return link
}
