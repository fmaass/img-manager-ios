import SwiftUI
import Testing

@testable import ImgManager

/// The plan's own new-spec line for P0a: "a layout smoke asserting the root resolves
/// three columns at a wide injected size and one at a narrow one — driven by injected
/// size, never by idiom." `LayoutResolver.resolve` IS the root's resolution logic
/// (`RootView` calls nothing else to decide); testing it directly, with injected widths,
/// is testing the root's behavior without needing a hosted UI harness.
@Suite("Layout mode resolution (P0a mechanism smoke test)")
struct LayoutModeTests {

  @Test("Wide injected width resolves to the three-column (regular) layout")
  func wideWidthResolvesRegular() {
    let mode = LayoutResolver.resolve(width: 1024)
    #expect(mode == .regular)
    #expect(LayoutResolver.columnVisibility(for: mode) == .all)
  }

  @Test("Narrow injected width resolves to the single-column (compact) layout")
  func narrowWidthResolvesCompact() {
    let mode = LayoutResolver.resolve(width: 390)
    #expect(mode == .compact)
    #expect(LayoutResolver.columnVisibility(for: mode) == .detailOnly)
  }

  @Test("Resolution is a pure function of width — idiom plays no part")
  func resolutionIsWidthOnly() {
    // There is no idiom parameter to pass here at all — that absence, checked
    // mechanically by the mac-gate's device-idiom absence grep, is the actual
    // guarantee. This asserts the function is at least deterministic in width alone.
    #expect(LayoutResolver.resolve(width: 820) == LayoutResolver.resolve(width: 820))
    #expect(LayoutResolver.resolve(width: 500) == .compact)
    #expect(LayoutResolver.resolve(width: 700) == .regular)
  }
}
