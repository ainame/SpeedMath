import ProtocolModels
import Testing

@testable import RemoteClient

// MARK: - Presenter

@Test func presenterCreatesSessionAndShowsInvite() {
  let environment = FakeEnvironment()
  let link = RemoteLink(
    role: .presenter, environment: environment, inbox: InviteInbox(), render: { _ in }, presenter: { _ in })
  link.show()
  #expect(link.model.open && link.model.joining)
  #expect(environment.requests.map(\.request) == [.create])
  link.show()
  environment.respond(.success(.created(id: sessionID, key: presenterKey)))
  #expect(!link.model.open, "creating the session does not reopen the closed panel")
  link.show()
  #expect(environment.stored == sessionID + "." + presenterKey, "kept for a reload")
  #expect(environment.socket.sessionID == sessionID)

  environment.socket.open()
  #expect(environment.socket.sent == [.auth(role: 1, key: presenterKey, autoQR: true)])
  environment.socket.receive(.connected(paired: false, peer: false))
  #expect(environment.socket.sent.last == .invite, "an invite follows the first connection")
  #expect(link.model.joining)
  environment.socket.receive(.invite(generation: generation, code: "ABCDEFGHJKMN", key: remoteKey))
  #expect(!link.model.joining)
  #expect(link.model.code == "ABCD-EFGH-JKMN")
  #expect(link.model.qr == "qr:" + sessionID + "." + generation + "." + remoteKey)
}

@Test func presenterResumesAfterReload() {
  let environment = FakeEnvironment()
  let inbox = InviteInbox(restoredPresenter: RemoteSession(id: sessionID, key: presenterKey))
  let link = RemoteLink(role: .presenter, environment: environment, inbox: inbox, render: { _ in }, presenter: { _ in })
  #expect(inbox.restoredPresenter == nil, "used once")
  #expect(environment.requests.isEmpty, "no new session")
  environment.socket.open()
  #expect(environment.socket.sent == [.auth(role: 1, key: presenterKey, autoQR: true)])
  environment.socket.receive(.connected(paired: true, peer: false))
  #expect(link.model.paired)
}

@Test func approvalClosesThePanelAndAsksForState() {
  let environment = FakeEnvironment()
  var stateRequests = 0
  let inbox = InviteInbox(restoredPresenter: RemoteSession(id: sessionID, key: presenterKey))
  let link = RemoteLink(
    role: .presenter, environment: environment, inbox: inbox, render: { _ in },
    presenter: { if $0 == nil { stateRequests += 1 } })
  environment.socket.open()
  environment.socket.receive(.connected(paired: false, peer: false))
  environment.socket.receive(.pending(request: "r1", check: "ABC123"))
  #expect(link.model.open && link.model.request == "r1" && link.model.check == "ABC123")
  link.decide(true, request: "other")
  #expect(environment.socket.count(.approve(request: "other")) == 0, "only the shown request can be approved")
  link.decide(true, request: "r1")
  #expect(environment.socket.sent.last == .approve(request: "r1"))
  environment.socket.receive(.peerUp)
  #expect(link.model.paired && !link.model.open)
  #expect(stateRequests == 1, "the hub publishes the current state")
}

@Test(arguments: [true, false])
func qrPairingRequiresTheDisplayedInvite(panelOpen: Bool) {
  let environment = FakeEnvironment()
  let inbox = InviteInbox(restoredPresenter: RemoteSession(id: sessionID, key: presenterKey))
  let link = RemoteLink(
    role: .presenter, environment: environment, inbox: inbox, render: { _ in }, presenter: { _ in })
  environment.socket.open()
  environment.socket.receive(.connected(paired: false, peer: false))
  link.show()
  environment.socket.receive(.invite(generation: generation, code: "ABCDEFGHJKMN", key: remoteKey))
  if !panelOpen { link.show() }
  environment.socket.receive(.pending(request: "scan", check: "ABC123", qrGeneration: generation))
  let expected: ClientMessage = panelOpen ? .approve(request: "scan") : .reject(request: "scan")
  #expect(environment.socket.sent.last == expected)
  #expect(link.model.request == nil)
  #expect(link.model.open == panelOpen)
}

@Test func presenterDisposeEndsTheSession() {
  let environment = FakeEnvironment()
  let inbox = InviteInbox(restoredPresenter: RemoteSession(id: sessionID, key: presenterKey))
  let link = RemoteLink(role: .presenter, environment: environment, inbox: inbox, render: { _ in }, presenter: { _ in })
  environment.socket.open()
  environment.socket.receive(.connected(paired: true, peer: true))
  let socket = environment.socket
  link.dispose()
  #expect(socket.sent.last == .end)
  #expect(socket.closed && socket.detached)
  #expect(environment.stored == nil)
}

