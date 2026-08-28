import Foundation
import ImgManagerAPI
import Observation
import UIKit

/// How a sign-out ended, deciding whether the credential may be destroyed. Mirrors
/// memos-ng-ios's `SignOutOutcome` (`SessionStore.swift:402`-area semantics, pinned verbatim by
/// p1-spec-rev2.md §3 item 2): 204 or 401 both mean the token is gone server-side (401 means it
/// was already gone), so both erase; anything else — no network, a 5xx — leaves the credential
/// exactly where it is, because a token that may still be live must not be abandoned by an app
/// that has stopped tracking it.
enum SignOutOutcome: Sendable, Equatable {
  case revoked
  case alreadyRevoked
  /// The revoke could not be delivered or the server failed. The credential is KEPT; the
  /// account sheet's "Forget This Device Anyway" is the deliberate, explicit way out.
  case revokeFailed
}

/// Where the app is with respect to a credential.
///
/// `credentialError` is NOT `signedOut`: p1-spec-rev2.md §3 item 3, verbatim — "Missing
/// entitlement, corruption or failed reads are errors — not 'signed out'." Routing a missing
/// entitlement to the sign-in screen would invite a second sign-in that mints a token the
/// device can never read back, on top of hiding a real device/OS problem behind an ordinary
/// "please sign in" prompt. Diff-gate round 1 (blocker 2) extends the same rule to every OTHER
/// path that can lose track of a credential: a save that fails after a successful exchange or
/// renewal, a foreground re-read that fails, and a Keychain clear that fails must all surface
/// here too — never a silent `.signedOut` a stale or dropped credential would make false.
enum AuthStatus: Sendable, Equatable {
  case checking
  case signedOut
  case signedIn(subject: String)
  case credentialError(String)
}

/// The session: one credential, backed by `CredentialStore`, and the rule that a renewal's
/// terminal 401 ends it. Owns bootstrap (launch), sign-in (via `SignInCoordinator`), renewal
/// (foreground) and sign-out — the four P1 acceptances the retired placeholder transport's
/// doc comment deferred here (P3-LIVE-AUTH-01..04 plus exchange/renew/logout/expiry routing).
@MainActor
@Observable
final class AuthSession {
  private(set) var status: AuthStatus = .checking
  /// The most recent sign-in attempt's failure, for the sign-in screen's inline error. Cleared
  /// at the start of every new attempt. `nil` after a successful sign-in or a cancel/already-
  /// signing-in outcome (never shown — see `SignInError.message`).
  private(set) var signInError: SignInError?

  private let credentialStore: any CredentialPersisting
  private let client: any APIProtocol
  private let coordinator: SignInCoordinator
  private let baseURL: URL
  private let deviceName: @MainActor () -> String

  /// Diff-gate round 1, blocker 1: the single in-flight renewal every trigger (bootstrap,
  /// foreground) joins instead of starting a second one. Two concurrent rotations would both
  /// present the SAME presenting token — the server answers one 200 successor and one 401 — and
  /// without this join, whichever save landed second could silently clobber the other's result
  /// (ported from memos-ng-ios `SessionStore.swift:927`'s `renewalInFlight`).
  private var renewalInFlight: Task<Void, Never>?

  init(
    credentialStore: any CredentialPersisting,
    client: any APIProtocol,
    coordinator: SignInCoordinator = SignInCoordinator(),
    baseURL: URL = ImgManagerAPIClient.baseURL,
    deviceName: @escaping @MainActor () -> String = { UIDevice.current.name }
  ) {
    self.credentialStore = credentialStore
    self.client = client
    self.coordinator = coordinator
    self.baseURL = baseURL
    self.deviceName = deviceName
  }

