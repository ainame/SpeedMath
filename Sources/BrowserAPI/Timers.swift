import JavaScriptKit

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
