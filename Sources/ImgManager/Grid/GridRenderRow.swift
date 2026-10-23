import CoreGraphics
import ImgManagerAPI

/// One rendered grid row of PHOTOGRAPHS with a stable identity: its leading cell's display id.
///
/// Moved here from `GridView` unchanged (WP13 P5b) so the section-layout derivation below — and
/// the tests that drive it — can build one without a SwiftUI render host. Index identity is what
/// crashed 0.7.0 (9) (`ForEachChild.updateValue`); a leading-cell id is unique per layout (each
/// cell packs into exactly one row) and moves with its row across repacks.
struct PackedRow: Identifiable, Equatable {
  let id: GridDisplayID
  let cells: [PackedTilePlan]
  /// IMGMGR-551 (R3-7): the cell edge of a Square-layout row, nil for a justified one. Carried on
  /// the ROW, independent of image availability, because a placeholder plan has no size: `GridView`
  /// frames every cell of a square row at `edge × edge` from this, so the grid's geometry never
  /// depends on a proxy having loaded. Nil keeps a justified row value-identical to before.
  var squareEdge: CGFloat? = nil
  /// IMGMGR-542 (R3-22): the scene whose peek band this row belongs to, nil for a stream row.
  /// Nil keeps every stream row value-identical to before.
  var band: Int? = nil
}

/// One section header, built ENTIRELY from `GET /api/image-groups` — the route's own words:
/// "the ONLY truthful way a client can place a section header" (`app/api/images.py:1816-1826`).
/// A page holds part of a group, so a client-side tally over the loaded page would state the PAGE
/// count and call it the section's. Every field here is the server's:
/// - `label` — including the explicit `Unknown` bucket's own label (live probe 2026-08-30:
///   `group_by=location` → `{key: null, label: "Unknown", count: 255}`).
/// - `count` — the WHOLE group's, not the page's.
/// - `timezone` — the zone the five time keys' labels are rendered in, named because estate
///   ADR-0007 (/link/2553) requires a rendered local time to name its zone. Nil for the
///   non-time keys, whose response carries none.
struct GroupHeaderRow: Identifiable, Equatable, Sendable {
  let key: GroupKey
  let label: String
  let count: Int
  let timezone: String?
  /// IMGMGR-541 (R3-6): Mark and Rating headers read as one line, "Picks · 5".
  var usesDot: Bool = false

  /// The one-line form, "Picks · 5".
  var dotTitle: String { "\(label) · \(count)" }

  var id: GroupKey { key }
}

/// A header's id is its group key; a tile row's id stays its leading cell's `GridDisplayID`.
///
/// A SEPARATE type from `GridDisplayID` on purpose: `GridDisplayID` gains no case for a header.
/// A header is not a display thing that could be hit-tested, dragged, focused or written to, and
/// widening that type would put a non-photograph into the one vocabulary the actionability
/// boundary is expressed in (`SceneRows.swift`'s own argument for why a scene card is `.stack`).
enum GridRenderRowID: Hashable, Sendable {
  case header(GroupKey)
  case tiles(GridDisplayID)
  case remainder
}

/// IMGMGR-541 (R3-21): the ONE row that stands for the photographs without a mark (or rating),
/// "493 photos without a mark ›". Its count is the server's header for the null bucket.
struct GroupRemainderRow: Equatable, Sendable {
  let groupBy: GroupByKey
  let count: Int

  var title: String { GroupRemainder.rowTitle(count: count, groupBy: groupBy) }
}

/// The grid's rendered sequence: section headers interleaved with packed tile rows.
///
/// Headers are DISPLAY-ONLY. They never reach `GridStore.rows` (arrow navigation), never reach
/// `actionableImages` (marking, tagging, undo, the loupe) and carry no mark affordance — the same
/// boundary a collapsed scene card holds.
enum GridRenderRow: Identifiable, Equatable {
  case header(GroupHeaderRow)
  case tiles(PackedRow)
  case remainder(GroupRemainderRow)

