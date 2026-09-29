import CoreGraphics
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP16 P2 (IMGMGR-298), Codex delta round. The collapse that reclaims the inspector's width also
/// rebuilds `GridView` in a different split-view slot, so the `ScrollView` starts at offset zero
/// and the reader loses their place. The anchor that survives that is the subject here.
///
/// The load-bearing case is `theAnchorSurvivesARepack`, and it is the one a naive fix fails:
/// remembering the row id `ScrollView` reports looks correct and passes every same-width test,
/// because a row's identity is its LEADING CELL — and the collapse changes the pane width from
/// ~209 pt to the full window, which repacks every justified row and leaves that id naming
/// nothing. Removing the translation (storing and returning the row id directly) turns that test
/// RED while the round-trip test below stays green.
@Suite("Grid scroll anchor — a place in the sheet, not a place in one packing")
struct GridScrollAnchorTests {

  private func plan() -> TileRenderPlan {
    TileRenderPlan.display(tier: .grid, size: CGSize(width: 120, height: 80))
  }

  private func tileRow(_ ids: [Int]) -> GridRenderRow {
    let cells = ids.map { PackedTilePlan(id: .image($0), plan: plan()) }
    return .tiles(PackedRow(id: .image(ids[0]), cells: cells))
  }

  private func headerRow(_ key: String) -> GridRenderRow {
    .header(GroupHeaderRow(key: .known(key), label: key, count: 9, timezone: nil))
  }

  @Test("A scroll position reduces to the photograph its row leads with")
  func aScrollPositionReducesToItsLeadingPhotograph() {
    #expect(GridScrollAnchor.displayID(of: .tiles(.image(7))) == .image(7))
    #expect(GridScrollAnchor.displayID(of: .tiles(.stack(3))) == .stack(3))
    #expect(GridScrollAnchor.displayID(of: nil) == nil)
  }

  @Test("A header anchors nothing — it carries no photograph to re-find after a repack")
  func aHeaderAnchorsNothing() {
    #expect(GridScrollAnchor.displayID(of: .header(.known("SONY ILCE-7RM5"))) == nil)
  }

  @Test("At an unchanged width the anchor resolves to the row it came from")
  func theAnchorRoundTripsAtAnUnchangedWidth() {
    let rows = [tileRow([1, 2, 3]), tileRow([4, 5, 6]), tileRow([7, 8, 9])]
    let reported: GridRenderRowID = .tiles(.image(4))
    let stored = GridScrollAnchor.displayID(of: reported)
    #expect(GridScrollAnchor.row(containing: stored, in: rows) == reported)
  }

  /// THE case the collapse actually produces. Narrow: three per row, so the reader's top row is
  /// led by photograph 4. Wide: six per row, and 4 is now the FOURTH cell of the first row — the
  /// row id `.tiles(.image(4))` does not exist in the wide packing at all. The anchor must still
  /// resolve, to the row that holds photograph 4 now.
  @Test("The anchor survives a repack: the photograph moves rows, the position follows it")
  func theAnchorSurvivesARepack() {
    let narrow = [tileRow([1, 2, 3]), tileRow([4, 5, 6]), tileRow([7, 8, 9])]
    let wide = [tileRow([1, 2, 3, 4, 5, 6]), tileRow([7, 8, 9])]

    let stored = GridScrollAnchor.displayID(of: .tiles(.image(4)))
    #expect(stored == .image(4))
    // The proof that the naive implementation is wrong: that row id is gone from the wide packing.
    #expect(wide.contains { $0.id == .tiles(.image(4)) } == false)
    // ...and the anchor resolves anyway, to the row photograph 4 is now part of.
    #expect(GridScrollAnchor.row(containing: stored, in: wide) == .tiles(.image(1)))
    // Still correct in the other direction, so this is not a one-way accident.
    #expect(GridScrollAnchor.row(containing: stored, in: narrow) == .tiles(.image(4)))
  }

