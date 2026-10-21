import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP28 P1 (IMGMGR-448): the Compact tabs as values, the Shoots badge, and the Shoots home's
/// Recent section — since IMGMGR-549 the badge counts the Untouched membership and Recent is this
/// device's open history, narrowed by the "Recent from" tier.
@Suite("CompactTab and ShootsHome — the Compact shell's declarations")
struct CompactTabTests {

  private func makeSummary(
    folderId: Int, readiness: String = "ready_to_review", path: String,
    sourceTier: String = "local", lastTouched: Date? = nil, untouched: Bool = false
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: lastTouched, nothingLeftUnmarked: false, path: path, picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: readiness)!, sourceTier: sourceTier,
      sync: nil, total: 10, unmarked: 10, untouched: untouched, withMasters: 0)
  }

  // MARK: - The tabs

  /// R3-18 (IMGMGR-550): the Search tab is gone.
  @Test("exactly two tabs, in the order Shoots, Library")
  func twoTabsInOrder() {
    #expect(CompactTab.allCases == [.shoots, .library])
  }

  @Test("each tab's identifier is the one the UI tests address")
  func identifiers() {
    #expect(CompactTab.allCases.map(\.identifier) == ["tab.shoots", "tab.library"])
  }

  // MARK: - The badge

  private static let horizon2026 = UntouchedSince.calendar(in: .gmt).date(
    from: DateComponents(year: 2026, month: 1, day: 1))!

  @Test("the badge counts the FULL Untouched membership — overflow included, archive excluded")
  func badgeCountsTheUntouchedMembers() {
    var summaries = (1...9).map { day in
      makeSummary(folderId: day, path: "photo_incoming/2026/2026-05-0\(day)-x", untouched: true)
    }
    summaries.append(
      makeSummary(folderId: 21, path: "2026/2026-05-01-a", sourceTier: "archive", untouched: true))
    summaries.append(makeSummary(folderId: 30, path: "photo_incoming/2026/2026-05-01-t"))
    #expect(CompactTab.badgeCount(summaries: summaries, since: Self.horizon2026) == 9)
    #expect(
      CompactTab.badgeCount(summaries: summaries, since: Self.horizon2026)
        == Untouched.members(from: summaries, since: Self.horizon2026).count)
  }

  @Test("no member means a zero badge — which renders no badge at all")
  func noMemberIsZero() {
    let summaries = [makeSummary(folderId: 3, path: "photo_incoming/2026/2026-05-01-c")]
    #expect(CompactTab.badgeCount(summaries: summaries, since: Self.horizon2026) == 0)
  }

  @Test("no summaries at all (an unreachable queue) is a zero badge, never a stale one")
  func noSummariesIsZero() {
    #expect(CompactTab.badgeCount(summaries: [], since: Self.horizon2026) == 0)
  }

  // MARK: - Recent

  private func entry(_ id: Int, _ tier: String = "local") -> ShootShortcutsStore.Entry {
    .init(folderID: id, sourceTier: tier)
  }

  @Test("Recent is the device's opens in their order, joined to the served summaries")
  func recentFollowsTheOpenHistory() {
    let summaries = [
      makeSummary(folderId: 1, path: "photo_incoming/a"),
      makeSummary(folderId: 3, path: "photo_incoming/c"),
      makeSummary(folderId: 5, path: "photo_incoming/e"),
    ]
    let recent = ShootsHome.recent(
      entries: [entry(5), entry(9), entry(1)], summaries: summaries, tier: .incoming)
    // 9 is remembered but not served: kept by the store, not drawn.
    #expect(recent.map(\.folderId) == [5, 1])
  }

  @Test("the tier narrows Recent: Incoming, Edits and Archive each keep only their own")
  func recentIsNarrowedByTier() {
    let summaries = [
      makeSummary(folderId: 1, path: "photo_incoming/a"),
      makeSummary(folderId: 2, path: "photo_edits/b"),
      makeSummary(folderId: 3, path: "2025/c", sourceTier: "archive"),
    ]
    let entries = [entry(3, "archive"), entry(2), entry(1)]
    #expect(
      ShootsHome.recent(entries: entries, summaries: summaries, tier: .incoming).map(\.folderId)
        == [1])
    #expect(
      ShootsHome.recent(entries: entries, summaries: summaries, tier: .edits).map(\.folderId)
        == [2])
    #expect(
      ShootsHome.recent(entries: entries, summaries: summaries, tier: .archive).map(\.folderId)
        == [3])
  }

  @Test("the title menu's picker is labelled for what it scopes")
  func recentPickerTitle() {
    #expect(ShootsHome.recentPickerTitle == "Recent from")
  }

  @Test("a path that only STARTS with the prefix's letters is not in that tier")
  func prefixIsAPathComponent() {
    let lookalike = makeSummary(
      folderId: 7, path: "photo_incoming_old/a")
    #expect(!ShootsHome.belongs(lookalike, to: .incoming))
  }

  @Test("an unrecognised source tier belongs to no tier")
  func unknownSourceTierBelongsNowhere() {
    let unknown = makeSummary(
      folderId: 8, path: "photo_incoming/a", sourceTier: "cloud")
    for tier in FolderTreeTier.allCases {
      #expect(!ShootsHome.belongs(unknown, to: tier))
    }
  }
}
