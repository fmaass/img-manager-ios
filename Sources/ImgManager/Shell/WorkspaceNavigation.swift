import Foundation
import Observation

/// The one destination a Compact tab's stack can push: the shared workspace (`WorkspaceContent`).
enum WorkspaceRoute: Hashable, Sendable {
  case workspace
  /// WP442 P12: the entered scene, pushed over the workspace. Never STORED in `paths`: it is
  /// projected from the grid store (`presentedPath(for:entered:)`).
  case scene(Int)
  /// IMGMGR-541 (P13): the Mark/Rating remainder, pushed over the workspace like a scene. Never
  /// STORED in `paths`: projected from the grid store's entry (`presentedPath(for:enteredRoute:)`).
  case group(key: String, value: String)

  var isScene: Bool {
    guard case .scene = self else { return false }
    return true
  }

  var isEntry: Bool {
    switch self {
    case .workspace: return false
    case .scene, .group: return true
    }
  }
}

/// What one user-initiated stack write means for the store and the host.
struct StackWriteEffect: Equatable, Sendable {
  var leavesScene: Bool
  var popsHost: Bool

  static let none = StackWriteEffect(leavesScene: false, popsHost: false)
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

  /// WP442 P12 (§2.2): the path a tab's stack SHOWS — the stored base path, plus the entered
  /// scene on the grid host's stack. A pure projection of the store; nothing writes it back.
  func presentedPath(for tab: CompactTab, entered: Int?) -> [WorkspaceRoute] {
    presentedPath(for: tab, enteredRoute: entered.map(WorkspaceRoute.scene))
  }

  /// IMGMGR-541: the same projection for any entry — the entered scene or the remainder route.
  func presentedPath(for tab: CompactTab, enteredRoute: WorkspaceRoute?) -> [WorkspaceRoute] {
    let base = path(for: tab)
    guard tab == gridHost, base == [.workspace], let enteredRoute, enteredRoute.isEntry else {
      return base
    }
    return base + [enteredRoute]
  }

  /// A USER stack write (Back, edge swipe, pop to root) — SwiftUI calls the binding's setter only
  /// for those. Stores the base path (scene/group stripped) and says what the store must do.
  func applyStackWrite(
    _ newPath: [WorkspaceRoute], for tab: CompactTab, entered: Int?
  ) -> StackWriteEffect {
    applyStackWrite(newPath, for: tab, enteredRoute: entered.map(WorkspaceRoute.scene))
  }

  /// `leavesScene` means "leaves the ENTRY" — a scene or the remainder (IMGMGR-541).
  func applyStackWrite(
    _ newPath: [WorkspaceRoute], for tab: CompactTab, enteredRoute: WorkspaceRoute?
  ) -> StackWriteEffect {
    let presented = presentedPath(for: tab, enteredRoute: enteredRoute)
    guard newPath != presented else { return .none }
    let wasHost = gridHost == tab
    let showedScene = presented.contains(where: \.isEntry)
    let keepsScene = newPath.contains(where: \.isEntry)
    setPath(newPath.filter { !$0.isEntry }, for: tab)
    var effect = StackWriteEffect.none
    effect.leavesScene = showedScene && !keepsScene
    effect.popsHost = wasHost && newPath.isEmpty
    return effect
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
