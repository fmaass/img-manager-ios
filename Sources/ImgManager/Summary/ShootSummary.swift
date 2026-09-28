import ImgManagerAPI

/// WP28 P3 (IMGMGR-450), plan Decision 2: what the Shoot Summary sheet shows, as a pure value
/// built from the server's shoot-wide `FolderSummary` for the selected folder — the same record
/// the queue already loads (`QueueStore.summaries`).
///
/// No count here is ever derived from loaded grid pages: the grid holds a window of a shoot,
/// never the shoot, so a count summed from it would be a different, smaller number. A folder the
/// server has no summary for (not in the queue, or the queue unreachable) shows "Counts
/// unavailable" and never the completion banner.
struct ShootSummary: Equatable, Sendable {
  /// The server's four shoot-wide counts, verbatim.
  struct Counts: Equatable, Sendable {
    let total: Int
    let picked: Int
    let disliked: Int
    let unmarked: Int
  }

  /// The server's write-back tally, verbatim (`FolderSyncCounts`; an absent field is 0, the
  /// schema's own default). Only marked photographs are in it.
  struct Sync: Equatable, Sendable {
    let synced: Int
    let stale: Int
    let never: Int
    let refused: Int
  }

  /// nil ⇒ "Counts unavailable".
  let counts: Counts?
  /// True ONLY when the server says `nothing_left_unmarked == true` — never inferred from
  /// `unmarked == 0`, and never without a summary.
  let showsNothingLeftUnmarkedBanner: Bool
  /// nil when the server sent no tally or there is no summary at all.
  let sync: Sync?

  static let unavailable = ShootSummary(
    counts: nil, showsNothingLeftUnmarkedBanner: false, sync: nil)
}

extension ShootSummary {
  /// The one construction path from the wire record. In an extension so the memberwise
  /// initializer `unavailable` uses stays synthesized.
  init(_ summary: Components.Schemas.FolderSummary?) {
    guard let summary else {
      self = .unavailable
      return
    }
    counts = Counts(
      total: summary.total, picked: summary.picked, disliked: summary.disliked,
      unmarked: summary.unmarked)
    showsNothingLeftUnmarkedBanner = summary.nothingLeftUnmarked
    sync = summary.sync.map {
      Sync(
        synced: $0.synced ?? 0, stale: $0.stale ?? 0, never: $0.never ?? 0,
        refused: $0.refused ?? 0)
    }
  }

  /// The selected folder's summary out of the queue's list — a `folder_id` join, the same one
  /// the tree's badges make (`FolderTreeRowPresentation.index`). No folder selected, or a folder
  /// the list does not carry, is `.unavailable`.
  static func forFolder(
    _ folderID: Int?, in summaries: [Components.Schemas.FolderSummary]
  ) -> ShootSummary {
    guard let folderID else { return .unavailable }
    return ShootSummary(summaries.first { $0.folderId == folderID })
  }
}
