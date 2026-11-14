// Freestanding, synchronous ABI. No JS or WASI imports, heap state, or I/O.
@_cdecl("protocol_version")
public func protocolVersion() -> Int32 { 1 }

@_cdecl("can_relay")
public func canRelay(_ role: Int32, _ kind: Int32) -> Int32 {
  guard let role = Role(rawValue: role), let kind = RelayKind(rawValue: kind) else { return 0 }
  return role.canRelay(kind) ? 1 : 0
}

@_cdecl("valid_card")
public func validCard(_ lhs: Int32, _ sign: Int32, _ rhs: Int32) -> Int32 {
  WireRules.validCard(lhs: Int(lhs), sign: Int(sign), rhs: Int(rhs)) ? 1 : 0
}

@_cdecl("valid_snapshot")
public func validSnapshot(_ version: Int32, _ phase: Int32, _ index: Int32, _ count: Int32, _ elapsed: Int32) -> Int32 {
  WireRules.validSnapshot(
    version: Int(version), phase: Int(phase), index: Int(index), count: Int(count), elapsed: Int(elapsed)) ? 1 : 0
}
