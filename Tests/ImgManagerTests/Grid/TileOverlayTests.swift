import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// R3-5 (IMGMGR-539): the Tile overlays toggles — their defaults, their persistence across a
/// relaunch, and the pure badge choice they gate (priority order and two-badge cap unchanged).
@Suite("Tile overlays (R3-5)")
@MainActor
struct TileOverlayTests {

  private static let allOn = TileOverlaySet(
    marks: true, edited: true, lightroomRating: true, sourceKind: true, filename: true)
  private static let allOff = TileOverlaySet(
    marks: false, edited: false, lightroomRating: false, sourceKind: false, filename: false)

  private func items(
    changedElsewhere: Bool = false, selected: Bool = false, pick: Bool = true,
    hasEdit: Bool = true, rating: Int? = 3, sourceKind: String? = "raw_embedded",
    overlays: TileOverlaySet
  ) -> [TileBadgeItem] {
    TileBadgeItem.items(
      changedElsewhere: changedElsewhere, selected: selected, mark: pick ? .pick : nil,
      hasEdit: hasEdit, rating: rating, sourceKind: sourceKind, overlays: overlays)
  }

  @Test("Defaults on an empty suite: Marks and Edited on, the other three off")
  func defaults() {
    let preferences = GridPreferences(defaults: makeEphemeralDefaults())
    #expect(preferences.overlayMarks)
    #expect(preferences.overlayEdited)
    #expect(!preferences.overlayLightroomRating)
    #expect(!preferences.overlaySourceKind)
    #expect(!preferences.filenamePlates)
    #expect(TileOverlaySet(preferences: preferences) == .defaults)
  }

  @Test("All five toggles persist across a relaunch on the same suite")
  func persistAcrossRelaunch() {
    let suite = makeEphemeralDefaults()
    let first = GridPreferences(defaults: suite)
    first.overlayMarks = false
    first.overlayEdited = false
    first.overlayLightroomRating = true
    first.overlaySourceKind = true
    first.filenamePlates = true

    let relaunched = GridPreferences(defaults: suite)
    #expect(!relaunched.overlayMarks)
    #expect(!relaunched.overlayEdited)
    #expect(relaunched.overlayLightroomRating)
    #expect(relaunched.overlaySourceKind)
    #expect(relaunched.filenamePlates)
  }

  @Test("A non-Bool stored value falls back to each overlay's default, never to true")
  func garbageFallsBackToDefault() {
    let suite = makeEphemeralDefaults()
    for key in [
      GridPreferences.overlayMarksKey, GridPreferences.overlayEditedKey,
      GridPreferences.overlayLightroomRatingKey, GridPreferences.overlaySourceKindKey,
    ] {
      suite.set("yes", forKey: key)
    }
    let preferences = GridPreferences(defaults: suite)
    #expect(preferences.overlayMarks == GridPreferences.overlayMarksDefault)
    #expect(preferences.overlayEdited == GridPreferences.overlayEditedDefault)
    #expect(!preferences.overlayLightroomRating)
    #expect(!preferences.overlaySourceKind)
  }

  @Test("All overlays on: the legacy order, the Lightroom slot after Edited, source kind last")
  func allOnKeepsTheLegacyOrder() {
    let all = items(changedElsewhere: true, selected: true, overlays: Self.allOn)
    #expect(all == [.changedElsewhere, .selected, .pick, .edited, .lightroomRating, .sourceKind])
  }

  @Test("Each overlay removes only its own badge")
  func eachOverlayGatesItsOwnBadge() {
    var marksOff = Self.allOn
    marksOff.marks = false
    #expect(items(overlays: marksOff) == [.edited, .lightroomRating, .sourceKind])
    let dislikeOn = TileBadgeItem.items(
      changedElsewhere: false, selected: false, mark: .dislike, hasEdit: false, rating: nil,
      sourceKind: nil, overlays: Self.allOn)
    #expect(dislikeOn == [.dislike])
    let dislikeOff = TileBadgeItem.items(
      changedElsewhere: false, selected: false, mark: .dislike, hasEdit: false, rating: nil,
      sourceKind: nil, overlays: marksOff)
    #expect(dislikeOff.isEmpty)
    var editedOff = Self.allOn
    editedOff.edited = false
    #expect(items(overlays: editedOff) == [.pick, .lightroomRating, .sourceKind])
    var ratingOff = Self.allOn
    ratingOff.lightroomRating = false
    #expect(items(overlays: ratingOff) == [.pick, .edited, .sourceKind])
    var kindOff = Self.allOn
    kindOff.sourceKind = false
    #expect(items(overlays: kindOff) == [.pick, .edited, .lightroomRating])
  }

  @Test("Changed-elsewhere and the Select tick survive every overlay turned off")
  func mandatoryBadgesSurviveAllOff() {
    let shown = items(changedElsewhere: true, selected: true, overlays: Self.allOff)
    #expect(shown == [.changedElsewhere, .selected])
  }

  @Test("Ratings 1, 3 and 5 draw ★N and speak 'Lightroom rating N'", arguments: [1, 3, 5])
  func ratingDrawsStarN(rating: Int) {
    let content = TileBadgeItem.lightroomRating.content(rating: rating, sourceKind: nil)
    #expect(content == .rating(rating))
    #expect(TileBadgeContent.ratingText(rating) == "★\(rating)")
    #expect(TileBadgeContent.ratingLabel(rating) == "Lightroom rating \(rating)")
    #expect(Set([1, 3, 5].map(TileBadgeContent.ratingText)).count == 3)
  }

  @Test(
    "No rating, unrated 0, rejected -1 or 6 draws nothing and frees the slot",
    arguments: [nil, 0, -1, 6] as [Int?])
  func absentRatingFreesTheSlot(rating: Int?) {
    #expect(TileBadgeItem.lightroomRating.content(rating: rating, sourceKind: nil) == nil)
    let shown = items(pick: false, hasEdit: false, rating: rating, overlays: Self.allOn)
    #expect(shown == [.sourceKind])
  }

  @Test("An unknown or absent source kind draws no badge; a known one carries its label")
  func sourceKindContent() {
    #expect(TileBadgeItem.sourceKind.content(rating: nil, sourceKind: nil) == nil)
    #expect(TileBadgeItem.sourceKind.content(rating: nil, sourceKind: "mystery") == nil)
    #expect(
      TileBadgeItem.sourceKind.content(rating: nil, sourceKind: "raw_embedded")
        == .sourceKind(symbol: "camera", label: "Camera preview"))
  }

  @Test("The cap of two still applies after the overlays")
  func capOfTwo() {
    let all = items(changedElsewhere: true, overlays: Self.allOn)
    #expect(TileBadgeItem.cap == 2)
    #expect(Array(all.prefix(TileBadgeItem.cap)) == [.changedElsewhere, .pick])
  }
}
