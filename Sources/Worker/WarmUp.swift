import JavaScriptKit
import ProtocolModels
import RemoteProtocol

/// Runs the Worker's shared synchronous helpers once while the isolate starts up, so V8 compiles
/// them before the first request (Cloudflare bills start-up work separately from request CPU).
/// It touches no storage, sockets or randomness and has no effect besides compilation.
enum WarmUp {
  static func run() {
    let id = String(repeating: "a", count: 32)
    let key = String(repeating: "b", count: 64)
    _ = SHA256.matches(Platform.credential(id, 1, key), SHA256.hex(key))
    _ = Wire.normalizeCode("abcd-efgh-jkmn")
    _ = Wire.isID(id) && Wire.isKey(key)
    let state = SessionState(id: id, expires: 1, presenter: .init(hash: key, until: 1, socket: id))
    _ = SessionState(json: state.json)
    let text = RemoteWire.packet("command") {
      $0["epoch"] = id.jsValue
      $0["id"] = id.jsValue
      $0["baseVersion"] = 1.jsValue
      $0["direction"] = 1.jsValue
    }
    if let message = RemoteWire.frame(text.jsValue) {
      _ = RemoteWire.command(message)
      _ = message.type.string == "command"
    }
    let sync = RemoteWire.packet("sync") {
      RemoteWire.fillSnapshot(
        $0,
        Snapshot(
          epoch: id, deckVersion: id, version: 1, phase: .playing, index: 0, elapsed: 0,
          cards: [WireCard(lhs: 1, sign: 1, rhs: 1)!])!)
    }
    if let message = RemoteWire.frame(sync.jsValue) { _ = RemoteWire.snapshot(message) }
    _ = String(validating: Array("{\"v\":1}".utf8), as: UTF8.self)
  }
}
