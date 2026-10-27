import Foundation
import ImgManagerAPI
import Observation
import SwiftUI

/// The Presets row's sections (IMGMGR-658): the favourites (every preset with a
/// `favourite_rank`) first, then one section per group, everything in the server's own order
/// (`GET /api/presets`: most used first, then the favourites' seed rank, then name). A
/// favourite is listed once, in Favourites, not again in its group.
enum PresetStripSections {
  typealias Preset = Components.Schemas.PresetOut

  enum Kind: Hashable, Sendable {
    case favourites
    /// A group by its name; nil is the presets the catalogue files under no group.
    case group(String?)

    var title: String {
      switch self {
      case .favourites: "Favourites"
      case .group(let name): name ?? "Other"
      }
    }
  }

  struct Section: Equatable, Sendable {
    let kind: Kind
    let presets: [Preset]
  }

  /// How much of the row shows: the favourites section alone (with "All" to expand past it),
  /// or every section. A row with no favourites section has nothing to collapse to and shows
  /// every section in either scope.
  enum Scope: Equatable, Sendable {
    case favourites
    case all
  }

  /// The row's scope when its catalogue arrives (IMGMGR-660): collapsed to the favourites
  /// section when any preset is ranked, every section — the groups — when none is.
  static func defaultScope(catalogue: [Preset]) -> Scope {
    catalogue.contains { $0.favouriteRank != nil } ? .favourites : .all
  }

  static func sections(catalogue: [Preset]) -> [Section] {
    var result: [Section] = []
    let favourites = catalogue.filter { $0.favouriteRank != nil }
    if !favourites.isEmpty { result.append(Section(kind: .favourites, presets: favourites)) }
    var groupOrder: [String?] = []
    var grouped: [String?: [Preset]] = [:]
    for preset in catalogue where preset.favouriteRank == nil {
      if grouped[preset.group] == nil { groupOrder.append(preset.group) }
      grouped[preset.group, default: []].append(preset)
    }
    for group in groupOrder {
      result.append(Section(kind: .group(group), presets: grouped[group] ?? []))
    }
    return result
  }

  static func visible(_ sections: [Section], scope: Scope) -> [Section] {
    guard scope == .favourites, sections.first?.kind == .favourites else { return sections }
    return Array(sections.prefix(1))
  }

  /// Whether "All" is offered: the row is collapsed to its favourites and more sections exist.
  static func offersAll(_ sections: [Section], scope: Scope) -> Bool {
    visible(sections, scope: scope).count < sections.count
  }

  /// The hidden-row rule: no presets — `[]` (no lane), a 404 (a server without the route) and a
  /// failed fetch all leave the catalogue empty — and the row is not built at all.
  static func isRowHidden(catalogue: [Preset]) -> Bool {
    catalogue.isEmpty
  }
}

/// A chip's text and accessibility label (IMGMGR-658). An approximate preset (one the renderer
/// applies only approximately) carries `≈`, and its label names every reason the lane gave.
enum PresetChipLabel {
  static let approximateMark = "\u{2248}"

  static func text(_ preset: Components.Schemas.PresetOut) -> String {
    preset.approximate ? "\(approximateMark) \(preset.name)" : preset.name
  }

  static func accessibilityLabel(_ preset: Components.Schemas.PresetOut) -> String {
    guard preset.approximate else { return preset.name }
    let reasons = preset.approximateReasons.map(reasonCopy)
    guard !reasons.isEmpty else { return "\(preset.name), approximate" }
    return "\(preset.name), approximate: \(reasons.joined(separator: ", "))"
  }

  /// One reason token in words. The lane's classifier answers `look_table`, `mask_unknown` and
  /// `mask_image_subtype_<n>`; any other token is read out as its own words, never dropped.
  static func reasonCopy(_ reason: String) -> String {
    switch reason {
    case "look_table":
      return "look table not applied"
    case "mask_unknown":
      return "unsupported mask"
    default:
      let prefix = "mask_image_subtype_"
      if reason.hasPrefix(prefix) {
        return "image mask subtype \(reason.dropFirst(prefix.count))"
      }
      return reason.replacingOccurrences(of: "_", with: " ")
    }
  }
}

