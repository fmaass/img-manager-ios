import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// WP16 P2 (IMGMGR-298), decision 4's second half: the facet counts must survive the inspector
/// being gone, so the ONE trigger for `GridStore.refreshFacets()` moves off `InspectorView` and
/// onto the workspace itself.
///
/// A test that merely called `store.refreshFacets()` would stay green after `RootView` stopped
/// attaching the trigger — the exact hole `GridStore.swift:631-635` describes in its own words.
/// So the wiring is proven at the CALL SITE, the shape this repo already uses for this failure
/// mode: `GridView.swift:28`'s `pointerGestureInstaller` and `HoverEffectInstaller`. Two
/// visibility facts are what make it reachable at all — `RootView.workspace` is internal rather
/// than private, and `RootView.init` takes an internal defaulted `facetsRefreshInstaller` — and
/// without either of them this file would not compile, which is the point.
///
/// Deleting the `facetsRefreshInstaller.attach(...)` call site in `RootView.workspace` turns the
/// assertion below RED. `FacetsRefreshInstallerTests` closes the other half: that the production
/// `.live` value actually attaches something rather than returning its content.
@MainActor
@Suite("RootView — the facets refresh is wired into the workspace, not just present in source")
struct RootViewFacetsWiringTests {

  /// Explicitly `@MainActor`: the installer's hook is a `@Sendable` closure, so what it captures
  /// has to be Sendable, and global-actor isolation is what makes this box so. (Same box
  /// `HoverEffectWiringTests` uses, for the same reason.)
  @MainActor
  private final class Spy {
    var count = 0
  }

  @Test("Building the workspace installs the facets refresh exactly once")
  func workspaceInstallsTheFacetsRefresh() {
    let spy = Spy()
    let view = RootView(
      transport: GridStubTransport(),
      facetsRefreshInstaller: FacetsRefreshInstaller(onApply: { spy.count += 1 }))

    _ = view.workspace

    #expect(
      spy.count == 1,
      "RootView.workspace does not install the facets refresh — with the inspector collapsible at Regular-3 there is now no trigger left anywhere, so the Stats counts would never load."
    )
  }

  /// The default is the SHIPPED value, so a production composition that forgot to pass an
  /// installer still gets the real one. `ImgManagerApp` constructs `RootView` without naming this
  /// parameter, and that call site has no test of its own.
  @Test("The installer defaults to `.live`")
  func theInstallerDefaultsToLive() {
    let view = RootView(transport: GridStubTransport())
    #expect(view.facetsRefreshInstaller.onApply == nil)
  }
}
