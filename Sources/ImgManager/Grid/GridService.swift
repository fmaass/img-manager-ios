import Foundation
import ImgManagerAPI
import OpenAPIRuntime

/// P4's own composition-root API boundary — a sibling of P3's `ImgManagerAPIService`, not an
/// extension of it. P3's type is deliberately confined to its own three read-only operations
/// (its own doc comment: "Confined to exactly the three v0.9.0 endpoints P3 depends on") and its
/// error type is opaque by design with exactly ONE case, built for operations that have no
/// outcome finer than "reachable or not". P4's operations need MORE outcomes distinguished
/// (a stale-precondition 409 must roll optimistic UI back; an undocumented cursor-fingerprint
/// 400 must discard the cursor) — reusing P3's single-case error would force those distinctions
/// through string-matching or a second parallel signal, which is exactly the raw-string leakage
/// fold item 4 exists to prevent. So this type owns its own error enum instead, still fully
/// opaque (no stored raw text, no server body, no hostname), just with three cases instead of
/// one. `client` is the SAME generated `APIProtocol` value the composition root builds once
/// (`ImgManagerAPIClient.make`) and hands to both service types — nothing here builds a second
/// transport or a second `Client`.
///
/// Every operation this type exposes was proven against the real generated client BEFORE this
/// file existed (the P4 generated-contract probe, `GridServiceContractProbeTests.swift`) — the
/// method bodies below are the same call shapes that probe already exercises.
struct GridService: Sendable {
  private let client: any APIProtocol

  init(client: any APIProtocol) {
    self.client = client
  }

  // MARK: - Folders (shoot navigation)

