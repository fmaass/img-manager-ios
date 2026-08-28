import Foundation
import ImgManagerAPI
import OpenAPIRuntime
import UIKit

/// Everything that can go wrong between "tap Sign in" and a credential in hand.
enum SignInError: Error, Sendable, Equatable {
  /// The browser view went away without a callback — usually a deliberate close.
  case cancelled
  case presentationFailed(String)
  /// A second tap arrived while a sign-in was already on screen. Silent by design (the browser
  /// view already on screen IS the feedback), same as memos-ng-ios's `alreadySigningIn`.
  case alreadySigningIn
  case malformedCallback
  /// The identity provider (or the backend's own callback handler) refused, carrying the
  /// stable `error` token the interstitial forwarded.
  case refused(reason: String)
  /// `/native/exchange` refused the handoff code. Terminal — the code is burned regardless.
  case exchangeRejected
  /// A device name or challenge the server would reject.
  case unusableRequest
  /// The exchange could not be delivered at all — classified, never the raw error text.
  case network(String)

  /// What to show. Mirrors memos-ng-ios's `NativeLoginError.message` — every failure case has
  /// something to say (`cancelled` included: silence is indistinguishable from a broken
  /// button), except `alreadySigningIn`, which is the one case where nothing went wrong.
  var message: String? {
    switch self {
    case .alreadySigningIn: nil
    case .cancelled:
      "The sign-in was closed before it came back. Nothing was signed in — tap Sign in to try "
        + "again."
    case .presentationFailed: "The sign-in window could not open. Please try again."
    case .malformedCallback: "The sign-in came back incomplete. Please try again."
    case .refused: "The sign-in was refused. Please try again."
    case .exchangeRejected: "That sign-in could not be completed. Please sign in again."
    case .unusableRequest: "This device could not start a sign-in. Please try again."
    case .network: "The sign-in could not reach the server. Please check your connection."
    }
  }
}

/// Drives one sign-in attempt: builds the login URL, puts the household sign-on on screen in a
/// browser view the app presents itself, waits for the custom-scheme callback, and trades the
/// handoff code for a device token through the generated client.
///
/// Ported in shape from memos-ng-ios's `SafariLoginPresenter` (`MemosFeatures/
/// SafariLoginPresenter.swift`), narrowed: one lane (custom scheme only, Adjudication A), no
/// presentation watchdog (that guarded against `ASWebAuthenticationSession`'s silent
/// non-presentation specifically — `SFSafariViewController.present(from:)` is a synchronous
/// UIKit call with no equivalent failure mode to watch for), and a bare `Int` generation fence
/// instead of a dedicated `Attempt`/`NativeLoginFlow` state machine — this app has none of the
/// concurrent surfaces (share extension, background media session) that made the fuller
/// machine load-bearing there. The fence itself IS kept: it is what stops a browser view
/// closing after its attempt already ended from cancelling the sign-in the person has since
/// started (`onClose` is cleared before the coordinator's own `dismiss()`, exactly as there).
@MainActor
final class SignInCoordinator {
  private struct Live {
    let generation: Int
    let continuation: CheckedContinuation<URL, Error>
    let browser: any LoginBrowser
  }

  private let resolveHost: @MainActor () -> UIViewController?
  private let makeBrowser: @MainActor (URL) -> any LoginBrowser
  private let inbox: NativeLoginCallbackInbox
  private var lastGeneration = 0
  private var live: Live?

  init(
    host resolve: @escaping @MainActor () -> UIViewController? = SignInCoordinator.currentHost,
    inbox: NativeLoginCallbackInbox = .shared,
    makeBrowser: @escaping @MainActor (URL) -> any LoginBrowser = { SafariLoginBrowser(url: $0) }
  ) {
    self.resolveHost = resolve
    self.inbox = inbox
    self.makeBrowser = makeBrowser
  }

  /// One full sign-in attempt: presents, waits for the callback, and exchanges it. The PKCE
  /// verifier lives only in this call's local `pkce` and is zeroized on every exit path.
  func signIn(
    baseURL: URL, deviceName: String, client: any APIProtocol
  ) async -> Result<Credential, SignInError> {
    guard live == nil else { return .failure(.alreadySigningIn) }
    guard let device = NativeAuth.normalizedDeviceName(deviceName) else {
      return .failure(.unusableRequest)
    }
    let pkce = PKCE()
    guard
      let authorizeURL = NativeAuth.authorizeURL(
        baseURL: baseURL, codeChallenge: pkce.challenge, device: device)
    else {
      return .failure(.unusableRequest)
    }

    let callbackURL: URL
    do {
      callbackURL = try await authenticate(authorizeURL: authorizeURL)
    } catch let error as SignInError {
      pkce.zeroize()
      return .failure(error)
    } catch {
      pkce.zeroize()
      return .failure(.presentationFailed("\(type(of: error))"))
    }

    switch NativeAuth.callback(from: callbackURL) {
    case .malformed:
      pkce.zeroize()
      return .failure(.malformedCallback)
    case .failed(let reason):
      pkce.zeroize()
      return .failure(.refused(reason: reason))
    case .code(let code):
      guard let verifier = pkce.verifier else {
        pkce.zeroize()
        return .failure(.unusableRequest)
      }
      pkce.zeroize()
      return await exchange(code: code, verifier: verifier, client: client)
    }
  }