  @Test("An anchor whose photograph is no longer rendered leaves the position alone")
  func anAnchorOntoAVanishedPhotographResolvesToNothing() {
    let rows = [headerRow("Camera A"), tileRow([1, 2, 3])]
    // 99 was filtered out of the current page; a fallback to "some row" would be a jump the
    // reader did not ask for, so the answer is nil and `scrollPosition` is left untouched.
    #expect(GridScrollAnchor.row(containing: .image(99), in: rows) == nil)
    #expect(GridScrollAnchor.row(containing: nil, in: rows) == nil)
    // Positive control in the same test: a photograph that IS rendered still resolves, so the
    // nil answers above are about the anchor and not about the search being broken.
    #expect(GridScrollAnchor.row(containing: .image(2), in: rows) == .tiles(.image(1)))
  }

  /// IMGMGR-473: the anchor is now RECORDED from `onScrollTargetVisibilityChange`, which reports
  /// which targets are visible but promises no order. The topmost row is decided by the measured
  /// frames, so a report listing the lower row first must still record the upper one.
  @Test("The recorded anchor is the topmost visible tile row by frame, whatever the report order")
  func theRecordedAnchorIsTheTopmostVisibleRowByFrame() {
    let frames: [GridDisplayID: CGRect] = [
      .image(4): CGRect(x: 0, y: -30, width: 120, height: 80),
      .image(7): CGRect(x: 0, y: 52, width: 120, height: 80),
    ]
    let reported: [GridRenderRowID] = [.tiles(.image(7)), .tiles(.image(4))]
    #expect(GridScrollAnchor.topmostPhotograph(visible: reported, frames: frames) == .image(4))
  }

  @Test("A report with no tile row records nothing; unmeasured rows fall back to report order")
  func theRecordedAnchorBoundaries() {
    // Empty and header-only reports: nil, so the last recorded photograph is kept.
    #expect(GridScrollAnchor.topmostPhotograph(visible: [], frames: [:]) == nil)
    #expect(
      GridScrollAnchor.topmostPhotograph(visible: [.header(.known("Camera A"))], frames: [:])
        == nil)
    // One row, a header above it: the header is skipped, the row is the anchor.
    #expect(
      GridScrollAnchor.topmostPhotograph(
        visible: [.header(.known("Camera A")), .tiles(.image(1))], frames: [:]) == .image(1))
    // No frames measured yet (the first report of a fresh view): the report's own order decides.
    #expect(
      GridScrollAnchor.topmostPhotograph(
        visible: [.tiles(.image(4)), .tiles(.image(7))], frames: [:]) == .image(4))
    // A measured row beats an unmeasured one listed before it.
    #expect(
      GridScrollAnchor.topmostPhotograph(
        visible: [.tiles(.image(4)), .tiles(.image(7))],
        frames: [.image(7): CGRect(x: 0, y: 10, width: 1, height: 1)]) == .image(7))
  }

  /// IMGMGR-473 round 3: the armed one-time restore, decided purely.
  @Test("The one-time restore scrolls, records, or waits for the saved photograph's page")
  func theRestoreStepTable() {
    let rows = [tileRow([1, 2, 3]), tileRow([4, 5, 6]), tileRow([7, 8, 9])]
    func step(_ saved: Int?, top: Int, in rows: [GridRenderRow], loading: Bool = false)
      -> GridScrollAnchor.RestoreStep
    {
      GridScrollAnchor.restoreStep(
        saved: saved.map { GridDisplayID.image($0) }, topmost: .image(top), rows: rows,
        isLoading: loading)
    }
    // Nothing saved (first visit, or retired by a filter/shoot/mode change): record.
    #expect(step(nil, top: 1, in: rows) == .record)
    // Saved photograph mid-row in the current packing: its row goes to the top.
    #expect(step(5, top: 1, in: rows) == .scroll(.tiles(.image(4))))
    // Already the topmost row: nothing to scroll, the restore is spent.
    #expect(step(5, top: 4, in: rows) == .record)
    // Not rendered yet while its page loads: stay armed, record nothing.
    #expect(step(42, top: 1, in: rows, loading: true) == .wait)
    // Not rendered and nothing loading: gone for good, so the restore is spent.
    #expect(step(42, top: 1, in: [], loading: false) == .record)
  }
}

