import ProtocolModels
import Testing

@Test func pairingCodeNormalization() {
  #expect(Wire.normalizeCode("abcd efgh jkmn") == "ABCDEFGHJKMN")
  #expect(Wire.normalizeCode("ABCD-EFGH-JKMN") == "ABCDEFGHJKMN")
  #expect(Wire.normalizeCode("o1il-0000-0000") == "0111" + "00000000")
  #expect(Wire.normalizeCode("ABCD-EFGH-JKMU") == nil)  // U is not in the alphabet
  #expect(Wire.normalizeCode("ABCD") == nil)
  #expect(Wire.normalizeCode(String(repeating: "A", count: 33)) == nil)
  #expect(Wire.formatCode("ABCDEFGHJKMN") == "ABCD-EFGH-JKMN")
}

@Test func sharedRules() {
  #expect(WireRules.validCard(lhs: 18, sign: -1, rhs: 9))
  #expect(!WireRules.validCard(lhs: 0, sign: 1, rhs: 1))
  #expect(!WireRules.validCard(lhs: 9, sign: 0, rhs: 1))
  #expect(WireRules.validSnapshot(version: 3, phase: 1, index: 2, count: 3, elapsed: 10))
  #expect(!WireRules.validSnapshot(version: 3, phase: 1, index: 3, count: 3, elapsed: 10))
  #expect(WireRules.validSnapshot(version: 4, phase: 2, index: 2, count: 3, elapsed: 10))
  #expect(!WireRules.validSnapshot(version: 4, phase: 3, index: 2, count: 3, elapsed: 10))
  #expect(!WireRules.validSnapshot(version: 1, phase: 1, index: 0, count: 55, elapsed: 0))
}

@Test func wireValues() {
  #expect(Wire.isID(String(repeating: "a", count: 32)))
  #expect(!Wire.isID(String(repeating: "A", count: 32)))
  #expect(Wire.isKey(String(repeating: "0", count: 64)))
  #expect(Wire.uint(3) == 3)
  #expect(Wire.uint(3.5) == nil)
  #expect(Wire.uint(-1) == nil)
  #expect(Wire.uint(19, max: 18) == nil)
  #expect(WireCard(lhs: 9, sign: 1, rhs: 9)?.answer == 18)
  #expect(WireCard(lhs: 9, sign: 1, rhs: 10) == nil)
  #expect(WireCard(lhs: 3, sign: -1, rhs: 4) == nil)
  let card = WireCard(lhs: 1, sign: 1, rhs: 1)!
  let id = String(repeating: "1", count: 32)
  #expect(Snapshot(epoch: id, deckVersion: id, version: 0, phase: .ready, index: 0, elapsed: 0, cards: []) != nil)
  #expect(Snapshot(epoch: id, deckVersion: id, version: 0, phase: .ready, index: 0, elapsed: 0, cards: [card]) == nil)
  #expect(Snapshot(epoch: id, deckVersion: id, version: 1, phase: .playing, index: 1, elapsed: 0, cards: [card]) == nil)
  #expect(Snapshot(epoch: id, deckVersion: id, version: 2, phase: .finished, index: 0, elapsed: 5, cards: [card]) != nil)
}
