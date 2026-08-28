import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Diff-gate round 1, blocker 2: `CredentialStore` failures must never be discarded. Every
/// path that can lose or misreport a credential is pinned here against a `FakeCredentialStore`
/// scripted to fail exactly the ONE operation each test is about — a real, correctly-entitled
/// Keychain cannot be made to fail JUST a save or JUST a clear on demand (see
/// `FakeCredentialStore`'s own doc comment).
@Suite("AuthSession credential-store failure surfacing (diff-gate round 1, blocker 2)")
struct AuthSessionCredentialFailureTests {
  private func makeClient() -> any APIProtocol {
    ImgManagerAPIClient.make(transport: JoinableRenewalStubTransport())
  }

  @Test("sign-in success + save failure surfaces .credentialError, not a mislabeled network error")
  func signInSaveFailureSurfacesCredentialError() async {
    let store = FakeCredentialStore(loadResults: [.absent], saveShouldFail: true)
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")

    await auth.adopt(freshCredential: credential)

    guard case .credentialError = await auth.status else {
      Issue.record("expected .credentialError, got \(await auth.status)")
      return
    }
    #expect(await auth.signInError == nil, "the failure must not also masquerade as a signInError")
  }

  @Test("sign-in success + save success -> .signedIn (positive control for the test above)")
  func signInSaveSuccessSignsIn() async {
    let store = FakeCredentialStore(loadResults: [.absent], saveShouldFail: false)
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")

    await auth.adopt(freshCredential: credential)

    #expect(await auth.status == .signedIn(subject: "alice"))
  }

  @Test("renewal success + save failure surfaces .credentialError, never a stale .signedIn")
  func renewalSaveFailureSurfacesCredentialError() async throws {
    let transport = JoinableRenewalStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let dueCredential = Credential(
      token: "old", expiresAt: Date().addingTimeInterval(60), subject: "alice")
    let store = FakeCredentialStore(loadResults: [.present(dueCredential)], saveShouldFail: true)
    let auth = await AuthSession(credentialStore: store, client: client)

    async let bootstrapTask: Void = auth.bootstrap()
    await transport.waitUntilStarted()
    await transport.release()
    await bootstrapTask

    guard case .credentialError = await auth.status else {
      let message: String =
        "expected .credentialError, got \(await auth.status) — the predecessor is dead "
        + "server-side and must not be silently presented as still signed in"
      Issue.record("\(message)")
      return
    }
  }

  @Test("foreground re-read finding nothing surfaces .credentialError, not a silent stay-signed-in")
  func foregroundAbsentSurfacesCredentialError() async {
    let farFuture = Date().addingTimeInterval(30 * 24 * 60 * 60)
    let initial = Credential(token: "tok", expiresAt: farFuture, subject: "alice")
    // First load (bootstrap) finds the credential; the second (foreground) finds nothing.
    let store = FakeCredentialStore(loadResults: [.present(initial), .absent])
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    await auth.bootstrap()
    #expect(await auth.status == .signedIn(subject: "alice"))

    await auth.renewOnForeground()

    guard case .credentialError = await auth.status else {
      Issue.record("expected .credentialError, got \(await auth.status)")
      return
    }
  }

  @Test("foreground re-read reporting a store error surfaces .credentialError")
  func foregroundStoreErrorSurfacesCredentialError() async {
    let farFuture = Date().addingTimeInterval(30 * 24 * 60 * 60)
    let initial = Credential(token: "tok", expiresAt: farFuture, subject: "alice")
    let store = FakeCredentialStore(
      loadResults: [.present(initial), .error(.corrupted)])
    let auth = await AuthSession(credentialStore: store, client: makeClient())
    await auth.bootstrap()

    await auth.renewOnForeground()

    guard case .credentialError = await auth.status else {
      Issue.record("expected .credentialError, got \(await auth.status)")
      return
    }
  }

  @Test("Forget Device: clear failure surfaces .credentialError, never a false .signedOut")
  func forgetDeviceClearFailureSurfacesCredentialError() async {
    let store = FakeCredentialStore(loadResults: [.absent], clearShouldFail: true)
    let auth = await AuthSession(credentialStore: store, client: makeClient())

    await auth.forgetDeviceAnyway()

    guard case .credentialError = await auth.status else {
      let message: String =
        "expected .credentialError, got \(await auth.status) — Keychain did not actually "
        + "clear, so .signedOut would be false"
      Issue.record("\(message)")
      return
    }
    #expect(await store.clearCallCount == 1)
  }

  @Test("Forget This Device Anyway: clear success -> .signedOut (positive control)")
  func forgetDeviceClearSuccessSignsOut() async {
    let store = FakeCredentialStore(loadResults: [.absent], clearShouldFail: false)
    let auth = await AuthSession(credentialStore: store, client: makeClient())

    await auth.forgetDeviceAnyway()

    #expect(await auth.status == .signedOut)
  }
}
