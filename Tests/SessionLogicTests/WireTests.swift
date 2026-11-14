import ProtocolModels
import Testing

@Test(arguments: [
  ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
  ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
  (
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  ),
])
func sha256KnownAnswers(input: String, digest: String) {
  #expect(SHA256.hex(input) == digest)
}

@Test func sha256LongInput() {
  // One million "a": the FIPS 180-4 long-message vector, crossing many blocks.
  let input = String(repeating: "a", count: 1_000_000)
  #expect(SHA256.hex(input) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

@Test func digestComparison() {
  #expect(SHA256.matches("ab", "ab"))
  #expect(!SHA256.matches("ab", "ac"))
  #expect(!SHA256.matches("ab", "abc"))
  #expect(!SHA256.matches("", ""))
}

@Test func pairingCodeNormalization() {
  #expect(Wire.normalizeCode("abcd efgh jkmn") == "ABCDEFGHJKMN")
  #expect(Wire.normalizeCode("ABCD-EFGH-JKMN") == "ABCDEFGHJKMN")
  #expect(Wire.normalizeCode("o1il-0000-0000") == "0111" + "00000000")
  #expect(Wire.normalizeCode("ABCD-EFGH-JKMU") == nil)  // U is not in the alphabet
  #expect(Wire.normalizeCode("ABCD") == nil)
  #expect(Wire.normalizeCode(String(repeating: "A", count: 33)) == nil)
  #expect(Wire.formatCode("ABCDEFGHJKMN") == "ABCD-EFGH-JKMN")
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
