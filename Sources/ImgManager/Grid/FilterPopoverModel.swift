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
/// **There is no Camera row** (decision 1, gate round 1 B7): no `camera` (make/model) filter
/// parameter and no `camera` facet exist on `/api/images`, `/api/facets` or `/api/image-groups`,
/// and `camera_preview_only` answers a different question — "is this image's best source the
/// camera's own preview" — so it is not offered as a stand-in. IMGMGR-316 carries the cross-repo
/// facet; only an explicit owner answer adds the row, and then only as one more declaration below.
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
    /// Empty means the values come from the RESPONSE rather than from here. Only Type does: `ext`
    /// is a free-form string in the vendored contract (no enum), so a declared list of extensions
    /// would be invented wire vocabulary — the failure mode IMGMGR-173 records.
    var values: [DeclaredValue] = []
  }

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
    var rows = counts(field, facets).map { count in
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
    return rows
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
