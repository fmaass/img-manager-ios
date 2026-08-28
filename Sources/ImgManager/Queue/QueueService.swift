import Foundation
import ImgManagerAPI

/// P7's own composition-root API boundary (WP8, IMGMGR-116) — a sibling of `GridService`/
/// `ImgManagerAPIService`, confined to the ONE read-only operation this screen needs:
/// `GET /api/folder-summaries` (WP7 P4, IMGMGR-110/111/112; live-verified 396 items, no query
/// parameters). No mutation, no second write lane — see `GridStore`'s own P6-coexistence doc
/// comment on why queue reads never share `GridStore`'s generation/lane state, and why this type
/// exists instead of extending `GridService`.
struct QueueService: Sendable {
  private let client: any APIProtocol

  init(client: any APIProtocol) {
    self.client = client
  }

  /// Unpaged: the endpoint declares no query parameters and returns every canonical folder's
  /// summary row in one response — the 396-item strategy (Q4) is a RENDERING concern (lazy
  /// list, no client-defined "active" subset), never a paging concern here.
  func summaries() async throws -> [Components.Schemas.FolderSummary] {
    let output: Operations.FolderSummariesApiFolderSummariesGet.Output
    do {
      output = try await client.folderSummariesApiFolderSummariesGet(.init())
    } catch {
      throw QueueServiceError.unreachable
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw QueueServiceError.unreachable
    }
    return body.items
  }
}

/// Opaque by construction, same discipline as `APIServiceError`/`GridServiceError`: this screen
/// has no outcome finer than "reachable or not" to distinguish (no mutation, no cursor, no
/// conflict) — one case, zero associated data.
enum QueueServiceError: Error, Sendable, Equatable {
  case unreachable
}