// MARK: - Remote: joining

@Test func remoteJoinsWithATypedCode() {
  let environment = FakeEnvironment()
  let link = RemoteLink(
    role: .remote, environment: environment, inbox: InviteInbox(), render: { _ in }, presenter: { _ in })
  link.begin("nope")
  #expect(environment.requests.isEmpty, "an impossible code is not looked up")
  #expect(!link.model.status.isEmpty)

  link.begin("abcd efgh jkmn")
  #expect(environment.requests.map(\.request) == [.lookup(code: "ABCDEFGHJKMN")])
  environment.respond(.success(.found(id: sessionID, generation: generation)))
  environment.socket.open()
  #expect(environment.socket.sent == [.joinCode(generation: generation, code: "ABCDEFGHJKMN")])
  environment.socket.receive(.waiting(check: "ABC123"))
  #expect(link.model.check == "ABC123")
  environment.socket.receive(.approved(key: remoteKey))
  #expect(link.model.paired)
  #expect(environment.socket.sent.last == .requestSync)
}

@Test func lookupFailuresAndTimeout() {
  let environment = FakeEnvironment()
  let link = RemoteLink(
    role: .remote, environment: environment, inbox: InviteInbox(), render: { _ in }, presenter: { _ in })
  link.begin("ABCDEFGHJKMN")
  environment.respond(.failure(.slow))
  #expect(link.model.status == "すこし まってから ためしてね")
  #expect(!link.model.joining)

  link.begin("ABCDEFGHJKMN")
  let pending = environment.requests[0].handle
  environment.advance(8_000)
  #expect(pending.aborted, "a stuck lookup is aborted")
  // A response of the wrong kind is treated as a failure.
  environment.respond(.success(.created(id: sessionID, key: presenterKey)))
  #expect(environment.opened.isEmpty)
}

@Test func scannedInviteReplacesACodeJoinButNotAPairing() {
  let environment = FakeEnvironment()
  let inbox = InviteInbox()
  let link = RemoteLink(role: .remote, environment: environment, inbox: inbox, render: { _ in }, presenter: { _ in })
  link.begin("ABCDEFGHJKMN")
  let lookup = environment.requests[0].handle
  inbox.deliver(RemoteSession(id: sessionID, key: presenterKey, generation: generation))
  #expect(lookup.aborted)
  environment.socket.open()
  #expect(environment.socket.sent == [.joinQR(generation: generation, key: presenterKey)])
  environment.socket.receive(.approved(key: remoteKey))
  let paired = environment.socket

  inbox.deliver(RemoteSession(id: sessionID, key: presenterKey, generation: generation))
  #expect(environment.socket === paired, "an approved pairing is kept")
  #expect(link.model.paired)
}

// MARK: - Remote: commands and ordering

@Test func commandIsResentUntilAcknowledged() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  link.command(.next)
  #expect(link.model.busy)
  let first = environment.socket.commands
  #expect(first.count == 1 && first[0].action == .next && first[0].baseVersion == 1)
  link.command(.previous)
  #expect(environment.socket.commands.count == 1, "one command in flight at a time")

  environment.advance(900)
  #expect(environment.socket.commands == [first[0], first[0]], "resent with the same id")
  environment.socket.receive(.ack(Ack(epoch: epoch, id: first[0].id, result: 1)))
  #expect(!link.model.busy)
  environment.advance(5_000)
  #expect(environment.socket.commands.count == 2, "no resend after the ack")
}

@Test func unacknowledgedCommandBecomesUncertain() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  link.command(.next)
  environment.advance(900 * 5)
  #expect(environment.socket.commands.count == 4, "four attempts")
  #expect(!link.model.busy)
  #expect(link.model.notice == "まえの そうさは かくにんできませんでした")
  #expect(environment.socket.sent.last == .requestSync)
}

@Test func rejectedCommandBecomesUncertain() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  link.command(.next)
  let command = environment.socket.commands[0]
  environment.socket.receive(.ack(Ack(epoch: epoch, id: "f" + command.id.dropFirst(), result: 1)))
  #expect(link.model.busy, "an ack for another command is ignored")
  environment.socket.receive(.ack(Ack(epoch: epoch, id: command.id, result: 3)))
  #expect(!link.model.busy && !link.model.notice.isEmpty)
}

