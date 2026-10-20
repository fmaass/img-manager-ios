import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-389: the pinned "Needs review" section's membership and derivation.
///
/// A case per readiness value, not a case per outcome: the rule is a classification over the
/// server's six-value vocabulary, and a test that only pinned the two members would stay green
/// while a third value quietly joined them. `ReadinessSection.allCases` is walked as well, so a
/// value ADDED to the vocabulary cannot slip past this suite unclassified.
@Suite("NeedsReview — membership over the served readiness vocabulary (IMGMGR-389)")
struct NeedsReviewTests {

  private func makeSummary(
    folderId: Int, readiness: String, path: String? = nil
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: path ?? "photo_incoming/\(folderId)",
      picked: 0, previewOutstanding: 0, readiness: .init(rawValue: readiness)!,
      sourceTier: "local", sync: nil, total: 10, unmarked: 10, untouched: false, withMasters: 0)
  }

  // MARK: - The rule, one case per readiness value

  @Test("ready_to_review is a member — the shoot is waiting to be reviewed")
  func readyToReviewIsAMember() {
    #expect(NeedsReview.includes(.readyToReview))
  }

  @Test("review_in_progress is a member — the review is started and unfinished")
  func reviewInProgressIsAMember() {
    #expect(NeedsReview.includes(.reviewInProgress))
  }

  @Test("needs_previews is not a member — there is nothing to look at yet")
  func needsPreviewsIsNotAMember() {
    #expect(!NeedsReview.includes(.needsPreviews))
  }

  @Test("historical_unreviewed is not a member — the pre-app history would flood the section")
  func historicalUnreviewedIsNotAMember() {
    #expect(!NeedsReview.includes(.historicalUnreviewed))
  }

  @Test("sync_problem is not a member — a problem to fix, not a review to finish")
  func syncProblemIsNotAMember() {
    #expect(!NeedsReview.includes(.syncProblem))
  }

  @Test("ready_for_editing is not a member — reviewed, done")
  func readyForEditingIsNotAMember() {
    #expect(!NeedsReview.includes(.readyForEditing))
  }

  /// The whole vocabulary, so the set cannot widen by accident: exactly two of the six values are
  /// members, and they are these two (premise gate 2026-09-16, IMGMGR-389 comment 6913).
  @Test("exactly two of the six served readiness values are members")
  func exactlyTwoOfSixAreMembers() {
    let members = ReadinessSection.allCases.filter(NeedsReview.includes)
    #expect(Set(members) == [.readyToReview, .reviewInProgress])
    #expect(ReadinessSection.allCases.count == 6)
  }

  // MARK: - The section's derivation

  @Test("members are the summaries in the order they arrived — never re-sorted")
  func membersKeepTheServerOrder() {
    let summaries = [
      makeSummary(folderId: 7, readiness: "review_in_progress"),
      makeSummary(folderId: 2, readiness: "needs_previews"),
      makeSummary(folderId: 9, readiness: "ready_to_review"),
      makeSummary(folderId: 4, readiness: "sync_problem"),
      makeSummary(folderId: 1, readiness: "ready_to_review"),
    ]

    // 7, 9, 1 — the arrival order, not 1, 7, 9 and not the readiness display order. The server
    // orders `/api/folder-summaries` newest-first and both clients consume that one answer
    // (IMGMGR-264); a client-side re-sort answers a different question.
    #expect(NeedsReview.members(from: summaries).map(\.folderId) == [7, 9, 1])
  }

  @Test("the count is the number of members, never the number of shoots")
  func theCountIsTheMemberCount() {
    let summaries = [
      makeSummary(folderId: 1, readiness: "ready_to_review"),
      makeSummary(folderId: 2, readiness: "historical_unreviewed"),
      makeSummary(folderId: 3, readiness: "ready_for_editing"),
      makeSummary(folderId: 4, readiness: "review_in_progress"),
    ]

    #expect(NeedsReview.members(from: summaries).count == 2)
  }

  @Test("no summaries at all means no members — the section renders nothing")
  func noSummariesMeansNoMembers() {
    #expect(NeedsReview.members(from: []).isEmpty)
  }

  /// The state the empty section exists for, and the one `-UITestSummariesReviewed` drives: a
  /// healthy library whose every shoot is outside the set. Empty is the same fact as absent.
  @Test("a library with no shoot in the set has no members")
  func everyShootOutsideTheSetMeansNoMembers() {
    let summaries = [
      makeSummary(folderId: 1, readiness: "ready_for_editing"),
      makeSummary(folderId: 2, readiness: "needs_previews"),
      makeSummary(folderId: 3, readiness: "historical_unreviewed"),
      makeSummary(folderId: 4, readiness: "sync_problem"),
    ]

    #expect(NeedsReview.members(from: summaries).isEmpty)
  }

  // MARK: - What a row says and how it is addressed

  @Test("a row is named by the shoot leaf's own path segment")
  func rowNameIsTheLeafPathSegment() {
    let summary = makeSummary(
      folderId: 3, readiness: "ready_to_review", path: "photo_incoming/2026/2026-09-14-wandern")

    #expect(NeedsReview.shootName(for: summary) == "2026-09-14-wandern")

    // A path with no separator is its own name rather than an empty row.
    let unseparated = makeSummary(folderId: 4, readiness: "ready_to_review", path: "stub")
    #expect(NeedsReview.shootName(for: unseparated) == "stub")
  }

  /// The badge on a pinned row is the SAME string the tree's folder row shows for that shoot —
  /// one wording, from `FolderTreeRowPresentation`, never a second vocabulary.
  @Test("a row states the served readiness in the tree's own words")
  func rowStatesTheServedReadiness() {
    let summary = makeSummary(folderId: 1, readiness: "review_in_progress")

    #expect(FolderTreeRowPresentation.readinessBadge(for: summary) == "Review in progress")
    #expect(
      FolderTreeRowPresentation.readinessBadge(for: summary)
        == ReadinessSection.reviewInProgress.title)
  }

  @Test("identifiers are derived here and keyed by the server's folder id")
  func identifiersAreDerivedOnce() {
    #expect(NeedsReview.sectionIdentifier == "needsReviewSection")
    #expect(NeedsReview.countIdentifier == "needsReviewCount")
    #expect(NeedsReview.rowIdentifier(for: 21) == "needsReviewRow-21")
    #expect(NeedsReview.title == "Needs review")
  }

  // MARK: - The fixture the UI suite walks

  #if DEBUG
    /// `NeedsReviewSectionUITests` hard-codes the header count it expects, because a UI test may
    /// not reach into the app's own types for it. This is where that number is proved: the
    /// shipped fixture serves exactly two members, folder 1 and folder 21, in that order.
    @Test("the DEBUG fixture serves exactly two members, in server order")
    func theFixtureServesTwoMembers() {
      let members = NeedsReview.members(from: DebugStubTransport.fixtureSummaries())

      #expect(members.map(\.folderId) == [1, 21])
      #expect(members.count == 2)
    }

    /// And the other half of the UI suite: `-UITestSummariesReviewed` serves the SAME six shoots
    /// with none of them in the set, so an absent section is an empty membership rather than an
    /// empty screen.
    @Test("the all-reviewed fixture serves the same shoots and no members")
    func theReviewedFixtureServesNoMembers() {
      let reviewed = DebugStubTransport.reviewedFixtureSummaries()

      #expect(reviewed.map(\.folderId) == DebugStubTransport.fixtureSummaries().map(\.folderId))
      #expect(reviewed.allSatisfy { $0.readiness.rawValue == "ready_for_editing" })
      #expect(NeedsReview.members(from: reviewed).isEmpty)
    }
  #endif
}
