import CoreGraphics

/// Where the contact sheet was scrolled to, expressed in a vocabulary that survives a repack.
///
/// WP16 P2 (IMGMGR-298), Codex delta round. Decision 4's Regular-3 collapse swaps the workspace
/// between the three-column and two-column `NavigationSplitView` shapes — the only shape change
/// that actually reclaims the inspector's width, because a column is reserved by the
/// initializer's arity, not by its content (measured: `actionBarMidX before=104.5 after=104.5`).
/// That moves `GridView` to a different slot, which is a new structural identity and therefore a
/// fresh `ScrollView` at offset zero. `GridStore` keeps the page, the selection and the focus;
/// nothing kept the offset.
///
/// The subtle part, and the reason this is a type rather than one line in the view: the obvious
/// anchor — the id `ScrollView` deals in, a `GridRenderRowID` — is NOT stable across the
/// collapse. A row's identity is its LEADING CELL's display id, and the collapse changes the pane
/// width from ~209 pt to the full window, which repacks every justified row. The photograph that
/// led a row at the narrow width is very likely mid-row at the wide one, so the remembered row id
/// simply does not exist any more and the restore silently does nothing.
///
/// So the anchor is stored as a PHOTOGRAPH (`GridDisplayID`) and translated in both directions:
/// what SwiftUI reports is reduced to the photograph that led that row, and what SwiftUI is told
/// is whichever row holds that photograph NOW. Both directions are pure functions of values a
/// test can build, which is what makes the repack case assertable without a render host.
///
/// IMGMGR-473: the anchor is RECORDED, never bound. It used to reach `ScrollView` through
/// `.scrollPosition(id:)`, and a bound id is one SwiftUI keeps re-applying: a mark inside an open
/// scene changed the content under it and the scroll view re-snapped the anchored row's top to the
/// viewport's top edge, so a reader whose top row was cut mid-height saw the whole grid drop by
/// exactly the cut (iPhone 402x874, gate on ea18cf7: +43.33 pt). `GridView` now writes the anchor
/// from the visible targets and reads it back exactly once per `ScrollView` lifetime, to restore.
enum GridScrollAnchor {
  /// The photograph a scroll position refers to. A header row anchors nothing — it is
  /// display-only and carries no `GridDisplayID` (see `GridRenderRowID`'s own note on why the two
  /// vocabularies stay separate), so remembering one would be remembering a position that cannot
  /// be re-derived after a repack.
  static func displayID(of rowID: GridRenderRowID?) -> GridDisplayID? {
    guard case .tiles(let displayID) = rowID else { return nil }
    return displayID
  }

  /// The row that holds `displayID` in the CURRENT packing — not the row that held it when the
  /// anchor was taken. Returns nil for an anchor whose photograph is no longer rendered at all
  /// (a filter dropped it, a scene collapsed over it), which correctly leaves the scroll position
  /// alone rather than jumping somewhere arbitrary.
  static func row(containing displayID: GridDisplayID?, in rows: [GridRenderRow])
    -> GridRenderRowID?
  {
    guard let displayID else { return nil }
    for row in rows {
      guard case .tiles(let packed) = row else { continue }
      if packed.cells.contains(where: { $0.id == displayID }) { return row.id }
    }
    return nil
  }

  /// The photograph leading the TOPMOST visible tile row: what the anchor records. `visible` is
  /// what `onScrollTargetVisibilityChange` reports, which promises membership, not order, so the
  /// order comes from the rows' measured frames (`GridView.tileFrames`, keyed by the same leading
  /// photograph) — a row with no frame yet sorts after every measured one, and ties keep the
  /// reported order. Headers carry no photograph and are skipped; nil when no tile row is visible,
  /// which leaves the recorded anchor alone.
  static func topmostPhotograph(
    visible: [GridRenderRowID], frames: [GridDisplayID: CGRect]
  ) -> GridDisplayID? {
    var best: GridDisplayID?
    var bestMinY = CGFloat.infinity
    for rowID in visible {
      guard let displayID = displayID(of: rowID) else { continue }
      let minY = frames[displayID]?.minY ?? .infinity
      if best == nil || minY < bestMinY {
        best = displayID
        bestMinY = minY
      }
    }
    return best
  }
}
