import ImgManagerAPI
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
  case info = "Info"
  case stats = "Stats"
  var id: String { rawValue }
}

/// One component, one system presentation (WP28 P3, IMGMGR-450: `.inspector` on
/// `WorkspaceContent`, toggled by the Info control):
/// - Regular-2/3: the system inspector column trailing the grid — non-modal, collapsed at launch.
/// - Compact: the system adapts it to ONE sheet with Info/Stats as segments (fold item 7 —
///   not two separate phone-only surfaces, and no bottom-sheet-of-three-tabs like the mobile web's Library/Stats/Info).
///
/// Filters live in the Stats segment as touch rows (Do-NOT: no dense icon filter row) — never
/// crammed into chrome. No path row exists ANYWHERE in this view — there is no property on
/// `InspectorInfo` a path could even bind to (see that type's own doc comment).
struct InspectorView: View {
  @Bindable var store: GridStore
  @State private var tab: InspectorTab = .info
  @State private var detail: Components.Schemas.ImageDetail?
  let service: GridService

  var body: some View {
    VStack(spacing: 0) {
      Picker("Section", selection: $tab) {
        ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding()

      switch tab {
      case .info:
        infoSection
      case .stats:
        statsSection
      }
    }
    .task(id: store.focusedImageID) {
      detail = nil
      guard let id = store.focusedImageID else { return }
      detail = try? await service.detail(imageID: id)
    }
    // WP16 P2 (IMGMGR-298): the `.task(id: store.queryIdentity)` that used to sit here is gone.
    // It was the ONLY trigger for `GridStore.refreshFacets()`, so the counts existed only where
    // this view did — and decision 4 makes the Regular-3 column collapsible, removing the one
    // width at which it always fired. The trigger now lives on `RootView.workspace` through
    // `FacetsRefreshInstaller`, which is mounted in every layout mode and every collapse state.
    // This view still renders `store.facets` and is otherwise unchanged.
  }

  @ViewBuilder
  private var infoSection: some View {
    ScrollView {
      if let detail {
        let info = InspectorInfo.build(from: detail)
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 2) {
            Text(info.filename).font(.headline).accessibilityIdentifier("inspectorFilename")
            Text("\(info.type) · \(info.sourceBadge)").font(.caption).foregroundStyle(.secondary)
            Text(info.capturedAtDisplay).font(.caption).foregroundStyle(.secondary)
            Text(info.dimensions).font(.caption).foregroundStyle(.secondary)
          }

          // "My marks" — deliberately a DIFFERENT section/type from Lightroom below.
          section("My marks") {
            let mark = InspectorMarkBlock.build(from: detail.mark)
            Text(mark.stateLabel)
            if !mark.tags.isEmpty {
              Text(mark.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
          }

          // Lightroom — visibly separated (binding rule).
          section("Lightroom") {
            let lr = InspectorLightroomBlock.build(from: detail.lightroom)
            if !lr.sidecarPresent {
              Text("No Lightroom sidecar.").foregroundStyle(.secondary)
            } else {
              Text(
                [lr.rating.map { "Rating \($0)" }, lr.label, lr.good == true ? "Good" : nil]
                  .compactMap { $0 }.joined(separator: " · "))
            }
          }

          section("Camera") {
            ForEach(info.exifRows) { row in
              HStack {
                Text(row.label).foregroundStyle(.secondary)
                Spacer()
                Text(row.value)
              }
              .font(.caption)
            }
          }
        }
        .padding()
      } else {
        Text("Focus a photograph to see its details.")
          .foregroundStyle(.secondary)
          .padding()
      }
    }
  }

  @ViewBuilder
  private var statsSection: some View {
    // Touch-sized facet rows — never the web's dense icon filter row (Do-NOT). On Compact this
    // IS the filter surface (the sheet is the only place filters live on the phone), which is
    // why the Clear row and the row-level selected state matter here and not only on iPad.
    List {
      // Deliberately OUTSIDE the `facets` branch: when the counts fail to load with a filter
      // still active, the way out must not disappear along with them.
      clearFiltersRow
      if let facets = store.facets {
        ForEach(InspectorFacetFilters.statsFields) { field in
          facetRows(field, facets)
        }
      } else {
        ProgressView()
      }
    }
    .listStyle(.plain)
  }

  /// Present only while something is actually filtered: an always-visible "Clear" row would
  /// claim a filter surface is active when none is. It clears the FACET fields only — never the
  /// shoot scope, never the free-text query (see `InspectorFacetFilters`).
  @ViewBuilder
  private var clearFiltersRow: some View {
    let activeFilters = InspectorFacetFilters.activeCount(store.currentQuery)
    if activeFilters > 0 {
      Section {
        Button {
          Task { await store.clearFacetFilters() }
        } label: {
          HStack {
            Label("Clear filters", systemImage: "xmark.circle")
            Spacer()
            Text("\(activeFilters)").foregroundStyle(.secondary).monospacedDigit()
          }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("inspectorClearFilters")
      }
    }
  }

  /// Tapping a facet row sets that dimension's filter to the tapped value; tapping the value
  /// that is ALREADY active clears the dimension (one value per dimension — the web's chip
  /// semantics). Every tap routes through `GridStore.applyFilterChange`, which is what fires the
  /// "any effective filter change resets selection" rule and the generation-fenced reload; the
  /// Stats counts refresh with it because the workspace's `.task(id: store.queryIdentity)`
  /// (WP16 P2's `FacetsRefreshInstaller`) re-fires on the same mutation — from a host that is on
  /// screen whether or not this view is. A dimension the server sent nothing for renders as
  /// absence.
  @ViewBuilder
  private func facetRows(
    _ field: InspectorFacetField, _ facets: Components.Schemas.ImageFacets
  ) -> some View {
    // B1 (diff-gate round 1): the row SEQUENCE is derived once, by a pure function this view
    // renders verbatim — never assembled inline here. `FilterPopoverModel.statsRows` is what a
    // test can hold to "one row per value the server sent, in the server's order, relabelled but
    // never filtered"; assembling the list in the body would have put that guarantee somewhere no
    // test could reach, which is exactly how a narrowed rating section could have shipped green.
    let rows = FilterPopoverModel.statsRows(field, facets, store.currentQuery)
    if !rows.isEmpty {
      Section(field.title) {
        ForEach(rows) { row in
          Button {
            Task { await store.applyFacetFilter(field, value: row.value) }
          } label: {
            HStack {
              Image(systemName: row.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(row.isActive ? .primary : .tertiary)
              Text(row.title)
                .fontWeight(row.isActive ? .semibold : .regular)
              Spacer()
              Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
            }
          }
          .frame(minHeight: 44)
          .accessibilityAddTraits(row.isActive ? [.isSelected] : [])
        }
      }
    }
  }

  @ViewBuilder
  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
      content()
    }
  }
}

extension GridStore {
  /// A cheap, comparable stand-in for "the current query generation" the Stats fetch keys its
  /// `.task(id:)` on — recomputed whenever `applyFilterChange` actually changes `query` (it stays
  /// equal across a no-op call, correctly not re-firing the facets fetch). WP16 P2 (IMGMGR-298)
  /// moved that `.task` from this view to `RootView.workspace` via `FacetsRefreshInstaller`; the
  /// identity it keys on is unchanged, which is why the move cannot alter WHEN counts refetch.
  var queryIdentity: GridImagesQuery { query }
  var currentQuery: GridImagesQuery { query }
}
