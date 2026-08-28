import Testing

@testable import ImgManager

/// `RootRouting.destination(for:)` is where `RootView` decides what to show for each
/// `AuthStatus` — pulled out as a pure value function precisely so this is a value test
/// (p1-spec-rev2.md §5 test inventory: "signed-out routing").
@Suite("RootRouting.destination(for:)")
struct RootRoutingTests {
  @Test(".checking routes to .checking")
  func checking() {
    #expect(RootRouting.destination(for: .checking) == .checking)
  }

  @Test(".signedOut routes to .signIn")
  func signedOut() {
    #expect(RootRouting.destination(for: .signedOut) == .signIn)
  }

  @Test(".signedIn routes to .workspace, for any subject")
  func signedIn() {
    #expect(RootRouting.destination(for: .signedIn(subject: "alice")) == .workspace)
    #expect(RootRouting.destination(for: .signedIn(subject: "")) == .workspace)
  }

  @Test(".credentialError NEVER routes to .signIn — spec §3 item 3: not 'signed out', verbatim")
  func credentialErrorIsNotSignIn() {
    let destination = RootRouting.destination(for: .credentialError("boom"))
    #expect(destination != .signIn)
    #expect(destination == .credentialError("boom"))
  }

  @Test(".credentialError carries the message through unchanged")
  func credentialErrorCarriesMessage() {
    #expect(
      RootRouting.destination(for: .credentialError("This app cannot reach its secure storage"))
        == .credentialError("This app cannot reach its secure storage"))
  }

  @Test("every AuthStatus case maps to exactly one RootDestination — no case is missed")
  func everyStatusHasADestination() {
    let statuses: [AuthStatus] = [
      .checking, .signedOut, .signedIn(subject: "x"), .credentialError("x"),
    ]
    let destinations = statuses.map(RootRouting.destination(for:))
    #expect(Set(destinations).count == 4, "each of the four statuses must route somewhere distinct")
  }
}
