#if DEBUG
  import SwiftUI
  import UIKit

  /// WP28 P4 (IMGMGR-451): EVIDENCE, fixture-only. The materials suite captures each surface under
  /// the REAL Reduce Transparency and Increase Contrast settings, set on the simulator by the gate
  /// (bin/gate-lib.sh `gate_materials_mode_run`). Whether a setting took is read HERE, in the app,
  /// before every capture: a screenshot taken while the app did not see the setting would be
  /// evidence of nothing.
  ///
  /// The value carries both sources — UIKit's `UIAccessibility` flags (what the plan names) and the
  /// SwiftUI environment values `MaterialPolicy` actually reads — so a disagreement between the
  /// two is visible in the log instead of hidden behind one of them.
  ///
  /// Mounted by `RootView` only under `-UITestMaterialsProbe`. It is 1 × 1 pt, clear, and takes no
  /// hits, like `GridView`'s `debugProbe`.
  struct MaterialsSettingsProbe: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
      Text("materialsSettingsProbe")
        .font(.system(size: 1))
        .foregroundStyle(.clear)
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityIdentifier("materialsSettingsProbe")
        .accessibilityValue(
          Self.reading(
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            darkerSystemColors: UIAccessibility.isDarkerSystemColorsEnabled,
            environmentReduceTransparency: reduceTransparency,
            environmentIncreasedContrast: colorSchemeContrast == .increased))
    }

    /// `reduceTransparency=1 darkerSystemColors=0 envReduceTransparency=1 envIncreasedContrast=0`
    static func reading(
      reduceTransparency: Bool, darkerSystemColors: Bool,
      environmentReduceTransparency: Bool, environmentIncreasedContrast: Bool
    ) -> String {
      func bit(_ value: Bool) -> String { value ? "1" : "0" }
      return "reduceTransparency=\(bit(reduceTransparency)) "
        + "darkerSystemColors=\(bit(darkerSystemColors)) "
        + "envReduceTransparency=\(bit(environmentReduceTransparency)) "
        + "envIncreasedContrast=\(bit(environmentIncreasedContrast))"
    }
  }
#endif
