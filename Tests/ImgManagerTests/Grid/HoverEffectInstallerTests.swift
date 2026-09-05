import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// WP13 P11 (IMGMGR-220), hover leg (a): the automated gate on the PRODUCTION installer value.
///
/// The call-site legs in `HoverEffectWiringTests` prove each cell calls *an* installer. None of
/// them can tell an installer that wraps its content from one that hands it straight back — a
/// `.live` that returned its input unchanged would ship no hover at all with every spy green,
/// which is the failure mode `GridViewPointerGestureWiringTests` records one layer down. This
/// test closes that gap at the only seam a unit test can reach without a render host.
@MainActor
@Suite("Hover — the production installer actually wraps what it is handed")
struct HoverEffectInstallerTests {

  /// Applying `.hoverEffect` necessarily produces a `ModifiedContent`-shaped wrapper, and an
  /// identity installer necessarily does not. So the assertion is a TYPE inequality: a no-op
  /// `.live` fails it, which is this test's whole purpose. It is also why
  /// `HoverEffectInstaller.apply` must return a concrete wrapped type and never `AnyView` —
  /// erasing the result would make input and output types equal and silently defeat the check.
  @Test("`.live` wraps its content rather than returning it")
  func liveWrapsItsContentRatherThanReturningIt() {
    let input = Color.clear
    let output = HoverEffectInstaller.live.apply(input)

    let inputType = String(describing: type(of: input))
    let outputType = String(describing: type(of: output))
    // Positive control for the inequality below: the input's own type name really was read, so
    // the comparison cannot pass on two empty strings.
    #expect(inputType == "Color", "the probe input is not the view it claims to be: \(inputType)")
    // ONE literal, never two concatenated: `#expect` takes a `Comment`, and `+` on a Comment is
    // not a string append (the trap `GridMoreMenuTests` already records; gate p11-red2).
    #expect(
      outputType != inputType,
      "HoverEffectInstaller.live returned its content unchanged (\(outputType)) — no hover effect is installed anywhere in the app."
    )
  }
}

/// Hover legs (b): each of the three photographic cells installs the effect, asserted ONE CELL
/// TYPE AT A TIME so deleting a single `.hoverEffect` call site fails a single named assertion
/// rather than none.
///
/// Leg (c) — that iPadOS actually RENDERS a hover treatment under a real pointer — is a named
/// manual acceptance probe on device, not an automated gate, and this suite says so plainly:
/// neither this test nor the installer test above can prove it.
@MainActor
@Suite("Hover — every photographic cell installs the effect")
struct HoverEffectWiringTests {

  /// Explicitly `@MainActor`: the installer's hook is a `@Sendable` closure, so what it captures
  /// has to be Sendable, and global-actor isolation is what makes this box so.
  @MainActor
  private final class Spy {
    var count = 0
  }

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() -> GridStore {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  private func makeStackRow(id: Int) -> Components.Schemas.StackBrowseStackRow {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: nil, editedCount: 0, hasPick: false, kind: .stack, matchedCount: 3,
      memberCount: 3,
      pickedCount: 0, representative: makeImage(id: id), stackId: id)
  }

  @Test("A tile, a scene card and a filmstrip thumbnail each install the hover effect")
  func tileCardAndFilmstripEachInstallTheHoverEffect() {
    let store = makeStore()
    let plan = TileRenderPlan.display(tier: .grid, size: CGSize(width: 120, height: 80))

    let tileSpy = Spy()
    var tile = TileView(
      image: makeImage(id: 1), plan: plan, isFocused: false, isSelected: false,
      isSelectMode: false, showsFilenamePlate: false, store: store)
    tile.hoverEffectInstaller = HoverEffectInstaller(onApply: { tileSpy.count += 1 })
    _ = tile.body
    #expect(tileSpy.count == 1, "TileView does not install the hover effect")

    let cardSpy = Spy()
    var card = SceneCardView(
      row: makeStackRow(id: 7), plan: plan, isExpanded: false, store: store)
    card.hoverEffectInstaller = HoverEffectInstaller(onApply: { cardSpy.count += 1 })
    _ = card.body
    #expect(cardSpy.count == 1, "SceneCardView does not install the hover effect")

    let stripSpy = Spy()
    var thumbnail = FilmstripThumbnail(
      image: makeImage(id: 2), isFocused: false, store: store)
    thumbnail.hoverEffectInstaller = HoverEffectInstaller(onApply: { stripSpy.count += 1 })
    _ = thumbnail.body
    #expect(stripSpy.count == 1, "FilmstripThumbnail does not install the hover effect")
  }
}
