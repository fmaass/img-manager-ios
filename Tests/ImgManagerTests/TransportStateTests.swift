import Testing

@testable import ImgManager

/// P3 fold item 2: the stub layer proves success/empty/readiness-degraded/transport-
/// failure/retry/recovery. `ConnectivityState.check()` is the one P3 code path that
/// actually consumes the transport (fold item 3's degraded state), so these tests drive
/// it directly rather than re-testing `StubTransport` in isolation.
@Suite("Transport state transitions (P3 fold item 2)")
struct TransportStateTests {

  @Test("Success: health ok -> connected")
  func successTransitionsToConnected() async {
    let stub = StubTransport(outcome: .success)
    let state = await ConnectivityState(transport: stub)
    await state.check()
    #expect(await state.status == .connected)
  }

  @Test("Empty: the stub can represent a zero-folder result distinctly from failure")
  func emptyIsRepresentedDistinctlyFromFailure() async {
    // Empty is a healthy-backend, empty-queue condition — P3 has no queue UI to render
    // it in yet (Do-NOT), but the transport layer must be able to represent it as a
    // real DATA shape distinct from "unreachable", which this proves at the response
    // level indepedently of ConnectivityState (which only looks at health()).
    let stub = StubTransport(outcome: .empty)
    let folders = try? await stub.folders()
    #expect(folders == FoldersResponse(count: 0))
    let health = try? await stub.health()
    #expect(health == HealthResponse(ok: true))
  }

  @Test("Readiness-degraded: health responds but reports not-ok -> the one closed state P3 owns")
  func degradedMapsToUnreachable() async {
    // P3 defines exactly one degraded UI state (fold item 3); a healthy-transport-but-
    // unready backend collapses into it for now — the functional spec names a finer
    // degraded-state set as explicitly OPEN for a later phase.
    let stub = StubTransport(outcome: .degraded)
    let state = await ConnectivityState(transport: stub)
    await state.check()
    #expect(await state.status == .unreachable)
  }

  @Test("Transport-failure: a thrown error -> the same closed state, never a distinct one")
  func transportFailureMapsToUnreachable() async {
    let stub = StubTransport(outcome: .transportFailure(raw: "connection refused"))
    let state = await ConnectivityState(transport: stub)
    await state.check()
    #expect(await state.status == .unreachable)
  }

  @Test("Retry then recovery: a second check() after the stub is fixed returns to connected")
  func retryThenRecovery() async {
    let stub = StubTransport(outcome: .transportFailure(raw: "timed out"))
    let state = await ConnectivityState(transport: stub)
    await state.check()
    #expect(await state.status == .unreachable)

    // Retry: re-invoking check() while still failing stays unreachable (never crashes,
    // never gets stuck in .checking).
    await state.check()
    #expect(await state.status == .unreachable)

    // Recovery: the same check() path, now against a fixed backend, returns to
    // connected — there is no separate "recovery" code path to wire, which is the
    // point (fold item 3's closed state is symmetric).
    await stub.setOutcome(.success)
    await state.check()
    #expect(await state.status == .connected)
    #expect(await stub.callCount == 3)
  }
}
