import ProtocolModels
import SessionLogic
import Testing

@Test func finishOnceAndReset() {
  var play = PlayState()
  #expect(play.move(.next, now: 10) == .resync)
  play.start(count: 2, epoch: "one", now: 100)
  #expect(play.move(.previous, now: 110) == .unchanged)
  #expect(play.move(.next, now: 150) == .applied)
  #expect(play.move(.next, now: 200) == .applied)
  #expect(play.phase == .finished)
  #expect(play.move(.next, now: 220) == .resync)
  #expect(play.elapsed == 100)
  play.reset()
  #expect(play.phase == .ready)
  play.start(count: 2, epoch: "two", now: 300)
  #expect(play.index == 0)
}

@Test func ledgerAppliesOnceAndRefusesStaleCommands() {
  var ledger = CommandLedger(epoch: "doc")
  let next = Command(id: "a", epoch: "doc", baseVersion: 0, action: .next)
  #expect(ledger.admit(next, now: 0) == .apply)
  ledger.record(next, result: .applied, now: 0)
  #expect(ledger.version == 1)
  // A resend gets the first answer; the same id with different content is a conflict.
  #expect(ledger.admit(next, now: 10) == .answer(.applied))
  #expect(ledger.admit(Command(id: "a", epoch: "doc", baseVersion: 0, action: .previous), now: 10) == .answer(.conflict))
  // A local change moves the version on, so a command based on the old state must resync.
  ledger.bump()
  #expect(ledger.admit(Command(id: "b", epoch: "doc", baseVersion: 1, action: .next), now: 20) == .answer(.resync))
  #expect(ledger.admit(Command(id: "c", epoch: "old", baseVersion: 2, action: .next), now: 20) == .answer(.resync))
  let settings = Command(id: "d", epoch: "doc", baseVersion: 2, action: .deck, value: 3)
  #expect(ledger.admit(settings, now: 30) == .apply)
  ledger.record(settings, result: .unchanged, now: 30)
  #expect(ledger.version == 3)
  // After the window the id is forgotten, but its base version is long gone.
  #expect(ledger.admit(next, now: 40_000) == .answer(.resync))
}

@Test func commandRules() {
  #expect(WireRules.validCommand(action: 1, value: 0))
  #expect(!WireRules.validCommand(action: 1, value: 1))
  #expect(WireRules.validCommand(action: 7, value: 3))
  #expect(!WireRules.validCommand(action: 7, value: 4))
  #expect(WireRules.validCommand(action: 9, value: 45))
  #expect(!WireRules.validCommand(action: 9, value: 30))
  #expect(!WireRules.validCommand(action: 0, value: 0))
  #expect(!WireRules.validCommand(action: 11, value: 0))
}
