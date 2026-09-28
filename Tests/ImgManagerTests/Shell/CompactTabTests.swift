import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP28 P1 (IMGMGR-448): the Compact tabs as values, the Shoots badge, and the Shoots home's
/// Recent section (plan Decision 3).
@Suite("CompactTab and ShootsHome — the Compact shell's declarations")
struct CompactTabTests {

  private func makeSummary(
    folderId: Int, readiness: String, path: String, sourceTier: String = "local",
    lastTouched: Date? = nil
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: lastTouched, nothingLeftUnmarked: false, path: path, picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: readiness)!, sourceTier: sourceTier,
      sync: nil, total: 10, unmarked: 10, withMasters: 0)
  }

  // MARK: - The tabs

  @Test("exactly three tabs, in the order Shoots, Library, Search")
  func threeTabsInOrder() {
    #expect(CompactTab.allCases == [.shoots, .library, .search])
  }

  @Test("each tab's identifier is the one the UI tests address")
  func identifiers() {
    #expect(CompactTab.allCases.map(\.identifier) == ["tab.shoots", "tab.library", "tab.search"])
  }

  // MARK: - The badge

  @Test("the badge counts exactly the Needs-review members")
  func badgeCountsTheMembers() {
    let summaries = [
      makeSummary(folderId: 1, readiness: "review_in_progress", path: "photo_incoming/a"),
      makeSummary(folderId: 2, readiness: "ready_to_review", path: "photo_incoming/b"),
      makeSummary(folderId: 3, readiness: "ready_for_editing", path: "photo_incoming/c"),
      makeSummary(folderId: 4, readiness: "sync_problem", path: "photo_incoming/d"),
    ]
    #expect(CompactTab.badgeCount(summaries: summaries) == 2)
    #expect(
      CompactTab.badgeCount(summaries: summaries)
        == NeedsReview.members(from: summaries).count)
  }

  @Test("no member means a zero badge — which renders no badge at all")
  func noMemberIsZero() {
    let summaries = [
      makeSummary(folderId: 3, readiness: "ready_for_editing", path: "photo_incoming/c")
    ]
    #expect(CompactTab.badgeCount(summaries: summaries) == 0)
  }

  @Test("no summaries at all (an unreachable queue) is a zero badge, never a stale one")
  func noSummariesIsZero() {
    #expect(CompactTab.badgeCount(summaries: []) == 0)
  }

  // MARK: - Recent

  @Test("Recent leaves out every Needs-review member")
  func recentExcludesMembers() {
    let summaries = [
      makeSummary(folderId: 1, readiness: "review_in_progress", path: "photo_incoming/a"),
      makeSummary(folderId: 3, readiness: "ready_for_editing", path: "photo_incoming/c"),
    ]
    let recent = ShootsHome.recent(from: summaries, tier: .incoming)
    #expect(recent.map(\.folderId) == [3])
  }

  @Test("Recent is newest first, undated last, ties in the server's order")
  func recentOrder() {
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let summaries = [
      makeSummary(folderId: 10, readiness: "sync_problem", path: "photo_incoming/x"),
      makeSummary(
        folderId: 11, readiness: "ready_for_editing", path: "photo_incoming/y", lastTouched: older),
      makeSummary(
        folderId: 12, readiness: "ready_for_editing", path: "photo_incoming/z", lastTouched: newer),
      makeSummary(folderId: 13, readiness: "sync_problem", path: "photo_incoming/w"),
      makeSummary(
        folderId: 14, readiness: "ready_for_editing", path: "photo_incoming/v", lastTouched: newer),
    ]
    let recent = ShootsHome.recent(from: summaries, tier: .incoming)
    #expect(recent.map(\.folderId) == [12, 14, 11, 10, 13])
  }

  @Test("the tier narrows Recent: Incoming, Edits and Archive each keep only their own")
  func recentIsNarrowedByTier() {
    let summaries = [
      makeSummary(folderId: 1, readiness: "ready_for_editing", path: "photo_incoming/a"),
      makeSummary(folderId: 2, readiness: "ready_for_editing", path: "photo_edits/b"),
      makeSummary(
        folderId: 3, readiness: "ready_for_editing", path: "2025/c", sourceTier: "archive"),
    ]
    #expect(ShootsHome.recent(from: summaries, tier: .incoming).map(\.folderId) == [1])
    #expect(ShootsHome.recent(from: summaries, tier: .edits).map(\.folderId) == [2])
    #expect(ShootsHome.recent(from: summaries, tier: .archive).map(\.folderId) == [3])
  }

  @Test("a path that only STARTS with the prefix's letters is not in that tier")
  func prefixIsAPathComponent() {
    let lookalike = makeSummary(
      folderId: 7, readiness: "ready_for_editing", path: "photo_incoming_old/a")
    #expect(!ShootsHome.belongs(lookalike, to: .incoming))
  }

  @Test("an unrecognised source tier belongs to no tier")
  func unknownSourceTierBelongsNowhere() {
    let unknown = makeSummary(
      folderId: 8, readiness: "ready_for_editing", path: "photo_incoming/a", sourceTier: "cloud")
    for tier in FolderTreeTier.allCases {
      #expect(!ShootsHome.belongs(unknown, to: tier))
    }
  }

  @Test("the served fixture's Incoming Recent is 5 then 3 (1 is under review)")
  func fixtureRecent() {
    #if DEBUG
      let recent = ShootsHome.recent(
        from: DebugStubTransport.fixtureSummaries(), tier: .incoming)
      #expect(recent.map(\.folderId) == [5, 3])
    #endif
  }
}
