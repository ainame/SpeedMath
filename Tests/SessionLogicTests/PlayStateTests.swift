import ProtocolModels
import SessionLogic
import Testing

@Test func repeatAndCompetingLocalAction() {
  var play = PlayState()
  play.start(count: 2, epoch: "one", now: 100)
  let next = Command(id: "a", epoch: "one", baseVersion: 1, direction: .next)
  #expect(play.receive(next, role: .presenter, now: 110) == .resync)
  #expect(play.receive(next, role: .remote, now: 120) == .applied)
  #expect(play.receive(next, role: .remote, now: 130) == .applied)
  #expect(play.index == 1)
  let conflict = Command(id: "a", epoch: "one", baseVersion: 1, direction: .previous)
  #expect(play.receive(conflict, role: .remote, now: 140) == .conflict)
  play.move(.previous, now: 150)
  let stale = Command(id: "b", epoch: "one", baseVersion: 2, direction: .next)
  #expect(play.receive(stale, role: .remote, now: 160) == .resync)
  #expect(play.index == 0)
}

@Test func finishOnceAndReset() {
  var play = PlayState()
  #expect(play.move(.next, now: 10) == .resync)
  play.start(count: 1, epoch: "one", now: 100)
  #expect(play.move(.previous, now: 110) == .unchanged)
  let last = Command(id: "last", epoch: "one", baseVersion: 1, direction: .next)
  #expect(play.receive(last, role: .remote, now: 200) == .applied)
  #expect(play.phase == .finished)
  #expect(play.receive(last, role: .remote, now: 210) == .applied)
  #expect(play.move(.next, now: 220) == .resync)
  #expect(play.elapsed == 100)
  #expect(play.version == 2)
  play.reset()
  play.start(count: 2, epoch: "two", now: 300)
  #expect(play.receive(last, role: .remote, now: 310) == .resync)
  #expect(play.index == 0)
}
