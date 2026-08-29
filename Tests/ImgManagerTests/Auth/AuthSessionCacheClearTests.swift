import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// The cached queue answer must not outlive the sign-in it was fetched under — and must survive
/// everything that is NOT a session ending. The hook therefore hangs off the ONE place a
/// credential is actually erased (`clearAndReport`'s successful `clear()`), never off the entry
/// or exit of a named method: `handleTerminalUnauthorized` returns without erasing anything for a
/// superseded token (the epoch fence), and `signOut()` returns `.revokeFailed` with the
/// credential deliberately KEPT when the revoke could not be delivered. Erasing the cache in
/// either case would drop the user's last usable answer while they are still signed in.
///
/// `FakeQueueSnapshotStore` doubles as the spy here (its `clearCount`) precisely because it is
/// the shape production wires in — `RootView` passes `{ await queueSnapshotStore.clear() }`.
@Suite("AuthSession — queue cache clears on the credential-erasure path only (gate item 1)")
struct AuthSessionCacheClearTests {
  private func makeSession(
    credentialStore: FakeCredentialStore,
    cache: FakeQueueSnapshotStore,
    transport: AuthOperationStubTransport
  ) async -> AuthSession {
    await AuthSession(
      credentialStore: credentialStore,
      client: ImgManagerAPIClient.make(transport: transport),
      onCredentialsErased: { await cache.clear() })
  }

  @Test("a renewal's terminal 401 erases the credential AND the cached queue answer")
  func renewalTerminalUnauthorizedClearsCache() async {
    let cache = FakeQueueSnapshotStore()
    let transport = AuthOperationStubTransport(renewOutcome: .status(401))
    let due = Credential(token: "old", expiresAt: Date().addingTimeInterval(60), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(due)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: transport)

    await auth.bootstrap()

    #expect(await auth.status == .signedOut)
    #expect(await credentials.clearCallCount == 1)
    #expect(await cache.clearCount == 1)
  }

  @Test("sign-out revoked (204) erases the credential AND the cached queue answer")
  func signOutRevokedClearsCache() async {
    let cache = FakeQueueSnapshotStore()
    let transport = AuthOperationStubTransport(logoutOutcome: .success)
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(credential)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: transport)
    await auth.adopt(freshCredential: credential)

    let outcome = await auth.signOut()

    #expect(outcome == .revoked)
    #expect(await auth.status == .signedOut)
    #expect(await cache.clearCount == 1)
  }

  @Test("sign-out on an already-revoked token (401) also erases the cached queue answer")
  func signOutAlreadyRevokedClearsCache() async {
    let cache = FakeQueueSnapshotStore()
    let transport = AuthOperationStubTransport(logoutOutcome: .status(401))
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(credential)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: transport)
    await auth.adopt(freshCredential: credential)

    let outcome = await auth.signOut()

    #expect(outcome == .alreadyRevoked)
    #expect(await cache.clearCount == 1)
  }

  @Test("a sign-out whose revoke could not be delivered KEEPS the credential and the cache")
  func signOutRevokeFailedKeepsCache() async {
    let cache = FakeQueueSnapshotStore()
    let transport = AuthOperationStubTransport(logoutOutcome: .transportFailure)
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(credential)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: transport)
    await auth.adopt(freshCredential: credential)

    let outcome = await auth.signOut()

    #expect(outcome == .revokeFailed)
    #expect(await auth.status == .signedIn(subject: "alice"))
    #expect(await credentials.clearCallCount == 0)
    // The session did not end: dropping the last usable answer here would degrade a still
    // signed-in user for nothing.
    #expect(await cache.clearCount == 0)
  }

  @Test("\"Forget This Device Anyway\" erases the cached queue answer with the credential")
  func forgetDeviceAnywayClearsCache() async {
    let cache = FakeQueueSnapshotStore()
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(credential)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: AuthOperationStubTransport())
    await auth.adopt(freshCredential: credential)

    await auth.forgetDeviceAnyway()

    #expect(await auth.status == .signedOut)
    #expect(await cache.clearCount == 1)
  }

  @Test("a 401 for the CURRENT token erases the cached queue answer (a real session end)")
  func terminalUnauthorizedForCurrentTokenClearsCache() async {
    let cache = FakeQueueSnapshotStore()
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(credential)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: AuthOperationStubTransport())
    await auth.adopt(freshCredential: credential)

    await auth.handleTerminalUnauthorized(presentedToken: "tok")

    #expect(await auth.status == .signedOut)
    #expect(await cache.clearCount == 1)
  }

  @Test("a 401 for a SUPERSEDED token (the epoch fence) leaves the cached queue answer alone")
  func supersededTokenUnauthorizedKeepsCache() async {
    let cache = FakeQueueSnapshotStore()
    let current = Credential(token: "new-token", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(current)])
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: AuthOperationStubTransport())
    await auth.adopt(freshCredential: current)

    await auth.handleTerminalUnauthorized(presentedToken: "old-token")

    #expect(await auth.status == .signedIn(subject: "alice"))
    #expect(await credentials.clearCallCount == 0)
    #expect(await cache.clearCount == 0)
  }

  @Test("a Keychain clear that FAILS leaves the cache alone — the credential is still there")
  func failedCredentialClearKeepsCache() async {
    let cache = FakeQueueSnapshotStore()
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(
      loadResults: [.present(credential)], clearShouldFail: true)
    let auth = await makeSession(
      credentialStore: credentials, cache: cache, transport: AuthOperationStubTransport())
    await auth.adopt(freshCredential: credential)

    await auth.handleTerminalUnauthorized(presentedToken: "tok")

    guard case .credentialError = await auth.status else {
      Issue.record("expected .credentialError, got \(await auth.status)")
      return
    }
    #expect(await credentials.clearCallCount == 1)
    // The erasure did not happen — the hook hangs off the SUCCESSFUL clear, not the attempt.
    #expect(await cache.clearCount == 0)
  }
}
