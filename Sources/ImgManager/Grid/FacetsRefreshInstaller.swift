import SwiftUI

/// The seam that keeps the Stats facet counts loading. WP16 P2 (IMGMGR-298), design record
/// [/link/3332] decision 4.
///
/// Until this phase the ONE trigger for `GridStore.refreshFacets()` lived inside
/// `InspectorView`'s `.task(id: store.queryIdentity)`, so the counts existed only where the
/// inspector did. Decision 4 makes the Regular-3 inspector collapsible — removing the trigger
/// from the one width at which it always fired — so the trigger moves up to the workspace, which
/// is mounted in every layout mode and every collapse state.
///
/// It moves as a VALUE, not as a bare `.task` one level up. `GridStore.swift` states the reason
/// in its own words: "a trigger that only exists inside a SwiftUI `.task(id:)` modifier cannot be
/// exercised by any test, so deleting it would break the app while every test stayed green".
/// Relocating the modifier would reproduce exactly that hole in `RootView`, and a test that
/// merely called `store.refreshFacets()` would stay green afterwards. With the trigger behind an
/// injectable installer, `RootViewFacetsWiringTests` substitutes a spy, ACCESSES
/// `RootView.workspace`, and asserts the wiring itself ran — so deleting the call site turns a
/// named assertion red.
///
/// A value with a GENERIC `attach` and a concrete wrapped return type, deliberately, and never an
/// `AnyView`-erasing one — the same reasoning `HoverEffectInstaller` writes down: erasing the
/// result would make input and output types equal and defeat
/// `FacetsRefreshInstallerTests.liveWrapsItsContentRatherThanReturningIt`, the only automated
/// gate on the PRODUCTION value. A `.live` that returned its content unchanged would ship no
/// facets trigger at all while every call-site spy stayed green.
///
/// The store method itself is unchanged: `refreshFacets()` is already single-flight and
/// identity-fenced (`GridStore.swift`), so moving WHEN it is called cannot double-fetch, and the
/// inspector re-appearing does not refetch counts the workspace already has.
struct FacetsRefreshInstaller: Sendable {
  /// Test-only observation hook, nil in `.live`: `RootViewFacetsWiringTests` substitutes an
  /// installer that records, evaluates `RootView.workspace`, and asserts it was invoked once.
  var onApply: (@MainActor @Sendable () -> Void)?

  /// The ONE installer the running app uses.
  static let live = FacetsRefreshInstaller()

  /// Keyed on `store.queryIdentity` — the same identity `InspectorView`'s `.task` used, so the
  /// "a filter change refetches the counts" chain is unchanged in behaviour; only its host moved.
  @MainActor
  func attach<Content: View>(_ content: Content, store: GridStore) -> some View {
    onApply?()
    return content.task(id: store.queryIdentity) {
      await store.refreshFacets()
    }
  }
}
