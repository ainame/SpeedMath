// The remote control's messages as plain Swift values. `RemoteWire` (in `RemoteProtocol`) turns
// them into JSON and back; everything else, including the tests, works with these types only.

/// A Presenter's acknowledgement of one Remote command.
public struct Ack: Equatable, Sendable {
  public let epoch: String
  public let id: String
  public let result: Int

  public init(epoch: String, id: String, result: Int) {
    self.epoch = epoch
    self.id = id
    self.result = result
  }
}

/// A message the server (or the peer, through the server) sends to this client.
public enum ServerMessage: Equatable, Sendable {
  case connected(paired: Bool, peer: Bool)
  /// The Remote's own credential after the Presenter approved it.
  case approved(key: String)
  /// Remote: waiting for approval; both screens show `check`.
  case waiting(check: String)
  /// Presenter: a join request to approve or reject.
  case pending(request: String, check: String)
  case pendingGone
  case invite(generation: String, code: String, key: String)
  case inviteMissing
  case reset
  case peerUp
  case peerDown
  case pong
  case sync(Snapshot)
  case ack(Ack)
  case command(Command)
  case requestSync
}

/// A message this client sends.
public enum ClientMessage: Equatable, Sendable {
  case auth(role: Int, key: String)
  case joinCode(generation: String, code: String)
  case joinQR(generation: String, key: String)
  case invite
  case approve(request: String)
  case reject(request: String)
  case revoke
  case end
  case ping
  case requestSync
  case sync(Snapshot)
  case ack(epoch: String, id: String, result: CommandResult)
  case command(Command)
}

/// HTTP control requests: create a session (Presenter) or look up a typed code (Remote).
public enum ControlRequest: Equatable, Sendable {
  case create
  case lookup(code: String)
}

public enum ControlResponse: Equatable, Sendable {
  /// A new session and the Presenter's credential.
  case created(id: String, key: String)
  /// The session and invite generation for a typed code.
  case found(id: String, generation: String)
}

public enum ControlFailure: Error, Equatable {
  /// HTTP 429 from a rate limiter.
  case slow
  /// Anything else: network, abort, status, an unreadable body.
  case unavailable
}
