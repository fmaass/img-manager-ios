import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-549 (design R3-1/R3-2): the Untouched section's membership, over fixture summary lists.
/// Incoming-tier, server-flagged untouched, dated on or after the stored horizon, never the
/// archive; newest eight, then "N more ›".
@Suite("Untouched — Incoming, untouched, on or after the horizon")
struct UntouchedTests {

  private static var utc: Calendar { UntouchedSince.calendar(in: .gmt) }
  private static var zurich: Calendar {
    UntouchedSince.calendar(in: UntouchedSince.displayTimeZone)
  }

  private static func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
    in calendar: Calendar = UntouchedSince.calendar(in: .gmt)
  ) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  /// 1 January 2026 at 00:00 UTC — the stored default for 2026.
  private static var horizon2026: Date { date(2026, 1, 1) }

  private func summary(
    _ folderID: Int, path: String, untouched: Bool = true, kind: String = "dated",
    sourceTier: String = "local"
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderID, kind: kind,
      lastTouched: nil, nothingLeftUnmarked: false, path: path, picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!,
      sourceTier: sourceTier, sync: nil, total: 4, unmarked: 4, untouched: untouched,
      withMasters: 0)
  }

  private func ids(_ summaries: [Components.Schemas.FolderSummary]) -> [Int] {
    summaries.map { $0.folderId }
  }

  @Test("an untouched ARCHIVE shoot is never a member")
  func archiveUntouchedIsExcluded() {
    let summaries = [
      summary(21, path: "2026/2026-03-01-archive", sourceTier: "archive"),
      summary(5, path: "photo_incoming/2026/2026-03-01-ufer"),
    ]
    #expect(ids(Untouched.members(from: summaries, since: Self.horizon2026)) == [5])
  }

  @Test("the horizon's own day is included, the day before it is not")
  func horizonBoundaryDayIsIncluded() {
    let horizon = Self.date(2026, 3, 15)
    let summaries = [
      summary(1, path: "photo_incoming/2026/2026-03-15-boundary"),
      summary(2, path: "photo_incoming/2026/2026-03-14-before"),
      summary(3, path: "photo_incoming/2026/2026-03-16-after"),
    ]
    #expect(ids(Untouched.members(from: summaries, since: horizon)) == [3, 1])
  }

  @Test("a horizon with a time of day still includes its whole UTC day")
  func horizonIsSnappedToItsUTCDay() {
    let lateInTheDay = Self.date(2026, 3, 15, 23, 30)
    let summaries = [summary(1, path: "photo_incoming/2026/2026-03-15-boundary")]
    #expect(ids(Untouched.members(from: summaries, since: lateInTheDay)) == [1])
  }

  @Test("nine untouched shoots show eight rows and \"1 more ›\"; the overflow lists all nine")
  func nineUntouchedYieldEightRowsAndOneMore() {
    let summaries = (1...9).map { day in
      summary(day, path: "photo_incoming/2026/2026-05-0\(day)-shoot")
    }
    let members = Untouched.members(from: summaries, since: Self.horizon2026)
    #expect(members.count == 9)
    #expect(ids(Untouched.visible(members)) == [9, 8, 7, 6, 5, 4, 3, 2])
    #expect(Untouched.overflowCount(members) == 1)
    #expect(Untouched.overflowLabel(count: Untouched.overflowCount(members)) == "1 more ›")
    // The overflow grid is handed the FULL membership, the ninth (oldest) included.
    #expect(ids(members).last == 1)
  }

  @Test("eight or fewer members show no overflow row")
  func eightOrFewerShowsNoOverflow() {
    let summaries = (1...8).map { day in
      summary(day, path: "photo_incoming/2026/2026-05-0\(day)-shoot")
    }
    let members = Untouched.members(from: summaries, since: Self.horizon2026)
    #expect(Untouched.visible(members).count == 8)
    #expect(Untouched.overflowCount(members) == 0)
    #expect(Untouched.overflowLabel(count: 0) == nil)
    #expect(Untouched.overflowLabel(count: 3) == "3 more ›")
  }

  @Test("the Edits tree is local storage but not the Incoming tier")
  func editsTierIsExcluded() {
    let summaries = [
      summary(11, path: "photo_edits/2026-08-02-edits-pass"),
      summary(5, path: "photo_incoming/2026/2026-08-02-ufer"),
    ]
    #expect(ids(Untouched.members(from: summaries, since: Self.horizon2026)) == [5])
  }

  @Test("a shoot the server does not call untouched is not a member")
  func untouchedFalseIsExcluded() {
    let summaries = [summary(5, path: "photo_incoming/2026/2026-08-02-ufer", untouched: false)]
    #expect(Untouched.members(from: summaries, since: Self.horizon2026).isEmpty)
  }

  @Test("undated folders and non-shoot kinds are never members")
  func undatedAndNonShootKindsAreExcluded() {
    let summaries = [
      summary(1, path: "photo_incoming/stub"),
      summary(
        4, path: "photo_incoming/2026/2026-09-14-wandern/2026-09-14-template", kind: "template"),
      summary(2, path: "photo_incoming/2026-09-14-other", kind: "other"),
    ]
    #expect(Untouched.members(from: summaries, since: Self.horizon2026).isEmpty)
  }

  @Test("an impossible calendar day is a name, not a date")
  func invalidDayIsExcluded() {
    let summaries = [
      summary(1, path: "photo_incoming/2026/2026-02-30-nope"),
      summary(2, path: "photo_incoming/2026/2026-13-01-nope"),
      summary(3, path: "photo_incoming/2026/2026-04-31-nope"),
    ]
    #expect(Untouched.members(from: summaries, since: Self.horizon2026).isEmpty)
  }

  @Test("a dated_split continuation is dated by its leading day")
  func datedSplitUsesItsLeadingDate() {
    let summaries = [
      summary(7, path: "photo_incoming/2026/2026-09-14-wandern-2", kind: "dated_split")
    ]
    #expect(ids(Untouched.members(from: summaries, since: Self.date(2026, 9, 14))) == [7])
    #expect(Untouched.members(from: summaries, since: Self.date(2026, 9, 15)).isEmpty)
  }

  @Test("newest day first; members of one day keep the server's order")
  func newestFirstTiesKeepServerOrder() {
    let summaries = [
      summary(10, path: "photo_incoming/2026/2026-03-01-a"),
      summary(11, path: "photo_incoming/2026/2026-06-01-b"),
      summary(12, path: "photo_incoming/2026/2026-03-01-c"),
      summary(13, path: "photo_incoming/2026/2026-06-01-d"),
    ]
    #expect(ids(Untouched.members(from: summaries, since: Self.horizon2026)) == [11, 13, 10, 12])
  }

  /// R3-2 / r2 amendment 2: a horizon CHOSEN in the Zurich picker at 00:30 local time is stored
  /// as that Zurich calendar day's UTC midnight, and the comparison includes a folder named for
  /// that day and excludes the day before — in winter (UTC+1) and in summer (UTC+2) alike, where
  /// 00:30 local is still the PREVIOUS day in UTC.
  @Test("a horizon picked in Zurich at 00:30 compares as its own calendar day, winter and summer")
  func aZurichPickedHorizonComparesAsItsCalendarDay() {
    for (month, day) in [(1, 20), (7, 20)] {
      let picked = Self.date(2026, month, day, 0, 30, in: Self.zurich)
      let stored = UntouchedSince.storedDate(forDisplayed: picked)
      let mm = String(format: "%02d", month)
      let summaries = [
        summary(1, path: "photo_incoming/2026/2026-\(mm)-\(day)-that-day"),
        summary(2, path: "photo_incoming/2026/2026-\(mm)-\(day - 1)-day-before"),
      ]
      #expect(ids(Untouched.members(from: summaries, since: stored)) == [1])
    }
  }

  @Test("the served fixture's Untouched section is 23, 5, 3 — 21 (archive) and 1 never")
  func fixtureMembership() {
    #if DEBUG
      let members = Untouched.members(
        from: DebugStubTransport.fixtureSummaries(),
        since: UntouchedSince.defaultStored(now: DebugStubLaunch.fixtureNow))
      #expect(ids(members) == [23, 5, 3])
      let many = Untouched.members(
        from: DebugStubTransport.fixtureSummaries() + DebugStubTransport.manyUntouchedExtras(),
        since: UntouchedSince.defaultStored(now: DebugStubLaunch.fixtureNow))
      #expect(many.count == 9)
      #expect(ids(Untouched.visible(many)) == [23, 5, 3, 36, 35, 34, 33, 32])
      #expect(Untouched.overflowLabel(count: Untouched.overflowCount(many)) == "1 more ›")
    #endif
  }
}
