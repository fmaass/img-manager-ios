import Foundation

/// The composition root's transport until P1's native-auth lane lands. Every call fails
/// closed with a transport error — a state the app already has to handle correctly (fold
/// item 3), so wiring this instead of a real network client costs nothing in P3 and,
/// deliberately, makes it impossible for any P3 code path to fire an unauthenticated live
/// request against the deployed VPN-only backend.
///
/// The four live-authenticated acceptances Amendment 8 defers to P1 all attach here — P1
/// replaces this type at the `RootView.init` call site with a real authenticated client:
///
/// - `P3-LIVE-AUTH-01`: authenticated `GET /api/health` through the deployed native
///   bearer route.
/// - `P3-LIVE-AUTH-02`: authenticated `GET /api/status`.
/// - `P3-LIVE-AUTH-03`: authenticated `GET /api/folders`, including the intended
///   local/tree query.
/// - `P3-LIVE-AUTH-04`: physical-device VPN-off -> exact unreachable copy -> VPN-on
///   recovery through the authenticated deployed route, with no raw error rendered.
///
/// Exchange, renew, logout and expiry routing remain P1 acceptances outright, not P3
/// deferrals (Amendment 8).
struct UnauthenticatedPlaceholderTransport: ImgManagerTransport {
  private static let reason = "P1 native-auth lane not yet wired (P3-LIVE-AUTH-01..04)"

  func folders() async throws -> FoldersResponse {
    throw TransportError.failed(raw: Self.reason)
  }

  func health() async throws -> HealthResponse {
    throw TransportError.failed(raw: Self.reason)
  }

  func status() async throws -> StatusResponse {
    throw TransportError.failed(raw: Self.reason)
  }
}
