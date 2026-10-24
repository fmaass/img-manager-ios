import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// IMGMGR-545: the three sync routes at the REAL `ClientTransport` seam, so every test decodes
/// through the generated `Client`. Replies are literal wire JSON, queued per operation (the
/// last one repeats). A call can be SUSPENDED until the test releases it, and the test can wait
/// until that call has arrived — so cancellation and ordering are tested on a request that is
/// really in flight, not on one that never started.
actor SyncStubTransport: ClientTransport {
  struct Reply: Sendable {
    let status: Int
    /// nil with status 0: the transport throws.
    let json: String?

    static func ok(_ json: String) -> Reply { Reply(status: 200, json: json) }
    static func created(_ json: String) -> Reply { Reply(status: 201, json: json) }
    static let transportFailure = Reply(status: 0, json: nil)
  }

  struct Recorded: Sendable {
    let operationID: String
    let path: String
    let body: Data?
  }

  static let create = Operations.CreateSyncRequestApiSyncPost.id
  static let read = Operations.GetSyncRequestApiSyncRequestIdGet.id
  static let status = Operations.GetFolderSyncStatusApiFoldersFolderIdSyncStatusGet.id

  private var replies: [String: [Reply]] = [:]
  private var suspended: Set<String> = []
  private var gates: [String: CheckedContinuation<Void, Never>] = [:]
  private var arrivalWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private(set) var recorded: [Recorded] = []

  func reply(_ operationID: String, _ queue: Reply...) {
    replies[operationID] = queue
  }

  /// The NEXT call to `operationID` waits until `release(_:)`.
  func suspendNext(_ operationID: String) {
    suspended.insert(operationID)
  }

  func release(_ operationID: String) {
    gates.removeValue(forKey: operationID)?.resume()
  }

  /// Returns once a suspended call to `operationID` has arrived and is waiting.
  func waitUntilSuspended(_ operationID: String) async {
    if gates[operationID] != nil { return }
    await withCheckedContinuation { arrivalWaiters[operationID, default: []].append($0) }
  }

  func count(_ operationID: String) -> Int {
    recorded.filter { $0.operationID == operationID }.count
  }

  func paths(_ operationID: String) -> [String] {
    recorded.filter { $0.operationID == operationID }.map(\.path)
  }

  func body(_ operationID: String) -> Data? {
    recorded.last { $0.operationID == operationID }?.body
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var bytes: Data?
    if let body {
      bytes = try await Data(collecting: body, upTo: 1 << 20)
    }
    recorded.append(Recorded(operationID: operationID, path: request.path ?? "", body: bytes))
    if suspended.remove(operationID) != nil {
      await withCheckedContinuation { gate in
        gates[operationID] = gate
        for waiter in arrivalWaiters.removeValue(forKey: operationID) ?? [] {
          waiter.resume()
        }
      }
    }
    guard var queue = replies[operationID], let reply = queue.first else {
      throw SentinelTransportError(raw: "SyncStubTransport: no reply for \(operationID)")
    }
    if queue.count > 1 {
      queue.removeFirst()
      replies[operationID] = queue
    }
    guard let json = reply.json else {
      throw SentinelTransportError(raw: "SENTINEL transport failure")
    }
    var response = HTTPResponse(status: .init(code: reply.status))
    response.headerFields[.contentType] = "application/json"
    return (response, HTTPBody(Data(json.utf8)))
  }
}

/// Wire JSON for the sync schemas, in the contract's own field names.
enum SyncWire {
  static func request(
    id: Int = 501, folderID: Int? = 7, state: String = "pending", finished: String? = nil
  ) -> String {
    let folder = folderID.map(String.init) ?? "null"
    let finishedAt = finished.map { "\"\($0)\"" } ?? "null"
    return """
      {"id": \(id), "folder_id": \(folder), "states": ["pick", "dislike", "none"],
       "state": "\(state)", "lightroom_closed_confirmed": true, "requested_by": "owner",
       "requested_via": "bearer", "requested_at": "2026-10-23T12:00:00Z",
       "started_at": null, "finished_at": \(finishedAt), "run_id": null}
      """
  }

  static func status(
    folderID: Int = 7, stale: Int = 2, never: Int = 3, refused: Int = 1, cannotTravel: Int = 3,
    latest: String? = nil
  ) -> String {
    let latestField = latest.map { ", \"latest\": \($0)" } ?? ", \"latest\": null"
    return """
      {"folder_id": \(folderID), "counts": {"synced": 5, "stale": \(stale),
       "refused": \(refused), "never": \(never)}, "cannot_travel": \(cannotTravel)\(latestField)}
      """
  }

  static func coded(_ code: String, requestID: Int? = nil) -> String {
    let id = requestID.map { ", \"request_id\": \($0)" } ?? ""
    return "{\"detail\": {\"code\": \"\(code)\", \"message\": \"SENTINEL server text\"\(id)}}"
  }
}
