import Foundation
import ImgManagerAPI
import OpenAPIRuntime

/// The P3 composition-root API boundary (fold item 2 / Amendment 8; diff-gate blocker 1
/// fold). Confined to exactly the three v0.9.0 endpoints P3 depends on:
/// - `GET /api/folders`
/// - `GET /api/health`
/// - `GET /api/status`
///
/// Bare `GET /health` is deliberately EXCLUDED: liveness can pass while the API/database
/// is unusable (Amendment 8), so it proves nothing this app can act on.
///
/// The ONLY injectable seam is the low-level `OpenAPIRuntime.ClientTransport` this factory
/// wraps into the REAL generated `Client` (conforming to the generated `APIProtocol`).
/// Everything above this line is the generated contract — there is no hand-written client
/// method and no synthetic response model standing between the app and the OpenAPI
/// document: a test that injects a `ClientTransport` proves its way through `Client`'s own
/// serializer/deserializer, so a renamed operation, a changed path, or a changed schema
/// breaks these tests, not just a parallel hand-rolled interface.
enum ImgManagerAPIClient {
  /// The deployed backend (RELEASING.md; v0.9.0 surface, Amendment 8 item 8(a)). The
  /// vendored OpenAPI document carries no `servers` block (FastAPI does not emit one), so
  /// this is a hand-set constant at the one call site that builds the generated `Client` —
  /// never duplicated elsewhere.
  static let baseURL = URL(string: "https://img.discomarder.live")!

  static func make(transport: any ClientTransport) -> any APIProtocol {
    Client(
      serverURL: baseURL,
      configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()),
      transport: transport)
  }
}

/// Wraps the generated `APIProtocol` client, confines calls to the three allowed
/// operations, and converts BOTH a generated `Output` that isn't `.ok` AND any thrown
/// transport error into one opaque, closed failure (fold item 4 / diff-gate blocker 2).
/// The catch blocks below never bind the underlying error to a name — there is nothing for
/// `localizedDescription`, a server body, a hostname, or any other raw transport text to
/// be copied into, at any point past this type.
struct ImgManagerAPIService: Sendable {
  private let client: any APIProtocol

  init(client: any APIProtocol) {
    self.client = client
  }

  func health() async throws -> Components.Schemas.ApiHealthResponse {
    let output: Operations.ApiHealthApiHealthGet.Output
    do {
      output = try await client.apiHealthApiHealthGet(.init())
    } catch {
      throw APIServiceError.unreachable
    }
    guard case .ok(let ok) = output else { throw APIServiceError.unreachable }
    guard let body = try? ok.body.json else { throw APIServiceError.unreachable }
    return body
  }

  func status() async throws -> Components.Schemas.StatusResponse {
    let output: Operations.StatusApiStatusGet.Output
    do {
      output = try await client.statusApiStatusGet(.init())
    } catch {
      throw APIServiceError.unreachable
    }
    guard case .ok(let ok) = output else { throw APIServiceError.unreachable }
    guard let body = try? ok.body.json else { throw APIServiceError.unreachable }
    return body
  }

  /// The intended local/tree query (fold item 2): `source_tier` left to the server's own
  /// default ("local"), which names the incoming spine.
  func folders() async throws -> Components.Schemas.FolderTree {
    let output: Operations.FolderTreeApiFoldersGet.Output
    do {
      output = try await client.folderTreeApiFoldersGet(
        .init(query: .init(sourceTier: .local, tree: nil)))
    } catch {
      throw APIServiceError.unreachable
    }
    guard case .ok(let ok) = output else { throw APIServiceError.unreachable }
    guard let body = try? ok.body.json else { throw APIServiceError.unreachable }
    return body
  }
}

/// Opaque by construction (fold item 4): one case, zero associated data. Nothing —
/// `localizedDescription`, a server body, a hostname, any raw transport string — can be
/// stored here even by mistake, because there is no storage for it to occupy.
enum APIServiceError: Error, Sendable, Equatable {
  case unreachable
}
