import Foundation
import ImgManagerAPI

/// One row of the grid's filter popover: a NAMED filter value, the live count it would deliver,
/// and whether it can be reached from here. WP16 P3 (IMGMGR-295), design record [/link/3332]
/// decision 1.
///
/// Carries a `MarkRole`, never a colour — the view resolves the colour through `MarkPalette`
/// (WP16 P1), so this type stays a pure value transform and the popover cannot tint a Pick
/// differently from the tile badge that means the same thing.
struct FilterPopoverRow: Identifiable, Sendable {
  let field: InspectorFacetField
  let value: String
  let title: String
  let count: Int
  let isActive: Bool
  /// A 0-count row is not reachable — applying it would empty the grid — UNLESS it is the value
  /// currently in force, which must always stay tappable so the filter it applies can be cleared
  /// from the same surface that applied it.
  let isEnabled: Bool
  let markRole: MarkRole?

  var id: String { "\(field.rawValue)-\(value)" }
  var accessibilityIdentifier: String { "filterPopoverRow-\(id)" }
}

/// One row of the inspector's Stats tab, exactly as rendered: the server's own value, the label
/// it is shown under and the number it states. A separate type from `FilterPopoverRow` because the
/// two surfaces differ in what they offer — the Stats tab renders every value the server sent and
/// nothing it did not, the popover renders a declared set whatever the server sent.
struct InspectorStatsRow: Identifiable, Sendable {
  let field: InspectorFacetField
  let value: String
  let title: String
  let count: Int
  let isActive: Bool

  var id: String { "\(field.rawValue)-\(value)" }
}

struct FilterPopoverSection: Identifiable, Sendable {
  let field: InspectorFacetField
  let title: String
  let rows: [FilterPopoverRow]

  var id: String { field.rawValue }
}

/// The popover's row set as a value: what it offers is DECLARED here, and a facets response only
/// supplies the numbers.
///
/// That is the one place this deliberately differs from the inspector's Stats tab. The Stats tab
/// discovers its sections from the response and renders nothing for a dimension the server sent no
/// values for (`InspectorView.facetRows`'s `if !counts.isEmpty`), which is right for a tab whose
/// job is "what does the server say about this scope". It is wrong here: decision 1 NAMES these
/// rows, and a named row that disappears is the opposite of the live count the decision asks for.
/// So an absent or empty dimension yields its named rows at 0, disabled — never omitted — and a
/// never-fetched response (`facets == nil`) yields the same declaration at zero rather than a
/// spinner standing where the rows should be.
///
/// Every row is built from `InspectorFacetField` and nothing else, so "which value is active",
/// "what a second tap does" and "what Clear clears" have exactly one implementation, shared with
/// the Stats tab (`InspectorModel.swift`). This type adds no mutation path of its own.
///
/// **The Camera row exists** (WP21 P2, IMGMGR-376 / -339; owner/orchestrator resolution
/// 2026-09-04, comment 3750/3751 on those tickets). The default this replaces was a fact about
/// the server, not a product choice: at WP16 P3 no `camera` filter parameter and no `camera`
/// facet existed on `/api/images`, `/api/facets` or `/api/image-groups`, so the row could not be
/// built. IMGMGR-316 shipped both in img-manager v0.20.0 — `ImageFacets.camera` and a `camera`
/// query parameter on all six filter-bearing routes — and this client re-vendored that contract
/// in WP21 P1, so the row is now built from the server's own values.
///
/// The shipped rule, in full:
///   - ONE dimension, `InspectorFacetField.camera`, with the two presentations every facet has —
///     this popover section and the Stats-tab section `InspectorView.facetRows` auto-renders from
///     `InspectorFacetField.allCases`. One owner state, both tappable. No chip and no third
///     control: the native app has exactly one filter surface.
///   - Values come ONLY from `ImageFacets.camera`, never derived client-side, which is why the
///     declaration below is empty (response-discovered, like Type).
///   - `camera_preview_only` is still NOT a stand-in and still not a row: it answers a different
///     question — "is this image's best source the camera's own preview".
enum FilterPopoverModel {

  /// A declared value: fixed, named, and present whatever the response holds.
  private struct DeclaredValue {
    let value: String
    let title: String
    var markRole: MarkRole?
  }

