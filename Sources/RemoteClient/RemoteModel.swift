import ProtocolModels

/// What the Presenter's pairing panel and the Remote screen render.
public struct RemoteModel: Equatable {
  public var status = ""
  public var online = false
  public var open = false
  public var started = false
  public var joining = false
  public var retry = false
  public var paired = false
  public var request: String?
  public var check: String?
  public var code: String?
  public var qr: String?
  /// The Presenter's screen and home-screen settings, mirrored on the Remote.
  public var screen: Screen = .home
  public var settings = WireSettings(deck: 0, includeZero: false, count: 45, showTimer: true)
  public var index = 0
  public var count = 0
  public var elapsed: Double = 0
  /// The environment's clock minus the Presenter's elapsed time when the latest snapshot arrived.
  public var startedAt: Double = 0
  public var question = ""
  public var answer = ""
  public var notice = ""
  public var busy = false

  public init() {}
}

public enum RemoteRole: Int {
  case presenter = 1
  case remote = 2
}

/// A pairing in progress or an authenticated role. While joining, `generation` is set and `key`
/// is the QR invite key (or `code` is the typed code); once approved, only `id` and `key` remain.
public struct RemoteSession: Equatable {
  public var id: String
  public var key: String?
  public var generation: String?
  public var code: String?

  public init(id: String, key: String? = nil, generation: String? = nil, code: String? = nil) {
    self.id = id
    self.key = key
    self.generation = generation
    self.code = code
  }

  public var isJoining: Bool { generation != nil }
  public var isAuthenticatedRole: Bool { generation == nil && key != nil }

  /// A QR invite value `<id>.<generation>.<key>`.
  public static func invite(_ value: String) -> RemoteSession? {
    let parts = split(value)
    guard parts.count == 3, Wire.isID(parts[0]), Wire.isID(parts[1]), Wire.isKey(parts[2]) else { return nil }
    return RemoteSession(id: parts[0], key: parts[2], generation: parts[1])
  }

  /// A stored Presenter credential `<id>.<key>`.
  public static func stored(_ value: String) -> RemoteSession? {
    let parts = split(value)
    guard parts.count == 2, Wire.isID(parts[0]), Wire.isKey(parts[1]) else { return nil }
    return RemoteSession(id: parts[0], key: parts[1])
  }

  /// `<id>.<key>` for storage, or nil while joining.
  public var storedValue: String? {
    guard !isJoining, let key else { return nil }
    return id + "." + key
  }

  private static func split(_ text: String) -> [String] {
    text.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
  }
}
