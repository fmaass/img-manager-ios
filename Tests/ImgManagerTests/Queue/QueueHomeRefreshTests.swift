import Testing

@testable import ImgManager

/// IMGMGR-350 P2: one pull-to-refresh on the home refreshes the summaries AND re-runs the tree
/// load. Before this story the gesture ran the summaries only — survivable while the tree was a
/// collapsed disclosure below them, and the home's own staleness once the tree IS the home.
///
/// What this can pin and what it cannot, stated plainly: the tree's load is SwiftUI view state,
/// so `QueueHomeRefresh` is the seam a test can reach and `TierHomeUITests` walks the surface.
/// Delete either call from `run` and this goes red; nothing here re-implements what those calls
/// do, and the expected order is a literal, not a value read back out of the type under test.
@MainActor
@Suite("Pull-to-refresh on the tree home (IMGMGR-350)")
struct QueueHomeRefreshTests {

  @MainActor
  private final class Spy {
    var events: [String] = []
  }

  @Test("one gesture runs the summaries refresh and the tree reload, in that order")
  func oneGestureRunsBothHalves() async {
    let spy = Spy()

    await QueueHomeRefresh.run(
      summaries: { spy.events.append("summaries") },
      tree: { spy.events.append("tree") })

    #expect(spy.events == ["summaries", "tree"])
  }
}
