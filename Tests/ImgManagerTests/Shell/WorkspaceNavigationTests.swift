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
    nav.open(folderID: 21, tier: nil, from: .search, via: spy.route)
    #expect(spy.calls == ["21|nil"])
    #expect(nav.gridHost == .search)
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

  @Test("open clears EVERY other tab, including one that never hosted")
  func openClearsEveryOtherTab() {
    let nav = WorkspaceNavigation()
    let spy = RouteSpy()
    nav.open(folderID: 3, tier: .local, from: .search, via: spy.route)
    nav.open(folderID: 5, tier: .local, from: .shoots, via: spy.route)
    #expect(nav.path(for: .search).isEmpty)
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
    nav.showSelectedShoot(in: .search)
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
}

@MainActor
@Suite("FolderSearchModel — one query shared across tab switches")
struct FolderSearchModelTests {
  @Test("starts empty and keeps what was typed")
  func keepsItsText() {
    let search = FolderSearchModel()
    #expect(search.text.isEmpty)
    search.text = "Wandern"
    #expect(search.text == "Wandern")
  }
}
