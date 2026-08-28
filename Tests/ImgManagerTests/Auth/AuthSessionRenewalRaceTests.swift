import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Diff-gate round 1, blocker 1: two concurrent renewal triggers (bootstrap + a foreground
/// re-entry, or two foreground re-entries) must never both reach the network — the server
/// would answer one 200 successor and one 401, and whichever save landed second could silently
/// clobber the other's result. `AuthSession.triggerRenewalIfDue`'s `renewalInFlight` join
/// (ported from memos-ng-ios `SessionStore.swift:927`) is what this proves.
@Suite("AuthSession renewal race (diff-gate round 1, blocker 1)")
struct AuthSessionRenewalRaceTests {
  @Test("a concurrent foreground renewal joins the one in flight — exactly one network call")
  func concurrentRenewalsJoinRatherThanRace() async throws {
    let transport = JoinableRenewalStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let dueCredential = Credential(
      token: "old-token", expiresAt: Date().addingTimeInterval(60), subject: "alice")
    let store = FakeCredentialStore(loadResults: [.present(dueCredential)])
    let auth = await AuthSession(credentialStore: store, client: client)

    async let bootstrapTask: Void = auth.bootstrap()
    // Deterministic: this only returns once performRenewal's network call has genuinely
    // started, which can only happen AFTER triggerRenewalIfDue has already set
    // `renewalInFlight` (that assignment strictly precedes the task's first suspension).
    await transport.waitUntilStarted()

    async let foregroundTask: Void = auth.renewOnForeground()
    await Task.yield()
    await transport.release()
    _ = await (bootstrapTask, foregroundTask)

    #expect(await transport.callCount == 1)
    switch await auth.status {
    case .signedIn(let subject):
      #expect(subject == "alice")
    default:
      Issue.record("expected .signedIn after a successful joined renewal")
    }
    // Only the joined renewal's single successor was ever saved — never a second, racing one.
    #expect(await store.savedCredentials.count == 1)
    #expect(await store.savedCredentials.first?.token == "renewed-token")
  }

  @Test("a renewal outside the window is a no-op and never touches the network")
  func notDueIsNoOp() async throws {
    let transport = JoinableRenewalStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let freshCredential = Credential(
      token: "fresh", expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60), subject: "bob")
    let store = FakeCredentialStore(loadResults: [.present(freshCredential)])
    let auth = await AuthSession(credentialStore: store, client: client)

    await auth.bootstrap()

    #expect(await transport.callCount == 0)
    #expect(await store.savedCredentials.isEmpty)
    switch await auth.status {
    case .signedIn(let subject): #expect(subject == "bob")
    default: Issue.record("expected .signedIn with no renewal attempted")
    }
  }
}