  var id: GridRenderRowID {
    switch self {
    case .header(let header): return .header(header.key)
    case .tiles(let row): return .tiles(row.id)
    case .remainder: return .remainder
    }
  }

  /// The packed photograph row this is, or nil because it is a header. The one sanctioned way to
  /// get tiles back out — which is what keeps `publishRows` (and therefore `GridStore.rows`)
  /// header-free by construction rather than by the caller remembering to filter.
  var packedRow: PackedRow? {
    guard case .tiles(let row) = self else { return nil }
    return row
  }
}

/// WP13 P5b (IMGMGR-221, part 2): the pure derivation that turns one paged stream plus the
/// server's group headers into rendered sections.
///
/// Free-standing and SwiftUI-free for the same reason `SceneRowBuilder` is: the properties that
/// have to hold — a header at every boundary, the server's own count, no justified row across a
/// boundary, no header in the actionable vocabulary — are testable without a render host.
enum GridSectionLayout {

  /// Which section a display row belongs to. `ImageSummary.group_key` is the server's answer to
  /// "where does a boundary fall inside this page" — the client never derives it from metadata it
  /// happens to hold.
  ///
  /// A scene card answers `.unknown` for totality only: grouping and Scene mode are ONE
  /// single-select state (`GroupingChoice`), so a `.stack` row can never be present while
  /// `groupBy` is non-nil.
  static func groupKey(of row: SceneDisplayRow) -> GroupKey {
    switch row {
    case .image(let image): return GroupKey(image.groupKey)
    case .stack: return .unknown
    }
  }

  /// Arrow navigation's row table: TILE rows only, in render order.
  ///
  /// The one projection from the rendered sequence to `GridStore.rows` — a header is not a
  /// photograph, so it never enters the array Up/Down navigation walks. Extracted here rather
  /// than left inline in `GridView.publishRows` so deleting the filter turns
  /// `GridSectionLayoutTests.headerRowsAreAbsentFromGridStoreRowsAndFromActionableImages` red
  /// instead of only changing a view body no test can reach.
  static func navigationRows(_ renderRows: [GridRenderRow]) -> [[GridDisplayID]] {
    renderRows.compactMap { $0.packedRow }.map { row in row.cells.map(\.id) }
  }

