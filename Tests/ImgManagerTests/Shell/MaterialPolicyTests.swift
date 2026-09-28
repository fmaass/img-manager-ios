import Testing

@testable import ImgManager

/// WP28 P4 (IMGMGR-451): the material policy's table — (Reduce Transparency, Increase Contrast)
/// in all four combinations, for every base a site can declare.
@Suite("Material policy (WP28 P4)")
struct MaterialPolicyTests {

  @Test("Neither setting: each site keeps its system material, no stroke")
  func defaultKeepsTheSystemMaterial() {
    #expect(
      MaterialPolicy.resolve(.thinMaterial, reduceTransparency: false, increasedContrast: false)
        == .init(fill: .thinMaterial, strokesSeparator: false))
    #expect(
      MaterialPolicy.resolve(.bar, reduceTransparency: false, increasedContrast: false)
        == .init(fill: .bar, strokesSeparator: false))
  }

  @Test("Reduce Transparency: opaque secondarySystemBackground, no stroke")
  func reduceTransparencyIsOpaque() {
    for base in MaterialPolicy.Base.allCases {
      #expect(
        MaterialPolicy.resolve(base, reduceTransparency: true, increasedContrast: false)
          == .init(fill: .opaqueSecondaryBackground, strokesSeparator: false))
    }
  }

  @Test("Increase Contrast: the system material plus a separator stroke")
  func increaseContrastStrokes() {
    #expect(
      MaterialPolicy.resolve(.thinMaterial, reduceTransparency: false, increasedContrast: true)
        == .init(fill: .thinMaterial, strokesSeparator: true))
    #expect(
      MaterialPolicy.resolve(.bar, reduceTransparency: false, increasedContrast: true)
        == .init(fill: .bar, strokesSeparator: true))
  }

  @Test("Both settings: opaque AND stroked")
  func bothSettingsCombine() {
    for base in MaterialPolicy.Base.allCases {
      #expect(
        MaterialPolicy.resolve(base, reduceTransparency: true, increasedContrast: true)
          == .init(fill: .opaqueSecondaryBackground, strokesSeparator: true))
    }
  }

  /// Glass on glass: a fill inside system glass is never a material, whatever the settings say.
  @Test(
    "Inside system glass: never a material, in any of the four combinations",
    arguments: [false, true], [false, true])
  func insideSystemGlassIsNeverAMaterial(reduceTransparency: Bool, increasedContrast: Bool) {
    let resolution = MaterialPolicy.resolve(
      .insideSystemGlass, reduceTransparency: reduceTransparency,
      increasedContrast: increasedContrast)
    #expect(resolution.fill == .opaqueSecondaryBackground)
    #expect(resolution.strokesSeparator == increasedContrast)
  }
}
