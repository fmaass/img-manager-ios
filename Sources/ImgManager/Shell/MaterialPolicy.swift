import SwiftUI
import UIKit

/// WP28 P4 (IMGMGR-451): the one place that decides how the app's OWN drawn chrome is filled — the
/// capsules and rows this app paints itself (the options row, the mode rows, the banners, the
/// action bar, the loupe's mark bar and filmstrip, the refresh capsule). System bars, the sidebar,
/// the tab bar and sheets are the system's and are not touched here (ADR-N1: system components
/// only, no custom glass).
///
/// The rules (p4128 "Materials and sizing rules", plan Phase 4):
/// - by default a site keeps the system material it has always used;
/// - under Reduce Transparency every site is opaque `secondarySystemBackground`;
/// - under Increase Contrast every site also draws a separator stroke along its edge.
///
/// A fill that sits INSIDE system glass (`insideSystemGlass`) is never a material, in any mode:
/// a material on glass is glass on glass. That is the refresh capsule, which rides the Regular
/// sidebar's list.
///
/// The inputs come from the environment (`accessibilityReduceTransparency`,
/// `colorSchemeContrast`) through `chromeFill(_:)`; `resolve` is the pure table the unit tests pin.
enum MaterialPolicy {

  /// What a site draws when no accessibility setting asks for more.
  enum Base: Equatable, Sendable, CaseIterable {
    /// `.thinMaterial` — the rows and capsules over the grid.
    case thinMaterial
    /// `.bar` — the action bar, the loupe's mark bar and its filmstrip.
    case bar
    /// Inside system glass (the Regular sidebar): opaque, never a material.
    case insideSystemGlass
  }

  enum Fill: Equatable, Sendable {
    case thinMaterial
    case bar
    /// `Color(uiColor: .secondarySystemBackground)`.
    case opaqueSecondaryBackground
  }

  struct Resolution: Equatable, Sendable {
    let fill: Fill
    /// A `separator` stroke along the fill's edge.
    let strokesSeparator: Bool
  }

  static func resolve(
    _ base: Base, reduceTransparency: Bool, increasedContrast: Bool
  ) -> Resolution {
    let fill: Fill
    if reduceTransparency {
      fill = .opaqueSecondaryBackground
    } else {
      switch base {
      case .thinMaterial: fill = .thinMaterial
      case .bar: fill = .bar
      case .insideSystemGlass: fill = .opaqueSecondaryBackground
      }
    }
    return Resolution(fill: fill, strokesSeparator: increasedContrast)
  }

  static func style(for fill: Fill) -> AnyShapeStyle {
    switch fill {
    case .thinMaterial: AnyShapeStyle(.thinMaterial)
    case .bar: AnyShapeStyle(.bar)
    case .opaqueSecondaryBackground: AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
    }
  }
}

extension View {
  /// A full-width chrome row or bar. Drawn with `.background(_:)`'s own default
  /// (`ignoresSafeAreaEdges: .all`), exactly as the `.background(.thinMaterial)` and
  /// `.background(.bar)` calls it replaces, so the default mode renders what it always did.
  func chromeFill(_ base: MaterialPolicy.Base) -> some View {
    modifier(ChromeRowFill(base: base))
  }

  /// A chrome capsule or other shape, as `.background(_:in:)` drew it.
  func chromeFill<S: InsettableShape>(_ base: MaterialPolicy.Base, in shape: S) -> some View {
    modifier(ChromeShapeFill(base: base, shape: shape))
  }
}

private struct ChromeRowFill: ViewModifier {
  let base: MaterialPolicy.Base
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  func body(content: Content) -> some View {
    let resolution = MaterialPolicy.resolve(
      base, reduceTransparency: reduceTransparency,
      increasedContrast: colorSchemeContrast == .increased)
    content
      .background(MaterialPolicy.style(for: resolution.fill))
      .overlay {
        if resolution.strokesSeparator {
          Rectangle()
            .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }
}

private struct ChromeShapeFill<S: InsettableShape>: ViewModifier {
  let base: MaterialPolicy.Base
  let shape: S
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  func body(content: Content) -> some View {
    let resolution = MaterialPolicy.resolve(
      base, reduceTransparency: reduceTransparency,
      increasedContrast: colorSchemeContrast == .increased)
    content
      .background(MaterialPolicy.style(for: resolution.fill), in: shape)
      .overlay {
        if resolution.strokesSeparator {
          shape
            .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }
}
