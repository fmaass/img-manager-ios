import Foundation
import ImgManagerAPI
import OpenAPIRuntime

/// IMGMGR-545 (R3-13): the three sync routes, through the SAME generated client every other
/// call uses (`GridService.syncService`). Nothing here builds a request by hand.
///
/// Only the transport call sits inside a `catch`: a coded refusal is mapped AFTER the call
/// returned, so it can never be collapsed into `.unreachable`. Cancellation is never a
/// failure — a cancelled call throws `CancellationError`, so a sheet that closed mid-request
/// does not report the server as unreachable.
struct SyncService: Sendable {
  private let client: any APIProtocol

  init(client: any APIProtocol) {
    self.client = client
  }

  /// `POST /api/sync`. The confirmation is the literal `true`: the only caller is a button
  /// that cannot fire with the "Lightroom is closed" switch off.
  func requestSync(target: SyncTarget) async throws -> SyncRequest {
    let body = Components.Schemas.SyncRequestCreate(
      folderId: target.folderID, lightroomClosedConfirmed: true)
    let output: Operations.CreateSyncRequestApiSyncPost.Output
    do {
      output = try await client.createSyncRequestApiSyncPost(.init(body: .json(body)))
    } catch {
      throw Self.callFailure()
    }
    switch output {
    case .created(let created):
      guard let request = try? created.body.json else { throw SyncFailure.unreachable }
      return Self.request(request)
    case .conflict(let conflict):
      guard let body = try? conflict.body.json else { throw SyncFailure.unreachable }
      throw SyncFailure.inProgress(requestID: body.detail.requestId)
    case .notFound(let notFound):
      guard let body = try? notFound.body.json else { throw SyncFailure.unreachable }
      switch body.detail.code {
      case .folderNotFound: throw SyncFailure.folderNotFound
      case .syncRequestNotFound: throw SyncFailure.requestNotFound
      }
    case .unprocessableContent(let refusal):
      guard let body = try? refusal.body.json else { throw SyncFailure.unreachable }
      throw Self.failure(body.detail.code)
    case .undocumented:
      throw SyncFailure.unreachable
    }
  }

  /// `GET /api/sync/{request_id}`. Both 404 codes mean the same thing here: the server no
  /// longer knows this request.
  func request(id: Int) async throws -> SyncRequest {
    let output: Operations.GetSyncRequestApiSyncRequestIdGet.Output
    do {
      output = try await client.getSyncRequestApiSyncRequestIdGet(
        .init(path: .init(requestId: id)))
    } catch {
      throw Self.callFailure()
    }
    switch output {
    case .ok(let ok):
      guard let request = try? ok.body.json else { throw SyncFailure.unreachable }
      return Self.request(request)
    case .notFound(let notFound):
      guard let body = try? notFound.body.json else { throw SyncFailure.unreachable }
      switch body.detail.code {
      case .folderNotFound, .syncRequestNotFound: throw SyncFailure.requestNotFound
      }
    case .unprocessableContent(let refusal):
      guard let body = try? refusal.body.json else { throw SyncFailure.unreachable }
      throw Self.failure(body.detail.code)
    case .undocumented:
      throw SyncFailure.unreachable
    }
  }

  /// `GET /api/folders/{folder_id}/sync-status`.
  func status(folderID: Int) async throws -> SyncStatus {
    let output: Operations.GetFolderSyncStatusApiFoldersFolderIdSyncStatusGet.Output
    do {
      output = try await client.getFolderSyncStatusApiFoldersFolderIdSyncStatusGet(
        .init(path: .init(folderId: folderID)))
    } catch {
      throw Self.callFailure()
    }
    switch output {
    case .ok(let ok):
      guard let status = try? ok.body.json else { throw SyncFailure.unreachable }
      return SyncStatus(
        notYetWritten: status.counts.stale + status.counts.never,
        refused: status.counts.refused, cannotTravel: status.cannotTravel,
        latest: status.latest.map(Self.request))
    case .notFound(let notFound):
      guard let body = try? notFound.body.json else { throw SyncFailure.unreachable }
      switch body.detail.code {
      case .folderNotFound, .syncRequestNotFound: throw SyncFailure.folderNotFound
      }
    case .unprocessableContent(let refusal):
      guard let body = try? refusal.body.json else { throw SyncFailure.unreachable }
      throw Self.failure(body.detail.code)
    case .undocumented:
      throw SyncFailure.unreachable
    }
  }

  /// A thrown call: cancellation stays cancellation, anything else is `.unreachable`. The
  /// underlying error is never bound to a name, so no raw text can travel past this type.
  private static func callFailure() -> any Error {
    Task.isCancelled ? CancellationError() : SyncFailure.unreachable
  }

  private static func failure(_ code: Components.Schemas.SyncRefusal.CodePayload) -> SyncFailure {
    switch code {
    case .invalidRequest: return .invalidRequest
    case .lightroomNotConfirmed: return .lightroomNotConfirmed
    case .unattributed: return .unattributed
    }
  }

  static func request(_ out: Components.Schemas.SyncRequestOut) -> SyncRequest {
    SyncRequest(
      id: out.id, folderID: out.folderId, state: state(out.state), finishedAt: out.finishedAt)
  }

  private static func state(
    _ state: Components.Schemas.SyncRequestOut.StatePayload
  ) -> SyncRequestState {
    switch state {
    case .pending: return .pending
    case .running: return .running
    case .succeeded: return .succeeded
    case .failed: return .failed
    case .refused: return .refused
    case .abandoned: return .abandoned
    }
  }
}