  private struct Declaration {
    let field: InspectorFacetField
    let title: String
    /// Empty means the values come from the RESPONSE rather than from here. Type and Camera both
    /// do: `ext` and `camera` are free-form strings in the vendored contract (no enum), so a
    /// declared list of extensions or camera bodies would be invented wire vocabulary — the
    /// failure mode IMGMGR-173 records.
    var values: [DeclaredValue] = []
    /// A response-discovered section's row cap, or nil for "however many the response holds".
    ///
    /// Only Camera sets one, and it is a stated cap rather than a silent truncation (WP21 P2's
    /// pivot). The server answers `_count_by` ordered by count DESC then value, capped at its own
    /// `FACET_VALUE_LIMIT` of 30, so a photographer with many bodies could hand this popover
    /// thirty rows — and `FilterPopoverView` renders an EAGER `VStack` precisely because the row
    /// set is "FIXED and small". Twelve is the head of that list; `cappedRows` keeps whichever
    /// row is currently in force even when it falls outside the head, so no filter is ever
    /// unclearable from the surface that applied it, and appends one disabled `+N more cameras`
    /// row stating exactly how many bodies did not fit — the cap is announced on the surface, not
    /// only in this comment. Type takes no cap: `ext` is a handful of file extensions.
    var valueLimit: Int?
  }

  /// The head of the Camera section, stated (see `Declaration.valueLimit`).
  static let cameraValueLimit = 12

  /// The owner's own order (decision 1): ">=stars and the tri-state mark row (Pick / Unmarked /
  /// Dislike) plus Edited / Type … drill-ins".
  private static let declarations: [Declaration] = [
    Declaration(
      field: .rating, title: "Rating",
      values: [
        DeclaredValue(value: "3", title: "≥ 3"),
        DeclaredValue(value: "4", title: "≥ 4"),
        DeclaredValue(value: "5", title: "≥ 5"),
      ]),
    // Tri-state, and always three rows: the server emits one `FacetCount` per mark state
    // including zeros, so "Unmarked" is `mark=none` — a real filter value, not an absence.
    Declaration(
      field: .mark, title: "Mark",
      values: [
        DeclaredValue(value: "pick", title: "Pick", markRole: .pick),
        DeclaredValue(value: "none", title: "Unmarked"),
        DeclaredValue(value: "dislike", title: "Dislike", markRole: .dislike),
      ]),
    // Decision 2: "Edited" resolves to `has_master` — the web's own sibling decision
    // ([/link/3330] decision 1, "Edited (the master-only bit)"), and the only one of the
    // candidates this client can actually send.
    Declaration(
      field: .hasMaster, title: "Edited",
      values: [DeclaredValue(value: "true", title: "Edited in Lightroom", markRole: .edited)]),
    Declaration(field: .ext, title: "Type"),
    // WP21 P2: response-discovered, last, and the only capped section. Last because it is the
    // widest dimension and the owner's order names the judgement rows first.
    Declaration(field: .camera, title: "Camera", valueLimit: cameraValueLimit),
  ]

  /// The declaration at rest: every named row at zero, nothing active, nothing reachable. This is
  /// literally what `rows(nil, GridImagesQuery())` returns, so the two can never describe
  /// different row sets.
  static let sections: [FilterPopoverSection] = rows(nil, GridImagesQuery())

  /// The count a `>= minimum` row would deliver.
  ///
  /// The server groups the rating facet by EXACT `SidecarMeta.rating` while the filter these rows
  /// apply (`rating_min`) is a `>=`, so the exact bucket is by construction NOT "the live result
  /// count before applying". The web resolves it the same way (`FilterBar.vue`'s `ratingAtLeast`).
  /// `unset` is excluded rather than treated as zero: it means "no rating at all", which
  /// `rating_min` would never return, and folding it in would overstate every row by the size of
  /// the unrated majority (29 of 33 on the 2026-09-01 live probe).
  static func ratingAtLeast(_ minimum: Int, in facets: Components.Schemas.ImageFacets?) -> Int {
    counts(.rating, facets)
      .filter { bucket in
        // A non-numeric bucket is `unset` — "no rating at all", which `rating_min` never returns.
        guard let rating = Int(bucket.value) else { return false }
        return rating >= minimum
      }
      .reduce(0) { $0 + $1.count }
  }

  // MARK: - The inspector's Stats tab, aligned on the same function (gate round 1, B1)

  /// The Stats tab's rating rows, as the SEQUENCE `InspectorView` renders — one row per value the
  /// server sent, in the server's own order, nothing filtered out.
  ///
  /// Diff-gate round 1, B1: `statsRowTitle`/`statsRowCount` alone cannot witness that. They answer
  /// about ONE value, so an implementation that narrowed the section to `>= 3 / >= 4 / >= 5` —
  /// deleting the shipped `rating_min` = 0/1/2 controls and the `unset` row — would leave every
  /// per-value assertion green. Deriving the whole list here, and rendering the view FROM it, is
  /// what makes "no row was dropped" a thing a test can fail on.
  static func statsRows(
    _ field: InspectorFacetField, _ facets: Components.Schemas.ImageFacets,
    _ query: GridImagesQuery
  ) -> [InspectorStatsRow] {
    field.counts(from: facets).map { count in
      InspectorStatsRow(
        field: field, value: count.value, title: statsRowTitle(field, count.value),
        count: statsRowCount(field, count.value, serverCount: count.count, in: facets),
        isActive: field.isActive(count.value, in: query))
    }
  }

