import Foundation
import Testing

@testable import ImgManager

/// A suspension a test controls (`ForegroundRefreshTests`' gate, plus whether anyone waits).
@MainActor
private final class Gate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var isWaiting = false

  func wait() async {
    if released { return }
    isWaiting = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    isWaiting = false
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

/// The store Triage talks to: a pool with pages behind it, a marker and a pager that can be
/// suspended, and a one-slot undo like `UndoStack`. Every store call is recorded in order.
@MainActor
private final class FakeTriageStore: TriageStore {
  var pool: [TriagePoolEntry]
  /// Pages appended when a successor is asked for at the tail.
  var pendingPages: [[TriagePoolEntry]] = []
  /// The answer at the tail once no page is left.
  var tailAnswer: SuccessorLookup = .exhausted
  var successorGate: Gate?
  var markGate: Gate?
  var refusesMarks = false
  /// A mark that drops the photograph from the pool, as an "unmarked only" filter does.
  var markRemovesImage = false
  var undoOutcome: UndoOutcome = .restoredAll
  var undoSlot: UndoEntry?
  private(set) var events: [String] = []

  init(ids: [Int], marked: Set<Int> = []) {
    pool = ids.map { TriagePoolEntry(id: $0, isMarked: marked.contains($0)) }
  }

  var markCalls: [String] { events.filter { $0.hasPrefix("mark:") } }
  var undoCalls: [String] { events.filter { $0 == "undo" } }

  var triagePool: [TriagePoolEntry] { pool }

  func triageSuccessor(after imageID: Int) async -> SuccessorLookup {
    events.append("successor:\(imageID)")
    if let successorGate { await successorGate.wait() }
    while true {
      guard let index = pool.firstIndex(where: { $0.id == imageID }) else { return .unresolved }
      if pool.indices.contains(index + 1) { return .found(pool[index + 1].id) }
      guard !pendingPages.isEmpty else { return tailAnswer }
      pool += pendingPages.removeFirst()
    }
  }

  func triageMark(_ state: MarkStateValue, imageID: Int) async -> TriageMarkOutcome {
    events.append("mark:\(state.rawValue):\(imageID)")
    if let markGate { await markGate.wait() }
    if refusesMarks { return .refused }
    let entry = UndoEntry(
      appliedState: state,
      priorStates: [PriorMarkSnapshot(imageID: imageID, state: .none, revisionBefore: "r")])
    undoSlot = entry
    if markRemovesImage {
      pool.removeAll { $0.id == imageID }
    }
    return .committed(entry)
  }

  var triageUndoEntry: UndoEntry? { undoSlot }

  func triageUndo() async -> UndoOutcome {
    events.append("undo")
    if undoOutcome == .restoredAll { undoSlot = nil }
    return undoOutcome
  }
}

/// What the view does before a decision can act: report the cursor's photograph as shown
/// (review B1), then decide.
@MainActor
private func displayAndDecide(_ session: TriageSession, _ verdict: TriageVerdict) async {
  if let cursor = session.cursor { session.didDisplay(cursor) }
  await session.decide(verdict)
}

/// WP31 P1 (IMGMGR-460): the Triage pass — start position, advance, Skip's absent write, undo
/// eligibility over a one-slot undo store, the end only after paging, and the busy fence.
@MainActor
@Suite("TriageSession — one pass over the live pool")
struct TriageSessionTests {

  /// Polls (bounded) until `condition` holds, so a suspended action is observed mid-flight.
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  @Test("Start: the first unmarked photograph, else the first, else nothing")
  func startPosition() {
    let mixed = FakeTriageStore(ids: [1, 2, 3], marked: [1])
    #expect(TriageSession(store: mixed).cursor == 2)
    let allMarked = FakeTriageStore(ids: [1, 2], marked: [1, 2])
    #expect(TriageSession(store: allMarked).cursor == 1)
    let empty = FakeTriageStore(ids: [])
    let session = TriageSession(store: empty)
    #expect(session.cursor == nil)
    #expect(session.canDecide == false)
    #expect(TriageSession(store: mixed, startAt: 3).cursor == 3)
  }

  @Test("Pick writes through the marker, logs, and advances; position follows the pool")
  func pickAdvances() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let session = TriageSession(store: store)
    #expect(session.position == 1)
    await displayAndDecide(session, .pick)
    #expect(store.markCalls == ["mark:pick:1"])
    #expect(session.cursor == 2)
    #expect(session.position == 2)
    #expect(session.log.map(\.verdict) == [.pick])
    #expect(session.busy == false)
  }

  @Test("Skip advances with no marker call at all")
  func skipMakesNoMarkerCall() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    #expect(store.markCalls.isEmpty)
    #expect(session.cursor == 2)
    #expect(session.log == [TriagePassAction(verdict: .skip, imageID: 1, undoEntry: nil)])
  }

  @Test("Undo after a Skip steps back with no store call")
  func undoAfterSkipIsUIOnly() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    #expect(session.canUndo)
    await session.undo()
    #expect(session.cursor == 1)
    #expect(session.log.isEmpty)
    #expect(store.markCalls.isEmpty)
    #expect(store.undoCalls.isEmpty)
    #expect(session.canUndo == false)
  }

  @Test("Mark, mark: only the last mark is undoable, then Undo is disabled")
  func undoEligibilityAcrossTwoMarks() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    #expect(session.canUndo)
    await displayAndDecide(session, .dislike)
    #expect(session.cursor == 3)
    #expect(session.canUndo)
    await session.undo()
    #expect(store.undoCalls.count == 1)
    #expect(session.cursor == 2)
    #expect(session.log.map(\.verdict) == [.pick])
    // The slot no longer holds the first mark's entry: one slot, no history.
    #expect(session.canUndo == false)
    await session.undo()
    #expect(store.undoCalls.count == 1, "Undo reached the store with nothing of this pass in it")
  }

  @Test("Skip after a mark: the Skip undoes, then the mark still holding the slot does")
  func undoEligibilityAcrossSkipAndMark() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    await displayAndDecide(session, .skip)
    await session.undo()
    #expect(session.cursor == 2)
    #expect(store.undoCalls.isEmpty)
    #expect(session.canUndo)
    await session.undo()
    #expect(session.cursor == 1)
    #expect(store.undoCalls.count == 1)
  }

  @Test("A mark whose entry left the slot is not undoable")
  func overwrittenSlotDisablesUndo() async {
    let store = FakeTriageStore(ids: [1, 2])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    store.undoSlot = UndoEntry(appliedState: .dislike, priorStates: [])
    #expect(session.canUndo == false)
  }

  @Test("A mark undo that does not restore everything keeps the cursor and the log")
  func partialUndoKeepsThePlace() async {
    let store = FakeTriageStore(ids: [1, 2])
    store.undoOutcome = .partial
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    await session.undo()
    #expect(session.cursor == 2)
    #expect(session.log.count == 1)
  }

  @Test("The pass ends only after paging is exhausted, not at the loaded tail")
  func endsOnlyAfterPagingIsExhausted() async {
    let store = FakeTriageStore(ids: [1, 2])
    store.pendingPages = [[TriagePoolEntry(id: 3, isMarked: false)]]
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    await displayAndDecide(session, .skip)
    #expect(session.cursor == 3)
    #expect(session.completed == false)
    #expect(session.isClosed == false)
    await displayAndDecide(session, .pick)
    #expect(session.completed)
    #expect(session.isClosed)
    let result = session.result
    #expect(result?.completed == true)
    #expect(result?.continuationImageID == 3, "The continuation is the final photograph")
    let verdicts = result?.actions.map(\.verdict) ?? []
    #expect(verdicts == [.skip, .skip, .pick])
  }

  @Test("The successor is resolved before a write that removes the current photograph")
  func successorResolvedBeforeTheWrite() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    store.markRemovesImage = true
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    #expect(store.events == ["successor:1", "mark:pick:1"])
    #expect(session.cursor == 2)
  }

  @Test("A refused write keeps the cursor and logs nothing")
  func refusedWriteKeepsTheCursor() async {
    let store = FakeTriageStore(ids: [1, 2])
    store.refusesMarks = true
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    #expect(session.cursor == 1)
    #expect(session.log.isEmpty)
    #expect(session.busy == false)
  }

  @Test("An unresolved successor ends the action: no write, no advance, no completion")
  func unresolvedSuccessorDoesNothing() async {
    let store = FakeTriageStore(ids: [1])
    store.tailAnswer = .unresolved
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    #expect(store.markCalls.isEmpty)
    #expect(session.cursor == 1)
    #expect(session.completed == false)
    #expect(session.isClosed == false)
    #expect(session.busy == false)
    #expect(session.canDecide)
  }

  @Test("Busy fence: while a write is suspended Skip, Pick and Undo are refused")
  func busyFenceRefusesActions() async throws {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let gate = Gate()
    defer { gate.release() }
    store.markGate = gate
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    let pending = Task { @MainActor in await displayAndDecide(session, .pick) }
    await waitUntil { gate.isWaiting }
    try #require(gate.isWaiting, "The write never reached its suspension")
    #expect(session.busy)
    #expect(session.canDecide == false)
    #expect(session.canUndo == false)
    await displayAndDecide(session, .skip)
    await displayAndDecide(session, .pick)
    await session.undo()
    #expect(store.markCalls == ["mark:pick:2"])
    #expect(session.cursor == 2)
    gate.release()
    await pending.value
    #expect(session.cursor == 3)
    #expect(session.busy == false)
  }

  @Test("Busy fence: Done closes the pass and a late write neither advances nor logs")
  func doneDuringWriteInvalidatesIt() async throws {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let gate = Gate()
    defer { gate.release() }
    store.markGate = gate
    let session = TriageSession(store: store)
    let pending = Task { @MainActor in await displayAndDecide(session, .pick) }
    await waitUntil { gate.isWaiting }
    try #require(gate.isWaiting, "The write never reached its suspension")
    let closed = session.close()
    #expect(session.isClosed)
    #expect(session.busy == false)
    #expect(closed.actions.isEmpty)
    gate.release()
    await pending.value
    #expect(session.cursor == 1)
    #expect(session.log.isEmpty)
    #expect(session.result == closed)
  }

  @Test("Closing during a suspended successor lookup submits no mark")
  func closeDuringPagingSubmitsNoMark() async throws {
    let store = FakeTriageStore(ids: [1, 2])
    let gate = Gate()
    defer { gate.release() }
    store.successorGate = gate
    let session = TriageSession(store: store)
    let pending = Task { @MainActor in await displayAndDecide(session, .pick) }
    await waitUntil { gate.isWaiting }
    try #require(gate.isWaiting, "The successor lookup never reached its suspension")
    session.close()
    gate.release()
    await pending.value
    #expect(store.markCalls.isEmpty)
    #expect(session.cursor == 1)
    #expect(session.log.isEmpty)
    #expect(session.result?.completed == false)
  }

  @Test("Close is idempotent: the first result stands")
  func closeIsIdempotent() async {
    let store = FakeTriageStore(ids: [1, 2])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    let first = session.close()
    let second = session.close()
    #expect(first == second)
    #expect(first.continuationImageID == 2)
    #expect(first.completed == false)
    await displayAndDecide(session, .skip)
    #expect(session.cursor == 2, "A closed pass still acted")
  }

  @Test("Decisions are inert until the cursor's photograph is the one displayed")
  func decisionsWaitForTheDisplayedPhotograph() async {
    let store = FakeTriageStore(ids: [1, 2, 3])
    let session = TriageSession(store: store)
    #expect(session.canDecide == false, "A decision was possible before anything was shown")
    await session.decide(.pick)
    await session.decide(.skip)
    #expect(store.events.isEmpty)
    #expect(session.cursor == 1)
    session.didDisplay(1)
    #expect(session.canDecide)
    await session.decide(.pick)
    #expect(session.cursor == 2)
    // Photograph 1 is still the one displayed while 2's preview loads: Pick, Dislike AND Skip
    // must not act on 2 unseen.
    #expect(session.displayedImageID == 1)
    #expect(session.canDecide == false)
    await session.decide(.dislike)
    await session.decide(.skip)
    #expect(store.markCalls == ["mark:pick:1"])
    #expect(session.cursor == 2)
    #expect(session.log.count == 1)
    session.didDisplay(2)
    await session.decide(.skip)
    #expect(session.cursor == 3)
  }

  @Test("Undo steps back to a photograph that must be displayed again before deciding")
  func undoNeedsTheStepBackDisplayed() async {
    let store = FakeTriageStore(ids: [1, 2])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    session.didDisplay(2)
    await session.undo()
    #expect(session.cursor == 1)
    #expect(session.canDecide == false)
    session.didDisplay(1)
    #expect(session.canDecide)
  }

  @Test("The haptic counts committed marks only, never a Skip, an Undo or a refusal")
  func committedMarksCountOnlyCommits() async {
    let store = FakeTriageStore(ids: [1, 2, 3, 4])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .skip)
    #expect(session.committedMarks == 0)
    await displayAndDecide(session, .pick)
    #expect(session.committedMarks == 1)
    await session.undo()
    #expect(session.committedMarks == 1)
    store.refusesMarks = true
    await displayAndDecide(session, .dislike)
    #expect(session.committedMarks == 1)
  }

  @Test("Copy and swipe: i of N, and the dominant axis past the threshold")
  func copyAndSwipe() {
    #expect(TriageCopy.position(3, of: 12) == "3 of 12")
    #expect(TriageCopy.position(nil, of: 12) == "– of 12")
    #expect(TriageSwipe.verdict(for: CGSize(width: -100, height: 10)) == .dislike)
    #expect(TriageSwipe.verdict(for: CGSize(width: 100, height: -10)) == .pick)
    #expect(TriageSwipe.verdict(for: CGSize(width: 10, height: -100)) == .skip)
    #expect(TriageSwipe.verdict(for: CGSize(width: 10, height: 100)) == nil)
    #expect(TriageSwipe.verdict(for: CGSize(width: 20, height: 5)) == nil)
  }
}
