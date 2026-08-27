import Foundation

/// The P3 composition-root transport boundary (fold item 2 / Amendment 8). Confined to
/// exactly the three v0.9.0 endpoints P3 depends on:
/// - `GET /api/folders`
/// - `GET /api/health`
/// - `GET /api/status`
///
/// Bare `GET /health` is deliberately EXCLUDED: liveness can pass while the API/database
/// is unusable (Amendment 8), so it proves nothing this app can act on.
///
/// Injected at the composition root (`ImgManagerApp.swift` -> `RootView.init`) so every
/// test substitutes `StubTransport` (see `StubTransport.swift`) for every state
/// transition fold item 2 names — success, empty, readiness-degraded, transport-failure,
/// retry, recovery — with no real networking anywhere in the test suite.
protocol ImgManagerTransport: Sendable {
  func folders() async throws -> FoldersResponse
  func health() async throws -> HealthResponse
  func status() async throws -> StatusResponse
}

struct FoldersResponse: Sendable, Equatable {
  let count: Int
}

struct HealthResponse: Sendable, Equatable {
  let ok: Bool
}

struct StatusResponse: Sendable, Equatable {
  let ready: Bool
}

/// Any transport-layer failure — connection refused, timeout, DNS, TLS, a non-2xx
/// response, a decode failure. `raw` exists ONLY so a DEBUG console can log what actually
/// happened; fold item 4 forbids it from ever being stored on a view-visible property or
/// rendered, which is exactly what `ConnectivityState` and its tests enforce (the
/// sentinel test in `DegradedStateTests.swift` proves this raw string never survives past
/// this error into anything a view can read).
enum TransportError: Error, Sendable, Equatable {
  case failed(raw: String)
}