  /// The Stats tab's label for one server-sent facet value.
  ///
  /// The tab keeps EVERY value the server sends — no row is added or removed by this phase. What
  /// changes is the rating dimension's NUMERIC rows: each one already applies `rating_min`, a
  /// `>=`, so it is relabelled to say so. `unset` is not a threshold — it clears the dimension
  /// (`InspectorFacetField.rating.toggle` cannot make an Int of it) — so it keeps its own label.
  static func statsRowTitle(_ field: InspectorFacetField, _ value: String) -> String {
    guard field == .rating, Int(value) != nil else { return field.displayValue(value) }
    return "≥ \(value)"
  }

  /// The Stats tab's count for one server-sent facet value: the server's own number everywhere
  /// except a numeric rating row, where the exact bucket is not the number that row delivers.
  static func statsRowCount(
    _ field: InspectorFacetField, _ value: String, serverCount: Int,
    in facets: Components.Schemas.ImageFacets?
  ) -> Int {
    guard field == .rating, let minimum = Int(value) else { return serverCount }
    return ratingAtLeast(minimum, in: facets)
  }

  /// The declared sections, carrying this response's numbers and this query's active state.
  static func rows(
    _ facets: Components.Schemas.ImageFacets?, _ query: GridImagesQuery
  ) -> [FilterPopoverSection] {
    declarations.map { declaration in
      FilterPopoverSection(
        field: declaration.field, title: declaration.title,
        rows: sectionRows(declaration, facets, query))
    }
  }

  /// A declared section's values come from this table; the one section whose values are discovered
  /// (Type) has an empty declaration and reads them off the response instead.
  private static func sectionRows(
    _ declaration: Declaration, _ facets: Components.Schemas.ImageFacets?, _ query: GridImagesQuery
  ) -> [FilterPopoverRow] {
    guard !declaration.values.isEmpty else {
      return discoveredRows(declaration, facets, query)
    }
    return declaration.values.map { declared in
      declaredRow(declared, declaration.field, facets, query)
    }
  }

  private static func counts(
    _ field: InspectorFacetField, _ facets: Components.Schemas.ImageFacets?
  ) -> [Components.Schemas.FacetCount] {
    facets.map { field.counts(from: $0) } ?? []
  }

  private static func declaredRow(
    _ declared: DeclaredValue, _ field: InspectorFacetField,
    _ facets: Components.Schemas.ImageFacets?, _ query: GridImagesQuery
  ) -> FilterPopoverRow {
    let count = declaredCount(declared.value, field, facets)
    return row(
      field: field, value: declared.value, title: declared.title, count: count,
      markRole: declared.markRole, query: query)
  }

  /// A declared row's number. Everywhere but Rating this is the server's own count for that exact
  /// value; a Rating row states the suffix sum, because the `rating_min` it applies is a `>=`.
  private static func declaredCount(
    _ value: String, _ field: InspectorFacetField, _ facets: Components.Schemas.ImageFacets?
  ) -> Int {
    if field == .rating, let minimum = Int(value) {
      return ratingAtLeast(minimum, in: facets)
    }
    return counts(field, facets).first(where: { $0.value == value })?.count ?? 0
  }

  /// Type's rows are whatever the response holds. Two absences are covered so the section is never
  /// a dead end: a value the reader has ALREADY filtered to that this response no longer carries
  /// is re-offered at 0 and enabled (otherwise that filter could not be cleared from here), and a
  /// dimension with nothing at all still renders one named row at 0, disabled, rather than
  /// vanishing (B2).
  private static func discoveredRows(
    _ declaration: Declaration, _ facets: Components.Schemas.ImageFacets?, _ query: GridImagesQuery
  ) -> [FilterPopoverRow] {
    let field = declaration.field
    var rows = counts(field, facets).filter { isOfferable($0.value, field) }.map { count in
      row(
        field: field, value: count.value, title: field.displayValue(count.value),
        count: count.count, markRole: nil, query: query)
    }
    if let active = field.activeValue(in: query), !rows.contains(where: { $0.value == active }) {
      rows.append(
        row(
          field: field, value: active, title: field.displayValue(active), count: 0,
          markRole: nil, query: query))
    }
    if rows.isEmpty {
      rows = [
        row(
          field: field, value: "", title: declaration.title, count: 0, markRole: nil, query: query)
      ]
    }
    if let limit = declaration.valueLimit {
      rows = cappedRows(rows, limit: limit, field: field)
    }
    return rows
  }

