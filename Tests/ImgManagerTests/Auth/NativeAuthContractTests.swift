import Foundation
import Testing

@testable import ImgManager

/// Login-URL construction and callback parsing — pure, unit-tested here rather than only
/// exercised through a live browser session (p1-spec-rev2.md §5: "first run
/// scripts/sync-openapi.sh... prove... Then build the session root, Keychain vault and sign-in
/// surface against that generated contract"; test inventory ORDER step 5: "login-URL
/// construction, callback URL parsing (good/missing/foreign scheme)").
@Suite("NativeAuth login URL construction")
struct NativeAuthLoginURLTests {
  private let baseURL = URL(string: "https://img.discomarder.live")!
  private let validChallenge = String(repeating: "a", count: 43)

  @Test("builds the exact endpoint with client=ios, code_challenge and device")
  func buildsExpectedURL() throws {
    let url = try #require(
      NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: validChallenge, device: "iPhone"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "https")
    #expect(components.host == "img.discomarder.live")
    #expect(components.path == "/api/auth/login")
    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "client", value: "ios")))
    #expect(items.contains(URLQueryItem(name: "code_challenge", value: validChallenge)))
    #expect(items.contains(URLQueryItem(name: "device", value: "iPhone")))
  }

  @Test("a code challenge shorter than 43 characters is rejected — the same 422 the server gives")
  func rejectsShortChallenge() {
    let tooShort = String(repeating: "a", count: 42)
    #expect(NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: tooShort, device: "d") == nil)
  }

  @Test("a code challenge longer than 128 characters is rejected")
  func rejectsLongChallenge() {
    let tooLong = String(repeating: "a", count: 129)
    #expect(NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: tooLong, device: "d") == nil)
  }

  @Test("a code challenge outside the base64url alphabet is rejected")
  func rejectsInvalidAlphabet() {
    let invalid = String(repeating: "a", count: 42) + "+"
    #expect(NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: invalid, device: "d") == nil)
  }

  @Test("an empty device name is rejected")
  func rejectsEmptyDevice() {
    #expect(
      NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: validChallenge, device: "  ")
        == nil)
  }

  @Test("a device name past 64 unicode scalars is rejected — native.py's DEVICE_NAME_MAX")
  func rejectsOverlongDevice() {
    let tooLong = String(repeating: "x", count: 65)
    #expect(
      NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: validChallenge, device: tooLong)
        == nil)
  }

  @Test("a device name of exactly 64 unicode scalars is accepted (boundary)")
  func acceptsExactlyMaxDevice() {
    let exact = String(repeating: "x", count: 64)
    #expect(
      NativeAuth.authorizeURL(baseURL: baseURL, codeChallenge: validChallenge, device: exact)
        != nil)
  }

  @Test("device name whitespace is trimmed before the length and emptiness checks")
  func trimsDeviceName() throws {
    let url = try #require(
      NativeAuth.authorizeURL(
        baseURL: baseURL, codeChallenge: validChallenge, device: "  iPhone  "))
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.contains(URLQueryItem(name: "device", value: "iPhone")))
  }
}

@Suite("NativeAuth callback parsing")
struct NativeAuthCallbackTests {
  private func url(_ string: String) -> URL {
    URL(string: string)!
  }

  // MARK: isOurCallback — the CLAIM

  @Test("recognizes the host form imgmanager://auth-callback")
  func recognizesHostForm() {
    #expect(NativeAuth.isOurCallback(url("imgmanager://auth-callback?code=abc")))
  }

  @Test("REJECTS the hostless form imgmanager:auth-callback (no slashes) — spec pins host form")
  func rejectsHostlessForm() {
    // The pinned lane is exactly scheme + HOST; the backend's IOS_RETURN_SCHEME_URL never
    // emits this shape, and admitting it only gives an injected URL more surface, not less.
    #expect(!NativeAuth.isOurCallback(url("imgmanager:auth-callback?code=abc")))
  }

  @Test("is case-insensitive on scheme and host")
  func caseInsensitive() {
    #expect(NativeAuth.isOurCallback(url("IMGMANAGER://Auth-Callback?code=abc")))
  }

  @Test("a foreign scheme is never ours")
  func foreignSchemeIsNotOurs() {
    #expect(!NativeAuth.isOurCallback(url("https://img.discomarder.live/ios/auth/callback")))
    #expect(!NativeAuth.isOurCallback(url("memosng://auth-callback?code=abc")))
    #expect(!NativeAuth.isOurCallback(url("someotherapp://auth-callback?code=abc")))
  }

  @Test("the right scheme with the wrong host is never ours")
  func wrongHostIsNotOurs() {
    #expect(!NativeAuth.isOurCallback(url("imgmanager://something-else?code=abc")))
  }

  // MARK: callback(from:) — the PARSE, only meaningful once isOurCallback is true

  @Test("a good callback carries the handoff code")
  func goodCallbackCarriesCode() {
    #expect(
      NativeAuth.callback(from: url("imgmanager://auth-callback?code=abc123")) == .code("abc123"))
  }

  @Test("a refused callback carries the error reason")
  func refusedCallbackCarriesReason() {
    #expect(
      NativeAuth.callback(from: url("imgmanager://auth-callback?error=access_denied"))
        == .failed(reason: "access_denied"))
  }

  @Test("a callback with no query at all is malformed — the stripped-echo case")
  func missingQueryIsMalformed() {
    #expect(NativeAuth.callback(from: url("imgmanager://auth-callback")) == .malformed)
  }

  @Test("a callback whose query has neither code nor error is malformed")
  func irrelevantQueryIsMalformed() {
    #expect(
      NativeAuth.callback(from: url("imgmanager://auth-callback?state=xyz")) == .malformed)
  }

  @Test("an empty code value is treated as malformed, not as an empty code")
  func emptyCodeIsMalformed() {
    #expect(NativeAuth.callback(from: url("imgmanager://auth-callback?code=")) == .malformed)
  }
}
