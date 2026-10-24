import Foundation
import Testing

@testable import ImgManager

/// IMGMGR-545: the words of the status lines and the watched request, exactly (plan §7).
@Suite("Sync — the status lines and the clock (IMGMGR-545)")
struct SyncCopyTests {
  private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
  }

  private func request(
    _ state: SyncRequestState, finished: String? = nil, folderID: Int? = 7
  ) -> SyncRequest {
    SyncRequest(id: 1, folderID: folderID, state: state, finishedAt: finished.map(date))
  }

  @Test("The ledger line: not yet written (stale + never) · last sync · refused · can't travel")
  func statusLineExact() {
    let status = SyncStatus(
      notYetWritten: 5, refused: 1, cannotTravel: 3,
      latest: request(.succeeded, finished: "2026-10-23T12:05:00Z"))
    #expect(
      SyncCopy.statusLine(status)
        == "5 marks not yet written to sidecars · last sync 14:05 CEST · 1 refused"
        + " · 3 on JPEG/HEIF can't travel")
    let empty = SyncStatus(notYetWritten: 0, refused: 0, cannotTravel: 0, latest: nil)
    #expect(
      SyncCopy.statusLine(empty)
        == "0 marks not yet written to sidecars · no sync yet · 0 refused"
        + " · 0 on JPEG/HEIF can't travel")
    #expect(SyncCopy.readMetadataLine == "Read Metadata from Files in Lightroom: not confirmed")
  }

  @Test("The last-sync segment never claims a success it cannot know")
  func lastSegmentBranches() {
    #expect(SyncCopy.lastSegment(nil) == "no sync yet")
    #expect(SyncCopy.lastSegment(request(.pending)) == "sync running now")
    #expect(SyncCopy.lastSegment(request(.running)) == "sync running now")
    #expect(
      SyncCopy.lastSegment(request(.succeeded, finished: "2026-01-15T10:00:00Z"))
        == "last sync 11:00 CET")
    #expect(SyncCopy.lastSegment(request(.succeeded)) == "last sync time unknown")
    for state in [SyncRequestState.failed, .refused, .abandoned] {
      #expect(
        SyncCopy.lastSegment(request(state, finished: "2026-07-01T10:00:00Z"))
          == "last attempt 12:00 CEST did not succeed")
      #expect(SyncCopy.lastSegment(request(state)) == "last attempt did not succeed")
    }
  }

  /// Europe/Zurich (estate ADR-0007) with a COMPUTED CET/CEST label, whatever the device's zone:
  /// the clock never reads `TimeZone.current`.
  @Test("The clock is Europe/Zurich and names CET or CEST")
  func clockIsCentralEuropean() {
    #expect(SyncClock.text(date("2026-07-01T10:00:00Z")) == "12:00 CEST")
    #expect(SyncClock.text(date("2026-01-15T10:00:00Z")) == "11:00 CET")
    // The last summer hour of 2026 (DST ends 25 Oct 01:00 UTC) and the first winter one.
    #expect(SyncClock.text(date("2026-10-25T00:59:00Z")) == "02:59 CEST")
    #expect(SyncClock.text(date("2026-10-25T01:00:00Z")) == "02:00 CET")
  }

  @Test("Terminal lines without a finish time carry no time at all")
  func terminalLinesWithNullFinishedAt() {
    let ours = SyncSheetModel.Origin.submitted
    #expect(
      SyncCopy.stateLine(request(.succeeded), origin: ours, presentationFolderID: 7)
        == "Sync finished.")
    #expect(
      SyncCopy.stateLine(
        request(.succeeded, finished: "2026-10-23T12:30:00Z"), origin: .observed,
        presentationFolderID: 7) == "Sync finished at 14:30 CEST.")
    #expect(
      SyncCopy.stateLine(request(.failed), origin: ours, presentationFolderID: 7)
        == "The sync failed. Marks not written stay counted above.")
    let overlap = SyncSheetModel.Origin.overlap(requested: .library)
    #expect(
      SyncCopy.stateLine(request(.refused), origin: overlap, presentationFolderID: 7)
        == "The overlapping sync of this shoot was refused. Your request was not queued —"
        + " confirm again and press Sync now.")
    #expect(
      SyncCopy.stateLine(
        request(.succeeded, finished: "2026-10-23T12:30:00Z", folderID: nil), origin: overlap,
        presentationFolderID: 7)
        == "The overlapping sync of the whole library finished at 14:30 CEST. Your request was"
        + " not queued — confirm again and press Sync now.")
    #expect(
      SyncCopy.stateLine(request(.running), origin: overlap, presentationFolderID: 7)
        == "Writing sidecars…")
  }

  /// R3-14: Regular layouts only. The app never branches on device idiom (gate idiom-grep).
  @Test("The Summary sync block shows on the Regular layouts and never on Compact")
  func summaryBlockPlacement() {
    #expect(SyncPlacement.showsSummaryBlock(layoutMode: .compact) == false)
    #expect(SyncPlacement.showsSummaryBlock(layoutMode: .regular2))
    #expect(SyncPlacement.showsSummaryBlock(layoutMode: .regular3))
  }

  @Test("Settings: Automatic is offered disabled, with its reason")
  func settingsAutomaticRow() {
    #expect(SettingsStaticRow.lightroomModeValue == "On demand")
    #expect(SettingsStaticRow.lightroomAutomatic.title == "Automatic")
    #expect(SettingsStaticRow.lightroomAutomatic.identifier == "settingsLightroomAutomaticRow")
    #expect(
      SyncCopy.automaticUnavailableReason
        == "Needs a signal that Lightroom is not writing sidecars. That signal does not exist yet.")
  }
}
