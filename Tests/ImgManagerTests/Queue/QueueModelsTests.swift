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

  @Test("Within a section: last_touched descending, nulls last, folder_id tiebreak")
  func withinSectionSort() {
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)
    let items = [
      makeSummary(folderId: 5, readiness: "ready_to_review", lastTouched: nil),
      makeSummary(folderId: 3, readiness: "ready_to_review", lastTouched: older),
      makeSummary(folderId: 1, readiness: "ready_to_review", lastTouched: newer),
      makeSummary(folderId: 2, readiness: "ready_to_review", lastTouched: newer),
      makeSummary(folderId: 4, readiness: "ready_to_review", lastTouched: nil),
    ]
    let sections = QueueSort.sections(from: items)
    #expect(sections.count == 1)
    // newer group (folder_id tiebreak 1 before 2), then older, then nulls last (4 before 5).
    #expect(sections[0].items.map(\.folderId) == [1, 2, 3, 4, 5])
  }

}
