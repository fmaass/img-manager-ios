import Foundation
import Testing

@testable import ImgManager

/// IMGMGR-545: the Sync form's request/poll lifecycle (plan §5), over the real generated client.
/// Every ordering and cancellation case runs against a call that is really in flight
/// (`SyncStubTransport.suspendNext` + `waitUntilSuspended`), never one that never started.
@MainActor
@Suite("Sync — the form's request and poll lifecycle (IMGMGR-545)")
struct SyncSheetModelTests {
  private typealias Stub = SyncStubTransport

  private func model(
    _ transport: SyncStubTransport, folderID: Int? = 7,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
      try Task.checkCancellation()
    }
  ) -> SyncSheetModel {
    SyncSheetModel(
      service: SyncService(client: ImgManagerAPIClient.make(transport: transport)),
      folderID: folderID, pollInterval: .zero, sleep: sleep)
  }

  private func submit(_ model: SyncSheetModel) async {
    model.lightroomClosed = true
    model.syncNow()
    await model.submission?.value
  }

  // MARK: - The confirmation

  @Test("Sync now with the switch off sends nothing")
  func syncNowRefusedWhenSwitchOff() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request()))
    let model = model(transport)
    #expect(model.canSyncNow == false)
    model.syncNow()
    await model.submission?.value
    #expect(model.submission == nil)
    #expect(await transport.count(Stub.create) == 0)
    // Positive control: the same model DOES send once the switch is on.
    await submit(model)
    #expect(await transport.count(Stub.create) == 1)
  }

  @Test(
    "The confirmation resets after every outcome",
    arguments: [
      SyncStubTransport.Reply.created(SyncWire.request()),
      SyncStubTransport.Reply(status: 409, json: SyncWire.coded("sync_in_progress", requestID: 9)),
      SyncStubTransport.Reply(status: 422, json: SyncWire.coded("lightroom_not_confirmed")),
      SyncStubTransport.Reply.transportFailure,
    ])
  func confirmationResetsAfterEveryOutcome(_ reply: SyncStubTransport.Reply) async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, reply)
    await transport.reply(Stub.read, .ok(SyncWire.request(id: 9, state: "running")))
    let model = model(transport)
    await submit(model)
    #expect(model.lightroomClosed == false)
    #expect(model.isSubmitting == false)
  }

  @Test("Two presses send one request")
  func doubleTapSendsOneRequest() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request()))
    let model = model(transport)
    model.lightroomClosed = true
    model.syncNow()
    model.syncNow()
    await model.submission?.value
    #expect(await transport.count(Stub.create) == 1)
  }

  @Test("The target is locked while submitting and while the run is active")
  func targetLockedWhileSubmittingAndWatching() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request(state: "pending")))
    await transport.suspendNext(Stub.create)
    let model = model(transport)
    #expect(model.isTargetLocked == false)
    model.lightroomClosed = true
    model.syncNow()
    await transport.waitUntilSuspended(Stub.create)
    #expect(model.isTargetLocked)
    #expect(model.canSyncNow == false)
    await transport.release(Stub.create)
    await model.submission?.value
    #expect(model.watched?.request.state == .pending)
    #expect(model.isTargetLocked, "an active run unlocked the target")
  }

  // MARK: - 409: an overlapping run

  @Test(
    "A 409 reads the overlapping run and watches it with its REAL target",
    arguments: [
      (SyncTarget.library, 7 as Int?, "this shoot"),
      (SyncTarget.shoot(7), nil as Int?, "the whole library"),
      (SyncTarget.library, 8 as Int?, "another shoot"),
    ])
  func conflictWatchesTheOverlappingRun(
    _ requested: SyncTarget, _ runFolder: Int?, _ named: String
  ) async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.create, .init(status: 409, json: SyncWire.coded("sync_in_progress", requestID: 9)))
    await transport.reply(
      Stub.read, .ok(SyncWire.request(id: 9, folderID: runFolder, state: "running")),
      .ok(SyncWire.request(id: 9, folderID: runFolder, state: "succeeded", finished: nil)))
    await transport.reply(Stub.status, .ok(SyncWire.status()))
    let model = model(transport)
    model.target = requested
    await submit(model)
    #expect(await transport.paths(Stub.read) == ["/api/sync/9"])
    #expect(model.watched?.request.folderID == runFolder)
    #expect(model.watched?.origin == .overlap(requested: requested))
    #expect(
      model.notice
        == "An overlapping sync is already running. Your request was not queued."
        + " Showing its progress.")
    await model.poll()
    let line = model.stateLine ?? ""
    #expect(line.contains("The overlapping sync of \(named) finished"), "\(line)")
    #expect(line.contains("Your request was not queued"))
    #expect(!line.contains("Sync finished"))
  }

  @Test("A 409 whose run cannot be read says so and watches nothing")
  func conflictAdoptionReadFails() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.create, .init(status: 409, json: SyncWire.coded("sync_in_progress", requestID: 9)))
    await transport.reply(
      Stub.read, .init(status: 404, json: SyncWire.coded("sync_request_not_found")))
    let model = model(transport)
    await submit(model)
    #expect(model.notice == SyncCopy.overlapUnreadable)
    #expect(model.watched == nil)
    #expect(model.canSyncNow == false, "the confirmation outlived the request")
    model.lightroomClosed = true
    #expect(model.canSyncNow)
  }

  // MARK: - Polling

  @Test("Polls to a terminal state, then refreshes the presentation's shoot once")
  func pollStopsAtTerminalStateThenRefreshes() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request(state: "pending")))
    await transport.reply(
      Stub.read, .ok(SyncWire.request(state: "running")),
      .ok(SyncWire.request(state: "succeeded", finished: "2026-10-23T12:30:00Z")))
    await transport.reply(Stub.status, .ok(SyncWire.status(stale: 0, never: 0)))
    let model = model(transport)
    await submit(model)
    await model.poll()
    #expect(await transport.count(Stub.read) == 2)
    #expect(await transport.paths(Stub.status) == ["/api/folders/7/sync-status"])
    #expect(model.stateLine == "Sync finished at 14:30 CEST.")
    #expect(model.status?.notYetWritten == 0)
    #expect(model.canSyncNow == false)
  }

  @Test("A library run refreshes the presentation's shoot, the only status there is")
  func libraryRunRefreshesThePresentationShoot() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.create, .created(SyncWire.request(folderID: nil, state: "succeeded")))
    await transport.reply(Stub.status, .ok(SyncWire.status()))
    let model = model(transport)
    model.target = .library
    await submit(model)
    await model.poll()
    #expect(await transport.paths(Stub.status) == ["/api/folders/7/sync-status"])
  }

  @Test("A run already terminal on arrival is not polled; the shoot is refreshed once")
  func terminalOnArrivalRefreshesOnceWithoutPolling() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request(state: "succeeded")))
    await transport.reply(Stub.status, .ok(SyncWire.status()))
    let model = model(transport)
    await submit(model)
    await model.poll()
    #expect(await transport.count(Stub.read) == 0)
    #expect(await transport.count(Stub.status) == 1)
    #expect(model.stateLine == "Sync finished.")
  }

  @Test("A presentation with no shoot makes no status call")
  func libraryOnlyPresentationMakesNoStatusCall() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.create, .created(SyncWire.request(folderID: nil, state: "succeeded")))
    let model = model(transport, folderID: nil)
    #expect(model.targets == [.library])
    await model.start()
    await submit(model)
    await model.poll()
    #expect(await transport.count(Stub.status) == 0)
    #expect(model.statusLine == "Status is shown per shoot.")
  }

  @Test("Opening on an active run watches it as observed, never as a rejected request")
  func startObservesAnActiveRun() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.status, .ok(SyncWire.status(latest: SyncWire.request(id: 3, state: "running"))))
    await transport.reply(
      Stub.read, .ok(SyncWire.request(id: 3, state: "succeeded", finished: nil)))
    let model = model(transport)
    await model.start()
    #expect(model.watched?.origin == .observed)
    #expect(model.canSyncNow == false)
    await model.poll()
    #expect(model.stateLine == "Sync finished.")
  }

  // MARK: - Ordering and cancellation

  @Test("A status read that answers after a submission started is dropped")
  func startResultArrivingAfterSubmissionIsDropped() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.status, .ok(SyncWire.status(latest: SyncWire.request(id: 3, state: "running"))))
    await transport.reply(Stub.create, .created(SyncWire.request(id: 501)))
    await transport.suspendNext(Stub.status)
    let model = model(transport)
    let start = Task { await model.start() }
    await transport.waitUntilSuspended(Stub.status)
    await submit(model)
    await transport.release(Stub.status)
    await start.value
    #expect(model.status == nil)
    #expect(model.watched?.request.id == 501)
    #expect(model.watched?.origin == .submitted)
  }

  @Test("A terminal refresh that answers after a new submission is dropped")
  func refreshAfterANewSubmissionIsDropped() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.create, .created(SyncWire.request(id: 1, state: "succeeded")),
      .created(SyncWire.request(id: 2, state: "pending")))
    await transport.reply(Stub.status, .ok(SyncWire.status()))
    let model = model(transport)
    await submit(model)
    await transport.suspendNext(Stub.status)
    let poll = Task { await model.poll() }
    await transport.waitUntilSuspended(Stub.status)
    await submit(model)
    await transport.release(Stub.status)
    await poll.value
    #expect(model.status == nil)
    #expect(model.watched?.request.id == 2)
  }

  @Test("Closing the form mid-poll stops it: no further read, no failure shown")
  func pollCancelledMidFlight() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request(state: "pending")))
    await transport.reply(Stub.read, .ok(SyncWire.request(state: "running")))
    let model = model(transport)
    await submit(model)
    await transport.suspendNext(Stub.read)
    let poll = Task { await model.poll() }
    await transport.waitUntilSuspended(Stub.read)
    poll.cancel()
    await transport.release(Stub.read)
    await poll.value
    #expect(await transport.count(Stub.read) == 1)
    #expect(model.watched?.request.state == .pending)
    #expect(model.notice == nil)
  }

  @Test("Closing the form during the poll's wait stops it before any read")
  func pollCancelledDuringSleep() async {
    let transport = SyncStubTransport()
    await transport.reply(Stub.create, .created(SyncWire.request(state: "pending")))
    let entered = SleepEntry()
    let model = model(transport) { _ in
      await entered.mark()
      try await Task.sleep(for: .seconds(60))
    }
    await submit(model)
    let poll = Task { await model.poll() }
    await entered.wait()
    poll.cancel()
    await poll.value
    #expect(await transport.count(Stub.read) == 0)
    #expect(model.notice == nil)
  }

  @Test("Closing the form during the POST: a late 409 is not adopted")
  func suspendedPostDismissedIsNotAdopted() async {
    let transport = SyncStubTransport()
    await transport.reply(
      Stub.create, .init(status: 409, json: SyncWire.coded("sync_in_progress", requestID: 9)))
    await transport.reply(Stub.read, .ok(SyncWire.request(id: 9, state: "running")))
    await transport.suspendNext(Stub.create)
    let model = model(transport)
    model.lightroomClosed = true
    model.syncNow()
    await transport.waitUntilSuspended(Stub.create)
    model.cancel()
    await transport.release(Stub.create)
    await model.submission?.value
    #expect(await transport.count(Stub.read) == 0)
    #expect(model.watched == nil)
    #expect(model.notice == nil)
    #expect(model.lightroomClosed == false)
  }
}

/// Signals that the injected sleep was entered.
private actor SleepEntry {
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func mark() {
    entered = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func wait() async {
    if entered { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
