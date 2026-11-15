import JavaScriptKit
import ProtocolModels

// The small browser API the remote control uses (`RemoteLink`, `RemoteHub`). It is built on the
// typed BridgeJS bindings in `WebBindings.swift`; callers see only Swift values and closures.
// Failures from JavaScript (blocked storage, a closed socket, a failed request) come back as nil
// or `.failure`, never as a trap.

/// A restartable one-shot timer on JavaScriptKit's `JSTimer` (`setTimeout`).
public final class Timeout {
  private var timer: JSTimer?
  private var action: (() -> Void)?

  public init() {}

  public var isActive: Bool { timer != nil }

  /// Runs `action` once after `milliseconds`, replacing any pending run.
  public func start(_ milliseconds: Double, _ action: @escaping () -> Void) {
    self.action = action
    timer = JSTimer(millisecondsDelay: milliseconds) { [self] in
      let action = self.action
      timer = nil
      action?()
    }
  }

  public func cancel() {
    timer = nil  // JSTimer clears the timeout when released.
    action = nil
  }
}

/// A repeating timer on JavaScriptKit's `JSTimer` (`setInterval`); stops when released or stopped.
public final class RepeatingTimer {
  private var timer: JSTimer?

  public init() {}

  public func start(every milliseconds: Double, _ action: @escaping () -> Void) {
    timer = JSTimer(millisecondsDelay: milliseconds, isRepeating: true, callback: action)
  }

  public func stop() { timer = nil }
}

/// One WebSocket to this site. After `detach()` it delivers no more events, so a late event from
/// a replaced socket can never reach the current connection.
public final class BrowserSocket {
  public var onOpen: (() -> Void)?
  public var onMessage: ((String) -> Void)?
  public var onClose: ((_ code: Int, _ reason: String) -> Void)?

  private let socket: WebSocket
  private var handlers: (open: JSTypedClosure<() -> Void>, message: JSTypedClosure<(MessageEvent) -> Void>,
    close: JSTypedClosure<(CloseEvent) -> Void>)?

  /// Opens `wss://<this origin><path>` (`ws://` on plain HTTP).
  public init?(path: String) {
    guard let origin = try? location.origin, let scheme = try? location.scheme,
      let url = try? URL(path, origin)
    else { return nil }
    try? url.setScheme(scheme == "https:" ? "wss:" : "ws:")
    guard let href = try? url.href, let socket = try? WebSocket(href) else { return nil }
    self.socket = socket
    let open = JSTypedClosure<() -> Void> { [self] in onOpen?() }
    let message = JSTypedClosure<(MessageEvent) -> Void> { [self] event in
      if let text = (try? event.data)?.string { onMessage?(text) }
    }
    let close = JSTypedClosure<(CloseEvent) -> Void> { [self] event in
      onClose?((try? event.code) ?? 0, (try? event.reason) ?? "")
    }
    try? socket.setOnOpen(open)
    try? socket.setOnMessage(message)
    try? socket.setOnClose(close)
    handlers = (open, message, close)
  }

  public var isOpen: Bool { (try? socket.readyState) == 1 }

  public func send(_ text: String) {
    if isOpen { try? socket.send(text) }
  }

  public func close() { try? socket.close() }

  /// Stops delivering events and releases the handlers. Safe to call from inside a handler: the
  /// handlers are unset at once and released on the next turn of the event loop.
  public func detach() {
    try? socket.setOnOpen(nil)
    try? socket.setOnMessage(nil)
    try? socket.setOnClose(nil)
    onOpen = nil
    onMessage = nil
    onClose = nil
    guard let handlers else { return }
    self.handlers = nil
    BrowserSocket.releaseLater(handlers)
  }

  private static var retired: [(JSTypedClosure<() -> Void>, JSTypedClosure<(MessageEvent) -> Void>,
    JSTypedClosure<(CloseEvent) -> Void>)] = []
  private static let releaser = Timeout()

  private static func releaseLater(
    _ handlers: (JSTypedClosure<() -> Void>, JSTypedClosure<(MessageEvent) -> Void>, JSTypedClosure<(CloseEvent) -> Void>)
  ) {
    retired.append(handlers)
    releaser.start(0) {
      for (open, message, close) in retired {
        open.release()
        message.release()
        close.release()
      }
      retired.removeAll()
    }
  }
}

