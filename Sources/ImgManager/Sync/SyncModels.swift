import Foundation

/// IMGMGR-545 (R3-13): the app's own values for the three sync routes. The generated types stay
/// inside `SyncService`; everything above it reads these, and none of them carries a server
/// `message` or any other raw text.

/// `SyncRequestOut.state`, one case per contract value.
enum SyncRequestState: String, Sendable, Equatable {
  case pending
  case running
  case succeeded
  case failed
  case refused
  case abandoned

  /// The writer has not finished with it yet: the only states worth polling.
  var isActive: Bool { self == .pending || self == .running }
  var isTerminal: Bool { !isActive }
}

/// One sync request: what the sheet watches.
struct SyncRequest: Sendable, Equatable {
  let id: Int
  /// The run's REAL target: a shoot's id, or nil for the whole library.
  let folderID: Int?
  let state: SyncRequestState
  /// Nullable in the contract even for a succeeded request.
  let finishedAt: Date?
}

/// `GET /api/folders/{folder_id}/sync-status`, reduced to what the status line shows.
struct SyncStatus: Sendable, Equatable {
  /// `stale + never`: marked photographs whose sidecar does not carry the current mark.
  let notYetWritten: Int
  let refused: Int
  let cannotTravel: Int
  /// The newest request whose scope COVERS the folder, in any state.
  let latest: SyncRequest?
}

/// What a sync request covers. The contract's only scope dimension (`folder_id`).
enum SyncTarget: Sendable, Hashable {
  case shoot(Int)
  case library

  var folderID: Int? {
    switch self {
    case .shoot(let id): return id
    case .library: return nil
    }
  }
}

/// Which route a failure came from: the same code reads differently per route.
enum SyncCall: Sendable, Equatable {
  case create
  case read
  case status
}

/// Every outcome of the three routes other than success, closed and opaque.
enum SyncFailure: Error, Sendable, Equatable {
  case invalidRequest
  case lightroomNotConfirmed
  case unattributed
  /// 409 `sync_in_progress`: nothing was queued; `requestID` names the overlapping run.
  case inProgress(requestID: Int)
  case folderNotFound
  case requestNotFound
  case unreachable
}
