import Foundation

/// IMGMGR-545 (R3-13): every word the Sync sheet, the Summary sync block and the Settings
/// Lightroom rows show about sync lives here, so a unit test reads exactly what renders. The
/// server's own `message` is never one of them.
enum SyncCopy {
  static let title = "Sync to Lightroom"
  static let syncNowTitle = "Sync now"
  static let lightroomClosedLabel = "Lightroom is closed"
  static let switchFooter =
    "Confirm for each sync that Lightroom is closed or has auto-write paused."
  static let targetTitle = "Sync"
  static let contentTitle = "Writes"
  static let contentValue = "Picks & dislikes"
  /// The run carries `none` too (IMGMGR-545 comment 12834): clearing a mark is written back.
  static let contentCaption = "A mark you cleared is removed from the sidecar too."
  /// No signal for this exists (R3-13); the owner still runs it in Lightroom after a sync.
  static let readMetadataLine = "Read Metadata from Files in Lightroom: not confirmed"
  static let libraryOnlyStatusLine = "Status is shown per shoot."
  static let readingStatusLine = "Reading sync status…"
  static let summaryLinkTitle = "Sync…"

  static func targetName(_ target: SyncTarget) -> String {
    switch target {
    case .shoot: return "This shoot"
    case .library: return "Whole library"
    }
  }

  // MARK: - Failures, route by route (plan §6)

  static let overlapUnreadable =
    "An overlapping sync is already running. Your request was not queued."
    + " Its progress could not be read."

  static func message(for failure: SyncFailure, during call: SyncCall) -> String {
    switch call {
    case .create: return createMessage(failure)
    case .read: return readMessage(failure)
    case .status: return statusMessage(failure)
    }
  }

  private static func createMessage(_ failure: SyncFailure) -> String {
    switch failure {
    case .invalidRequest, .requestNotFound:
      return "The server did not accept this sync request. Nothing was queued."
    case .lightroomNotConfirmed:
      return "Confirm that Lightroom is closed, then press Sync now. Nothing was queued."
    case .unattributed:
      return "The server could not tell who sent this request."
        + " Sign out and in again, then retry. Nothing was queued."
    case .inProgress:
      return "An overlapping sync is already running. Your request was not queued."
        + " Showing its progress."
    case .folderNotFound:
      return "This shoot is no longer in the library. Nothing was queued."
    case .unreachable:
      return "The server could not be reached. Reopen Sync to see whether the request arrived."
    }
  }

  private static func readMessage(_ failure: SyncFailure) -> String {
    switch failure {
    case .requestNotFound:
      return "The server no longer knows this sync. Reopen Sync to see the latest status."
    case .unreachable:
      return "Sync status is unavailable right now."
    case .invalidRequest, .lightroomNotConfirmed, .unattributed, .inProgress, .folderNotFound:
      return "The sync's progress could not be read."
    }
  }

  private static func statusMessage(_ failure: SyncFailure) -> String {
    switch failure {
    case .unreachable:
      return "Sync status is unavailable right now."
    case .invalidRequest, .lightroomNotConfirmed, .unattributed, .inProgress, .folderNotFound,
      .requestNotFound:
      return "Sync status is unavailable for this shoot."
    }
  }

  // MARK: - The status line (plan §7)

  /// "N marks not yet written to sidecars · <last> · N refused · N on JPEG/HEIF can't travel".
  static func statusLine(_ status: SyncStatus) -> String {
    [
      "\(status.notYetWritten) marks not yet written to sidecars",
      lastSegment(status.latest),
      "\(status.refused) refused",
      "\(status.cannotTravel) on JPEG/HEIF can't travel",
    ]
    .joined(separator: " · ")
  }

  /// `latest` is the newest COVERING request in any state, so an earlier success behind it is
  /// not knowable: the words never claim "last successful" for anything but a succeeded latest.
  static func lastSegment(_ latest: SyncRequest?) -> String {
    guard let latest else { return "no sync yet" }
    switch latest.state {
    case .pending, .running:
      return "sync running now"
    case .succeeded:
      return latest.finishedAt.map { "last sync \(SyncClock.text($0))" }
        ?? "last sync time unknown"
    case .failed, .refused, .abandoned:
      return latest.finishedAt.map { "last attempt \(SyncClock.text($0)) did not succeed" }
        ?? "last attempt did not succeed"
    }
  }

  // MARK: - The watched request (plan §5)

  static func stateLine(
    _ request: SyncRequest, origin: SyncSheetModel.Origin, presentationFolderID: Int?
  ) -> String {
    switch request.state {
    case .pending: return "Waiting for the writer…"
    case .running: return "Writing sidecars…"
    case .succeeded, .failed, .refused, .abandoned: break
    }
    guard case .overlap = origin else { return terminalLine(request) }
    let at = request.finishedAt.map { " at \(SyncClock.text($0))" } ?? ""
    return "The overlapping sync of \(runTarget(request, presentationFolderID))"
      + " \(overlapPhrase(request.state))\(at). Your request was not queued —"
      + " confirm again and press Sync now."
  }

  private static func terminalLine(_ request: SyncRequest) -> String {
    switch request.state {
    case .succeeded:
      return request.finishedAt.map { "Sync finished at \(SyncClock.text($0))." }
        ?? "Sync finished."
    case .failed:
      return "The sync failed. Marks not written stay counted above."
    case .refused:
      return "The writer refused this run. Check that Lightroom is closed, then try again."
    case .abandoned, .pending, .running:
      return "The sync stopped before it finished. Try again."
    }
  }

  private static func overlapPhrase(_ state: SyncRequestState) -> String {
    switch state {
    case .succeeded: return "finished"
    case .failed: return "failed"
    case .refused: return "was refused"
    case .abandoned, .pending, .running: return "stopped"
    }
  }

  /// The overlapping run's REAL target, never the one the rejected request asked for.
  private static func runTarget(_ request: SyncRequest, _ presentationFolderID: Int?) -> String {
    guard let folderID = request.folderID else { return "the whole library" }
    return folderID == presentationFolderID ? "this shoot" : "another shoot"
  }

  // MARK: - Settings › Lightroom Sync

  static let automaticTitle = "Automatic"
  static let automaticUnavailableReason =
    "Needs a signal that Lightroom is not writing sidecars. That signal does not exist yet."
}

/// Estate ADR-0007: a rendered time is Europe/Zurich and names its zone. The zone label is
/// COMPUTED (CET or CEST), never a locale abbreviation — an en_US formatter prints "GMT+2".
/// Value types only: no shared formatter is mutated.
enum SyncClock {
  static let zone = StatusSheetModel.zone

  static func text(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    let label = zone.isDaylightSavingTime(for: date) ? "CEST" : "CET"
    return "\(twoDigits(parts.hour ?? 0)):\(twoDigits(parts.minute ?? 0)) \(label)"
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }
}

/// R3-14: the Summary's sync block is iPad-only this round. The app decides iPad layout by
/// width (`LayoutMode`), never by device idiom — the gate's idiom-grep leg forbids idiom
/// branching — so the block shows wherever the Regular layouts do.
enum SyncPlacement {
  static func showsSummaryBlock(layoutMode: LayoutMode) -> Bool {
    layoutMode != .compact
  }
}