@Test func snapshotsAreOrderedWithinAnEpoch() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment, version: 5)
  environment.socket.receive(.sync(snapshot(version: 4, index: 1)))
  #expect(link.model.index == 1, "a snapshot even one version older is ignored (index is 1-based)")
  environment.socket.receive(.sync(snapshot(version: 5, index: 1)))
  #expect(link.model.index == 2, "the same version is applied again (a resync answer)")
  environment.socket.receive(.sync(snapshot(version: 5, index: 0)))
  environment.socket.receive(.sync(snapshot(version: 6, index: 1)))
  #expect(link.model.index == 2)
  #expect(link.model.question == "3 − 1" && link.model.answer == "2")

  let newEpoch = String(repeating: "f", count: 32)
  environment.socket.receive(.sync(snapshot(version: 1, screen: .home, epoch: newEpoch)))
  #expect(link.model.screen == .home, "a reloaded Presenter starts a new epoch")
  environment.socket.receive(.sync(snapshot(version: 9, epoch: epoch)))
  #expect(link.model.screen == .home, "snapshots from the old epoch are ignored afterwards")
}

@Test func commandFromAnOldEpochIsUncertain() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  link.command(.next)
  environment.socket.receive(.sync(snapshot(version: 1, screen: .home, epoch: String(repeating: "f", count: 32))))
  #expect(!link.model.busy && !link.model.notice.isEmpty)
}

@Test func timerCountsOnFromTheSnapshot() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  let state = Snapshot(
    epoch: epoch, deckVersion: epoch, version: 2, screen: .playing, index: 0, elapsed: 1_500,
    cards: [WireCard(lhs: 1, sign: 1, rhs: 2)!], settings: homeSettings)!
  environment.socket.receive(.sync(state))
  #expect(link.model.startedAt == environment.now - 1_500)
}

// MARK: - Connection

@Test func reconnectsWithBackoffAndStops() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  var delays: [Double] = []
  for _ in 0..<7 {
    let before = environment.opened.count
    environment.socket.drop()
    #expect(link.model.retry && !link.model.online)
    var waited = 0.0
    while environment.opened.count == before && waited < 20_000 {
      environment.advance(50)
      waited += 50
    }
    if environment.opened.count == before { break }
    delays.append(waited)
  }
  #expect(delays == [250, 500, 1_000, 2_000, 4_000, 8_000], "doubling, capped, six attempts")
  link.retry()
  #expect(environment.opened.count == 8, "a manual retry starts again")
}

@Test func definitiveCloseEndsThePairing() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  environment.socket.drop(code: 4001, reason: "revoked")
  #expect(!link.model.paired && !link.model.retry)
  #expect(link.model.status == "せつぞくが おわりました")
  let count = environment.opened.count
  environment.advance(30_000)
  #expect(environment.opened.count == count, "no reconnect")
}

@Test func goingOfflineDropsTheSocketAndOnlineReconnects() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  let socket = environment.socket
  environment.isOnline = false
  environment.send(.offline)
  #expect(!link.model.online && link.model.retry)
  #expect(socket.detached && socket.closed)
  environment.isOnline = true
  environment.send(.online)
  #expect(environment.socket !== socket)
  environment.socket.open()
  #expect(environment.socket.sent == [.auth(role: 2, key: remoteKey)])
}

@Test func returningToThePageProbesTheConnection() {
  let environment = FakeEnvironment()
  let link = pairedRemote(environment)
  environment.send(.visibilityChange)
  #expect(environment.socket.sent.last == .ping)
  #expect(!link.model.online, "controls pause until the state is confirmed")
  environment.socket.receive(.pong)
  #expect(environment.socket.sent.last == .requestSync)
  environment.advance(5_000)
  #expect(!environment.socket.closed)

  environment.send(.visibilityChange)
  environment.advance(3_500)
  #expect(environment.socket.closed, "no pong: the socket is closed so it reconnects")
}

@Test func remoteDisposeStopsListeningForInvites() {
  let environment = FakeEnvironment()
  let inbox = InviteInbox()
  let link = RemoteLink(role: .remote, environment: environment, inbox: inbox, render: { _ in }, presenter: { _ in })
  link.dispose()
  inbox.deliver(RemoteSession(id: sessionID, key: presenterKey, generation: generation))
  #expect(environment.opened.isEmpty)
  #expect(inbox.pendingInvite != nil, "kept for the next Remote screen")
}

@Test func sessionValuesParse() {
  #expect(RemoteSession.invite(sessionID + "." + generation + "." + presenterKey)?.generation == generation)
  #expect(RemoteSession.invite(sessionID + "." + generation) == nil)
  #expect(RemoteSession.stored(sessionID + "." + presenterKey)?.key == presenterKey)
  #expect(RemoteSession.stored("x.y") == nil)
  #expect(RemoteSession(id: sessionID, key: presenterKey, generation: generation).storedValue == nil)
}
