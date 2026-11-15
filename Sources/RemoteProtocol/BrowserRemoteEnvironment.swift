import BrowserAPI
import ProtocolModels
import RemoteClient

/// `RemoteLink`'s environment in the browser: `BrowserAPI` for sockets, HTTP, timers, page events
/// and storage, and `RemoteWire` for turning messages into JSON and back.
public final class BrowserRemoteEnvironment: RemoteEnvironment {
  public static let shared = BrowserRemoteEnvironment()
  /// Start-up state from the URL and the previous document (see `start()`).
  public static let inbox = InviteInbox()

  private static let presenterKey = "speedmath.presenter.v2"
  private static var hashSubscription: BrowserPage.Subscription?

  /// Runs once before the app renders: takes a QR invite out of the URL, restores the Presenter's
  /// session after a reload, and watches for invites that iOS Safari delivers to an already open
  /// tab as a same-document hash change.
  public static func start() {
    inbox.pendingInvite = takeInvite()
    let stored = BrowserPage.sessionValue(presenterKey)
    BrowserPage.setSessionValue(presenterKey, nil)
    if let stored, BrowserPage.wasReloaded { inbox.restoredPresenter = RemoteSession.stored(stored) }
    hashSubscription = BrowserPage.observe(.hashChange) {
      if let invite = takeInvite() { inbox.deliver(invite) }
    }
  }

  /// Reads `#/remote?invite=<id>.<generation>.<key>` and removes it from history.
  private static func takeInvite() -> RemoteSession? {
    guard let value = BrowserPage.hashQuery(route: "#/remote", name: "invite") else { return nil }
    BrowserPage.replaceHash("#/remote")
    return RemoteSession.invite(value)
  }

  public var now: Double { BrowserPage.now }
  public var isOnline: Bool { BrowserPage.isOnline }
  public var isHidden: Bool { BrowserPage.isHidden }

  public func makeTimer() -> Timeout { Timeout() }

  public func openSocket(sessionID: String) -> WireSocket? {
    BrowserSocket(path: "/api/socket/" + sessionID).map(WireSocket.init)
  }

  public func post(
    _ request: ControlRequest, completion: @escaping (Result<ControlResponse, ControlFailure>) -> Void
  ) -> BrowserHTTP.Request {
    let path = if case .lookup = request { "lookup" } else { "session" }
    return BrowserHTTP.post(path, body: RemoteWire.encode(request)) { result in
      switch result {
      case .success(let text):
        if let response = RemoteWire.decode(text, for: request) {
          completion(.success(response))
        } else {
          completion(.failure(.unavailable))
        }
      case .failure(.slow): completion(.failure(.slow))
      case .failure: completion(.failure(.unavailable))
      }
    }
  }

  public func observe(_ event: RemoteEvent, _ handler: @escaping () -> Void) -> BrowserPage.Subscription {
    let pageEvent: BrowserPage.Event =
      switch event {
      case .visibilityChange: .visibilityChange
      case .online: .online
      case .offline: .offline
      }
    return BrowserPage.observe(pageEvent, handler)
  }

  public func storePresenter(_ value: String?) { BrowserPage.setSessionValue(Self.presenterKey, value) }

  public func randomID() -> String { BrowserPage.randomHex(bytes: 16) }

  public func inviteQRCode(_ invite: String) -> String? {
    BrowserPage.qrCode(BrowserPage.url(withHash: "/remote?invite=" + invite))
  }
}

/// A `BrowserSocket` that speaks `ServerMessage` / `ClientMessage` through `RemoteWire`.
public final class WireSocket: RemoteSocket {
  private let socket: BrowserSocket

  init(_ socket: BrowserSocket) { self.socket = socket }

  public var onOpen: (() -> Void)? {
    get { socket.onOpen }
    set { socket.onOpen = newValue }
  }

  public var onMessage: ((ServerMessage) -> Void)? {
    didSet {
      let handler = onMessage
      socket.onMessage = handler.map { handler in
        { text in if let message = RemoteWire.decode(text) { handler(message) } }
      }
    }
  }

  public var onClose: ((_ code: Int, _ reason: String) -> Void)? {
    get { socket.onClose }
    set { socket.onClose = newValue }
  }

  public var isOpen: Bool { socket.isOpen }
  public func send(_ message: ClientMessage) { socket.send(RemoteWire.encode(message)) }
  public func close() { socket.close() }

  public func detach() {
    onMessage = nil
    socket.detach()
  }
}

extension Timeout: RemoteTimer {}
extension BrowserHTTP.Request: RemoteRequest {}
extension BrowserPage.Subscription: RemoteSubscription {}
