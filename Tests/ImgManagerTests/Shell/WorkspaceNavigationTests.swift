import Testing

@testable import ImgManager

/// WP28 P1 (IMGMGR-448): the Compact shell's one-grid-host rule and its width transitions.
///
/// The rule under test: one `GridStore`, three stacks, so at most one stack may show the
/// workspace — and a stack retained behind another tab can never be left showing a shoot the
/// store no longer holds.
@MainActor
@Suite("WorkspaceNavigation — one grid host across the Compact tabs")
struct WorkspaceNavigationTests {

  /// Records every call into the routing seam, so a test can say the ONE path was taken.
  private final class RouteSpy {
    var calls: [String] = []
    func route(_ folderID: Int, _ tier: GridSourceTier?) {
      calls.append("\(folderID)|\(tier?.rawValue ?? "nil")")
    }
  }

  @Test("launches on Shoots with no host and every stack at its root")
  func launchState() {
    let nav = WorkspaceNavigation()
    #expect(nav.activeTab == .shoots)
    #expect(nav.gridHost == nil)
    for tab in CompactTab.allCases {
      #expect(nav.path(for: tab).isEmpty)
    }
  }

  @Test("open routes through the one seam exactly once, then hosts the grid in that tab")
  func openRoutesOnceAndHosts() {
    let nav = WorkspaceNavigation()
    let spy = RouteSpy()
    nav.open(folderID: 1, tier: .local, from: .shoots, via: spy.route)
    #expect(spy.calls == ["1|local"])
    #expect(nav.gridHost == .shoots)
    #expect(nav.activeTab == .shoots)
    #expect(nav.path(for: .shoots) == [.workspace])
  }

  @Test("an unrecognised tier reaches the seam as nil, never an invented tier")
  func openPassesANilTierThrough() {
    let nav = WorkspaceNavigation()
    let spy = RouteSpy()
    nav.open(folderID: 21, tier: nil, from: .library, via: spy.route)
    #expect(spy.calls == ["21|nil"])
    #expect(nav.gridHost == .library)
  }

  @Test("A then B from another tab: B's tab hosts, A's stack is cleared (the A→B→return case)")
  func openingFromAnotherTabClearsTheFormerHost() {
    let nav = WorkspaceNavigation()
    let spy = RouteSpy()
    nav.open(folderID: 1, tier: .local, from: .shoots, via: spy.route)
    nav.activeTab = .library
    nav.open(folderID: 2, tier: .local, from: .library, via: spy.route)
    #expect(spy.calls == ["1|local", "2|local"])
    #expect(nav.gridHost == .library)
    #expect(nav.path(for: .shoots).isEmpty)
    #expect(nav.path(for: .library) == [.workspace])
    nav.activeTab = .shoots
    #expect(nav.path(for: .shoots).isEmpty)
  }

  @Test("open clears every other tab")
  func openClearsEveryOtherTab() {
    let nav = WorkspaceNavigation()
    let spy = RouteSpy()
    nav.open(folderID: 3, tier: .local, from: .library, via: spy.route)
    nav.open(folderID: 5, tier: .local, from: .shoots, via: spy.route)
    #expect(nav.path(for: .library).isEmpty)
    #expect(nav.path(for: .shoots) == [.workspace])
  }