/// `fetch` POSTs of small JSON control messages to this site's API.
public enum BrowserHTTP {
  public enum Failure: Error {
    /// HTTP 429 from a rate limiter.
    case slow
    /// Any other failure: network, abort, non-2xx status, unreadable body.
    case unavailable
  }

  /// A request that can be aborted (which completes it with `.unavailable`).
  public final class Request {
    fileprivate let controller: AbortController?

    fileprivate init(controller: AbortController?) { self.controller = controller }

    public func abort() { try? controller?.abort() }
  }

  /// POSTs `body` as JSON to `/api/<path>` and returns the response text.
  @discardableResult
  public static func post(
    _ path: String, body: String, completion: @escaping (Result<String, Failure>) -> Void
  ) -> Request {
    let controller = try? AbortController()
    let request = Request(controller: controller)
    let options = FetchOptions(
      method: "POST", headers: ["Content-Type": "application/json"], body: body, signal: try? controller?.signal)
    guard let promise = try? fetch("/api/" + path, options) else {
      completion(.failure(.unavailable))
      return request
    }
    JS.then(promise.jsValue, { value in
      guard let object = value.object else { return completion(.failure(.unavailable)) }
      let response = Response(unsafelyWrapping: object)
      guard (try? response.ok) == true, let text = try? response.text() else {
        return completion(.failure((try? response.status) == 429 ? .slow : .unavailable))
      }
      JS.then(text.jsValue, { value in
        if let text = value.string { completion(.success(text)) } else { completion(.failure(.unavailable)) }
      }, { completion(.failure(.unavailable)) })
    }, { completion(.failure(.unavailable)) })
    return request
  }
}

/// The page itself: location and history, connectivity, visibility, tab storage and page events.
public enum BrowserPage {
  public enum Event: String {
    case visibilityChange = "visibilitychange"
    case online
    case offline
    case hashChange = "hashchange"
    case resize
  }

  /// An event subscription; `cancel()` removes the listener and releases it.
  public final class Subscription {
    private var stop: (() -> Void)?

    fileprivate init(stop: @escaping () -> Void) { self.stop = stop }

    public func cancel() {
      stop?()
      stop = nil
    }
  }

  public static func observe(_ event: Event, _ handler: @escaping () -> Void) -> Subscription {
    let listener = JSTypedClosure<() -> Void>(handler)
    let onDocument = event == .visibilityChange
    if onDocument { try? document.addEventListener(event.rawValue, listener) } else {
      try? addEventListener(event.rawValue, listener)
    }
    return Subscription {
      if onDocument { try? document.removeEventListener(event.rawValue, listener) } else {
        try? removeEventListener(event.rawValue, listener)
      }
      listener.release()
    }
  }

  /// A key pressed on the page (`keydown` on the document).
  public struct KeyPress {
    public let key: String
    /// Auto-repeat from a held key.
    public let isRepeat: Bool
    /// Ctrl, Cmd or Alt is held (a browser or system shortcut).
    public let hasModifier: Bool
    fileprivate let event: KeyboardEvent

    /// Stops the browser's own handling (e.g. Space scrolling the page).
    public func preventDefault() { try? event.preventDefault() }
  }

  public static func observeKeyDown(_ handler: @escaping (KeyPress) -> Void) -> Subscription {
    let listener = JSTypedClosure<(KeyboardEvent) -> Void> { event in
      handler(
        KeyPress(
          key: (try? event.key) ?? "", isRepeat: (try? event.isRepeat) ?? false,
          hasModifier: (try? event.ctrlKey) == true || (try? event.metaKey) == true || (try? event.altKey) == true,
          event: event))
    }
    try? document.addKeyListener("keydown", listener)
    return Subscription {
      try? document.removeKeyListener("keydown", listener)
      listener.release()
    }
  }

