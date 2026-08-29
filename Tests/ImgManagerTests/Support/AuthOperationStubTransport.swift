import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// Test-only stub for the two native-auth operations whose OUTCOME decides whether a session
/// genuinely ends: logout (204 / 401 / undeliverable) and renew (200 / terminal 401). The
/// existing `JoinableRenewalStubTransport` always answers one canned renewed token and has no
/// logout route at all, so it cannot express "the revoke failed, keep the credential" — the
/// exact negative control the cache-clear hook has to be pinned against.
///
/// Routing is keyed on `operationID` (the real generated `Operations.*.id` constants), same
/// discipline as `StubClientTransport`/`GridStubTransport`: a renamed backend operation breaks
/// these tests at the `default` branch instead of silently succeeding.
actor AuthOperationStubTransport: ClientTransport {
  enum Outcome: Sendable {
    /// 204 for logout / 200 + a renewed token for renew.
    case success
    case status(Int)
    /// The request could not be delivered at all (no network) — a thrown transport error.
    case transportFailure
  }

  private var logoutOutcome: Outcome
  private var renewOutcome: Outcome
  private(set) var logoutCallCount = 0
  private(set) var renewCallCount = 0

  init(logoutOutcome: Outcome = .success, renewOutcome: Outcome = .success) {
    self.logoutOutcome = logoutOutcome
    self.renewOutcome = renewOutcome
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    switch operationID {
    case Operations.NativeLogoutApiAuthNativeLogoutPost.id:
      logoutCallCount += 1
      switch logoutOutcome {
      case .success:
        return (HTTPResponse(status: .noContent), nil)
      case .status(let code):
        return (HTTPResponse(status: .init(code: code)), nil)
      case .transportFailure:
        throw SentinelTransportError(raw: "AuthOperationStubTransport: forced logout failure")
      }

    case Operations.NativeRenewApiAuthNativeRenewPost.id:
      renewCallCount += 1
      switch renewOutcome {
      case .success:
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        // A hand-written literal for the same reason `JoinableRenewalStubTransport` uses one:
        // the generated client decodes dates through its own configured transcoder.
        let json = #"""
          {"token": "renewed-token", "expires_at": "2027-01-01T00:00:00Z", "subject": "alice"}
          """#
        return (response, HTTPBody(Data(json.utf8)))
      case .status(let code):
        return (HTTPResponse(status: .init(code: code)), nil)
      case .transportFailure:
        throw SentinelTransportError(raw: "AuthOperationStubTransport: forced renew failure")
      }

    default:
      throw SentinelTransportError(
        raw: "AuthOperationStubTransport: unexpected operationID: \(operationID)")
    }
  }
}