  /// `GET /api/folders`. P4's endpoint-consumption table: "sufficient. Never render
  /// `FolderNode.path`." — this method returns the raw tree; the "never render path" rule is a
  /// VIEW-layer discipline (no view here reads `.path`), not something this method can enforce
  /// by omission without also breaking `folder_id` derivation elsewhere that legitimately needs
  /// the tree's other fields.
  func folders() async throws -> Components.Schemas.FolderTree {
    let output: Operations.FolderTreeApiFoldersGet.Output
    do {
      output = try await client.folderTreeApiFoldersGet(
        .init(query: .init(sourceTier: .local, tree: nil)))
    } catch {
      throw GridServiceError.unreachable
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return body
  }

  // MARK: - Images (grid + paging)

  /// One page of `GET /api/images`. Throws `.cursorInvalid` specifically when the server
  /// answers `400` — the cursor-fingerprint refusal (`app/api/cursor.py`'s `CursorError`,
  /// verified against the backend's own test suite, `tests/test_api_images_cursor_fingerprint.
  /// py`; the vendored v0.9.2 OpenAPI document does not declare this response for
  /// `list_images_api_images_get`, so the generated `Output` carries it as `.undocumented
  /// (statusCode: 400, _)` rather than a named case — the status code alone is what this method
  /// keys on, since the body has no declared schema to decode through the generated boundary).
  /// The caller's pinned response is "discard cursor, restart the same scope from page one".
  func images(_ query: GridImagesQuery, cursor: String?, limit: Int) async throws
    -> GridImagesPage
  {
    let output: Operations.ListImagesApiImagesGet.Output
    do {
      output = try await client.listImagesApiImagesGet(
        .init(query: query.asListImagesQuery(cursor: cursor, limit: limit)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let page = try? ok.body.json else { throw GridServiceError.unreachable }
      return GridImagesPage(items: page.items, nextCursor: page.nextCursor)
    case .unprocessableContent:
      throw GridServiceError.unreachable
    case .undocumented(let statusCode, _):
      if statusCode == 400 { throw GridServiceError.cursorInvalid }
      throw GridServiceError.unreachable
    }
  }

  // MARK: - Facets (Stats tab filter rows)

  func facets(_ query: GridImagesQuery) async throws -> Components.Schemas.ImageFacets {
    let output: Operations.ImageFacetsApiFacetsGet.Output
    do {
      output = try await client.imageFacetsApiFacetsGet(.init(query: query.asFacetsQuery()))
    } catch {
      throw GridServiceError.unreachable
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return body
  }

  // MARK: - Detail (inspector)

  func detail(imageID: Int) async throws -> Components.Schemas.ImageDetail {
    let output: Operations.GetImageApiImagesImageIdGet.Output
    do {
      output = try await client.getImageApiImagesImageIdGet(.init(path: .init(imageId: imageID)))
    } catch {
      throw GridServiceError.unreachable
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return body
  }

  // MARK: - Proxy pixels (fold item 2, closed 770786a)

  /// `v` is the identity token the list/detail response carried for this image ("required for
  /// immutable caching" per the schema) — callers pass whatever `ImageSummary`/`ImageDetail`
  /// most recently reported, never a hand-rolled value.
  func proxy(imageID: Int, tier: ProxyTier, v: String?) async throws -> ProxyFetchResult {
    let output: Operations.GetProxyApiImagesImageIdProxyTierGet.Output
    do {
      output = try await client.getProxyApiImagesImageIdProxyTierGet(
        .init(
          path: .init(imageId: imageID, tier: tier.rawValue),
          query: .init(v: v)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard case .jpeg(let body) = ok.body else { throw GridServiceError.unreachable }
      // A single proxy image is capped well under this; a runaway body is treated as
      // unreachable rather than silently buffered without bound.
      let data = try await Data(collecting: body, upTo: 30 * 1024 * 1024)
      return .ok(data)
    case .notModified:
      return .notModified
    case .notFound:
      return .notFound
    case .unprocessableContent, .undocumented:
      throw GridServiceError.unreachable
    }
  }

  // MARK: - Marks (revision-precondition path only — never unconditional)

  /// `preconditions` is REQUIRED and must be non-empty: P4 never sends an unconditional mark
  /// mutation (plan Mutations rule). The caller builds one `MarkPrecondition` per submitted id
  /// from the currently-loaded `MarkView.revision`.
  func setMarkState(
    imageIDs: [Int], state: MarkStateValue, preconditions: [Components.Schemas.MarkPrecondition]
  ) async throws -> Components.Schemas.MarksApplied {
    precondition(!preconditions.isEmpty, "setMarkState requires a non-empty precondition set")
    let payloadState: Components.Schemas.MarkStateRequest.StatePayload
    switch state {
    case .pick: payloadState = .pick
    case .dislike: payloadState = .dislike
    case .none: payloadState = .none
    }
    let body = Components.Schemas.MarkStateRequest(
      imageIds: imageIDs, preconditions: preconditions, state: payloadState)
    let output: Operations.SetMarkStateApiMarksStatePost.Output
    do {
      output = try await client.setMarkStateApiMarksStatePost(.init(body: .json(body)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let applied = try? ok.body.json else { throw GridServiceError.unreachable }
      return applied
    case .conflict:
      // Nothing was applied for ANY submitted id on a 409 (schema description: "nothing was
      // applied"), so the caller rolls the WHOLE batch back — no partial-stale bookkeeping is
      // needed even though the 409 body's `stale_image_ids` field has no declared schema to
      // decode it through (see GridServiceError.conflict's doc comment).
      throw GridServiceError.conflict
    case .unprocessableContent, .undocumented:
      throw GridServiceError.unreachable
    }
  }

  func editMarkTags(
    imageIDs: [Int], operation: MarkTagOperation, tag: String,
    preconditions: [Components.Schemas.MarkPrecondition]
  ) async throws -> Components.Schemas.MarksApplied {
    precondition(!preconditions.isEmpty, "editMarkTags requires a non-empty precondition set")
    let payloadOperation: Components.Schemas.MarkTagsRequest.OperationPayload
    switch operation {
    case .add: payloadOperation = .add
    case .remove: payloadOperation = .remove
    }
    let body = Components.Schemas.MarkTagsRequest(
      imageIds: imageIDs, operation: payloadOperation, preconditions: preconditions, tag: tag)
    let output: Operations.EditMarkTagsApiMarksTagsPost.Output
    do {
      output = try await client.editMarkTagsApiMarksTagsPost(.init(body: .json(body)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let applied = try? ok.body.json else { throw GridServiceError.unreachable }
      return applied
    case .conflict:
      throw GridServiceError.conflict
    case .unprocessableContent, .undocumented:
      throw GridServiceError.unreachable
    }
  }
}

enum MarkTagOperation: Sendable, Equatable { case add, remove }

enum ProxyFetchResult: Equatable, Sendable {
  case ok(Data)
  case notModified
  case notFound
}

struct GridImagesPage: Sendable, Equatable {
  var items: [Components.Schemas.ImageSummary]
  var nextCursor: String?
}

/// Opaque by construction, same discipline as P3's `APIServiceError`: every case carries zero
/// associated raw data. `.conflict` and `.cursorInvalid` add DISTINGUISHABILITY, not detail —
/// there is still no server body, hostname, or transport string reachable from any case here.
enum GridServiceError: Error, Sendable, Equatable {
  case unreachable
  /// 409 on a mark mutation: a named precondition was stale, nothing was applied.
  case conflict
  /// 400 on `GET /api/images`: the cursor-fingerprint refusal (see `images(_:)`'s doc comment).
  case cursorInvalid
}

/// The filter surface P4's Stats-tab facet rows and paging both need, shared between
/// `list_images_api_images_get` and `image_facets_api_facets_get` — their query parameters are
/// identical except for paging (`cursor`/`limit`, images-only). One value type here; two
/// mapping methods below produce each operation's own distinct generated `Input.Query` type
/// (the generator does not share query types across operations even when their shapes match).
struct GridImagesQuery: Sendable, Equatable {
  var folderID: Int?
  var sourceTier: GridSourceTier?
  var ratingMin: Int?
  var good: Bool?
  var label: String?
  var keyword: String?
  var q: String?
  var tag: String?
  var tree: String?
  var ext: String?
  var hasMaster: Bool?
  var mark: String?
  var dateFrom: Date?
  var dateTo: Date?
  var cameraPreviewOnly: Bool?
  var missing: Bool?

  init(folderID: Int? = nil) {
    self.folderID = folderID
  }

  func asListImagesQuery(cursor: String? = nil, limit: Int? = nil)
    -> Operations
    .ListImagesApiImagesGet.Input.Query
  {
    .init(
      cursor: cursor, limit: limit, folderId: folderID, ratingMin: ratingMin, good: good,
      label: label, keyword: keyword, q: q, tag: tag, sourceTier: sourceTier?.listImagesPayload,
      tree: tree, ext: ext, hasMaster: hasMaster, mark: mark, dateFrom: dateFrom, dateTo: dateTo,
      cameraPreviewOnly: cameraPreviewOnly, missing: missing)
  }

  func asFacetsQuery() -> Operations.ImageFacetsApiFacetsGet.Input.Query {
    .init(
      folderId: folderID, ratingMin: ratingMin, good: good, label: label, keyword: keyword, q: q,
      tag: tag, sourceTier: sourceTier?.facetsPayload, tree: tree, ext: ext, hasMaster: hasMaster,
      mark: mark, dateFrom: dateFrom, dateTo: dateTo, cameraPreviewOnly: cameraPreviewOnly,
      missing: missing)
  }
}

enum GridSourceTier: String, Sendable, Equatable {
  case local
  case archive

  var listImagesPayload: Operations.ListImagesApiImagesGet.Input.Query.SourceTierPayload {
    switch self {
    case .local: return .local
    case .archive: return .archive
    }
  }

  var facetsPayload: Operations.ImageFacetsApiFacetsGet.Input.Query.SourceTierPayload {
    switch self {
    case .local: return .local
    case .archive: return .archive
    }
  }
}
