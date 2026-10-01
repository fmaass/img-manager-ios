import Foundation

/// WP31 P2 (IMGMGR-461): one pass's own counts — the plan's Pass Summary, never shoot-wide
/// remaining/reviewed (the client holds no unmarked count for unloaded pages).
///
/// Counted from the pass log a CLOSED pass froze (`TriagePassResult.actions`), which already is
/// the net of undos — an Undo pops its action — and holds no late commit: a mark whose write
/// commits only after the pass closed is never logged (plan decision 7), so it stands on the
/// server and in the grid but not here. The sheet's copy says "this pass" for that reason.
struct PassSummary: Equatable, Sendable {
  let picks: Int
  let dislikes: Int
  let skipped: Int

  /// The marks this pass wrote: picks + dislikes. A Skip writes nothing.
  var marked: Int { picks + dislikes }

  init(picks: Int, dislikes: Int, skipped: Int) {
    self.picks = picks
    self.dislikes = dislikes
    self.skipped = skipped
  }

  init(actions: [TriagePassAction]) {
    var picks = 0
    var dislikes = 0
    var skipped = 0
    for action in actions {
      switch action.verdict {
      case .pick: picks += 1
      case .dislike: dislikes += 1
      case .skip: skipped += 1
      }
    }
    self.init(picks: picks, dislikes: dislikes, skipped: skipped)
  }

  init(result: TriagePassResult) {
    self.init(actions: result.actions)
  }
}

/// What the Pass Summary sheet shows, frozen when the pass ended (plan decision 4): the counts,
/// whether the pass completed, the shoot's name, and the Handoff payload the sheet advertises.
struct PassSummaryPresentation: Identifiable, Equatable, Sendable {
  let id: UUID
  let summary: PassSummary
  let completed: Bool
  let folderTitle: String
  let handoff: TriageActivity?

  /// Decision 4: a pass that ended with at least one action has a summary; with none it just
  /// closes (nil).
  static func make(
    result: TriagePassResult, folderID: Int?, tier: GridSourceTier?, folderTitle: String,
    pool: [Int]
  ) -> PassSummaryPresentation? {
    guard !result.actions.isEmpty else { return nil }
    return PassSummaryPresentation(
      id: UUID(), summary: PassSummary(result: result), completed: result.completed,
      folderTitle: folderTitle,
      handoff: TriageActivity.advertised(
        folderID: folderID, tier: tier, imageID: result.continuationImageID, pool: pool,
        completed: result.completed))
  }
}

/// The sheet's words, pure so a test reads them directly.
enum PassSummaryCopy {
  static func title(completed: Bool) -> String {
    completed ? "Pass finished" : "Pass summary"
  }

  static func marked(_ count: Int) -> String {
    "You marked \(count) this pass"
  }

  static let handoffTitle = "Continue on iPad"
  /// Decision 5: a row that EXPLAINS Handoff — iOS has no API to push an activity to another
  /// device, so nothing here "sends".
  static let handoffDetail =
    "This shoot opens in the culling loupe where you left off. Your iPad shows img-manager in "
    + "its Dock or app switcher while this summary is open."
}
