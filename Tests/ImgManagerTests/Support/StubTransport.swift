import Foundation

@testable import ImgManager

/// Test-only stub proving every state transition P3 fold item 2 names — success, empty,
/// readiness-degraded, transport-failure, retry, recovery — with no real networking. An
/// `actor` because `ImgManagerTransport` is `Sendable` and this stub's mutable outcome
/// must be safely reconfigurable mid-test (retry/recovery both reconfigure a stub
/// mid-flight).
actor StubTransport: ImgManagerTransport {
  enum Outcome: Sendable {
    case success
    case empty
    case degraded
    case transportFailure(raw: String)
  }

  private var outcome: Outcome
  private(set) var callCount = 0

  init(outcome: Outcome) {
    self.outcome = outcome
  }

  func setOutcome(_ newOutcome: Outcome) {
    outcome = newOutcome
  }

  func folders() async throws -> FoldersResponse {
    callCount += 1
    switch outcome {
    case .success: return FoldersResponse(count: 3)
    case .empty: return FoldersResponse(count: 0)
    case .degraded: return FoldersResponse(count: 0)
    case .transportFailure(let raw): throw TransportError.failed(raw: raw)
    }
  }

  func health() async throws -> HealthResponse {
    callCount += 1
    switch outcome {
    case .success, .empty: return HealthResponse(ok: true)
    case .degraded: return HealthResponse(ok: false)
    case .transportFailure(let raw): throw TransportError.failed(raw: raw)
    }
  }

  func status() async throws -> StatusResponse {
    callCount += 1
    switch outcome {
    case .success, .empty: return StatusResponse(ready: true)
    case .degraded: return StatusResponse(ready: false)
    case .transportFailure(let raw): throw TransportError.failed(raw: raw)
    }
  }
}
