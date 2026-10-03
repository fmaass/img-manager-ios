import Testing

@testable import ImgManager

/// IMGMGR-502 review r2: the fixture's preview hold (`DebugPreviewHold`) lets a parked request go
/// when its task is cancelled — Triage went away before the UI test released it — and a release
/// that comes afterwards resumes nothing a second time. Each test uses its own instance, never
/// the fixture's shared one, so nothing here reaches `DebugProbe`.
@Suite("DEBUG preview hold — release and cancellation")
struct DebugPreviewHoldTests {

  #if DEBUG
    /// The most yields a handshake spends waiting for the waiter to park. Parking takes a few
    /// actor hops, so this bound is never reached by a working hold; it exists so the wait
    /// cannot spin forever.
    private static let parkingYieldBudget = 1_000_000

    /// Yields until `gate` has exactly one continuation PARKED (review r3: the waiter itself, not
    /// merely a caller inside `hold()`). Bounded and cancellation-aware (review r4): it gives up
    /// when the test's task is cancelled (the time limit) or the budget runs out, and says so,
    /// so the caller's cleanup always gets to run.
    private func waitUntilParked(_ gate: DebugPreviewHold) async -> Bool {
      for _ in 0..<Self.parkingYieldBudget {
        if Task.isCancelled { return false }
        if await gate.waiterCount == 1 { return true }
        await Task.yield()
      }
      return false
    }

    /// Runs `body` with the cleanup installed FIRST (review r4): if the test's task is cancelled
    /// at any point — during the handshake or while joining — the gate is released, and the held
    /// task is always joined before this returns, so a stranded hold cannot outlive the test.
    private func withHeldTask(
      _ gate: DebugPreviewHold,
      _ body: (Task<Void, Never>) async -> Void
    ) async {
      let held = Task { await gate.hold() }
      await withTaskCancellationHandler {
        await body(held)
      } onCancel: {
        Task { await gate.release() }
      }
      // The join: on every path the body either let the hold go (cancel or release) or the
      // cancellation handler released the gate, so this returns.
      await gate.release()
      await held.value
    }

    @Test(
      "A cancelled hold finishes, drops the count, and a later release is harmless",
      .timeLimit(.minutes(1)))
    func cancelledHoldFinishes() async {
      let gate = DebugPreviewHold()
      await withHeldTask(gate) { held in
        let parked = await waitUntilParked(gate)
        #expect(parked, "the hold never parked a waiter")
        guard parked else { return }

        held.cancel()
        // A cancellation-blind hold never returns here; the time limit turns that hang red,
        // and its cancellation of this test releases the gate (`withHeldTask`), so the wait
        // ends rather than outliving the test.
        await held.value
        let afterCancel = await gate.heldCount
        #expect(afterCancel == 0, "the cancelled hold is still counted")
        let parkedAfterCancel = await gate.waiterCount
        #expect(parkedAfterCancel == 0, "the cancelled hold's waiter is still parked")

        // The waiter is gone, so a release resumes nothing twice (which would trap) and leaves
        // the count where it was.
        await gate.release()
        let afterRelease = await gate.heldCount
        #expect(afterRelease == 0)
      }
    }

    @Test("A release lets a parked hold through, and every later hold", .timeLimit(.minutes(1)))
    func releaseLetsHoldsThrough() async {
      let gate = DebugPreviewHold()
      await withHeldTask(gate) { held in
        let parked = await waitUntilParked(gate)
        #expect(parked, "the hold never parked a waiter")
        guard parked else { return }

        await gate.release()
        await held.value
        let afterRelease = await gate.heldCount
        #expect(afterRelease == 0)

        // One-way: a hold after the release does not park.
        await gate.hold()
        let afterLateHold = await gate.heldCount
        #expect(afterLateHold == 0)
      }
    }
  #endif
}