/// The loupe's presets (IMGMGR-658): the catalogue, fetched once per app session on the first
/// open (a failed fetch is asked again on the next), the row's scope, and the one render.
@Observable
@MainActor
final class PresetModel {
  typealias Preset = Components.Schemas.PresetOut

  private(set) var catalogue: [Preset] = []
  private(set) var catalogueState: LookModel.CatalogueState = .notLoaded
  var scope: PresetStripSections.Scope
  let render: PresetRenderModel

  private let fetchCatalogue: @Sendable () async throws -> [Preset]
  private let fetchFile: @Sendable (Int, String, String) async throws -> PresetFileFetchResult

  init(
    fetchCatalogue: @escaping @Sendable () async throws -> [Preset],
    fetchFile: @escaping @Sendable (Int, String, String) async throws -> PresetFileFetchResult,
    render: PresetRenderModel,
    initialScope: PresetStripSections.Scope? = nil
  ) {
    self.fetchCatalogue = fetchCatalogue
    self.fetchFile = fetchFile
    self.render = render
    self.pinnedScope = initialScope
    self.scope = initialScope ?? .all
  }

  /// A scope the caller fixed at init; nil lets the loaded catalogue pick the default.
  private let pinnedScope: PresetStripSections.Scope?

  var isRowHidden: Bool { PresetStripSections.isRowHidden(catalogue: catalogue) }

  func preset(id: String) -> Preset? { catalogue.first { $0.id == id } }

  func loadCatalogueIfNeeded() async {
    switch catalogueState {
    case .loading, .loaded:
      return
    case .notLoaded, .failed:
      break
    }
    catalogueState = .loading
    do {
      catalogue = try await fetchCatalogue()
      scope = pinnedScope ?? PresetStripSections.defaultScope(catalogue: catalogue)
      catalogueState = .loaded
    } catch {
      catalogue = []
      catalogueState = .failed
    }
  }

  /// The `ok` render's full-size bytes for the loupe's overlay, held in memory only. A 404 is
  /// the eviction-before-download case: the render model asks for the render again.
  func overlayData(for render: PresetRenderSnapshot) async -> Data? {
    guard let hash = render.renderHash else { return nil }
    let result: PresetFileFetchResult
    do {
      result = try await fetchFile(render.imageID, render.presetID, hash)
    } catch {
      return nil
    }
    switch result {
    case .ok(let data):
      return data
    case .notFound:
      self.render.renderVanished(
        imageID: render.imageID, presetID: render.presetID, renderHash: hash)
      return nil
    case .notModified, .tooLarge:
      return nil
    }
  }
}

/// The Presets row (IMGMGR-658): the second row of the Looks panel, under the looks strip, built
/// only when the server lists presets. A chip asks for its render; while it is requested or
/// pending the chip shows progress, an `ok` render paints over the loupe's preview (the
/// "Preset" toggle swaps back), a failure says why on long-press, and a timeout offers
/// "Check again".
struct PresetStripView: View {
  let store: GridStore
  let image: Components.Schemas.ImageSummary
  let share: ShareExportStore
  let launcher: ShareLauncher

  private var presets: PresetModel { store.presets }
  private var render: PresetRenderModel { store.presets.render }

  nonisolated static func chipIdentifier(for presetID: String) -> String {
    "loupePresetChip-\(presetID)"
  }

