import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A transport that blocks inside `send(...)` until deliberately released — used ONLY to prove
/// diff-gate round 1 blocker 1's renewal join: a test can confirm a renewal's network call has
/// genuinely started (`waitUntilStarted()`), start a SECOND concurrent trigger, and prove it
/// joins rather than firing a network call of its own, before letting the first complete
/// (`release()`). Always answers the same canned 200 `NativeTokenOut` once released.
actor JoinableRenewalStubTransport: ClientTransport {
  private(set) var callCount = 0
  private var hasStarted = false
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  /// Suspends until `send(...)` has been entered at least once.
  func waitUntilStarted() async {
    if hasStarted { return }
    await withCheckedContinuation { continuation in
      self.startedContinuation = continuation
    }
  }

  /// Lets a blocked `send(...)` proceed to return its canned response.
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCount += 1
    hasStarted = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation in
      self.releaseContinuation = continuation
    }
    var response = HTTPResponse(status: .ok)
    response.headerFields[.contentType] = "application/json"
    // A hand-written literal, not JSONEncoder(body:) — the generated client decodes dates
    // through its configured ISO-8601 date transcoder (OpenAPIRuntime.Configuration's
    // default), and a literal string sidesteps any doubt about matching that format exactly.
    let json = #"""
      {"token": "renewed-token", "expires_at": "2027-01-01T00:00:00Z", "subject": "alice"}
      """#
    return (response, HTTPBody(Data(json.utf8)))
  }
}
