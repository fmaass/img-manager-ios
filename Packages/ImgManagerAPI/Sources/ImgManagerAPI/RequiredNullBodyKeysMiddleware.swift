import Foundation
import HTTPTypes
import OpenAPIRuntime

/// IMGMGR-545: a REQUIRED request key whose value may be JSON null must reach the wire as
/// `"key": null`. The generated request types hold such a key as a Swift Optional, and an
/// Optional that is nil can be encoded by leaving the key out — which for
/// `SyncRequestCreate.folder_id` would turn "the whole library" into a 422 `invalid_request`
/// (the contract: "a client that forgets the key must not get a whole-library run").
///
/// The request is still built only by the generated client. This middleware adds `null` for a
/// listed key that is ABSENT from a JSON-object body of a listed operation, and nothing else:
/// a present key (a value or an explicit null) is never touched, every other operation is
/// passed through without reading its body, and a body it cannot read as a JSON object is
/// passed on as the identical bytes.
public struct RequiredNullBodyKeysMiddleware: ClientMiddleware {
  /// operationId → the required nullable keys of its request body.
  public static let requiredNullableKeys: [String: [String]] = [
    "create_sync_request_api_sync_post": ["folder_id"]
  ]

  /// A request body larger than this is not one of the listed small JSON objects.
  static let maxBodyBytes = 64 * 1024

  private let table: [String: [String]]

  public init(table: [String: [String]] = RequiredNullBodyKeysMiddleware.requiredNullableKeys) {
    self.table = table
  }

  public func intercept(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    guard let keys = table[operationID], let body else {
      return try await next(request, body, baseURL)
    }
    let original = try await Data(collecting: body, upTo: Self.maxBodyBytes)
    guard let patched = Self.addingNull(for: keys, to: original) else {
      return try await next(request, HTTPBody(original), baseURL)
    }
    var request = request
    if request.headerFields[.contentLength] != nil {
      request.headerFields[.contentLength] = String(patched.count)
    }
    return try await next(request, HTTPBody(patched), baseURL)
  }

  /// The body with `null` added for each absent key, or nil when nothing needs adding or the
  /// body is not a JSON object.
  static func addingNull(for keys: [String], to data: Data) -> Data? {
    guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return nil
    }
    let missing = keys.filter { object[$0] == nil }
    guard !missing.isEmpty else { return nil }
    for key in missing {
      object[key] = NSNull()
    }
    return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