  /// Restores a stored credential at launch. Renewal is attempted inline if the restored
  /// credential is already inside the renewal window — the same join `renewOnForeground` uses,
  /// so there is exactly one place that decides whether a renewal is due and exactly one
  /// renewal may ever be in flight at a time.
  func bootstrap() async {
    switch await credentialStore.load() {
    case .absent:
      status = .signedOut
    case .error(let error):
      status = .credentialError(Self.message(for: error))
    case .present(let credential):
      status = .signedIn(subject: credential.subject)
      await triggerRenewalIfDue(credential)
    }
  }

  /// Runs one sign-in attempt and adopts its result. A concurrent tap is absorbed silently by
  /// `SignInCoordinator` itself (`.alreadySigningIn`) — nothing here needs to guard against it
  /// twice.
  func signIn() async {
    signInError = nil
    let result = await coordinator.signIn(
      baseURL: baseURL, deviceName: deviceName(), client: client)
    switch result {
    case .success(let credential):
      await adopt(freshCredential: credential)
    case .failure(let error):
      if error != .alreadySigningIn { signInError = error }
    }
  }

  /// Saves a freshly obtained credential (a completed sign-in's result) and reports the
  /// outcome. Internal, not `private` — diff-gate round 1's pinning test drives this directly
  /// (`AuthSessionCredentialFailureTests.swift`) rather than fabricating a full
  /// browser-presented sign-in through `SignInCoordinator` just to reach the save step.
  func adopt(freshCredential credential: Credential) async {
    do {
      try await credentialStore.save(credential)
      status = .signedIn(subject: credential.subject)
    } catch {
      // Diff-gate round 1, blocker 2: a successful exchange whose save then fails must not
      // read as an ordinary network hiccup on the sign-in screen — the server already minted
      // a token this device cannot use because it cannot be stored. Surface the pinned error
      // state, not a mislabeled `signInError`.
      status = .credentialError(
        "The sign-in succeeded but could not be saved on this device. Please try again.")
    }
  }

  /// Called on scene foreground (`RootView`'s `scenePhase` observer). A no-op unless there is a
  /// signed-in credential inside its renewal window — never renews eagerly, never renews while
  /// signed out or in an error state.
  func renewOnForeground() async {
    guard case .signedIn = status else { return }
    switch await credentialStore.load() {
    case .present(let credential):
      await triggerRenewalIfDue(credential)
    case .absent:
      // Diff-gate round 1, blocker 2: a foreground re-read that finds nothing where a moment
      // ago there was a signed-in credential is not silently "still signed in" — something
      // removed it outside this session's own paths, and that is worth surfacing.
      status = .credentialError(
        "This device's sign-in could not be found. Please sign in again.")
    case .error(let error):
      status = .credentialError(Self.message(for: error))
    }
  }

  /// Called by the transport when an ORDINARY authenticated operation (not one of the three
  /// native-auth operations, which classify their own 401s below) comes back 401 — a revoked
  /// or expired PAT presented on a live request. Diff-gate round 1, blocker 3: this must end
  /// the credential and route to sign-in, not render as a permanent "Not connected".
  func handleTerminalUnauthorized() async {
    guard case .signedIn = status else { return }
    await clearAndReport(
      fallbackMessage: "Your sign-in has expired. Please sign in again.")
  }

  /// The single renewal join point (blocker 1). A second trigger arriving while one is already
  /// running awaits the SAME task instead of starting a rotation of its own.
  private func triggerRenewalIfDue(_ credential: Credential) async {
    if let renewalInFlight {
      await renewalInFlight.value
      return
    }
    let task = Task { [weak self] in
      await self?.performRenewal(credential)
      self?.renewalInFlight = nil
    }
    renewalInFlight = task
    await task.value
  }

