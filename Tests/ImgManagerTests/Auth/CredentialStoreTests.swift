import Foundation
import Testing

@testable import ImgManager

/// Exercises the REAL Keychain, not a mock — mirrors memos-ng-ios's own test pattern
/// (`KeychainTests.swift`/`CredentialVaultTests.swift`), which is why `ImgManagerTests` is
/// hosted in the app rather than run as a host-less bundle (project.yml's own comment: "a
/// host-less unit-test bundle has no keychain entitlement in the simulator"). Never mock the
/// unit under test: what is being proven here is that this app's actual entitlement, service
/// and access-group resolve to a working Keychain namespace on THIS build, which a mock cannot
/// tell you.
///
/// Each test uses its own throwaway `account`, so tests never interfere with each other or with
/// whatever `native-pat` a signed-in run of the app left behind on the same simulator, and each
/// test tears its own account down at the end regardless of outcome.
///
/// NOT exercised here (would need a genuinely different provisioning/entitlement, not
/// achievable inside a unit test): `Keychain.Failure.notEntitled`
/// (`errSecMissingEntitlement`) and `.unexpectedStatus`. That an `AuthStatus.credentialError`
/// (the state `AuthSession` reaches on any `CredentialLoadResult.error`, corruption included)
/// never routes to the sign-in surface is proven separately in `RootRoutingTests.swift`.
@Suite("CredentialStore (real Keychain)")
struct CredentialStoreTests {
  private func makeStore() -> CredentialStore {
    CredentialStore(account: "test-\(UUID().uuidString)")
  }

  @Test("a fresh account reads back absent, not an error")
  func freshAccountIsAbsent() async {
    let store = makeStore()
    #expect(await store.load() == .absent)
    try? await store.clear()
  }

  @Test("save then load round-trips token, expiry and subject exactly")
  func saveThenLoadRoundTrips() async throws {
    let store = makeStore()
    let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
    let credential = Credential(token: "tok_abc123", expiresAt: expiresAt, subject: "alice")
    try await store.save(credential)

    guard case .present(let loaded) = await store.load() else {
      Issue.record("expected .present after save")
      try? await store.clear()
      return
    }
    #expect(loaded.token == "tok_abc123")
    #expect(loaded.subject == "alice")
    // ISO-8601 round-trips to the second; the stored value must not silently lose precision.
    #expect(abs(loaded.expiresAt.timeIntervalSince(expiresAt)) < 1)

    try? await store.clear()
  }

  @Test("clear erases a saved credential back to absent, and is idempotent")
  func clearErasesAndIsIdempotent() async throws {
    let store = makeStore()
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "bob")
    try await store.save(credential)
    #expect(await store.load() != .absent)

    try await store.clear()
    #expect(await store.load() == .absent)

    // Clearing an account that is already empty must not throw — sign-out must leave nothing
    // behind whatever state it started from.
    try await store.clear()
    #expect(await store.load() == .absent)
  }

  @Test("saving twice replaces the credential (the same call renewal's atomic swap uses)")
  func saveTwiceReplaces() async throws {
    let store = makeStore()
    let first = Credential(token: "tok-1", expiresAt: Date(), subject: "carol")
    let second = Credential(
      token: "tok-2", expiresAt: Date().addingTimeInterval(3600), subject: "carol")
    try await store.save(first)
    try await store.save(second)

    guard case .present(let loaded) = await store.load() else {
      Issue.record("expected .present after two saves")
      try? await store.clear()
      return
    }
    #expect(loaded.token == "tok-2", "the second save must win, not silently fail as a duplicate")
    try? await store.clear()
  }

  @Test("a corrupted stored value reads back as .error, never as .absent")
  func corruptedValueIsAnErrorNotAbsence() async throws {
    let account = "test-\(UUID().uuidString)"
    let store = CredentialStore(account: account)
    // Bypasses CredentialStore's JSON encoding entirely — writes raw, non-JSON bytes directly
    // into the SAME namespace CredentialStore reads, via the lower-level Keychain type it
    // itself wraps. This is corruption, not "nothing saved yet".
    // The RESOLVED group (Keychain.swift's KeychainAccessGroup.resolved), matching what
    // CredentialStore's own default now uses — a literal "$(AppIdentifierPrefix)…" string is
    // never substituted inside compiled Swift and would write into a namespace this build's
    // signature is not entitled to, which is a DIFFERENT bug from the one this test proves.
    let rawKeychain = Keychain(
      service: "live.discomarder.imgmanager",
      accessGroup: KeychainAccessGroup.resolved
        ?? "$(AppIdentifierPrefix)live.discomarder.imgmanager.credentials")
    try rawKeychain.set("not valid credential json", for: account)

    #expect(await store.load() == .error(.corrupted))

    try? await store.clear()
  }
}
