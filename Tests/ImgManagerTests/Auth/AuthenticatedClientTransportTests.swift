import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// `AuthenticatedClientTransport` is the ONE injectable seam this app's composition root uses
/// (`RootView.init`'s doc comment) — proved here against a spy INNER transport rather than a
/// real network call, so the header-injection behaviour is a fast, deterministic unit test
/// (p1-spec-rev2.md §5 test inventory: "transport Bearer injection").
@Suite("AuthenticatedClientTransport")
struct AuthenticatedClientTransportTests {
  private func request() -> HTTPRequest {
    HTTPRequest(
      method: .get, scheme: "https", authority: "img.discomarder.live", path: "/api/health")
  }

  @Test("a stored credential is injected as Authorization: Bearer <token>")
  func injectsBearerWhenCredentialPresent() async throws {
    let store = CredentialStore(account: "transport-test-\(UUID().uuidString)")
    try await store.save(Credential(token: "tok_xyz", expiresAt: Date(), subject: "alice"))
    let spy = SpyClientTransport()
    let transport = AuthenticatedClientTransport(inner: spy, credentialStore: store)

    _ = try await transport.send(
      request(), body: nil, baseURL: URL(string: "https://img.discomarder.live")!,
      operationID: "apiHealthApiHealthGet")

    let sent = await spy.lastRequest
    #expect(sent?.headerFields[.authorization] == "Bearer tok_xyz")
    try? await store.clear()
  }

  @Test("no stored credential — no Authorization header at all, never an empty Bearer")
  func omitsHeaderWhenNoCredential() async throws {
    let store = CredentialStore(account: "transport-test-\(UUID().uuidString)")
    let spy = SpyClientTransport()
    let transport = AuthenticatedClientTransport(inner: spy, credentialStore: store)

    _ = try await transport.send(
      request(), body: nil, baseURL: URL(string: "https://img.discomarder.live")!,
      operationID: "nativeExchangeApiAuthNativeExchangePost")

    let sent = await spy.lastRequest
    #expect(sent?.headerFields[.authorization] == nil)
  }

  @Test(
    "a credentialError (corrupted) state also sends no Authorization header — never a bad one"
  )
  func omitsHeaderOnCredentialError() async throws {
    let account = "transport-test-\(UUID().uuidString)"
    // The RESOLVED group (Keychain.swift's KeychainAccessGroup.resolved), matching what
    // CredentialStore's own default now uses — a literal "$(AppIdentifierPrefix)…" string is
    // never substituted inside compiled Swift and would write into a namespace this build's
    // signature is not entitled to, which is a DIFFERENT bug from the one this test proves.
    let rawKeychain = Keychain(
      service: "live.discomarder.imgmanager",
      accessGroup: KeychainAccessGroup.resolved
        ?? "$(AppIdentifierPrefix)live.discomarder.imgmanager.credentials")
    try rawKeychain.set("not json", for: account)
    let store = CredentialStore(account: account)
    let spy = SpyClientTransport()
    let transport = AuthenticatedClientTransport(inner: spy, credentialStore: store)

    _ = try await transport.send(
      request(), body: nil, baseURL: URL(string: "https://img.discomarder.live")!,
      operationID: "apiHealthApiHealthGet")

    let sent = await spy.lastRequest
    #expect(sent?.headerFields[.authorization] == nil)
    try? await store.clear()
  }

  @Test("the request otherwise passes through to the inner transport unchanged")
  func passesThroughToInner() async throws {
    let store = CredentialStore(account: "transport-test-\(UUID().uuidString)")
    let spy = SpyClientTransport()
    let transport = AuthenticatedClientTransport(inner: spy, credentialStore: store)

    let original = request()
    _ = try await transport.send(
      original, body: nil, baseURL: URL(string: "https://img.discomarder.live")!,
      operationID: "op")

    let sent = await spy.lastRequest
    #expect(sent?.method == original.method)
    #expect(sent?.path == original.path)
    #expect(await spy.callCount == 1)
  }
}
