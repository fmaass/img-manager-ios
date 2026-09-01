import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

@Suite("QueueModels — readiness sections, sync worst-present, sort (Q1/Q2/Q4)")
struct QueueModelsTests {

  private func makeSummary(
    folderId: Int, readiness: String, lastTouched: Date? = nil,
    sync: Components.Schemas.FolderSyncCounts? = nil, nothingLeftUnmarked: Bool = false
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: lastTouched, nothingLeftUnmarked: nothingLeftUnmarked, path: "p/\(folderId)",
      picked: 0, previewOutstanding: 0, readiness: .init(rawValue: readiness)!,
      sourceTier: "local", sync: sync, total: 10, unmarked: 10, withMasters: 0)
  }

  // MARK: - ReadinessSection

  @Test("displayOrder is the exact Q1 binding order")
  func displayOrderMatchesBinding() {
    #expect(
      ReadinessSection.displayOrder == [
        .reviewInProgress, .readyToReview, .syncProblem,
        .readyForEditing, .needsPreviews, .historicalUnreviewed,
      ])
  }

  @Test("First three (display order) default-expanded, remaining three default-collapsed")
  func defaultExpansion() {
    #expect(ReadinessSection.reviewInProgress.isDefaultExpanded)
    #expect(ReadinessSection.readyToReview.isDefaultExpanded)
    #expect(ReadinessSection.syncProblem.isDefaultExpanded)
    #expect(!ReadinessSection.readyForEditing.isDefaultExpanded)
    #expect(!ReadinessSection.needsPreviews.isDefaultExpanded)
    #expect(!ReadinessSection.historicalUnreviewed.isDefaultExpanded)
  }

  @Test("ReadinessSection round-trips every live/schema readiness string verbatim")
  func rawValuesMatchSchema() {
    let schemaValues = [
      "needs_previews", "historical_unreviewed", "ready_to_review", "review_in_progress",
      "sync_problem", "ready_for_editing",
    ]
    for value in schemaValues {
      #expect(ReadinessSection(rawValue: value) != nil, "schema value \(value) must map")
    }
    #expect(ReadinessSection(rawValue: "made_up_value") == nil)
  }

  // MARK: - SyncSignal (Q2)

  @Test("Precedence: refused wins over stale/never/synced")
  func precedenceRefused() {
    let sync = Components.Schemas.FolderSyncCounts(never: 5, refused: 1, stale: 2, synced: 3)
    #expect(SyncSignal.compute(from: sync) == SyncSignal(kind: .refused, count: 1))
  }

  @Test("Precedence: stale wins over never/synced when refused is zero")
  func precedenceStale() {
    let sync = Components.Schemas.FolderSyncCounts(never: 5, refused: 0, stale: 2, synced: 3)
    #expect(SyncSignal.compute(from: sync) == SyncSignal(kind: .stale, count: 2))
  }

  @Test("Precedence: never wins over synced when refused/stale are zero")
  func precedenceNever() {
    let sync = Components.Schemas.FolderSyncCounts(never: 5, refused: 0, stale: 0, synced: 3)
    #expect(SyncSignal.compute(from: sync) == SyncSignal(kind: .never, count: 5))
  }

  @Test("Precedence: synced shown only when the other three are all zero")
  func precedenceSynced() {
    let sync = Components.Schemas.FolderSyncCounts(never: 0, refused: 0, stale: 0, synced: 12)
    #expect(SyncSignal.compute(from: sync) == SyncSignal(kind: .synced, count: 12))
  }

  @Test("All-zero rollup renders NO signal — never presented as synced")
  func allZeroIsNoSignal() {
    let sync = Components.Schemas.FolderSyncCounts(never: 0, refused: 0, stale: 0, synced: 0)
    #expect(SyncSignal.compute(from: sync) == nil)
  }

  @Test("Absent (nil) rollup renders NO signal")
  func absentIsNoSignal() {
    #expect(SyncSignal.compute(from: nil) == nil)
  }

  @Test("The count shown is the server's OWN count for that state, never a sum")
  func countIsNeverSummed() {
    let sync = Components.Schemas.FolderSyncCounts(never: 0, refused: 7, stale: 9, synced: 0)
    let signal = SyncSignal.compute(from: sync)
    #expect(signal?.count == 7)  // not 7+9
  }

  // MARK: - QueueSort (Q1/Q4)

  @Test("Zero-item sections are omitted entirely")
  func emptySectionsOmitted() {
    let items = [makeSummary(folderId: 1, readiness: "ready_to_review")]
    let sections = QueueSort.sections(from: items)
    #expect(sections.map(\.section) == [.readyToReview])
  }

  @Test("Sections render in the exact Q1 display order regardless of input order")
  func sectionOrderIsFixed() {
    let items = [
      makeSummary(folderId: 1, readiness: "historical_unreviewed"),
      makeSummary(folderId: 2, readiness: "review_in_progress"),
      makeSummary(folderId: 3, readiness: "needs_previews"),
    ]
    let sections = QueueSort.sections(from: items)
    #expect(sections.map(\.section) == [.reviewInProgress, .needsPreviews, .historicalUnreviewed])
  }

  /// IMGMGR-264 (owner directive, 2026-08-31): the ORDER is the server's — `/api/folder-summaries`
  /// returns folders by name descending (names are dates, so newest first) with a `folder_id`
  /// tiebreak, and the client's job is grouping ONLY. The shipped client re-sorted by
  /// `last_touched` descending, which is a different question entirely ("what did I touch last",
  /// not "which shoot is newest") and silently overrode whatever order the server chose.
  ///
  /// `last_touched` here deliberately CONTRADICTS the response order — the most recently touched
  /// folder is served last — so a surviving client sort is visible rather than coincidental.
  @Test("Within a section the SERVER's order is preserved verbatim — no client re-sort")
  func withinSectionServerOrderIsPreserved() {
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)
    let items = [
      makeSummary(folderId: 5, readiness: "ready_to_review", lastTouched: nil),  // "2026-08-31"
      makeSummary(folderId: 3, readiness: "ready_to_review", lastTouched: older),  // "2026-08-30"
      makeSummary(folderId: 1, readiness: "ready_to_review", lastTouched: newer),  // "2026-08-29"
    ]
    let sections = QueueSort.sections(from: items)
    #expect(sections.count == 1)
    #expect(sections[0].items.map(\.folderId) == [5, 3, 1])
  }

  /// The other half of "grouping only": splitting an interleaved response into sections must not
  /// disturb the relative order WITHIN each section either. The folder ids descend in the
  /// response, so the old `folder_id`-ascending tiebreak (the shipped comparator's answer when
  /// `last_touched` is absent on every row) reverses both sections and is visible here.
  @Test("Grouping an interleaved response is order-preserving inside every section")
  func groupingPreservesOrderWithinEachSection() {
    let items = [
      makeSummary(folderId: 40, readiness: "review_in_progress", lastTouched: nil),
      makeSummary(folderId: 30, readiness: "ready_to_review", lastTouched: nil),
      makeSummary(folderId: 20, readiness: "review_in_progress", lastTouched: nil),
      makeSummary(folderId: 10, readiness: "ready_to_review", lastTouched: nil),
    ]
    let sections = QueueSort.sections(from: items)
    #expect(sections.map(\.section) == [.reviewInProgress, .readyToReview])
    #expect(sections[0].items.map(\.folderId) == [40, 20])
    #expect(sections[1].items.map(\.folderId) == [30, 10])
  }

  // MARK: - QueueCardDestination (diff-gate round 3 closure, B1)

  @Test(
    "A queue card's destination always clears the tier, even matching a prior tree selection"
  )
  func queueCardDestinationAlwaysClearsTier() {
    let summary = makeSummary(folderId: 6, readiness: "ready_to_review")
    let archiveSummary = Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: 7, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/7", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!, sourceTier: "archive",
      sync: nil, total: 10, unmarked: 10, withMasters: 0)

    #expect(QueueCardDestination.route(for: summary) == (folderID: 6, sourceTier: nil))
    #expect(QueueCardDestination.route(for: archiveSummary) == (folderID: 7, sourceTier: nil))
  }

}
