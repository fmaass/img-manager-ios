import SwiftUI

/// IMGMGR-478: the Regular sidebar's visibility, remembered across launches, and the grid bar's
/// own way back to it.
///
/// The Regular shell is one two-column `NavigationSplitView` in the default style (WP28 P2), so
/// the sidebar is a real column the reader can hide with the system toggle — and on iPadOS 26 that
/// toggle was the ONLY way back, which the owner could not find once the sidebar was gone (build
/// 20). Two answers, both decided here as values so a unit test pins them:
///
/// - the reader's choice is remembered: ONE boolean, "the Regular sidebar is hidden", in the
///   standard `UserDefaults` suite (`@AppStorage` on `RootView`). `UserDefaults`, not
///   `@SceneStorage`: the system discards a scene's restoration data when the reader force-quits
///   the app from the switcher, which is exactly the "kill + relaunch" this must survive. A
///   boolean, not the visibility itself: "shown" means `.all` at Regular-3 and `.doubleColumn` at
///   Regular-2, and that stays `LayoutResolver`'s answer for whatever width the next launch has;
/// - while the sidebar is hidden at Regular the grid's bar carries a labelled toggle in its
///   leading slot (p4128 draws "[sidebar toggle]" as the bar's first item). It is present only
///   while the sidebar is hidden: when the sidebar shows, the system toggle sits on the sidebar's
///   own bar, and a second one on the grid's bar would duplicate it and add a cluster to the bar
///   P1 pinned (`GridToolbarUITests`).
///
/// Compact never reads or writes the flag: it has no sidebar, only the tab shell.
enum SidebarVisibilityMemory {
  typealias Visibility = NavigationSplitViewVisibility

  /// Not a grid preference, so not one of `GridPreferences.persistedKeys`: the shell owns it.
  /// IMGMGR-548: Settings › Sidebar › "Show Sidebar" is a second writer of the same key
  /// (`SettingsToggle.sidebarVisible`); `visibilityAfterFlagChange` applies its write.
  static let hiddenKey = "shell.regularSidebarHidden"
  /// A fresh install shows the sidebar — `LayoutResolver.columnVisibility(for:)` decides how.
  static let hiddenDefault = false

  /// The grid bar's toggle.
  static let toggleIdentifier = "regularSidebarToggle"
  static let showLabel = "Show Sidebar"
  static let hideLabel = "Hide Sidebar"
  static let symbol = "sidebar.leading"

  /// The split's visibility at `mode`, given the remembered flag. Shown is always the resolver's
  /// own answer, so a fresh install (`hiddenDefault`) is unchanged by this type.
  static func columnVisibility(for mode: LayoutMode, sidebarHidden: Bool) -> Visibility {
    guard mode != .compact, sidebarHidden else {
      return LayoutResolver.columnVisibility(for: mode)
    }
    return .detailOnly
  }

  /// Hidden is `.detailOnly` the reader chose, never `.automatic`: on iOS 26.5 `.automatic` is
  /// `.detailOnly` carrying an automatic flag that `==` does not compare (lane-m gate on 651fb63:
  /// `shown → NavigationSplitViewVisibility(kind: .detailOnly, isAutomatic: true)` read hidden).
  static func isHidden(_ visibility: Visibility) -> Bool {
    visibility == .detailOnly && !isAutomatic(visibility)
  }

  /// The flag `==` ignores, read by reflection; a representation without it reads false, which
  /// keeps plain `==` semantics.
  private static func isAutomatic(_ visibility: Visibility) -> Bool {
    Mirror(reflecting: visibility).children.contains {
      $0.label == "isAutomatic" && ($0.value as? Bool) == true
    }
  }

  /// What the split reporting `visibility` at `mode` means for the flag; nil at Compact, whose
  /// `.doubleColumn` is the resolver's value for a split that is not on screen.
  static func recordedHidden(_ visibility: Visibility, in mode: LayoutMode) -> Bool? {
    guard mode != .compact else { return nil }
    return isHidden(visibility)
  }

  /// IMGMGR-548: what the split should become when the remembered flag changes to `hidden` —
  /// written by Settings, or echoed back by `RootView`'s own `onChange(of: columnVisibility)`.
  /// nil when nothing is to change: at Compact (no sidebar), and whenever the split already
  /// records `hidden`, which is what the echo of a split-side change always reads — so the two
  /// writers converge instead of looping.
  static func visibilityAfterFlagChange(
    _ current: Visibility, in mode: LayoutMode, hidden: Bool
  ) -> Visibility? {
    guard let recorded = recordedHidden(current, in: mode), recorded != hidden else { return nil }
    return columnVisibility(for: mode, sidebarHidden: hidden)
  }

  /// The grid bar carries the toggle while the sidebar is hidden at Regular — never at Compact.
  static func showsGridBarToggle(in mode: LayoutMode, visibility: Visibility) -> Bool {
    mode != .compact && isHidden(visibility)
  }

  /// The toggle's one action: hidden shows the resolver's layout for `mode`, shown hides.
  static func toggled(_ visibility: Visibility, in mode: LayoutMode) -> Visibility {
    isHidden(visibility) ? LayoutResolver.columnVisibility(for: mode) : .detailOnly
  }

  static func label(for visibility: Visibility) -> String {
    isHidden(visibility) ? showLabel : hideLabel
  }
}

/// IMGMGR-478: the grid bar's sidebar toggle, in the bar's leading slot while the sidebar is
/// hidden at Regular (`SidebarVisibilityMemory.showsGridBarToggle`). It writes the same
/// `RootView.columnVisibility` the system toggle does; `RootView` remembers the result.
struct GridBarSidebarToggle: ToolbarContent {
  let layoutMode: LayoutMode
  @Binding var columnVisibility: NavigationSplitViewVisibility

  private var isPresent: Bool {
    SidebarVisibilityMemory.showsGridBarToggle(in: layoutMode, visibility: columnVisibility)
  }

  private var label: String {
    SidebarVisibilityMemory.label(for: columnVisibility)
  }

  var body: some ToolbarContent {
    if isPresent {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: toggle) {
          Label(label, systemImage: SidebarVisibilityMemory.symbol)
        }
        .accessibilityIdentifier(SidebarVisibilityMemory.toggleIdentifier)
      }
    }
  }

  private func toggle() {
    let next = SidebarVisibilityMemory.toggled(columnVisibility, in: layoutMode)
    withAnimation { columnVisibility = next }
  }
}