  /// The rendered sequence.
  ///
  /// Ungrouped (`groupBy == nil`) is ONE packing pass over the whole stream and no headers —
  /// byte-for-byte the shipped behaviour. Grouped splits the stream at every `group_key` boundary
  /// and packs EACH RUN on its own, so `JustifiedRowLayout.packWithTierPlan` never packs a row
  /// that straddles two groups.
  ///
  /// IMGMGR-551 (R3-7): `layout` picks the packer — `.justified` (the default, unchanged) or
  /// `.square` (`SquareGridLayout`, its rows carrying `squareEdge`). Both pack per run, so no
  /// square row straddles a header either; `targetRowHeight` is the square cell's target edge.
  ///
  /// `headers` empty means the header fetch has not landed (or failed): the stream renders
  /// UNSECTIONED rather than with invented labels, and rather than hiding photographs behind a
  /// missing header. Same for one absent key — its tiles render, its header does not. Nothing
  /// here ever computes a label, a count or a timezone.
  static func renderRows(
    rows: [SceneDisplayRow],
    groupBy: GroupByKey?,
    headers: [GroupKey: Components.Schemas.GroupHeader],
    timezone: String?,
    paneWidth: CGFloat,
    targetRowHeight: CGFloat,
    displayScale: CGFloat,
    spacing: CGFloat = 2,
    layout: GridLayoutStyle = .justified,
    remainderCount: Int? = nil,
    bands: [SceneBand] = [],
    availability: (GridDisplayID, ProxyTier) -> ProxyAvailability
  ) -> [GridRenderRow] {
    // IMGMGR-541: the remainder row closes the stream, after the last section, when the caller
    // vouches for a non-zero null bucket (`GridStore.remainderCount` once the stream reached it).
    let remainderRow: GridRenderRow? = {
      guard let groupBy, groupBy.hasRemainder, let remainderCount, remainderCount > 0 else {
        return nil
      }
      return .remainder(GroupRemainderRow(groupBy: groupBy, count: remainderCount))
    }()
    // IMGMGR-542 (R3-22): each open band hangs under the packed row holding its card. The stream
    // is packed exactly as without bands, so every stream row keeps its composition and size and
    // the rows above a band keep their y. Bands under ONE row follow insertion order (`bands`'
    // order); bands under different rows follow their cards. Each band row is its own element of
    // the grid's lazy row list — a band is never one eager container.
    func withBands(_ packed: [GridRenderRow]) -> [GridRenderRow] {
      guard !bands.isEmpty else { return packed }
      var out: [GridRenderRow] = []
      for row in packed {
        out.append(row)
        guard case .tiles(let tiles) = row else { continue }
        let cards = Set(
          tiles.cells.compactMap { cell -> Int? in
            guard case .stack(let id) = cell.id else { return nil }
            return id
          })
        guard !cards.isEmpty else { continue }
        for band in bands where cards.contains(band.stackID) && !band.rows.isEmpty {
          out.append(contentsOf: packRows(band.rows, band: band.stackID))
        }
      }
      return out
    }
    func pack(_ slice: [SceneDisplayRow]) -> [GridRenderRow] {
      withBands(packRows(slice, band: nil))
    }
    func packRows(_ slice: [SceneDisplayRow], band: Int?) -> [GridRenderRow] {
      let tiles = slice.map { JustifiedTile(id: $0.id, aspectRatio: $0.aspectRatio) }
      switch layout {
      case .justified:
        return JustifiedRowLayout.packWithTierPlan(
          tiles: tiles,
          paneWidth: paneWidth, targetRowHeight: targetRowHeight, displayScale: displayScale,
          spacing: spacing, availability: availability
        )
        .compactMap { packed in
          packed.first.map { .tiles(PackedRow(id: $0.id, cells: packed, band: band)) }
        }
      case .square:
        let edge = SquareGridLayout.geometry(
          paneWidth: paneWidth, targetCellEdge: targetRowHeight, spacing: spacing)?.edge
        return SquareGridLayout.packWithTierPlan(
          tiles: tiles,
          paneWidth: paneWidth, targetCellEdge: targetRowHeight, displayScale: displayScale,
          spacing: spacing, availability: availability
        )
        .compactMap { packed in
          packed.first.map {
            .tiles(PackedRow(id: $0.id, cells: packed, squareEdge: edge, band: band))
          }
        }
      }
    }

    // Unvouched headers: no sections and no remainder row (its count would be unvouched too).
    guard let groupBy, !headers.isEmpty else { return pack(rows) }

    var out: [GridRenderRow] = []
    var run: [SceneDisplayRow] = []
    var runKey: GroupKey?

    func flushRun() {
      guard let runKey, !run.isEmpty else { return }
      // The null bucket is NEVER headed under Mark or Rating (R3-21): it is the one row below.
      let isRemainderKey = groupBy.hasRemainder && runKey == .unknown
      if !isRemainderKey, let header = headers[runKey] {
        out.append(
          .header(
            GroupHeaderRow(
              key: runKey,
              label: GroupRemainder.headerTitle(
                groupBy: groupBy, key: header.key, label: header.label),
              count: header.count,
              // The zone is stated for the time keys only — it is what the server sends a
              // non-nil `timezone` for, and the only case where a label is a rendered local time.
              timezone: groupBy.isTimeKey ? timezone : nil,
              usesDot: GroupRemainder.usesDotHeader(groupBy))))
      }
      out.append(contentsOf: pack(run))
      run = []
    }

    for row in rows {
      let key = groupKey(of: row)
      if key != runKey {
        flushRun()
        runKey = key
      }
      run.append(row)
    }
    flushRun()
    if let remainderRow { out.append(remainderRow) }
    return out
  }
}
