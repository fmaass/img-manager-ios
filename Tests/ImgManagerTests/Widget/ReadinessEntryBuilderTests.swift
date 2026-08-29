import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP12 (IMGMGR-199). The widget's whole mapping from server truth to rendered numbers is this
/// one type, so this is where the invariants live: counts come from `FolderSummary.readiness`
/// and nothing else, and an "as of" timestamp exists if and only if a real fetch produced the
/// counts it is stamping.
@Suite("ReadinessEntryBuilder — queue summaries to a timeline entry")
struct ReadinessEntryBuilderTests {

  /// The live vocabulary, verbatim: folder kind "dated" (IMGMGR-173 — fixtures use kinds the API
  /// actually emits) and the schema's own snake_case readiness strings.
  private func makeSummary(_ folderId: Int, _ readiness: String)
    -> Components.Schemas.FolderSummary
  {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: readiness)!, sourceTier: "local",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  private let fetchedAt = Date(timeIntervalSince1970: 1_756_000_000)

  @Test("All six sections are counted from their own readiness string, in displayOrder")
  func sixSectionsCounted() {
    let summaries = [
      makeSummary(1, "review_in_progress"),
      makeSummary(2, "ready_to_review"),
      makeSummary(3, "sync_problem"),
      makeSummary(4, "ready_for_editing"),
      makeSummary(5, "needs_previews"),
      makeSummary(6, "historical_unreviewed"),
    ]
    let entry = ReadinessEntryBuilder.live(from: summaries, fetchedAt: fetchedAt)

    #expect(entry.orderedCounts.map(\.section) == ReadinessSection.displayOrder)
    #expect(entry.orderedCounts.map(\.count) == [1, 1, 1, 1, 1, 1])
    #expect(entry.totalShoots == 6)
    #expect(entry.state == .live)
    #expect(entry.fetchedAt == fetchedAt)
    #expect(entry.date == fetchedAt)
  }

  @Test("Several shoots in one section accumulate into that section's count only")
  func repeatedSectionAccumulates() {
    let entry = ReadinessEntryBuilder.live(
      from: [
        makeSummary(1, "sync_problem"), makeSummary(2, "sync_problem"),
        makeSummary(3, "sync_problem"), makeSummary(4, "ready_to_review"),
      ], fetchedAt: fetchedAt)

    #expect(entry.count(for: .syncProblem) == 3)
    #expect(entry.count(for: .readyToReview) == 1)
    #expect(entry.count(for: .needsPreviews) == 0)
    #expect(entry.totalShoots == 4)
  }

  /// The sync-problem number the widget shows is the `sync_problem` READINESS section's count —
  /// the one rollup the queue home itself renders (its section header). It is deliberately NOT
  /// derived from `FolderSyncCounts`/`SyncSignal`, whose per-folder fields that type refuses to
  /// sum. `sync: nil` on every fixture here is the proof: the number is 2 anyway.
  @Test("The sync-problem count is the sync_problem section, never a FolderSyncCounts rollup")
  func syncProblemCountIsTheSection() {
    let entry = ReadinessEntryBuilder.live(
      from: [
        makeSummary(1, "sync_problem"), makeSummary(2, "sync_problem"),
        makeSummary(3, "needs_previews"),
      ], fetchedAt: fetchedAt)

    #expect(entry.syncProblemCount == 2)
    #expect(entry.syncProblemCount == entry.count(for: .syncProblem))
  }

  /// A successful fetch that found no shoots is a LIVE reading of zero — a real answer with a
  /// real timestamp — and must never be confused with the never-fetched state.
  @Test("An empty response is all-zero counts in a live entry, not the no-data state")
  func emptyResponseIsZeroesNotNoData() {
    let entry = ReadinessEntryBuilder.live(from: [], fetchedAt: fetchedAt)

    #expect(entry.state == .live)
    #expect(entry.hasFetchedCounts)
    #expect(entry.fetchedAt == fetchedAt)
    #expect(entry.totalShoots == 0)
    #expect(entry.orderedCounts.map(\.count) == [0, 0, 0, 0, 0, 0])
  }

  @Test("The signed-out entry carries no counts and no fabricated timestamp")
  func signedOutHasNoTimestamp() {
    let now = fetchedAt.addingTimeInterval(600)
    let entry = ReadinessEntryBuilder.signedOut(at: now)

    #expect(entry.state == .signedOut)
    #expect(entry.fetchedAt == nil)
    #expect(!entry.hasFetchedCounts)
    #expect(entry.totalShoots == 0)
    #expect(entry.date == now)
  }

  @Test("The never-fetched entry carries no counts and no fabricated timestamp")
  func noDataHasNoTimestamp() {
    let now = fetchedAt.addingTimeInterval(600)
    let entry = ReadinessEntryBuilder.noData(at: now)

    #expect(entry.state == .noData)
    #expect(entry.fetchedAt == nil)
    #expect(!entry.hasFetchedCounts)
    #expect(entry.totalShoots == 0)
  }

  /// The state a locked device renders: the counts and their REAL age survive; only the
  /// timeline date moves. "Live" never means "the refresh deadline passed".
  @Test("A last-known entry re-dates to now but keeps the original fetch time and counts")
  func lastKnownKeepsTheOriginalFetchTime() {
    let now = fetchedAt.addingTimeInterval(3600)
    let previous = ReadinessEntryBuilder.live(
      from: [makeSummary(1, "ready_to_review")], fetchedAt: fetchedAt)
    let entry = ReadinessEntryBuilder.lastKnown(carrying: previous, at: now)

    #expect(entry.state == .lastKnown)
    #expect(entry.date == now)
    #expect(entry.fetchedAt == fetchedAt)
    #expect(entry.count(for: .readyToReview) == 1)
    #expect(entry.hasFetchedCounts)
  }

  @Test("A last-known built from an entry that never held fetched counts degrades to no-data")
  func lastKnownFromPlaceholderDegrades() {
    let now = fetchedAt.addingTimeInterval(3600)
    let entry = ReadinessEntryBuilder.lastKnown(
      carrying: ReadinessEntryBuilder.signedOut(at: fetchedAt), at: now)

    #expect(entry.state == .noData)
    #expect(entry.fetchedAt == nil)
  }

  @Test("Across every state: a timestamp exists if and only if the counts were really fetched")
  func timestampExistsOnlyWithFetchedCounts() {
    let live = ReadinessEntryBuilder.live(from: [], fetchedAt: fetchedAt)
    let entries = [
      live,
      ReadinessEntryBuilder.lastKnown(carrying: live, at: fetchedAt.addingTimeInterval(60)),
      ReadinessEntryBuilder.signedOut(at: fetchedAt),
      ReadinessEntryBuilder.noData(at: fetchedAt),
    ]
    for entry in entries {
      #expect((entry.fetchedAt != nil) == entry.hasFetchedCounts)
    }
  }
}
