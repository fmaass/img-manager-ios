import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// The composition root's live wire transport (P1, retiring the placeholder transport
/// / IMGMGR-169). Wraps a real `ClientTransport` (`ImgManagerAPI.liveTransport()` — a
/// `URLSessionTransport`, kept behind that package's boundary; see its own doc comment) and
/// adds the `Authorization: Bearer <token>` header from `CredentialStore` before every request.
///
/// This stays the ONE injectable seam `RootView.init` names (ImgManagerAPIClient.swift's own
/// doc comment: "there is no hand-written client method... the ONLY injectable seam is the
/// low-level ClientTransport") — an `OpenAPIRuntime.ClientMiddleware` would have been the
/// officially-suggested mechanism for header injection (and is what memos-ng-ios uses,
/// `MemosAPI/BearerAuthMiddleware.swift`), but this repo's P3 diff-gate already fixed the
/// transport as the one seam, so Bearer injection is a transport wrapper here rather than a
/// second seam.
///
/// A request that has no stored credential is sent with NO `Authorization` header — never a
/// synthetic empty Bearer value — which is exactly what `/api/auth/native/exchange`'s anonymous
/// security (`p1-spec-rev2.md` §2: "exchange is anonymous") needs: this transport is the SAME
/// one the exchange call goes through, so it must not itself require a token to exist.
///
/// Diff-gate round 1, blocker 3: a terminal 401 on an ORDINARY authenticated operation
/// (health/status/folders — anything that is not one of the three native-auth operations,
/// which already classify their own 401s in `AuthSession`) must end the credential, not render
/// as a generic network failure forever. This is the one place that sees the raw response for
/// EVERY call, so it is where that classification belongs — `onTerminalUnauthorized` is invoked
/// (never the credential store's own `clear()` directly, so the caller decides how to report
/// the outcome, mirroring the same clear-with-error-handling path renewal and sign-out use).
struct AuthenticatedClientTransport: ClientTransport {
  /// The three native-auth operations classify their own 401s (renew: token dead, mint no
  /// successor; logout: already revoked). Re-firing the generic handler for them would be
  /// redundant at best and, under concurrent renewal, a second uncoordinated writer at worst.
  private static let selfManaged401OperationIDs: Set<String> = [
    "nativeExchangeApiAuthNativeExchangePost",
    "nativeRenewApiAuthNativeRenewPost",
    "nativeLogoutApiAuthNativeLogoutPost",
  ]

  private let inner: any ClientTransport
  private let credentialStore: CredentialStore
  private let onTerminalUnauthorized: @Sendable () async -> Void

  init(
    inner: any ClientTransport = ImgManagerAPI.liveTransport(),
    credentialStore: CredentialStore,
    onTerminalUnauthorized: @escaping @Sendable () async -> Void = {}
  ) {
    self.inner = inner
    self.credentialStore = credentialStore
    self.onTerminalUnauthorized = onTerminalUnauthorized
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var request = request
    var presentedBearer = false
    if case .present(let credential) = await credentialStore.load() {
      request.headerFields[.authorization] = "Bearer \(credential.token)"
      presentedBearer = true
    }
    let (response, responseBody) = try await inner.send(
      request, body: body, baseURL: baseURL, operationID: operationID)
    if presentedBearer, response.status.code == 401,
      !Self.selfManaged401OperationIDs.contains(operationID)
    {
      await onTerminalUnauthorized()
    }
    return (response, responseBody)
  }
}