  /// Is this server-sent value one this surface can OFFER as a filter?
  ///
  /// One value fails it: `unset`, which the server emits for a NULL column (`_count_by`: "A NULL
  /// is reported as 'unset' rather than dropped"). It is a real population — "no `exif_camera` at
  /// all" is four of the twelve DEBUG photographs — but there is no `camera=` request that asks
  /// for it, and a row whose only effect is to clear the dimension is not a filter, it is a
  /// mislabelled Clear button. `InspectorFacetField.camera.toggle` treats it the same way for the
  /// Stats tab, which renders every value the server sent by design.
  ///
  /// Scoped to the dimensions where a NULL is ordinary rather than applied to every discovered
  /// row: `ext` is never null on an indexed photograph, and dropping a value from Type would be a
  /// change this phase has no reason to make.
  private static func isOfferable(_ value: String, _ field: InspectorFacetField) -> Bool {
    guard field == .camera else { return true }
    return value != "unset"
  }

  /// The head of a capped section — and the row that SAYS it is a head (diff-gate B1).
  ///
  /// The server's own order is count DESC (`_count_by`), so `prefix(limit)` IS the top `limit` by
  /// count. Two things then keep the cap from being a silent truncation, which the plan's pivot
  /// forbids in as many words:
  ///
  ///   1. The row currently IN FORCE survives whatever its position, and is APPENDED rather than
  ///      swapped in over an evicted head row — a body the reader chose must stay clearable from
  ///      the surface that applied it (the same rule the active-value re-offer above exists for),
  ///      and evicting a genuinely top-ranked body to make room for it would hide a row the
  ///      reader never asked to lose. A capped section is therefore `limit` rows, or `limit + 1`
  ///      while a body outside the head is in force.
  ///   2. Whatever is still not shown is COUNTED and stated in one trailing row. `hidden` is
  ///      computed from this same function's own output — `rows.count - head.count` — so the
  ///      number cannot drift from what was actually dropped, and it falls to zero (no row) the
  ///      moment the head plus the active row covers everything.
  private static func cappedRows(
    _ rows: [FilterPopoverRow], limit: Int, field: InspectorFacetField
  ) -> [FilterPopoverRow] {
    guard rows.count > limit else { return rows }
    var head = Array(rows.prefix(limit))
    if let active = rows.first(where: { $0.isActive }), !head.contains(where: { $0.isActive }) {
      head.append(active)
    }
    let hidden = rows.count - head.count
    guard hidden > 0 else { return head }
    head.append(overflowRow(field: field, hidden: hidden))
    return head
  }

  /// The "and there are more" row: a statement, never a filter.
  ///
  /// Disabled and never active, so it cannot be tapped and `applyFacetFilter` can never be called
  /// with its `value` — the identifier `filterPopoverRow-<field>-more` names a notice, not a
  /// camera body. It carries `hidden` as its `count` like every other row rather than a zero,
  /// because the popover publishes a row's number as its accessibility VALUE: a reader (and a
  /// test) can then read the exact number of bodies that did not fit.
  private static func overflowRow(field: InspectorFacetField, hidden: Int) -> FilterPopoverRow {
    FilterPopoverRow(
      field: field, value: overflowValue, title: overflowTitle(field, hidden: hidden),
      count: hidden, isActive: false, isEnabled: false, markRole: nil)
  }

  /// The overflow row's wire-shaped `value`, and the reason it is not one: no facet value is ever
  /// read out of this row (it is disabled), so this string only has to be stable for the
  /// identifier and distinct from a body a photographer owns.
  static let overflowValue = "more"

  private static func overflowTitle(_ field: InspectorFacetField, hidden: Int) -> String {
    switch field {
    case .camera: return "+\(hidden) more cameras"
    default: return "+\(hidden) more"
    }
  }

  private static func row(
    field: InspectorFacetField, value: String, title: String, count: Int, markRole: MarkRole?,
    query: GridImagesQuery
  ) -> FilterPopoverRow {
    let isActive = field.isActive(value, in: query)
    return FilterPopoverRow(
      field: field, value: value, title: title, count: count, isActive: isActive,
      isEnabled: count > 0 || isActive, markRole: markRole)
  }
}
