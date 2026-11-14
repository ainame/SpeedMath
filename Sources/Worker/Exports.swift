// Freestanding, synchronous ABI. No JS or WASI imports, heap state, or I/O.
@_cdecl("protocol_version")
public func protocolVersion() -> Int32 { 1 }

@_cdecl("can_relay")
public func canRelay(_ role: Int32, _ kind: Int32) -> Int32 {
  guard let role = Role(rawValue: role), let kind = RelayKind(rawValue: kind) else { return 0 }
  return role.canRelay(kind) ? 1 : 0
}
