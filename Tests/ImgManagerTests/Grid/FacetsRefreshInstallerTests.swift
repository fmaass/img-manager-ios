import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// WP16 P2 (IMGMGR-298), the seam's own gate — the twin of
/// `HoverEffectInstallerTests.liveWrapsItsContentRatherThanReturningIt`, and here for the same
/// reason it exists there.
///
/// `RootViewFacetsWiringTests` proves `RootView.workspace` calls *an* installer. Nothing in it
/// can tell an installer that attaches the refresh from one that hands its content straight
/// back — a `.live` that returned its input unchanged would ship no facets trigger AT ALL while
/// every spy stayed green, which is precisely the failure mode `GridStore.swift`'s own comment
/// on `refreshFacets` warns about one layer down ("a trigger that only exists inside a SwiftUI
/// `.task(id:)` modifier cannot be exercised by any test, so deleting it would break the app
/// while every test stayed green").
@MainActor
@Suite("Facets refresh — the production installer actually wraps what it is handed")
struct FacetsRefreshInstallerTests {

  private func makeStore() -> GridStore {
    let client = ImgManagerAPIClient.make(transport: GridStubTransport())
    return GridStore(service: GridService(client: client))
  }

  /// Attaching `.task(id:)` necessarily produces a wrapper type, and an identity installer
  /// necessarily does not. So the assertion is a TYPE inequality: a no-op `.live` fails it, which
  /// is this test's whole purpose. It is also why `FacetsRefreshInstaller.attach` must return a
  /// concrete wrapped type and never `AnyView` — erasing the result would make input and output
  /// types equal and silently defeat the check.
  @Test("`.live` wraps its content rather than returning it")
  func liveWrapsItsContentRatherThanReturningIt() {
    let input = Color.clear
    let output = FacetsRefreshInstaller.live.attach(input, store: makeStore())

    let inputType = String(describing: type(of: input))
    let outputType = String(describing: type(of: output))
    // Positive control for the inequality below: the input's own type name really was read, so
    // the comparison cannot pass on two empty strings.
    #expect(inputType == "Color", "the probe input is not the view it claims to be: \(inputType)")
    // ONE literal, never two concatenated: `#expect` takes a `Comment`, and `+` on a Comment is
    // not a string append (the trap `GridMoreMenuTests` already records).
    #expect(
      outputType != inputType,
      "FacetsRefreshInstaller.live returned its content unchanged (\(outputType)) — no facets refresh is installed anywhere in the app."
    )
  }

  /// `.live` carries no observation hook, so nothing a test substitutes can be mistaken for the
  /// shipped value. Stated as an assertion rather than left to reading, because the whole seam
  /// rests on `.live` being the one installer the running app uses.
  @Test("`.live` carries no test hook")
  func liveCarriesNoTestHook() {
    #expect(FacetsRefreshInstaller.live.onApply == nil)
  }
}
