import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-658: the Presets row's sections, its "All" scope, the hidden-row rule and the chip
/// labels — the pure builders the row draws from.
@Suite("Preset strip sections and chips (IMGMGR-658)")
struct PresetStripTests {
  static func preset(
    _ id: String, group: String? = "Film", rank: Int? = nil, approximate: Bool = false,
    reasons: [String] = []
  ) -> Components.Schemas.PresetOut {
    Components.Schemas.PresetOut(
      approximate: approximate, approximateReasons: reasons, favouriteRank: rank, group: group,
      id: id, name: "Preset \(id)", useCount: 0)
  }

  @Test("Without a favourite_rank there is no Favourites section: groups in server order")
  func sectionsWithoutFavourites() {
    let catalogue = [
      Self.preset("a", group: "Mono"), Self.preset("b", group: "Film"),
      Self.preset("c", group: "Mono"), Self.preset("d", group: nil),
    ]
    let sections = PresetStripSections.sections(catalogue: catalogue)
    #expect(sections.map(\.kind) == [.group("Mono"), .group("Film"), .group(nil)])
    #expect(sections.map { $0.presets.map(\.id) } == [["a", "c"], ["b"], ["d"]])
    #expect(sections.map(\.kind.title) == ["Mono", "Film", "Other"])
    // Nothing to collapse to: every section shows, and "All" is not offered.
    #expect(PresetStripSections.visible(sections, scope: .favourites) == sections)
    #expect(!PresetStripSections.offersAll(sections, scope: .favourites))
  }

  @Test("Ranked presets lead as Favourites, in server order, and leave their groups")
  func sectionsWithFavourites() {
    let catalogue = [
      Self.preset("a", group: "Film"), Self.preset("b", group: "Film", rank: 2),
      Self.preset("c", group: "Mono", rank: 1), Self.preset("d", group: "Mono"),
    ]
    let sections = PresetStripSections.sections(catalogue: catalogue)
    #expect(sections.map(\.kind) == [.favourites, .group("Film"), .group("Mono")])
    #expect(sections.map { $0.presets.map(\.id) } == [["b", "c"], ["a"], ["d"]])
  }

  @Test("Collapsed to Favourites, \"All\" expands past them to every section")
  func allExpandsPastFavourites() {
    let sections = PresetStripSections.sections(catalogue: [
      Self.preset("a", rank: 1), Self.preset("b", group: "Film"), Self.preset("c", group: "Mono"),
    ])
    #expect(PresetStripSections.visible(sections, scope: .favourites).map(\.kind) == [.favourites])
    #expect(PresetStripSections.offersAll(sections, scope: .favourites))
    #expect(PresetStripSections.visible(sections, scope: .all) == sections)
    #expect(!PresetStripSections.offersAll(sections, scope: .all))
    // Favourites only: nothing past them, so no "All".
    let onlyFavourites = PresetStripSections.sections(catalogue: [Self.preset("a", rank: 1)])
    #expect(!PresetStripSections.offersAll(onlyFavourites, scope: .favourites))
  }

  @Test("The row is hidden exactly when the catalogue is empty")
  func hiddenRowRule() {
    #expect(PresetStripSections.isRowHidden(catalogue: []))
    #expect(!PresetStripSections.isRowHidden(catalogue: [Self.preset("a")]))
  }

  @Test(
    "An approximate chip carries ≈ and its label names the reason",
    arguments: [
      ("look_table", "look table not applied"),
      ("mask_unknown", "unsupported mask"),
      ("mask_image_subtype_0", "image mask subtype 0"),
      ("mask_image_subtype_3", "image mask subtype 3"),
      ("some_new_reason", "some new reason"),
    ])
  func approximateChipLabel(reason: String, words: String) {
    let preset = Self.preset("a", approximate: true, reasons: [reason])
    #expect(PresetChipLabel.text(preset) == "\u{2248} Preset a")
    #expect(PresetChipLabel.reasonCopy(reason) == words)
    #expect(PresetChipLabel.accessibilityLabel(preset) == "Preset a, approximate: \(words)")
  }

  @Test("Every reason of one preset is named, in the lane's order")
  func everyReasonNamed() {
    let preset = Self.preset(
      "a", approximate: true, reasons: ["look_table", "mask_image_subtype_3", "mask_unknown"])
    #expect(
      PresetChipLabel.accessibilityLabel(preset)
        == "Preset a, approximate: look table not applied, image mask subtype 3, unsupported mask"
    )
  }

  @Test("A faithful preset has no mark and a plain label; approximate without reasons says so")
  func plainAndReasonlessChips() {
    let plain = Self.preset("a")
    #expect(PresetChipLabel.text(plain) == "Preset a")
    #expect(PresetChipLabel.accessibilityLabel(plain) == "Preset a")
    let bare = Self.preset("b", approximate: true)
    #expect(PresetChipLabel.accessibilityLabel(bare) == "Preset b, approximate")
  }

  @Test("The row opens on Favourites when any preset is ranked, on the groups when none is")
  func defaultScopeFollowsRanks() {
    let ranked = [Self.preset("a", group: "Film"), Self.preset("b", group: "Mono", rank: 1)]
    let unranked = [Self.preset("a", group: "Film"), Self.preset("b", group: "Mono")]
    #expect(PresetStripSections.defaultScope(catalogue: ranked) == .favourites)
    #expect(PresetStripSections.defaultScope(catalogue: unranked) == .all)
    #expect(PresetStripSections.defaultScope(catalogue: []) == .all)
    let rankedSections = PresetStripSections.sections(catalogue: ranked)
    let opened = PresetStripSections.visible(
      rankedSections, scope: PresetStripSections.defaultScope(catalogue: ranked))
    #expect(opened.map(\.kind) == [.favourites])
    let unrankedSections = PresetStripSections.sections(catalogue: unranked)
    let groups = PresetStripSections.visible(
      unrankedSections, scope: PresetStripSections.defaultScope(catalogue: unranked))
    #expect(groups.map(\.kind) == [.group("Film"), .group("Mono")])
  }

  @MainActor
  @Test("The loaded catalogue sets the model's scope: Favourites when ranked, all when not")
  func modelDefaultScope() async {
    for ranked in [true, false] {
      let model = PresetModel(
        fetchCatalogue: { [Self.preset("a", rank: ranked ? 1 : nil), Self.preset("b")] },
        fetchFile: { _, _, _ in .notFound },
        render: PresetRenderModel(
          request: { _, _ in throw PresetRenderError.gone },
          status: { _, _ in throw PresetRenderError.gone }))
      await model.loadCatalogueIfNeeded()
      #expect(model.scope == (ranked ? .favourites : .all))
    }
  }

  @MainActor
  @Test("A 404, [] or a failed fetch leaves the model's row hidden; a listing shows it")
  func modelHiddenRow() async {
    for outcome in [0, 1, 2, 3] {
      let model = PresetModel(
        fetchCatalogue: {
          switch outcome {
          case 0: return []
          case 1: throw GridServiceError.unreachable
          default: return [Self.preset("a")]
          }
        },
        fetchFile: { _, _, _ in .notFound },
        render: PresetRenderModel(
          request: { _, _ in throw PresetRenderError.gone },
          status: { _, _ in throw PresetRenderError.gone }))
      await model.loadCatalogueIfNeeded()
      #expect(model.isRowHidden == (outcome < 2))
    }
  }
}