  private func authenticate(authorizeURL: URL) async throws -> URL {
    guard let host = resolveHost() else {
      throw SignInError.presentationFailed("no window is on screen to open it on")
    }
    lastGeneration += 1
    let generation = lastGeneration
    return try await withCheckedThrowingContinuation { continuation in
      let browser = makeBrowser(authorizeURL)
      live = Live(generation: generation, continuation: continuation, browser: browser)
      browser.onClose = { [weak self] in
        self?.finish(generation: generation, resume: { $0.resume(throwing: SignInError.cancelled) })
      }
      // Registered before the view is on screen: a return trip cannot be faster than the
      // presentation animation, but a wait that starts after it is a race for no reason.
      inbox.waitForCallback(generation: generation) { [weak self] url in
        guard let self, self.live?.generation == generation, NativeAuth.isOurCallback(url) else {
          return false
        }
        self.finish(generation: generation, resume: { $0.resume(returning: url) })
        return true
      }
      browser.present(from: host)
    }
  }

  /// Takes the attempt down and resumes its continuation — but only if it is still the live
  /// one, so a late signal can never resolve a sign-in that is not its own, and never resumes
  /// twice when a stale signal and the real one race.
  private func finish(
    generation: Int, resume: (CheckedContinuation<URL, Error>) -> Void
  ) {
    guard let live, live.generation == generation else { return }
    self.live = nil
    inbox.stopWaiting(generation: generation)
    live.browser.onClose = nil
    live.browser.dismiss()
    resume(live.continuation)
  }

  /// Trades the handoff code for a device token. Every failure the exchange itself can report
  /// is terminal (`p1-spec-rev2.md` §2: "a code is burned by the attempt whatever its outcome"),
  /// so this reports one closed `.exchangeRejected` for anything other than a decoded 200 —
  /// `NativeExchangeFailure` stays available as a tested pure parser (`NativeAuthContract.swift`)
  /// for a future pass to thread the specific reason through; wiring it here needs reading the
  /// generated client's undocumented-response body, deliberately deferred rather than guessed.
  private func exchange(
    code: String, verifier: String, client: any APIProtocol
  ) async -> Result<Credential, SignInError> {
    let body = Components.Schemas.NativeExchangeIn(code: code, codeVerifier: verifier)
    let output: Operations.NativeExchangeApiAuthNativeExchangePost.Output
    do {
      output = try await client.nativeExchangeApiAuthNativeExchangePost(.init(body: .json(body)))
    } catch {
      return .failure(.network(Self.classify(error)))
    }
    guard case .ok(let ok) = output, let token = try? ok.body.json else {
      return .failure(.exchangeRejected)
    }
    return .success(
      Credential(token: token.token, expiresAt: token.expiresAt, subject: token.subject))
  }

  /// Classifies a transport failure without ever surfacing its raw text (host, body, the
  /// handoff code and verifier the request carried) anywhere reachable from the sign-in screen.
  private static func classify(_ error: any Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain
      && nsError.code == URLError.Code.notConnectedToInternet.rawValue
    {
      return "offline"
    }
    return "unreachable"
  }

  /// The view controller the browser view is put on top of, decided by `LoginAnchor` on a
  /// description of the app's scenes rather than on UIKit itself.
  private static func currentHost() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let described = scenes.map {
      LoginAnchor.SceneState(
        activation: LoginAnchor.Activation($0.activationState),
        windowIsKey: $0.windows.map(\.isKeyWindow))
    }
    guard case .window(let scene, let window) = LoginAnchor.choice(among: described),
      let root = scenes[scene].windows[window].rootViewController
    else { return nil }
    var top = root
    while let above = top.presentedViewController, !above.isBeingDismissed {
      top = above
    }
    return top
  }
}

extension LoginAnchor.Activation {
  init(_ state: UIScene.ActivationState) {
    switch state {
    case .foregroundActive: self = .foregroundActive
    case .foregroundInactive: self = .foregroundInactive
    case .background: self = .background
    case .unattached: self = .unattached
    @unknown default: self = .unattached
    }
  }
}
