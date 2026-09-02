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

  @Test("the tree renders in every phase except the summaries' own first load")
  func theTreeRendersUnlessTheSummariesAreStillOnTheirFirstLoad() {
    #expect(QueueHomePresentation.showsFirstLoadSpinner(for: .initialLoading))
    #expect(!QueueHomePresentation.rendersTree(for: .initialLoading))

    #expect(QueueHomePresentation.rendersTree(for: .reachable))
    #expect(QueueHomePresentation.rendersTree(for: .unreachableStale))
    // The one this finding is about: no cached summaries AT ALL is still a home with a tree in
    // it, because the tree never came from the summaries.
    #expect(QueueHomePresentation.rendersTree(for: .unreachableNoCache))
    #expect(!QueueHomePresentation.showsFirstLoadSpinner(for: .unreachableNoCache))
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
