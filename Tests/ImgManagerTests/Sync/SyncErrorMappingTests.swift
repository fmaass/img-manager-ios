import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-545 acceptance 1: every coded 422/409 (and 404) the contract declares on the sync
/// routes maps to its OWN message, route by route. Each case goes over the wire through the
/// REAL generated `Client` (`SyncStubTransport`), so a renamed code or a changed body shape
/// fails here, and the exact sentence is asserted — never "some message".
@Suite("Sync — each coded refusal maps to its message (IMGMGR-545)")
struct SyncErrorMappingTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let status: Int
    let code: String
    let requestID: Int?
    let failure: SyncFailure
    let message: String

    var testDescription: String { "\(status) \(code)" }
  }

  /// `POST /api/sync`: 422 ×3, 409, 404.
  static let postRows: [Row] = [
    Row(
      status: 422, code: "invalid_request", requestID: nil, failure: .invalidRequest,
      message: "The server did not accept this sync request. Nothing was queued."),
    Row(
      status: 422, code: "lightroom_not_confirmed", requestID: nil,
      failure: .lightroomNotConfirmed,
      message: "Confirm that Lightroom is closed, then press Sync now. Nothing was queued."),
    Row(
      status: 422, code: "unattributed", requestID: nil, failure: .unattributed,
      message: "The server could not tell who sent this request."
        + " Sign out and in again, then retry. Nothing was queued."),
    Row(
      status: 409, code: "sync_in_progress", requestID: 77,
      failure: .inProgress(requestID: 77),
      message: "An overlapping sync is already running. Your request was not queued."
        + " Showing its progress."),
    Row(
      status: 404, code: "folder_not_found", requestID: nil, failure: .folderNotFound,
      message: "This shoot is no longer in the library. Nothing was queued."),
  ]

  /// `GET /api/sync/{request_id}`: 422, and both 404 codes sharing one message on purpose.
  static let readRows: [Row] = [
    Row(
      status: 422, code: "invalid_request", requestID: nil, failure: .invalidRequest,
      message: "The sync's progress could not be read."),
    Row(
      status: 404, code: "sync_request_not_found", requestID: nil, failure: .requestNotFound,
      message: "The server no longer knows this sync. Reopen Sync to see the latest status."),
    Row(
      status: 404, code: "folder_not_found", requestID: nil, failure: .requestNotFound,
      message: "The server no longer knows this sync. Reopen Sync to see the latest status."),
  ]

  /// `GET /api/folders/{folder_id}/sync-status`: 422 and 404, one message on purpose.
  static let statusRows: [Row] = [
    Row(
      status: 422, code: "invalid_request", requestID: nil, failure: .invalidRequest,
      message: "Sync status is unavailable for this shoot."),
    Row(
      status: 404, code: "folder_not_found", requestID: nil, failure: .folderNotFound,
      message: "Sync status is unavailable for this shoot."),
  ]

  private func service(_ transport: SyncStubTransport) -> SyncService {
    SyncService(client: ImgManagerAPIClient.make(transport: transport))
  }

  private func reply(_ row: Row) -> SyncStubTransport.Reply {
    SyncStubTransport.Reply(
      status: row.status, json: SyncWire.coded(row.code, requestID: row.requestID))
  }

  @Test("POST /api/sync: each coded answer is its own failure and sentence", arguments: postRows)
  func postRoutes(_ row: Row) async {
    let transport = SyncStubTransport()
    await transport.reply(SyncStubTransport.create, reply(row))
    await #expect(throws: row.failure) {
      _ = try await service(transport).requestSync(target: .shoot(7))
    }
    #expect(SyncCopy.message(for: row.failure, during: .create) == row.message)
  }

  @Test(
    "GET /api/sync/{id}: each coded answer is its own failure and sentence", arguments: readRows)
  func readRoutes(_ row: Row) async {
    let transport = SyncStubTransport()
    await transport.reply(SyncStubTransport.read, reply(row))
    await #expect(throws: row.failure) {
      _ = try await service(transport).request(id: 501)
    }
    #expect(SyncCopy.message(for: row.failure, during: .read) == row.message)
  }

  @Test("GET sync-status: each coded answer is its own failure and sentence", arguments: statusRows)
  func statusRoutes(_ row: Row) async {
    let transport = SyncStubTransport()
    await transport.reply(SyncStubTransport.status, reply(row))
    await #expect(throws: row.failure) {
      _ = try await service(transport).status(folderID: 7)
    }
    #expect(SyncCopy.message(for: row.failure, during: .status) == row.message)
  }

  @Test("A thrown transport is .unreachable, with its own sentence per route")
  func transportFailureIsUnreachable() async {
    let transport = SyncStubTransport()
    await transport.reply(SyncStubTransport.create, .transportFailure)
    await #expect(throws: SyncFailure.unreachable) {
      _ = try await service(transport).requestSync(target: .library)
    }
    #expect(
      SyncCopy.message(for: .unreachable, during: .create)
        == "The server could not be reached. Reopen Sync to see whether the request arrived.")
    #expect(
      SyncCopy.message(for: .unreachable, during: .read) == "Sync status is unavailable right now.")
    #expect(
      SyncCopy.message(for: .unreachable, during: .status)
        == "Sync status is unavailable right now.")
  }

  /// Every code the GENERATED enums carry has a row on every route that declares it. The
  /// switches are exhaustive over the generated types, so a re-vendored contract that adds a
  /// code stops compiling here until the code has a row.
  @Test("Every generated code has a row on each route that declares it")
  func everyGeneratedCodeHasARouteRow() {
    func refusal(_ code: Components.Schemas.SyncRefusal.CodePayload) -> String {
      switch code {
      case .invalidRequest: return "invalid_request"
      case .lightroomNotConfirmed: return "lightroom_not_confirmed"
      case .unattributed: return "unattributed"
      }
    }
    func notFound(_ code: Components.Schemas.SyncNotFound.CodePayload) -> String {
      switch code {
      case .folderNotFound: return "folder_not_found"
      case .syncRequestNotFound: return "sync_request_not_found"
      }
    }
    let refusals = [
      refusal(.invalidRequest), refusal(.lightroomNotConfirmed), refusal(.unattributed),
    ]
    let postCodes = Set(Self.postRows.map(\.code))
    #expect(refusals.allSatisfy(postCodes.contains))
    #expect(postCodes.contains("sync_in_progress"))
    #expect(postCodes.contains(notFound(.folderNotFound)))
    let readCodes = Set(Self.readRows.map(\.code))
    #expect(readCodes.contains(refusal(.invalidRequest)))
    #expect(readCodes.contains(notFound(.folderNotFound)))
    #expect(readCodes.contains(notFound(.syncRequestNotFound)))
    let statusCodes = Set(Self.statusRows.map(\.code))
    #expect(statusCodes.contains(refusal(.invalidRequest)))
    #expect(statusCodes.contains(notFound(.folderNotFound)))
  }

  /// The server's `message` ("SENTINEL server text" in every coded fixture) never reaches a
  /// rendered string.
  @Test("The server's own message is never rendered")
  func serverMessageNeverRendered() {
    for row in Self.postRows {
      #expect(!SyncCopy.message(for: row.failure, during: .create).contains("SENTINEL"))
    }
    for row in Self.readRows {
      #expect(!SyncCopy.message(for: row.failure, during: .read).contains("SENTINEL"))
    }
    for row in Self.statusRows {
      #expect(!SyncCopy.message(for: row.failure, during: .status).contains("SENTINEL"))
    }
    #expect(!String(describing: SyncFailure.inProgress(requestID: 77)).contains("SENTINEL"))
  }
}
