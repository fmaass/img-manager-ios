import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The composition root's low-level transport until P1's native-auth lane lands. Every
/// call fails closed with an opaque, argument-less error — a state the app already has to
/// handle correctly (fold item 3) — so wiring this instead of a real network client costs
/// nothing in P3 and, deliberately, makes it impossible for any P3 code path to fire an
/// unauthenticated live request against the deployed VPN-only backend. Carries no message,
/// no host, no body: there is nothing here for fold item 4's suppression to fail on even by
/// omission, because there is nothing to suppress.
///
/// The four live-authenticated acceptances Amendment 8 defers to P1 all attach here — P1
/// replaces this type at the `RootView.init` call site with a real authenticated
/// `ClientTransport` (URLSession-backed, bearer-token middleware):
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
struct UnauthenticatedPlaceholderClientTransport: ClientTransport {
  /// Deliberately empty — see the type doc comment. `Error` alone, no associated value,
  /// no `CustomStringConvertible`/`LocalizedError` override: there is no string anywhere
  /// on this type for anything downstream to accidentally surface.
  struct PlaceholderTransportError: Error, Sendable {}

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    throw PlaceholderTransportError()
  }
}
