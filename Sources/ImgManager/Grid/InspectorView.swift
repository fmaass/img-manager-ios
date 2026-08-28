import ImgManagerAPI
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
  case info = "Info"
  case stats = "Stats"
  var id: String { rawValue }
}

/// One component, three presentations (P4 Approach + fold item 7):
/// - Regular-3: a permanent column (`RootView.detailColumn`).
/// - Regular-2: a slide-over (presented as a sheet here — see the file's scope note).
/// - Compact: ONE sheet with Info/Stats as segments (fold item 7 — not two separate phone-only
///   surfaces, and no bottom-sheet-of-three-tabs like the mobile web's Library/Stats/Info).
///
/// Filters live in the Stats segment as touch rows (Do-NOT: no dense icon filter row) — never
/// crammed into chrome. No path row exists ANYWHERE in this view — there is no property on
/// `InspectorInfo` a path could even bind to (see that type's own doc comment).
struct InspectorView: View {
  @Bindable var store: GridStore
  @State private var tab: InspectorTab = .info
  @State private var detail: Components.Schemas.ImageDetail?
  @State private var facets: Components.Schemas.ImageFacets?
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
    .task(id: store.queryIdentity) {
      facets = try? await service.facets(store.currentQuery)
    }
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
    // Touch-sized facet rows — never the web's dense icon filter row (Do-NOT).
    List {
      if let facets {
        facetRows("Mark", facets.mark) { value, query in query.mark = value }
        facetRows("Rating", facets.rating) { value, query in query.ratingMin = Int(value) }
        facetRows("Label", facets.label) { value, query in query.label = value }
        facetRows("Keyword", facets.keyword) { value, query in query.keyword = value }
        facetRows("Tag", facets.tag) { value, query in query.tag = value }
        facetRows("Source", facets.sourceTier) { value, query in
          query.sourceTier = GridSourceTier(rawValue: value)
        }
      } else {
        ProgressView()
      }
    }
    .listStyle(.plain)
  }

  /// Tapping a facet row sets that dimension's filter to the tapped value — a clean toggle
  /// (tap a different value in the same dimension to switch, no explicit "clear" row here) —
  /// and routes through `GridStore.applyFilterChange`, which is what fires the "any effective
  /// filter change resets selection" rule.
  @ViewBuilder
  private func facetRows(
    _ title: String, _ counts: [Components.Schemas.FacetCount]?,
    apply: @escaping (String, inout GridImagesQuery) -> Void
  ) -> some View {
    if let counts, !counts.isEmpty {
      Section(title) {
        ForEach(counts, id: \.value) { count in
          Button {
            Task { await store.applyFilterChange { apply(count.value, &$0) } }
          } label: {
            HStack {
              Text(count.value)
              Spacer()
              Text("\(count.count)").foregroundStyle(.secondary)
            }
          }
          .frame(minHeight: 44)
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
  /// A cheap, comparable stand-in for "the current query generation" the inspector's Stats
  /// fetch keys its `.task(id:)` on — recomputed whenever `applyFilterChange` actually changes
  /// `query` (it stays equal across a no-op call, correctly not re-firing the facets fetch).
  var queryIdentity: GridImagesQuery { query }
  var currentQuery: GridImagesQuery { query }
}
