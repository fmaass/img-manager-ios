import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// Live-incident regression (2026-08-28, TestFlight 0.3.0 (3)): the backend answered the
/// token exchange 200 with `expires_at: "2027-08-28T07:01:52.019478Z"`, the runtime's
/// DEFAULT transcoder rejected the fractional seconds, and the decode failure surfaced as
/// "couldn't reach your server". These tests go through the REAL generated client built by
/// `ImgManagerAPIClient.make` — the exact wiring the incident proved untested — with a stub
/// transport replaying the live wire bytes.
@Suite("RFC3339 date decoding through the generated client")
struct DateTranscoderRegressionTests {
  private final class CannedTransport: ClientTransport, @unchecked Sendable {
    let body: String
    init(body: String) { self.body = body }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
      async throws -> (HTTPResponse, HTTPBody?)
    {
      var response = HTTPResponse(status: .ok)
      response.headerFields[.contentType] = "application/json"
      return (response, HTTPBody(self.body))
    }
  }

  private func exchange(expiresAt: String) async throws -> Date {
    let client = ImgManagerAPIClient.make(
      transport: CannedTransport(
        body: #"{"token":"imgmgr_pat_regression","expires_at":"\#(expiresAt)","subject":"s"}"#))
    let output = try await client.nativeExchangeApiAuthNativeExchangePost(
      .init(body: .json(.init(code: "c", codeVerifier: String(repeating: "v", count: 43)))))
    guard case .ok(let ok) = output, let token = try? ok.body.json else {
      Issue.record("exchange response did not decode")
      throw CancellationError()
    }
    return token.expiresAt
  }

  @Test("the live microsecond form decodes (the incident's exact wire value)")
  func fractionalSecondsDecode() async throws {
    let date = try await exchange(expiresAt: "2027-08-28T07:01:52.019478Z")
    #expect(abs(date.timeIntervalSince1970 - 1_819_436_512.019478) < 0.001)
  }

  @Test("the zero-microsecond form (serialised without a fraction) also decodes")
  func wholeSecondsDecode() async throws {
    let date = try await exchange(expiresAt: "2027-08-28T07:01:52Z")
    #expect(abs(date.timeIntervalSince1970 - 1_819_436_512.0) < 0.001)
  }

  @Test("garbage still refuses")
  func garbageRefuses() {
    #expect(throws: (any Error).self) {
      _ = try RFC3339DateTranscoder().decode("yesterday-ish")
    }
  }
}
