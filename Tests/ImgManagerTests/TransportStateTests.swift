import ImgManagerAPI
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// P3 fold item 2: the stub layer proves success/empty/readiness-degraded/transport-
/// failure/retry/recovery THROUGH the real generated client (diff-gate blocker 1 fold —
/// `StubClientTransport` implements `OpenAPIRuntime.ClientTransport`, injected into the
/// same `ImgManagerAPIClient.make`/`ImgManagerAPIService` composition-root path production
/// uses). `ConnectivityState.check()` is the one P3 code path that actually consumes the
/// transport (fold item 3's degraded state), so most of these tests drive it directly
/// rather than re-testing the stub in isolation — the two exceptions below prove the other
/// two allowed operations (`folders`, `status`) decode the REAL generated schema shapes,
/// since fold item 2 confines P3 to all three, not just the one `ConnectivityState` uses.
@Suite("Transport state transitions (P3 fold item 2)")
struct TransportStateTests {

  private func makeService(outcome: StubClientTransport.Outcome) -> ImgManagerAPIService {
    let transport = StubClientTransport(outcome: outcome)
    let client = ImgManagerAPIClient.make(transport: transport)
    return ImgManagerAPIService(client: client)
  }

  @Test("Success: health ok -> connected")
  func successTransitionsToConnected() async {
    let state = await ConnectivityState(service: makeService(outcome: .success))
    await state.check()
    #expect(await state.status == .connected)
  }

  @Test("Empty: folders() decodes a real, empty FolderTree.items distinctly from failure")
  func emptyIsRepresentedDistinctlyFromFailure() async throws {
    let service = makeService(outcome: .empty)
    let folders = try await service.folders()
    #expect(folders.items.isEmpty)
    let health = try await service.health()
    #expect(health.status == "ok")
  }

  @Test("status() decodes the real StatusResponse shape (maintenance/coverage/runs)")
  func statusDecodesRealShape() async throws {
    let service = makeService(outcome: .success)
    let status = try await service.status()
    #expect(status.maintenance.enabled == false)
    #expect(status.coverage.imagesActive == 0)
    #expect(status.runs.isEmpty)
  }

  @Test("Readiness-degraded: health responds but reports not-ok -> the one closed state P3 owns")
  func degradedMapsToUnreachable() async {
    // The stub returns a real 503 (undocumented for this operation) with a decodable
    // "degraded" body — ImgManagerAPIService's `.ok`-only guard collapses BOTH a decode
    // miss and an undocumented status into the same closed state, which is what this
    // proves against the real generated Output enum's `.undocumented` case.
    let state = await ConnectivityState(service: makeService(outcome: .degraded))
    await state.check()
    #expect(await state.status == .unreachable)
  }

  @Test("Transport-failure: a thrown error -> the same closed state, never a distinct one")
  func transportFailureMapsToUnreachable() async {
    let state = await ConnectivityState(
      service: makeService(outcome: .transportFailure(raw: "connection refused")))
    await state.check()
    #expect(await state.status == .unreachable)
  }

  @Test("Retry then recovery: a second check() after the stub is fixed returns to connected")
  func retryThenRecovery() async {
    let transport = StubClientTransport(outcome: .transportFailure(raw: "timed out"))
    let client = ImgManagerAPIClient.make(transport: transport)
    let state = await ConnectivityState(service: ImgManagerAPIService(client: client))
    await state.check()
    #expect(await state.status == .unreachable)

    // Retry: re-invoking check() while still failing stays unreachable (never crashes,
    // never gets stuck in .checking).
    await state.check()
    #expect(await state.status == .unreachable)

    // Recovery: the same check() path, now against a fixed backend, returns to
    // connected — there is no separate "recovery" code path to wire, which is the
    // point (fold item 3's closed state is symmetric).
    await transport.setOutcome(.success)
    await state.check()
    #expect(await state.status == .connected)
    #expect(await transport.callCount == 3)
  }
}
