import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// IMGMGR-545 acceptance 3 (client half): the request body the app really sends, read off the
/// wire after the generated client and the composition root's middleware. The live
/// `sync_requests` row (`lightroom_closed_confirmed = true`) is the owner's read on staging.
@Suite("Sync — the request body on the wire (IMGMGR-545)")
struct SyncRequestBodyTests {
  private func sentBody(
    target: SyncTarget, client make: (SyncStubTransport) -> any APIProtocol
  ) async throws -> [String: Any] {
    let transport = SyncStubTransport()
    await transport.reply(SyncStubTransport.create, .created(SyncWire.request()))
    _ = try await SyncService(client: make(transport)).requestSync(target: target)
    let data = try #require(await transport.body(SyncStubTransport.create))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("The confirmation is the JSON boolean true, and folder_id names the shoot")
  func confirmationFlagIsJSONTrue() async throws {
    let body = try await sentBody(target: .shoot(7)) { ImgManagerAPIClient.make(transport: $0) }
    let flag = try #require(body["lightroom_closed_confirmed"] as? NSNumber)
    // A JSON `true`, not 1 and not "true": only a boolean confirms (contract).
    #expect(CFGetTypeID(flag) == CFBooleanGetTypeID())
    #expect(flag.boolValue)
    #expect(body["folder_id"] as? Int == 7)
  }

  @Test("Whole library sends the folder_id KEY with JSON null")
  func libraryScopeSendsExplicitNullFolderID() async throws {
    let body = try await sentBody(target: .library) { ImgManagerAPIClient.make(transport: $0) }
    #expect(body.keys.contains("folder_id"), "folder_id is missing: \(body)")
    #expect(body["folder_id"] is NSNull)
    let flag = try #require(body["lightroom_closed_confirmed"] as? NSNumber)
    #expect(CFGetTypeID(flag) == CFBooleanGetTypeID() && flag.boolValue)
  }

  /// Characterization, measured on the Mac build host: what the GENERATED encoder alone does
  /// with a nil `folder_id` (a client built without the middleware). If a generator upgrade
  /// starts writing the null itself, this fails and the middleware's table entry can go.
  @Test("Generator alone: a nil folder_id is left out of the body (measured)")
  func generatorEncodingOfNilFolderID() async throws {
    let body = try await sentBody(target: .library) {
      Client(
        serverURL: ImgManagerAPIClient.baseURL,
        configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()), transport: $0)
    }
    #expect(
      !body.keys.contains("folder_id"),
      "ENCODING-PROBE: the generated encoder WROTE folder_id for nil: \(body)")
  }
}

/// The middleware on its own: what it changes, and everything it leaves byte-identical.
@Suite("RequiredNullBodyKeysMiddleware (IMGMGR-545)")
struct RequiredNullBodyKeysMiddlewareTests {
  private let operation = "create_sync_request_api_sync_post"

  /// Runs the middleware and returns the request and bytes `next` received.
  private func intercept(
    _ data: Data, operationID: String, contentLength: Bool = true, singleUse: Bool = false
  ) async throws -> (HTTPRequest, Data) {
    var request = HTTPRequest(method: .post, scheme: "https", authority: "x", path: "/api/sync")
    if contentLength {
      request.headerFields[.contentLength] = String(data.count)
    }
    let body: HTTPBody
    if singleUse {
      let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
        continuation.yield(ArraySlice(data))
        continuation.finish()
      }
      body = HTTPBody(stream, length: .known(Int64(data.count)), iterationBehavior: .single)
    } else {
      body = HTTPBody(data)
    }
    let seen = SeenRequest()
    _ = try await RequiredNullBodyKeysMiddleware().intercept(
      request, body: body, baseURL: URL(string: "https://x")!, operationID: operationID
    ) { request, body, _ in
      let bytes = try await Data(collecting: try #require(body), upTo: 1 << 20)
      await seen.set(request, bytes)
      return (HTTPResponse(status: .ok), nil)
    }
    return try #require(await seen.value)
  }

  @Test("An absent folder_id becomes null, and Content-Length follows the new body")
  func insertsNullWhenAbsent() async throws {
    let sent = Data(#"{"lightroom_closed_confirmed":true}"#.utf8)
    let (request, bytes) = try await intercept(sent, operationID: operation)
    let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["folder_id"] is NSNull)
    #expect(object["lightroom_closed_confirmed"] as? Bool == true)
    #expect(request.headerFields[.contentLength] == String(bytes.count))
  }

  @Test("Other operations, a present value and a present null pass byte-identical")
  func presentKeysAndOtherOperationsAreUntouched() async throws {
    let absent = Data(#"{"lightroom_closed_confirmed":true}"#.utf8)
    #expect(try await intercept(absent, operationID: "set_mark_state").1 == absent)
    let value = Data(#"{"folder_id": 7, "lightroom_closed_confirmed": true}"#.utf8)
    #expect(try await intercept(value, operationID: operation).1 == value)
    let null = Data(#"{"folder_id": null, "lightroom_closed_confirmed": true}"#.utf8)
    #expect(try await intercept(null, operationID: operation).1 == null)
  }

  @Test("A body that is not a JSON object is passed on as the same bytes, even read-once")
  func nonObjectBodiesPassThroughIdentically() async throws {
    for text in ["[1, 2]", "{", "\"folder_id\""] {
      let data = Data(text.utf8)
      let (request, bytes) = try await intercept(data, operationID: operation, singleUse: true)
      #expect(bytes == data, "changed \(text)")
      #expect(request.headerFields[.contentLength] == String(data.count))
    }
  }
}

private actor SeenRequest {
  private(set) var value: (HTTPRequest, Data)?

  func set(_ request: HTTPRequest, _ data: Data) {
    value = (request, data)
  }
}
