import ProtocolModels

/// Everything `RemoteLink` needs from the outside world. The browser implementation lives in
/// `RemoteProtocol` (`BrowserRemoteEnvironment`); tests use a fake with a manual clock. These are
/// used as generic parameters (not existentials) so Embedded Swift specializes them.
public protocol RemoteEnvironment: AnyObject {
  associatedtype Socket: RemoteSocket
  associatedtype Timer: RemoteTimer
  associatedtype Request: RemoteRequest
  associatedtype Subscription: RemoteSubscription

  /// A monotonic clock in milliseconds.
  var now: Double { get }
  var isOnline: Bool { get }
  var isHidden: Bool { get }

  func makeTimer() -> Timer
  /// Opens the WebSocket for a session; nil when it cannot be created.
  func openSocket(sessionID: String) -> Socket?
  func post(_ request: ControlRequest, completion: @escaping (Result<ControlResponse, ControlFailure>) -> Void)
    -> Request
  func observe(_ event: RemoteEvent, _ handler: @escaping () -> Void) -> Subscription

  /// Keeps the Presenter's `<id>.<key>` for this tab, so a reload resumes the pairing.
  func storePresenter(_ value: String?)
  /// A random 32-hex identifier.
  func randomID() -> String
  /// The QR code image for an invite link to `<id>.<generation>.<key>`.
  func inviteQRCode(_ invite: String) -> String?
}

public enum RemoteEvent {
  case visibilityChange
  case online
  case offline
}

public protocol RemoteSocket: AnyObject {
  var onOpen: (() -> Void)? { get set }
  var onMessage: ((ServerMessage) -> Void)? { get set }
  var onClose: ((_ code: Int, _ reason: String) -> Void)? { get set }
  var isOpen: Bool { get }
  func send(_ message: ClientMessage)
  func close()
  /// Stops delivering events; safe to call from inside a handler.
  func detach()
}

public protocol RemoteTimer: AnyObject {
  var isActive: Bool { get }
  func start(_ milliseconds: Double, _ action: @escaping () -> Void)
  func cancel()
}

public protocol RemoteRequest: AnyObject {
  func abort()
}

public protocol RemoteSubscription: AnyObject {
  func cancel()
}

/// State that arrives before (or outside) any `RemoteLink`: a QR invite from the URL, and a
/// Presenter credential restored after a reload. The app creates one inbox at start-up.
public final class InviteInbox {
  public var pendingInvite: RemoteSession?
  public var restoredPresenter: RemoteSession?
  /// Set by the mounted Remote screen; called when an invite arrives while it is open.
  var onInvite: (() -> Void)?

  public init(pendingInvite: RemoteSession? = nil, restoredPresenter: RemoteSession? = nil) {
    self.pendingInvite = pendingInvite
    self.restoredPresenter = restoredPresenter
  }

  /// A QR invite delivered to an already open page (iOS Safari reuses tabs).
  public func deliver(_ invite: RemoteSession) {
    pendingInvite = invite
    onInvite?()
  }
}
