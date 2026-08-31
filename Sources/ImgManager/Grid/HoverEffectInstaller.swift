import SwiftUI

/// The pointer-hover seam for the app's three photographic cells — a grid tile, a scene card and
/// a loupe filmstrip thumbnail. WP13 P11 (IMGMGR-220).
///
/// A value with a GENERIC `apply`, deliberately, and never an `AnyView`-erasing one in the shape
/// of `PointerGestureInstaller.attach`. Erasing the result would make the input and output types
/// equal, and `HoverEffectInstallerTests.liveWrapsItsContentRatherThanReturningIt` — the only
/// automated gate on the PRODUCTION value — is precisely the assertion that they differ. A `.live`
/// that returned its content unchanged would ship no hover at all while every call-site spy
/// stayed green (the failure mode `GridViewPointerGestureWiringTests` documents one layer down);
/// with a concrete wrapped return type, that regression cannot compile past the test.
///
/// The effect itself is the SYSTEM content effect the pointer capability map names ("system
/// content effects on tiles and toolbar items", design round p3220 §3.1) — never a custom hover
/// animation, and never glass on a cell (ADR-N1).
struct HoverEffectInstaller: Sendable {
  /// Test-only observation hook, nil in `.live`: the call-site legs
  /// (`HoverEffectWiringTests.tileCardAndFilmstripEachInstallTheHoverEffect`) substitute an
  /// installer that records, evaluate each cell's `body`, and assert it was invoked once per cell
  /// type — so deleting one `.hoverEffect` call site fails one named assertion rather than none.
  var onApply: (@MainActor @Sendable () -> Void)?

  /// The ONE installer the running app uses.
  static let live = HoverEffectInstaller()

  @MainActor
  func apply<Content: View>(_ content: Content) -> some View {
    onApply?()
    // RED (gate r1): the identity `.live` — the exact regression leg (a) exists to catch. The
    // GREEN commit returns `content.hoverEffect(.highlight)`.
    return content
  }
}