  var body: some View {
    let sections = PresetStripSections.sections(catalogue: presets.catalogue)
    let scope = presets.scope
    VStack(alignment: .leading, spacing: 4) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .bottom, spacing: 10) {
          ForEach(PresetStripSections.visible(sections, scope: scope), id: \.kind) { section in
            VStack(alignment: .leading, spacing: 2) {
              Text(section.kind.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
              HStack(spacing: 6) {
                ForEach(section.presets, id: \.id) { chip($0) }
              }
            }
          }
          if PresetStripSections.offersAll(sections, scope: scope) {
            Button("All") { presets.scope = .all }
              .font(.caption)
              .buttonStyle(.bordered)
              .focusable(false)
              .accessibilityIdentifier("loupePresetsAll")
          }
        }
        .padding(.horizontal, 12)
      }
      actions
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("loupePresetsRow")
  }

  private func chip(_ preset: Components.Schemas.PresetOut) -> some View {
    let phase = render.phase(imageID: image.id, presetID: preset.id)
    return Button {
      tap(preset, phase: phase)
    } label: {
      HStack(spacing: 4) {
        if phase == .requested || phase == .pending {
          ProgressView()
            .controlSize(.mini)
        }
        Text(PresetChipLabel.text(preset))
          .font(.caption)
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Capsule().fill(.quaternary))
      .overlay {
        Capsule().strokeBorder(
          Self.isActive(phase) ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .accessibilityIdentifier(Self.chipIdentifier(for: preset.id))
    .accessibilityLabel(PresetChipLabel.accessibilityLabel(preset))
    .accessibilityValue(Self.phaseValue(phase))
    .contextMenu {
      if case .failed(let failure) = phase {
        Text(failure.copy)
        Button("Try Again", systemImage: "arrow.clockwise") {
          render.start(imageID: image.id, presetID: preset.id)
        }
      }
    }
  }

  @ViewBuilder
  private var actions: some View {
    if let target = render.target, target.imageID == image.id {
      HStack(spacing: 12) {
        switch render.phase {
        case .ok(let snapshot):
          Button(render.showsPreset ? "Original" : "Preset") { render.toggleOverlay() }
            .focusable(false)
            .accessibilityIdentifier("loupePresetOverlayToggle")
          Button("Share", systemImage: "square.and.arrow.up") {
            launcher.startPreset(
              share: share, image: image,
              presetName: presets.preset(id: snapshot.presetID)?.name ?? snapshot.presetID,
              render: snapshot,
              renderGone: {
                render.invalidate(
                  imageID: snapshot.imageID, presetID: snapshot.presetID,
                  renderHash: snapshot.renderHash ?? "")
              })
          }
          .disabled(share.isPreparing)
          .focusable(false)
          .accessibilityIdentifier("loupePresetShare")
        case .timedOut:
          Text("Still rendering.")
            .foregroundStyle(.secondary)
          Button("Check Again") { render.checkAgain() }
            .focusable(false)
            .accessibilityIdentifier("loupePresetCheckAgain")
        case .failed:
          Text("Couldn't render. Long-press the preset for details.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("loupePresetFailed")
        case .requested, .pending:
          ProgressView()
            .controlSize(.small)
          Text("Rendering\u{2026}")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("loupePresetStatus")
        case .idle:
          EmptyView()
        }
      }
      .font(.caption)
      .padding(.horizontal, 12)
    }
  }

  private func tap(_ preset: Components.Schemas.PresetOut, phase: PresetRenderModel.Phase) {
    switch phase {
    case .requested, .pending:
      return
    case .ok:
      render.toggleOverlay()
    case .idle, .failed, .timedOut:
      render.start(imageID: image.id, presetID: preset.id)
    }
  }

  private static func isActive(_ phase: PresetRenderModel.Phase) -> Bool {
    phase != .idle
  }

  /// The chip's accessibility value: the render's phase in words, empty while idle.
  static func phaseValue(_ phase: PresetRenderModel.Phase) -> String {
    switch phase {
    case .idle: ""
    case .requested: "Requested"
    case .pending: "Rendering"
    case .ok: "Ready"
    case .failed: "Failed"
    case .timedOut: "Timed out"
    }
  }
}