  private func performRenewal(_ credential: Credential) async {
    guard RenewalWindow.shouldRenew(expiresAt: credential.expiresAt) else { return }
    let output: Operations.NativeRenewApiAuthNativeRenewPost.Output
    do {
      output = try await client.nativeRenewApiAuthNativeRenewPost(.init())
    } catch {
      // Network failure: retain the credential and say nothing here — the app's existing
      // unreachable-state surface (ConnectivityState) is what reports connectivity; a renewal
      // that could not even be attempted is not evidence the credential is bad.
      return
    }
    switch output {
    case .ok(let ok):
      guard let token = try? ok.body.json else { return }
      let renewed = Credential(
        token: token.token, expiresAt: token.expiresAt, subject: token.subject)
      // Atomic replace only after the response already succeeded (p1-spec-rev2.md §3).
      do {
        try await credentialStore.save(renewed)
        status = .signedIn(subject: renewed.subject)
      } catch {
        // Diff-gate round 1, blocker 2: the server already revoked the PREDECESSOR when it
        // minted this successor — leaving the predecessor sitting in Keychain (because the
        // successor's save failed) would silently present a token that no longer works. This
        // must surface as an error, never a quiet continuation of `.signedIn`.
        status = .credentialError(
          "A device sign-in refresh succeeded on the server but could not be saved on this "
            + "device. Please sign in again.")
      }
    case .undocumented(let statusCode, _):
      guard statusCode == 401 else { return }
      // Terminal: the presenting token is dead server-side. Erase and return to sign-in.
      await clearAndReport(fallbackMessage: "Your sign-in has expired. Please sign in again.")
    default:
      break
    }
  }

  /// Revokes the presenting token and, if that settled its fate, forgets it. Mirrors
  /// memos-ng-ios's `SessionStore.signOut()` exactly (204 -> revoked+erase, 401 -> already-
  /// revoked+erase, anything else -> revokeFailed+KEEP).
  @discardableResult
  func signOut() async -> SignOutOutcome {
    let output: Operations.NativeLogoutApiAuthNativeLogoutPost.Output
    do {
      output = try await client.nativeLogoutApiAuthNativeLogoutPost(.init())
    } catch {
      return .revokeFailed
    }
    switch output {
    case .noContent:
      await clearAndReport(
        fallbackMessage:
          "Signed out on the server, but this device could not forget its local copy. Please "
          + "try again.")
      return .revoked
    case .undocumented(let statusCode, _):
      guard statusCode == 401 else { return .revokeFailed }
      await clearAndReport(
        fallbackMessage:
          "That sign-in was already gone on the server, but this device could not forget its "
          + "local copy. Please try again.")
      return .alreadyRevoked
    default:
      return .revokeFailed
    }
  }

  /// "Forget This Device Anyway" — the deliberate way out of a failed revoke
  /// (`SignOutFlow.decision(for:)` in memos-ng-ios names the same escape hatch). Erases the
  /// LOCAL credential without another server round trip; the server-token caveat is the
  /// account sheet's copy, not this method's job.
  func forgetDeviceAnyway() async {
    await clearAndReport(
      fallbackMessage: "This device could not forget its stored sign-in. Please try again.")
  }

  /// Clears the stored credential and reports the outcome. Diff-gate round 1, blocker 2:
  /// `.signedOut` is published ONLY when the Keychain genuinely cleared — a failed clear
  /// surfaces `.credentialError` instead of a false signedOut that would leave a stale
  /// credential silently behind while the UI claims nothing is stored.
  private func clearAndReport(fallbackMessage: String) async {
    do {
      try await credentialStore.clear()
      status = .signedOut
    } catch {
      status = .credentialError(fallbackMessage)
    }
  }

  private static func message(for error: CredentialStoreError) -> String {
    switch error {
    case .corrupted:
      return "The saved sign-in could not be read. Please sign in again."
    case .keychain(.notEntitled):
      return "This app cannot reach its secure storage right now. Please reinstall or contact "
        + "support."
    case .keychain(.itemNotData), .keychain(.dataNotUTF8):
      return "The saved sign-in could not be read. Please sign in again."
    case .keychain(.unexpectedStatus):
      return "This device's secure storage could not be reached. Please try again."
    }
  }
}
