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
struct AuthenticatedClientTransport: ClientTransport {
  private let inner: any ClientTransport
  private let credentialStore: CredentialStore

  init(
    inner: any ClientTransport = ImgManagerAPI.liveTransport(), credentialStore: CredentialStore
  ) {
    self.inner = inner
    self.credentialStore = credentialStore
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var request = request
    if case .present(let credential) = await credentialStore.load() {
      request.headerFields[.authorization] = "Bearer \(credential.token)"
    }
    return try await inner.send(request, body: body, baseURL: baseURL, operationID: operationID)
  }
}
