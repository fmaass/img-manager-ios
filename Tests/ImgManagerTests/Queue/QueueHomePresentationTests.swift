import Testing

@testable import ImgManager

/// IMGMGR-350 checkpoint-2, finding B1: what the tree home renders for one SUMMARIES phase.
///
/// The defect these pin: `QueueView` switched its whole surface on `QueueStore.phase`, so a
/// `/api/folder-summaries` outage replaced the home with "Not connected" even when `/api/folders`
/// had answered and the tree was ready to draw. Since IMGMGR-350 the summaries are not the home's
/// data — the folder tree is, with its own load, its own failure state and its own retry — so a
/// summaries failure may degrade only what summaries feed.
@Suite("Queue home presentation — a summaries outage never blanks the tree (B1)")
struct QueueHomePresentationTests {

  /// Checkpoint-3 finding F1 sharpened B1: the tree renders in EVERY summaries phase, the first
  /// load included. `QueueStore.performLoad` returns to `.initialLoading` whenever there is
  /// nothing of its own on screen — which a "Try Again" tap after a summaries-only outage does —
  /// so a phase-gated home replaced a perfectly good tree with the summaries' centered spinner.
  /// Only the tree's OWN first load may show the tree's placeholder, and that is
  /// `FolderTreeLoad.phase`, not this one.
  @Test("the tree renders in every summaries phase, the first load included")
  func theTreeRendersInEverySummariesPhase() {
    #expect(QueueHomePresentation.rendersTree(for: .initialLoading))
    #expect(QueueHomePresentation.rendersTree(for: .reachable))
    #expect(QueueHomePresentation.rendersTree(for: .unreachableStale))
    // The one B1 was about: no cached summaries AT ALL is still a home with a tree in it,
    // because the tree never came from the summaries.
    #expect(QueueHomePresentation.rendersTree(for: .unreachableNoCache))
  }

  @Test("an unreachable summaries load says so above the tree, cached answer or not")
  func theDegradedNoticeCoversBothUnreachablePhases() {
    #expect(!QueueHomePresentation.showsDegradedBanner(for: .reachable))
    #expect(!QueueHomePresentation.showsDegradedBanner(for: .initialLoading))
    #expect(QueueHomePresentation.showsDegradedBanner(for: .unreachableStale))
    // Without this the no-cache phase would render a tree and say nothing at all about the
    // summaries being gone — the notice is the whole of what a reader is owed here.
    #expect(QueueHomePresentation.showsDegradedBanner(for: .unreachableNoCache))
  }
}