  @Test("popping the host's stack leaves no host")
  func poppingTheHostReleasesIt() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .library)
    nav.setPath([], for: .library)
    #expect(nav.gridHost == nil)
    #expect(nav.path(for: .library).isEmpty)
  }

  @Test("popping a stack that is not the host leaves the host alone")
  func poppingANonHostKeepsTheHost() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .library)
    nav.setPath([], for: .shoots)
    #expect(nav.gridHost == .library)
    #expect(nav.path(for: .library) == [.workspace])
  }

  @Test("a non-host stack can never push the workspace behind the rule's back")
  func aNonHostPushIsRefused() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .library)
    nav.setPath([.workspace], for: .shoots)
    #expect(nav.path(for: .shoots).isEmpty)
    #expect(nav.gridHost == .library)
  }

  @Test("showSelectedShoot makes the tab active as well as the host")
  func showSelectedShootActivatesTheTab() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .library)
    #expect(nav.activeTab == .library)
    #expect(nav.gridHost == .library)
  }

  @Test("Regular→Compact with a selected shoot lands on its grid in Library")
  func regularToCompactWithASelection() {
    let nav = WorkspaceNavigation()
    nav.applyLayoutChange(from: .regular2, to: .compact, hasSelectedShoot: true)
    #expect(nav.gridHost == .library)
    #expect(nav.activeTab == .library)
    #expect(nav.path(for: .library) == [.workspace])
    #expect(nav.path(for: .shoots).isEmpty)
  }

  @Test("Regular-3→Compact behaves exactly as Regular-2→Compact")
  func regularThreeToCompact() {
    let nav = WorkspaceNavigation()
    nav.applyLayoutChange(from: .regular3, to: .compact, hasSelectedShoot: true)
    #expect(nav.gridHost == .library)
  }

  @Test("Regular→Compact without a selection leaves every stack at its root")
  func regularToCompactWithoutASelection() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .shoots)
    nav.applyLayoutChange(from: .regular2, to: .compact, hasSelectedShoot: false)
    #expect(nav.gridHost == nil)
    for tab in CompactTab.allCases {
      #expect(nav.path(for: tab).isEmpty)
    }
  }

  @Test("Compact→Regular changes nothing: the split's detail shows the selection itself")
  func compactToRegularKeepsState() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .shoots)
    nav.applyLayoutChange(from: .compact, to: .regular2, hasSelectedShoot: true)
    #expect(nav.gridHost == .shoots)
    #expect(nav.activeTab == .shoots)
    #expect(nav.path(for: .shoots) == [.workspace])
  }

  @Test("a change between the two Regular modes touches nothing")
  func regularToRegularIsANoOp() {
    let nav = WorkspaceNavigation()
    nav.applyLayoutChange(from: .regular2, to: .regular3, hasSelectedShoot: true)
    #expect(nav.gridHost == nil)
    #expect(nav.activeTab == .shoots)
  }

  @Test("Compact→Compact (a width change inside Compact) touches nothing")
  func compactToCompactIsANoOp() {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: .shoots)
    nav.applyLayoutChange(from: .compact, to: .compact, hasSelectedShoot: true)
    #expect(nav.gridHost == .shoots)
  }

  /// Final audit F4: `RootView`'s erase hook calls this beside the queue's and the tree's own
  /// `endSession()`, so the next account starts where a launch does.
  @Test("endSession returns to the launch state: Shoots, no host, every stack at its root")
  func endSessionResetsToLaunchState() {
    let nav = WorkspaceNavigation()
    nav.open(folderID: 4, tier: nil, from: .library) { _, _ in }
    #expect(nav.path(for: .library) == [.workspace])
    nav.activeTab = .library
    nav.endSession()
    #expect(nav.activeTab == .shoots)
    #expect(nav.gridHost == nil)
    for tab in CompactTab.allCases {
      #expect(nav.path(for: tab).isEmpty)
    }
  }

  // MARK: - WP442 P12 (IMGMGR-540): the scene route is a projection of the store

  private let base: [WorkspaceRoute] = [.workspace]
  private let inScene5: [WorkspaceRoute] = [.workspace, .scene(5)]

  private func hosted(_ tab: CompactTab = .shoots) -> WorkspaceNavigation {
    let nav = WorkspaceNavigation()
    nav.showSelectedShoot(in: tab)
    return nav
  }

  /// R1 · kills M15 (an effect computed without the projection: no leave on a Back).
  @Test("R1 — the system Back out of a scene leaves it and keeps the host")
  func systemBackFromTheSceneLeavesIt() {
    let nav = hosted()
    #expect(nav.presentedPath(for: .shoots, entered: 5) == inScene5)
    let effect = nav.applyStackWrite(base, for: .shoots, entered: 5)
    #expect(effect == StackWriteEffect(leavesScene: true, popsHost: false))
    #expect(nav.gridHost == .shoots)
    #expect(nav.path(for: .shoots) == base)
    #expect(nav.presentedPath(for: .shoots, entered: nil) == base)
  }

  /// R2 · kills M15: the edge swipe reaches the binding as the very same write.
  @Test("R2 — an edge swipe is the same binding write, from any hosting tab")
  func anEdgeSwipeIsTheSameWrite() {
    let nav = hosted(.library)
    let effect = nav.applyStackWrite(base, for: .library, entered: 5)
    #expect(effect.leavesScene)
    #expect(!effect.popsHost)
    #expect(nav.gridHost == .library)
  }

  /// R3 · kills M15 (pop-to-root treated as a scene Back only).
  @Test("R3 — pop to root leaves the scene and releases the host")
  func popToRootLeavesAndUnhosts() {
    let nav = hosted()
    let effect = nav.applyStackWrite([], for: .shoots, entered: 5)
    #expect(effect == StackWriteEffect(leavesScene: true, popsHost: true))
    #expect(nav.gridHost == nil)
    #expect(nav.presentedPath(for: .shoots, entered: 5).isEmpty)
  }

  /// R4 · kills M15 (`applyStackWrite` ignores the echo).
  @Test("R4 — the stack echoing the projection back is a no-op")
  func anEchoIsANoOp() {
    let nav = hosted()
    #expect(nav.applyStackWrite(inScene5, for: .shoots, entered: 5) == .none)
    #expect(nav.path(for: .shoots) == base)
    #expect(nav.gridHost == .shoots)
  }

  /// R5 · kills M15: a pop that finishes after the store already left produces no second leave.
  @Test("R5 — a stale scene write after the store left is ignored")
  func aStaleSceneWriteAfterTheStoreLeftIsIgnored() {
    let nav = hosted()
    #expect(nav.applyStackWrite(base, for: .shoots, entered: nil) == .none)
    #expect(nav.applyStackWrite(inScene5, for: .shoots, entered: nil) == .none)
    #expect(nav.path(for: .shoots) == base, "a stale .scene was stored in the base path")
    #expect(nav.presentedPath(for: .shoots, entered: nil) == base)
  }

  /// R6 · kills M14 (`showSelectedShoot` writes `.scene` into the base).
  @Test("R6 — a programmatic host replacement is not a Back")
  func programmaticHostReplacementIsNotABack() {
    let nav = hosted(.library)
    nav.showSelectedShoot(in: .shoots)
    #expect(nav.path(for: .shoots) == base)
    #expect(nav.presentedPath(for: .shoots, entered: 5) == inScene5)
    #expect(nav.presentedPath(for: .library, entered: 5).isEmpty)
    #expect(nav.applyStackWrite(inScene5, for: .shoots, entered: 5) == .none)
  }

  /// R7 · kills M16 (the projection ignores `gridHost`).
  @Test("R7 — Regular→Compact presents the entered scene on the new host only")
  func regularToCompactPresentsTheEnteredScene() {
    let nav = WorkspaceNavigation()
    nav.applyLayoutChange(from: .regular2, to: .compact, hasSelectedShoot: true)
    #expect(nav.presentedPath(for: .library, entered: 5) == inScene5)
    #expect(nav.presentedPath(for: .shoots, entered: 5).isEmpty)
  }

  /// R8 · kills M14: Compact→Regular writes nothing, the entry is the store's alone.
  @Test("R8 — Compact→Regular writes no path")
  func compactToRegularWritesNothing() {
    let nav = hosted()
    nav.applyLayoutChange(from: .compact, to: .regular3, hasSelectedShoot: true)
    #expect(nav.path(for: .shoots) == base)
    #expect(nav.gridHost == .shoots)
    #expect(nav.presentedPath(for: .shoots, entered: 5) == inScene5)
  }

  /// R9 · kills M15: a retarget changes the projection in one step and its echo is a no-op.
  @Test("R9 — a topology retarget is not a pop")
  func aTopologyRetargetIsNotAPop() {
    let nav = hosted()
    #expect(nav.presentedPath(for: .shoots, entered: 5) == inScene5)
    #expect(nav.presentedPath(for: .shoots, entered: 9) == [.workspace, .scene(9)])
    #expect(nav.applyStackWrite([.workspace, .scene(9)], for: .shoots, entered: 9) == .none)
    #expect(nav.path(for: .shoots) == base)
  }

  /// R10 · kills M16: no host after the session ends, so no scene is presented anywhere.
  @Test("R10 — endSession drops the scene from every stack")
  func endSessionDropsTheScene() {
    let nav = hosted()
    nav.endSession()
    for tab in CompactTab.allCases {
      #expect(nav.presentedPath(for: tab, entered: 5).isEmpty)
    }
  }

  /// R11 · the `.group` route exists (P13's entry) with no UI and no projection.
  @Test("R11 — the group route is hashable and never projected or stored")
  func groupRouteIsHashableAndNeverProjected() {
    let a = WorkspaceRoute.group(key: "camera", value: "X-T5")
    #expect(Set([a, .group(key: "camera", value: "X-T5")]).count == 1)
    #expect(a != .group(key: "camera", value: "X-H2"))
    #expect(a.isEntry && !a.isScene)
    let nav = hosted()
    #expect(!nav.presentedPath(for: .shoots, entered: 5).contains(a))
    _ = nav.applyStackWrite([.workspace, a], for: .shoots, entered: nil)
    #expect(nav.path(for: .shoots) == base)
  }
}