  /// Page-wide guards for the home-screen web app, installed once at start-up: snap back to the
  /// top whenever the viewport changes (iOS can leave the page scrolled after a rotation), and
  /// block pinch and double-tap zoom, which iOS may still allow despite the viewport settings.
  public static func installAppGuards() {
    // Kept for the page's lifetime, so these listeners are never released.
    try? addEventListener("resize", JSTypedClosure<() -> Void> { try? scrollTo(0, 0) })
    let cancel = JSTypedClosure<(DOMEvent) -> Void> { try? $0.preventDefault() }
    try? document.addCancelableListener("gesturestart", cancel, ListenerOptions(passive: false))
    try? document.addCancelableListener("dblclick", cancel, ListenerOptions(passive: false))
  }

  /// `performance.now()`: a high-resolution timestamp in milliseconds.
  public static var now: Double { (try? performance.now()) ?? 0 }

  /// The local calendar date and time.
  public static func localTime() -> LocalTime {
    let date = JSDate()
    return LocalTime(
      year: date.fullYear, month: date.month + 1, day: date.date, hours: date.hours, minutes: date.minutes)
  }

  public static var isOnline: Bool { (try? navigator.onLine) ?? true }
  public static var isHidden: Bool { (try? document.visibilityState) == "hidden" }
  public static var hash: String { (try? location.hash) ?? "" }

  /// A query value from a hash route such as `#/remote?invite=…`, decoded like `URLSearchParams`.
  public static func hashQuery(route: String, name: String) -> String? {
    let prefix = route + "?"
    let hash = self.hash
    guard hash.utf8.starts(with: prefix.utf8),
      let search = try? URLSearchParams(String(decoding: hash.utf8.dropFirst(prefix.utf8.count), as: UTF8.self))
    else { return nil }
    return (try? search.get(name)) ?? nil
  }

  /// Replaces the current history entry's hash without adding an entry or notifying the router.
  public static func replaceHash(_ hash: String) {
    guard let state = try? history.state, let pathname = try? location.pathname, let search = try? location.search
    else { return }
    try? history.replaceState(state, "", pathname + search + hash)
  }

  /// This page's URL with a different hash.
  public static func url(withHash hash: String) -> String {
    guard let href = try? location.href, let url = try? URL(href, href) else { return "" }
    try? url.setHash(hash)
    return (try? url.href) ?? ""
  }

  /// The tab was reloaded (not opened from another page or restored into a new tab).
  public static var wasReloaded: Bool {
    guard let entries = try? performance.getEntriesByType("navigation"), let first = entries.first,
      (try? first.type) == "reload"
    else { return false }
    return (try? opener) == .some(nil)
  }

  /// sessionStorage (this tab only); nil when missing or when storage is blocked.
  public static func sessionValue(_ key: String) -> String? {
    (try? sessionStorage.getItem(key)) ?? nil
  }

  public static func setSessionValue(_ key: String, _ value: String?) {
    if let value { try? sessionStorage.setItem(key, value) } else { try? sessionStorage.removeItem(key) }
  }

  /// localStorage (kept across visits); nil when missing or when storage is blocked.
  public static func localValue(_ key: String) -> String? {
    (try? localStorage.getItem(key)) ?? nil
  }

  public static func setLocalValue(_ key: String, _ value: String?) {
    if let value { try? localStorage.setItem(key, value) } else { try? localStorage.removeItem(key) }
  }

  /// Random bytes from `crypto.getRandomValues`.
  public static func randomBytes(_ count: Int) -> [UInt8] {
    let array = JSTypedArray<UInt8>(length: count)
    _ = try? crypto.getRandomValues(array)
    var out: [UInt8] = []
    for i in 0..<count { out.append(array[i]) }
    return out
  }

  /// Random lower-case hex from `crypto.getRandomValues`.
  public static func randomHex(bytes: Int) -> String { Wire.hex(randomBytes(bytes)) }

  /// A QR code image (data URL) for `text`, from the QR library injected by `web/main.js`.
  public static func qrCode(_ text: String) -> String? { try? qrCodeDataURL(text) }
}

/// A local calendar date and time; `month` is 1...12.
public struct LocalTime: Equatable {
  public let year: Int
  public let month: Int
  public let day: Int
  public let hours: Int
  public let minutes: Int
}
