import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Diff-gate round 1, blocker 3: a terminal 401 on an ORDINARY authenticated operation (health/
/// status/folders — anything other than the three native-auth operations, which classify their
/// own 401s directly in `AuthSession`) must end the credential and route to sign-in, never
/// render as a permanent "Not connected". `AuthSession.handleTerminalUnauthorized(presentedToken:)`
/// is the method the transport calls; the transport's own decision to call it is pinned in
/// `AuthenticatedClientTransportTests.swift`.
///
/// Diff-gate round 1, delta: `presentedToken` is the generation fence (ported from
/// memos-ng-ios's `PresentedCredential` epoch) — a 401 is terminal only for the credential the
/// store STILL holds at the moment it is handled. `supersededTokenUnauthorizedIsIgnored` below
/// is the named pin: "a 401 for a token the credential has since replaced is not a 401 to
/// anyone else."
@Suite("AuthSession.handleTerminalUnauthorized (diff-gate round 1, blocker 3 + delta)")
struct AuthSessionTerminalUnauthorizedTests {
  private func makeClient() -> any APIProtocol {
    ImgManagerAPIClient.make(transport: JoinableRenewalStubTransport())
  }

  @Test("a 401 for the CURRENT token clears the credential and routes to sign-in")
  func terminalUnauthorizedForCurrentTokenSignsOut() async {
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let store = FakeCredentialStore(loadResults: [.present(credential)], clearShouldFail: false)
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    await auth.adopt(freshCredential: credential)
    #expect(await auth.status == .signedIn(subject: "alice"))

    await auth.handleTerminalUnauthorized(presentedToken: "tok")

    #expect(await auth.status == .signedOut)
    #expect(await store.clearCallCount == 1)
  }

  @Test("a 401 for a SUPERSEDED token is ignored — credential retained, no sign-out")
  func supersededTokenUnauthorizedIsIgnored() async {
    // The concrete ordering the delta names: an ordinary request left with the OLD token; a
    // renewal completed and saved a NEW one; THEN the old request's 401 arrives. The store
    // already holds the new token by the time this runs.
    let newCredential = Credential(token: "new-token", expiresAt: Date(), subject: "alice")
    let store = FakeCredentialStore(loadResults: [.present(newCredential)])
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    await auth.adopt(freshCredential: newCredential)
    #expect(await auth.status == .signedIn(subject: "alice"))

    // Names the OLD token — the one the store no longer holds.
    await auth.handleTerminalUnauthorized(presentedToken: "old-token")

    // Untouched: "a 401 for a token the credential has since replaced is not a 401 to anyone
    // else" — the fresh credential must survive a stale refusal.
    #expect(await auth.status == .signedIn(subject: "alice"))
    #expect(await store.clearCallCount == 0)
  }

  @Test("a terminal 401 whose clear fails surfaces .credentialError, never a false .signedOut")
  func terminalUnauthorizedClearFailureSurfacesError() async {
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let store = FakeCredentialStore(loadResults: [.present(credential)], clearShouldFail: true)
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    await auth.adopt(freshCredential: credential)

    await auth.handleTerminalUnauthorized(presentedToken: "tok")

    guard case .credentialError = await auth.status else {
      Issue.record("expected .credentialError, got \(await auth.status)")
      return
    }
  }

  @Test("a terminal 401 while already signed out or in error is a no-op")
  func terminalUnauthorizedIsNoOpWhenNotSignedIn() async {
    let store = FakeCredentialStore(loadResults: [.absent])
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    #expect(await auth.status == .checking)

    await auth.handleTerminalUnauthorized(presentedToken: "irrelevant")

    // Never called clear() — there was nothing to end, and the guard fires before any load().
    #expect(await auth.status == .checking)
    #expect(await store.clearCallCount == 0)
  }
}