/// WP16 P2 (IMGMGR-298), Codex round-3 blocker. The anchor's LIFETIME, at the store, where the
/// rule actually lives — `GridScrollAnchorTests` above proves the anchor resolves correctly, and
/// proved nothing about when it should stop existing.
///
/// The path that forced this: scroll deep, apply a filter matching nothing, clear it again. With
/// the anchor surviving a filter change, it is still set while no rows exist to resolve it
/// against, so the position jumps deep into the repopulated grid the moment rows return —
/// instead of the top, where a filter change has always left the reader. RED against `f8acd45`,
/// which retired the anchor on a shoot change and a display-mode switch but deliberately not
/// here.
@MainActor
@Suite("Grid scroll anchor — retired whenever a query change rebuilds the sequence")
struct GridScrollAnchorLifecycleTests {

  private func makeStore() -> GridStore {
    let client = ImgManagerAPIClient.make(transport: GridStubTransport())
    return GridStore(service: GridService(client: client))
  }

  /// IMGMGR-473 round 3: the key whose change re-places the anchor after a repack. Thumbnail
  /// size and width are in it; the anchor itself and a mark are not (see
  /// `SceneMarkScrollAnchorTests` for the mark leg).
  @Test("The packing key moves with width and thumbnail size, not with the anchor")
  func thePackingKeyTracksPackingInputsOnly() {
    let store = makeStore()
    let base = GridPackingKey(store: store, paneWidth: 402, displayScale: 3)
    store.gridScrollAnchor = .image(42)
    #expect(GridPackingKey(store: store, paneWidth: 402, displayScale: 3) == base)
    #expect(GridPackingKey(store: store, paneWidth: 300, displayScale: 3) != base)
    let other = GridRowHeight.allCases.first { $0 != store.rowHeight } ?? .step120
    store.setRowHeight(other)
    #expect(GridPackingKey(store: store, paneWidth: 402, displayScale: 3) != base)
  }

  @Test("An effective filter change retires the anchor")
  func anEffectiveFilterChangeRetiresTheAnchor() async {
    let store = makeStore()
    store.gridScrollAnchor = .image(42)

    await store.applyFilterChange { $0.ratingMin = 4 }

    #expect(
      store.gridScrollAnchor == nil,
      "A filter change rebuilt the result sequence but left the reader anchored to a photograph from the old one — the zero-result-then-cleared path jumps deep into the grid instead of landing at the top."
    )
  }

  @Test("A filter change that clears back to nothing also retires the anchor")
  func clearingAFilterRetiresTheAnchor() async {
    // The second half of the reported path, driven rather than argued: the anchor must be gone
    // after the filter is applied AND after it is taken away again.
    let store = makeStore()
    await store.applyFilterChange { $0.ratingMin = 5 }
    store.gridScrollAnchor = .image(7)

    await store.applyFilterChange { $0.ratingMin = nil }

    #expect(store.gridScrollAnchor == nil)
  }

  @Test("A no-op filter change leaves the reader exactly where they are")
  func aNoOpFilterChangeLeavesTheAnchorAlone() async {
    // The guard in `applyFilterChange` returns before anything is rebuilt, so nothing about the
    // reader's position changed either. Without this, "clear it everywhere" would also clear it
    // on a tap that did nothing — and this test is what makes the clear specific to a real
    // rebuild rather than to the function being called.
    let store = makeStore()
    store.gridScrollAnchor = .image(42)

    await store.applyFilterChange { _ in }

    #expect(store.gridScrollAnchor == .image(42))
  }

  @Test("A shoot change retires the anchor")
  func aShootChangeRetiresTheAnchor() async {
    let store = makeStore()
    store.gridScrollAnchor = .image(42)

    await store.selectShoot(folderID: 1)

    #expect(store.gridScrollAnchor == nil)
  }

  @Test("Entering Scene mode retires the anchor")
  func aDisplayModeSwitchRetiresTheAnchor() async {
    // Every row id changes vocabulary across this switch (`.image` to `.stack`), so an anchor
    // from the flat sequence cannot mean anything in the scene one.
    let store = makeStore()
    store.gridScrollAnchor = .image(42)

    await store.setDisplayMode(.scene)

    #expect(store.gridScrollAnchor == nil)
  }
}
