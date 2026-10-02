import SwiftUI
import Testing

@testable import ImgManager

/// IMGMGR-469 (ADR-N1 Amendment 1): which widths extend the grid's photographs under the
/// sidebar. The visual result — the mirrored photographs under the floating sidebar — is the
/// iPad screenshot `IMGMGR-469-regular3-collapsed-grid-under-sidebar`
/// (`GridBackgroundExtensionScreenshotUITests`); this suite pins the width rule that decides
/// whether `GridView`'s scroll content asks for it at all.
@MainActor
@Suite("Grid background extension — Regular widths only")
struct GridBackgroundExtensionTests {

  @Test("Regular-2 and Regular-3 extend the grid under the sidebar; Compact does not")
  func extendsAtRegularWidthsOnly() {
    #expect(GridBackgroundExtension.extendsUnderSidebar(for: .regular2))
    #expect(GridBackgroundExtension.extendsUnderSidebar(for: .regular3))
    #expect(!GridBackgroundExtension.extendsUnderSidebar(for: .compact))
  }
}
