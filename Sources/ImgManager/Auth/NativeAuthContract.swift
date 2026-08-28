import Foundation

/// The browser-brokered device login, as far as the wire is concerned — pure functions only,
/// unit-tested here rather than exercised only through a live browser session.
///
/// Ported from memos-ng-ios's `MemosAPI/NativeLogin.swift`, narrowed to ONE return lane: the
/// pinned port contract (p1-spec-rev2.md §2, Adjudication A) names exactly one — the custom
/// scheme `imgmanager://auth-callback` — never a universal link, so there is no
/// `NativeLoginReturn.Lane` distinction to make here. The endpoints, query parameter names and
/// device-name bound mirror `app/api/auth.py` and `app/auth/native.py` in img-manager verbatim
/// (`IOS_RETURN_SCHEME_URL = "imgmanager://auth-callback"`, `DEVICE_NAME_MAX = 64`,
/// `_CODE_CHALLENGE_RE = [A-Za-z0-9_-]{43,128}`, both verified against the vendored v0.9.2
/// source at commit eff6a12ddf3c7e2a6f748625747345ca57c86349).
enum NativeAuth {
  /// The `client` value that switches the backend's `/api/auth/login` into device-handoff mode.
  static let client = "ios"

  /// The custom-scheme return lane's scheme and host (Adjudication A). Any app on the phone
  /// could claim this scheme — nothing that crosses it is trusted for being on it. What crosses
  /// it is a one-shot handoff code that is worthless without the PKCE verifier, which never
  /// leaves this process. Registered in `CFBundleURLTypes` (project.yml).
  static let callbackScheme = "imgmanager"
  static let callbackHost = "auth-callback"

  /// `native.DEVICE_NAME_MAX` on the server, which answers 422 to anything longer.
  static let deviceNameMaxLength = 64

  /// What came back on the callback URL.
  enum Callback: Sendable, Equatable {
    /// The one-shot handoff code, to be exchanged together with the PKCE verifier.
    case code(String)
    /// The login was refused upstream, or the backend's own callback handler failed — either
    /// way the interstitial forwards it as a stable `error` token
    /// (`app/api/auth.py::_native_redirect`).
    case failed(reason: String)
    /// Neither: a stripped echo of the callback address, or a URL that was never ours.
    case malformed
  }

  /// The URL that starts a device login, or `nil` when these arguments could only produce a 422.
  ///
  /// Validation mirrors the server's own (`native.valid_code_challenge`,
  /// `native.valid_device_name`) on purpose: a request that cannot succeed should fail on the
  /// device, where the sign-in screen can say why, rather than inside a browser view that can
  /// only show an error page.
  static func authorizeURL(
    baseURL: URL,
    codeChallenge: String,
    device: String
  ) -> URL? {
    guard isValidCodeChallenge(codeChallenge) else { return nil }
    guard let device = normalizedDeviceName(device) else { return nil }
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = "/api/auth/login"
    components.queryItems = [
      URLQueryItem(name: "client", value: client),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "device", value: device),
    ]
    return components.url
  }

  /// Whether a URL is on the custom-scheme return lane at all — the CLAIM, not the parse.
  /// Every URL the app is opened with reaches `onOpenURL`, so a URL that is not the callback
  /// must come back `false` rather than as a malformed callback: an unrelated tap (a shared
  /// link, another app's own custom scheme) must not resolve a sign-in that is still waiting.
  ///
  /// Case-insensitive: iOS lowercases a scheme it opens, and a host is case-insensitive by
  /// RFC 3986. Handles both `imgmanager://auth-callback?...` (host form) and
  /// `imgmanager:auth-callback?...` (no slashes — a shape a hand-written link in the
  /// interstitial's HTML page can take), matching the path form too.
  static func isOurCallback(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), scheme == callbackScheme
    else { return false }
    let trimmedPath = components.percentEncodedPath.trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    let named = (components.host ?? trimmedPath).lowercased()
    return named == callbackHost
  }

  /// Reads the callback the browser view handed back. `.malformed` for any URL that IS on our
  /// lane (`isOurCallback` true) but carries neither a usable `code` nor an `error` — a stripped
  /// echo of the address, which iOS reports on some browser redirect delegates with the query
  /// withheld. Call `isOurCallback` first; this does not re-check the scheme/host.
  static func callback(from url: URL) -> Callback {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
      return .malformed
    }
    if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
      return .code(code)
    }
    if let reason = items.first(where: { $0.name == "error" })?.value, !reason.isEmpty {
      return .failed(reason: reason)
    }
    return .malformed
  }

  /// RFC 7636 §4.1 in the server's own bounds: 43–128 characters of un-padded base64url.
  static func isValidCodeChallenge(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
      .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"))
      .union(CharacterSet(charactersIn: "0123456789-_"))
    guard (43...128).contains(value.unicodeScalars.count) else { return false }
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  /// A device display name the server will accept: it becomes the PAT's name. Counted in
  /// unicode scalars because the server counts Python `len()` (code points) — a
  /// `String.count` of grapheme clusters would let a name through the server then rejects.
  static func normalizedDeviceName(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= deviceNameMaxLength else {
      return nil
    }
    return trimmed
  }
}

/// Why `POST /api/auth/native/exchange` refused a code — the server's stable `detail` codes
/// (`app/auth/native.py::_code_rejection_reason`, `app/api/auth.py::native_exchange`). All four
/// are terminal: a code is burned by the attempt whatever its outcome, so none is retried — the
/// app starts a new login instead.
enum NativeExchangeFailure: String, Sendable, Equatable, CaseIterable {
  case codeInvalid = "code_invalid"
  case codeExpired = "code_expired"
  case codeConsumed = "code_consumed"
  case verifierMismatch = "verifier_mismatch"

  /// Reads the `detail` out of a 400 body, or `nil` when this is not one of ours (including a
  /// 422's `detail` LIST shape, which must not be misread as one of these four strings).
  static func fromDetailBody(_ data: Data) -> NativeExchangeFailure? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let detail = object["detail"] as? String
    else { return nil }
    return NativeExchangeFailure(rawValue: detail)
  }

  /// What to tell the person holding the phone. None of these blames them; all are fixed by
  /// signing in again.
  var message: String {
    switch self {
    case .codeInvalid: "That sign-in could not be completed. Please sign in again."
    case .codeExpired: "The sign-in took too long. Please sign in again."
    case .codeConsumed: "That sign-in was already used. Please sign in again."
    case .verifierMismatch: "The sign-in could not be verified. Please sign in again."
    }
  }
}
