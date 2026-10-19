import Foundation
import Observation

/// The one destination a Compact tab's stack can push: the shared workspace (`WorkspaceContent`).
enum WorkspaceRoute: Hashable, Sendable {
  case workspace
}

/// WP28 P1 (IMGMGR-448): the Compact shell's navigation state, and the explicit ownership rule
/// for the ONE `GridStore` every tab shares.
///
/// The tabs each keep their own stack, but there is one grid store, so at most one stack may
/// show the workspace at a time: `gridHost` names it. Opening a shoot from any tab routes through
/// the caller's single `selectShoot` path, makes that tab the host and CLEARS every other tab's
/// path — so a stack retained behind another tab can never be showing a different shoot's store
/// when the reader switches back to it.
///
/// Owned by `RootView` (one instance for the scene) and read by `CompactShell`; the Regular split
/// never reads it, which is why a width change is the only other thing that writes it.
@MainActor
@Observable
final class WorkspaceNavigation {
  var activeTab: CompactTab = .shoots
  private(set) var gridHost: CompactTab?
  private(set) var paths: [CompactTab: [WorkspaceRoute]] = [:]

  func path(for tab: CompactTab) -> [WorkspaceRoute] {
    paths[tab] ?? []
  }

  /// The stack's own writes (a Back tap, a swipe back). Popping the host's stack leaves no tab
  /// hosting the workspace; a path this type did not hand out is never accepted for a tab that
  /// is not the host, so no stack can push the workspace behind the ownership rule's back.
  func setPath(_ path: [WorkspaceRoute], for tab: CompactTab) {
    if path.isEmpty {
      paths[tab] = []
      if gridHost == tab { gridHost = nil }
    } else if gridHost == tab {
      paths[tab] = path
    }
  }

  /// A row tap in `tab`: the shoot is selected through `route` — the caller's ONE path into
  /// `GridStore.selectShoot(folderID:sourceTier:)` — and then shown in that tab.
  func open(
    folderID: Int, tier: GridSourceTier?, from tab: CompactTab,
    via route: (Int, GridSourceTier?) -> Void
  ) {
    route(folderID, tier)
    showSelectedShoot(in: tab)
  }

  /// Makes `tab` the grid host showing the ALREADY-selected shoot, and the active tab. Every other
  /// tab's stack is emptied. Used by `open` and by the entries that select without a row tap
  /// (a restored window's shoot, the DEBUG fixture's auto-select, a Regular→Compact change).
  func showSelectedShoot(in tab: CompactTab) {
    gridHost = tab
    activeTab = tab
    for other in CompactTab.allCases where other != tab {
      paths[other] = []
    }
    paths[tab] = [.workspace]
  }

  /// A width change. Regular→Compact with a shoot selected lands on that shoot's grid in Library
  /// (the tab that holds the tree the split's sidebar was); without one, the tabs stay at their
  /// roots. Compact→Regular changes nothing here: the selection lives in `GridStore`, and the
  /// split's detail column shows it without asking this type.
  func applyLayoutChange(from old: LayoutMode, to new: LayoutMode, hasSelectedShoot: Bool) {
    guard old != .compact, new == .compact else { return }
    if hasSelectedShoot {
      showSelectedShoot(in: .library)
    } else {
      gridHost = nil
      for tab in CompactTab.allCases { paths[tab] = [] }
    }
  }

  /// The session boundary (sign-out, erased credentials), called beside
  /// `QueueStore.endSession()` and `FolderTreeState.endSession()`. This object is `RootView`'s
  /// and outlives the session, so without it the next account would open on the previous one's
  /// tab and on a stack still pushed onto a shoot it cannot see. Back to the launch state.
  func endSession() {
    activeTab = .shoots
    gridHost = nil
    paths = [:]
  }
}
