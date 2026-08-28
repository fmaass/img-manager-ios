import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Diff-gate round 1, blocker 3: a terminal 401 on an ORDINARY authenticated operation (health/
/// status/folders — anything other than the three native-auth operations, which classify their
/// own 401s directly in `AuthSession`) must end the credential and route to sign-in, never
/// render as a permanent "Not connected". `AuthSession.handleTerminalUnauthorized()` is the
/// method the transport calls; the transport's own decision to call it is pinned in
/// `AuthenticatedClientTransportTests.swift`.
@Suite("AuthSession.handleTerminalUnauthorized (diff-gate round 1, blocker 3)")
struct AuthSessionTerminalUnauthorizedTests {
  private func makeClient() -> any APIProtocol {
    ImgManagerAPIClient.make(transport: JoinableRenewalStubTransport())
  }

  @Test("while signed in, a terminal 401 clears the credential and routes to sign-in")
  func terminalUnauthorizedSignsOut() async {
    let store = FakeCredentialStore(loadResults: [.absent], clearShouldFail: false)
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    await auth.adopt(freshCredential: credential)
    #expect(await auth.status == .signedIn(subject: "alice"))

    await auth.handleTerminalUnauthorized()

    #expect(await auth.status == .signedOut)
    #expect(await store.clearCallCount == 1)
  }

  @Test("a terminal 401 whose clear fails surfaces .credentialError, never a false .signedOut")
  func terminalUnauthorizedClearFailureSurfacesError() async {
    let store = FakeCredentialStore(loadResults: [.absent], clearShouldFail: true)
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    await auth.adopt(freshCredential: credential)

    await auth.handleTerminalUnauthorized()

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

    await auth.handleTerminalUnauthorized()

    // Never called clear() — there was nothing to end.
    #expect(await auth.status == .checking)
    #expect(await store.clearCallCount == 0)
  }
}
