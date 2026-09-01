import SwiftUI
import Testing
import UIKit

@testable import ImgManager

/// WP16 P1 (IMGMGR-299, p3332 decision 5 — "Marks gain the web's colors"): the badge truth table,
/// the untouched SF-Symbol vocabulary, and the RESOLVED colour behind each mark role.
///
/// The colour leg is deliberately an RGB assertion rather than a name-existence one: a colour set
/// whose swatch is still the template default has a perfectly good name. Resolving in BOTH
/// appearances is what pins the plan's "appearance-INDEPENDENT" decision — a light-appearance
/// variant creeping in fails the `.light` pass against the same expected triple.
@MainActor
@Suite("Mark palette (WP16 P1, p3332 decision 5)")
struct MarkPaletteTests {

  /// The web's own `mark-pick` / `mark-reject` / `mark-edited` DEFAULT values, verbatim
  /// (`frontend/tailwind.config.js`, pinned web-side by `frontend/tests/workspaceTokens.spec.ts`).
  /// Written out here rather than read from the palette, so the test states the hex independently
  /// of the code that ships it.
  private func expectedComponents(for role: MarkRole) -> (red: Int, green: Int, blue: Int) {
    switch role {
    case .pick: return (0x7f, 0xe0, 0xb2)
    case .dislike: return (0xf0, 0xa3, 0xaa)
    case .edited: return (0xc9, 0xa4, 0x4d)
    }
  }

  /// 8-bit sRGB components of a colour already resolved for one appearance.
  private func components(of color: UIColor, style: UIUserInterfaceStyle) throws -> (
    red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
  ) {
    let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    let read = resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    try #require(read, "the resolved colour is not readable in an RGB space")
    return (red * 255, green * 255, blue * 255, alpha)
  }

  @Test(
    "Each role's asset colour resolves to its web hex in BOTH appearances",
    arguments: MarkRole.allCases)
  func assetColourResolvesToTheWebHexInBothAppearances(role: MarkRole) throws {
    let named = try #require(
      UIColor(named: role.assetName, in: .main, compatibleWith: nil),
      "\(role.assetName) is missing from Assets.xcassets — UIColor(named:) returned nil")
    let expected = expectedComponents(for: role)

    for style in [UIUserInterfaceStyle.light, .dark] {
      let got = try components(of: named, style: style)
      #expect(abs(got.red - CGFloat(expected.red)) <= 1, "red, \(role.assetName), style \(style)")
      #expect(
        abs(got.green - CGFloat(expected.green)) <= 1, "green, \(role.assetName), style \(style)")
      #expect(
        abs(got.blue - CGFloat(expected.blue)) <= 1, "blue, \(role.assetName), style \(style)")
      // A transparent swatch renders nothing at all, which no other assertion here would catch.
      #expect(abs(got.alpha - 1) <= 1.0 / 255.0, "alpha, \(role.assetName), style \(style)")
    }
  }

  @Test(
    "MarkPalette.color(for:) hands back that asset colour — the one place a hue is named",
    arguments: MarkRole.allCases)
  func paletteResolvesTheAssetColour(role: MarkRole) throws {
    let expected = expectedComponents(for: role)
    let got = try components(of: UIColor(MarkPalette.color(for: role)), style: .dark)
    #expect(abs(got.red - CGFloat(expected.red)) <= 1, "red, \(role)")
    #expect(abs(got.green - CGFloat(expected.green)) <= 1, "green, \(role)")
    #expect(abs(got.blue - CGFloat(expected.blue)) <= 1, "blue, \(role)")
  }

  @Test("Only Pick, Dislike and Edited take a colour — Select, Good and changed-elsewhere do not")
  func badgeTruthTable() {
    #expect(TileBadgeItem.pick.markRole == .pick)
    #expect(TileBadgeItem.dislike.markRole == .dislike)
    #expect(TileBadgeItem.edited.markRole == .edited)
    // p3332 decision 5 names three roles and no more. Good is Lightroom's read-only flag and must
    // never look like this app's writable Pick (the web pins that as a value test); Select's tick
    // and the changed-elsewhere glyph are not verdicts at all.
    #expect(TileBadgeItem.selected.markRole == nil)
    #expect(TileBadgeItem.good.markRole == nil)
    #expect(TileBadgeItem.changedElsewhere.markRole == nil)
    // A seventh badge added later has to answer this question deliberately.
    #expect(TileBadgeItem.allCases.count == 6)
  }

  @Test("The badge SF-Symbols are byte-identical to 4753450 — colour never replaces shape")
  func badgeSymbolsUnchanged() {
    #expect(TileBadgeItem.selected.systemImage == "checkmark.circle.fill")
    #expect(TileBadgeItem.pick.systemImage == "hand.thumbsup.fill")
    #expect(TileBadgeItem.dislike.systemImage == "hand.thumbsdown.fill")
    #expect(TileBadgeItem.edited.systemImage == "pencil.circle.fill")
    #expect(TileBadgeItem.good.systemImage == "star.fill")
    #expect(TileBadgeItem.changedElsewhere.systemImage == "arrow.triangle.2.circlepath")
  }

  @Test("The two latch verbs and the two loupe controls read the SAME table as the badges")
  func verbAndLoupeControlRolesAgreeWithTheBadges() {
    #expect(LatchVerb.pick.markRole == TileBadgeItem.pick.markRole)
    #expect(LatchVerb.dislike.markRole == TileBadgeItem.dislike.markRole)
    #expect(LoupeMarkPresentation.Control.pick.markRole == TileBadgeItem.pick.markRole)
    #expect(LoupeMarkPresentation.Control.dislike.markRole == TileBadgeItem.dislike.markRole)
  }
}
