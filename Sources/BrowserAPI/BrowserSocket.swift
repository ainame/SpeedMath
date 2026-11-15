import JavaScriptKit

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
