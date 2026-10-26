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
  ///
  /// `sourceTier` generalized (WP8 P7, Q5): P4 hardcoded `.local` here because the sidebar only
  /// ever browsed the local tree — P7's iPad secondary "Folders" disclosure needs BOTH tier
  /// branches (`FolderTreeSection`), so the caller now names which tree it wants. Defaulting to
  /// `.local` keeps the one pre-existing call site (`RootView`'s old sidebar `.task`)
  /// byte-for-byte behavior-preserving.
  ///
  /// IMGMGR-350 P1: the parameter becomes `FolderTreeTier`, because the browse tier is the PAIR
  /// `(source_tier, tree)` and `GridSourceTier` can only say the first half — `edits` is a
  /// tree-role prefix inside the local store, not a source tier (`app/api/folders.py:38`). The
  /// `tree: nil` this used to send meant "whatever the server's own `PHOTO_TREE_ORIGINALS` is";
  /// `.incoming` now names that same prefix explicitly (`photo_incoming`, `app/config.py:113`),
  /// so the default keeps every pre-existing call site behaviour-preserving while making the
  /// edits tree expressible at all.
  func folders(tier: FolderTreeTier = .incoming) async throws -> Components.Schemas.FolderTree {
    let output: Operations.FolderTreeApiFoldersGet.Output
    do {
      output = try await client.folderTreeApiFoldersGet(
        .init(query: .init(sourceTier: tier.sourceTier.folderTreePayload, tree: tier.treePrefix)))
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

  // MARK: - Neighbours (P5 loupe forward prefetch)

  /// `GET /api/images/{id}/neighbours` — the images immediately after `imageID` in the CURRENT
  /// filter's order (fold-verified premise: this endpoint already existed server-side; P5 adds
  /// only this app-layer wrapper). Distinct from `images(_:cursor:limit:)`: this is the loupe's
  /// own small, targeted forward-look from a specific image, never a backward variant (the
  /// endpoint has none — fold: "NEVER a new/backward server endpoint"), and never a
  /// filmstrip-local paging path (its result is merged into `GridStore.images`, never kept
  /// separately).
  func neighbours(after imageID: Int, query: GridImagesQuery, limit: Int) async throws
    -> GridImagesPage
  {
    let output: Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Output
    do {
      output = try await client.imageNeighboursApiImagesImageIdNeighboursGet(
        .init(path: .init(imageId: imageID), query: query.asNeighboursQuery(limit: limit)))
    } catch {
      throw GridServiceError.unreachable
    }
    guard case .ok(let ok) = output, let page = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return GridImagesPage(items: page.items, nextCursor: page.nextCursor)
  }

  // MARK: - Group headers (WP13 P5b: the only truthful section source)

  /// `GET /api/image-groups` — the section headers for `query` under `groupBy`.
  ///
  /// This exists because a page holds PART of a group: `/api/images` can tell a client where a
  /// boundary falls (`ImageSummary.group_key`), but it cannot tell it how big the group is, what
  /// the Unknown bucket is called, or which timezone a time-key label was rendered in. The route
  /// says so itself — "the ONLY truthful way a client can place a section header"
  /// (`app/api/images.py:1816-1826`) — and `sum(headers[].count) == total` including Unknown
  /// (live-probed 2026-08-30: `group_by=camera` → 3 headers summing to 37,061 == `total`).
  ///
  /// No paging and no order: a header list is neither paged nor sorted, which is also why this
  /// endpoint takes no `sort`/`direction`/`cursor` at all.
  func imageGroups(_ query: GridImagesQuery, groupBy: GroupByKey) async throws
    -> Components.Schemas.ImageGroups
  {
    let output: Operations.ImageGroupsApiImageGroupsGet.Output
    do {
      output = try await client.imageGroupsApiImageGroupsGet(
        .init(query: query.asImageGroupsQuery(groupBy: groupBy)))
    } catch {
      throw GridServiceError.unreachable
    }
    if case .serviceUnavailable(let cancelled) = output {
      throw GridServiceError.countCancelled(retryAfterSeconds: cancelled.headers.retryAfter)
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return body
  }

  // MARK: - Scene browse (WP12: stacks as display rows)

  /// One page of `GET /api/browse/stacks` — DISPLAY ROWS, not photographs: a loose photo is one
  /// row and a whole scene is one row, so `limit` counts rows and a page of 100 can stand for
  /// thousands of frames.
  ///
  /// Chronological only, by the contract's own words ("stack mode has no other order"): there is
  /// no `sort` and no `group_by` parameter to pass, because a stack carries ONE stored capture-
  /// order anchor. `seekDate` is the endpoint's own way to jump to a Europe/Zurich calendar day
  /// and is mutually exclusive with `cursor` — passing both is the caller's error, and the server
  /// answers 422.
  ///
  /// The 400 mapping is the same as `images(_:cursor:limit:)`'s and for the same reason, with one
  /// extra edge this endpoint adds: a stack cursor and an `/api/images` cursor carry DIFFERENT
  /// fingerprints, so handing this endpoint a flat cursor is refused as `cursor_scope_mismatch` —
  /// a 400 the vendored document does not declare (the operation declares 200 and 422 only,
  /// verified against `openapi.json` at the vendored commit), so it arrives as
  /// `.undocumented(400, _)` exactly like the flat refusal does.
  func browseStacks(
    _ query: GridImagesQuery, direction: SceneBrowseDirection = .asc, cursor: String?,
    seekDate: String? = nil, limit: Int
  ) async throws -> StackBrowsePageResult {
    let output: Operations.BrowseStacksApiBrowseStacksGet.Output
    do {
      output = try await client.browseStacksApiBrowseStacksGet(
        .init(
          query: query.asBrowseStacksQuery(
            direction: direction, cursor: cursor, seekDate: seekDate, limit: limit)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let page = try? ok.body.json else { throw GridServiceError.unreachable }
      // A row that narrows to NEITHER branch is an unusable page, not a photograph to skip
      // quietly: silently dropping it would leave a hole in capture order that no badge, count
      // or cursor accounts for. `compactMap` + a count check keeps the whole page honest.
      let rows = page.items.compactMap(SceneBrowseRow.narrow(_:))
      guard rows.count == page.items.count else { throw GridServiceError.unreachable }
      return StackBrowsePageResult(rows: rows, nextCursor: page.nextCursor)
    case .unprocessableContent:
      throw GridServiceError.unreachable
    case .undocumented(let statusCode, _):
      if statusCode == 400 { throw GridServiceError.cursorInvalid }
      throw GridServiceError.unreachable
    }
  }

  /// One page of `GET /api/stacks/{id}/members` — the AUTHORITATIVE membership: every member
  /// including tombstoned ones, in capture order, and deliberately UNFILTERED (the filtered
  /// number is the card's own `matched_count`; conflating the two would make an opened scene show
  /// fewer photographs than its badge claims — the handler's own docstring,
  /// `app/api/stacks.py`).
  ///
  /// The members cursor has its own fingerprint too, so the same undocumented-400 mapping applies.
  func stackMembers(stackID: Int, cursor: String?, limit: Int) async throws -> StackMemberPageResult
  {
    let output: Operations.ListStackMembersApiStacksStackIdMembersGet.Output
    do {
      output = try await client.listStackMembersApiStacksStackIdMembersGet(
        .init(path: .init(stackId: stackID), query: .init(cursor: cursor, limit: limit)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let page = try? ok.body.json else { throw GridServiceError.unreachable }
      return StackMemberPageResult(
        stackID: page.stackId, items: page.items, nextCursor: page.nextCursor)
    case .unprocessableContent:
      throw GridServiceError.unreachable
    case .undocumented(let statusCode, _):
      if statusCode == 400 { throw GridServiceError.cursorInvalid }
      // WP442 P12: an undocumented 404 is the server's evidence that the scene is gone.
      if statusCode == 404 { throw GridServiceError.notFound }
      throw GridServiceError.unreachable
    }
  }

  /// `GET /api/stacks/{id}` — ONE scene's row, re-read in the SAME filter context the page was
  /// browsed in so its `matched_count` answers the question the active filters are asking.
  ///
  /// This is the cover-refresh read: after a write touches a member, the card's aggregate fields
  /// are stale (the representative is derived at read time and moves the moment a member is
  /// picked). Re-reading one row is what lets the card tell the truth without a reload costing the
  /// reader their scroll position, their open scenes and their selection on every press of P.
  /// No `direction`: a single row has no order.
  func stackRow(stackID: Int, query: GridImagesQuery) async throws
    -> Components.Schemas.StackBrowseStackRow
  {
    let output: Operations.GetStackApiStacksStackIdGet.Output
    do {
      output = try await client.getStackApiStacksStackIdGet(
        .init(path: .init(stackId: stackID), query: query.asStackRowQuery()))
    } catch {
      throw GridServiceError.unreachable
    }
    // WP442 P12: an undocumented 404 is the server's evidence that the scene is gone.
    if case .undocumented(let statusCode, _) = output, statusCode == 404 {
      throw GridServiceError.notFound
    }
    guard case .ok(let ok) = output, let row = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return row
  }

  // MARK: - Scene editing (WP14 P4, IMGMGR-277)

  /// `POST /api/stacks/merge` — join two or more scenes of ONE folder into one.
  ///
  /// The SURVIVOR is the server's choice (the lowest id) and comes back in `stack_ids`; the others
  /// come back in `dissolved_stack_ids`. Nothing here names one, and nothing here changes local
  /// membership: the client re-reads (ADR-0005's server-authority stance, which ADR-0008 leaves
  /// untouched).
  ///
  /// img-manager v0.20.0 declares the 409 `StackExtractConflictError` here too (IMGMGR-371) — it
  /// used to declare none, on the principle that a status code declared on a route that never
  /// emits it is as wrong as an emitted one nobody declared. It is NOT the same answer as the
  /// refusal: a cross-folder or cross-tier merge is still a coded 422 (the request was wrong),
  /// while the 409 says the scenes moved under a request that was right when it was written.
  func mergeStacks(stackIDs: [Int]) async throws -> Components.Schemas.StackEditResult {
    let output: Operations.MergeStacksApiStacksMergePost.Output
    do {
      output = try await client.mergeStacksApiStacksMergePost(
        .init(body: .json(Components.Schemas.StackMergeRequest(stackIds: stackIDs))))
    } catch {
      throw StackEditError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let result = try? ok.body.json else { throw StackEditError.unreachable }
      return result
    case .conflict(let conflict):
      guard let body = try? conflict.body.json else { throw StackEditError.unreachable }
      switch body.detail.code {
      case .foreignFolderMember: throw StackEditError.conflict(.foreignFolderMember)
      case .membershipChanged: throw StackEditError.conflict(.membershipChanged)
      }
    case .unprocessableContent:
      throw StackEditError.refused
    case .serviceUnavailable(let busy):
      throw StackEditError.busy(retryAfterSeconds: busy.headers.retryAfter)
    case .undocumented:
      throw StackEditError.unreachable
    }
  }

  /// `POST /api/stacks/{id}/split` — cut a scene BEFORE `atImageID`: it and every later member
  /// become a new stack, and both halves come back fenced `manual`.
  func splitStack(stackID: Int, atImageID: Int) async throws
    -> Components.Schemas.StackEditResult
  {
    let output: Operations.SplitStackApiStacksStackIdSplitPost.Output
    do {
      output = try await client.splitStackApiStacksStackIdSplitPost(
        .init(
          path: .init(stackId: stackID),
          body: .json(Components.Schemas.StackSplitRequest(atImageId: atImageID))))
    } catch {
      throw StackEditError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let result = try? ok.body.json else { throw StackEditError.unreachable }
      return result
    case .conflict(let conflict):
      guard let body = try? conflict.body.json else { throw StackEditError.unreachable }
      switch body.detail.code {
      case .foreignFolderMember: throw StackEditError.conflict(.foreignFolderMember)
      case .membershipChanged: throw StackEditError.conflict(.membershipChanged)
      }
    case .unprocessableContent:
      throw StackEditError.refused
    case .serviceUnavailable(let busy):
      throw StackEditError.busy(retryAfterSeconds: busy.headers.retryAfter)
    case .undocumented:
      throw StackEditError.unreachable
    }
  }

  /// `POST /api/stacks/{id}/extract` — take exactly these members into a scene of their own.
  ///
  /// The FIRST editor to answer 409, and no longer the only one: v0.20.0 declares the same
  /// `StackExtractConflictError` on merge, split and eject as well (IMGMGR-371), so the mapping
  /// below is now the shape four of this client's editors share. Its two codes are mapped to a
  /// typed reason here, so the surface that renders it never sees a status number.
  func extractFromStack(stackID: Int, imageIDs: [Int]) async throws
    -> Components.Schemas.StackEditResult
  {
    let output: Operations.ExtractFromStackApiStacksStackIdExtractPost.Output
    do {
      output = try await client.extractFromStackApiStacksStackIdExtractPost(
        .init(
          path: .init(stackId: stackID),
          body: .json(Components.Schemas.StackExtractRequest(imageIds: imageIDs))))
    } catch {
      throw StackEditError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let result = try? ok.body.json else { throw StackEditError.unreachable }
      return result
    case .conflict(let conflict):
      guard let body = try? conflict.body.json else { throw StackEditError.unreachable }
      switch body.detail.code {
      case .foreignFolderMember: throw StackEditError.conflict(.foreignFolderMember)
      case .membershipChanged: throw StackEditError.conflict(.membershipChanged)
      }
    case .unprocessableContent:
      throw StackEditError.refused
    case .serviceUnavailable(let busy):
      throw StackEditError.busy(retryAfterSeconds: busy.headers.retryAfter)
    case .undocumented:
      throw StackEditError.unreachable
    }
  }

  /// `POST /api/stacks/{id}/absorb` — take LOOSE photographs into an existing scene (IMGMGR-347,
  /// the client half of IMGMGR-289's verb).
  ///
  /// The one editor whose subject is not a membership, and the only one that answers 404: the
  /// scene may be gone, or a photograph this request named may not be in the library at all
  /// (`unknown_image`). That is mapped to its own `.vanished` rather than folded into `.refused`,
  /// because it is not the edit that was wrong. The 409 pair is the extraction's own
  /// (`StackExtractConflictError`), which the contract widened to this route for the same two
  /// reasons from the other direction — a loose photograph of another folder, or a photograph
  /// that stopped being loose between the check and the write.
  func absorbIntoStack(stackID: Int, imageIDs: [Int]) async throws
    -> Components.Schemas.StackEditResult
  {
    let output: Operations.AbsorbIntoStackApiStacksStackIdAbsorbPost.Output
    do {
      output = try await client.absorbIntoStackApiStacksStackIdAbsorbPost(
        .init(
          path: .init(stackId: stackID),
          body: .json(Components.Schemas.StackAbsorbRequest(imageIds: imageIDs))))
    } catch {
      throw StackEditError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard let result = try? ok.body.json else { throw StackEditError.unreachable }
      return result
    case .notFound:
      throw StackEditError.vanished
    case .conflict(let conflict):
      guard let body = try? conflict.body.json else { throw StackEditError.unreachable }
      switch body.detail.code {
      case .foreignFolderMember: throw StackEditError.conflict(.foreignFolderMember)
      case .membershipChanged: throw StackEditError.conflict(.membershipChanged)
      }
    case .unprocessableContent:
      throw StackEditError.refused
    case .serviceUnavailable(let busy):
      throw StackEditError.busy(retryAfterSeconds: busy.headers.retryAfter)
    case .undocumented:
      throw StackEditError.unreachable
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
    if case .serviceUnavailable(let cancelled) = output {
      throw GridServiceError.countCancelled(retryAfterSeconds: cancelled.headers.retryAfter)
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return body
  }

  // MARK: - Status + marks export (WP13 P5a, IMGMGR-221)

  /// P3's own read-only boundary, over the SAME generated client this type already holds —
  /// deliberately vended rather than re-implemented. `ImgManagerAPIService.status()` exists,
  /// is tested, and its single-case opaque error is exactly the granularity a status read
  /// needs ("reachable or not"); copying it here would give one endpoint two client methods.
  var statusService: ImgManagerAPIService { ImgManagerAPIService(client: client) }

  /// IMGMGR-545: the three sync routes, over the same client (`SyncService`).
  var syncService: SyncService { SyncService(client: client) }

  /// `GET /api/marks/export` with the server's DEFAULTS — `state=pick`, `format=json`.
  ///
  /// `format=txt` is never requested: the vendored document declares only `application/json`
  /// for the 200 response, so a `txt` request is unrepresentable by the generated client (it
  /// would decode as `.undocumented`). Live-probed 2026-08-30 against the deployed backend:
  /// `count=211`, `state=["pick"]`, `truncated=false`, bare stems with no path separator.
  ///
  /// The response describes the WHOLE marked set, never the browse scope, and may be
  /// truncated — see `MarksExportCopy`, which is where that is turned into what the reader is
  /// told. This method deliberately passes no query at all, so no filter can leak in and make
  /// the answer look scoped when it is not.
  func marksExport() async throws -> Components.Schemas.MarksExport {
    let output: Operations.ExportMarksApiMarksExportGet.Output
    do {
      output = try await client.exportMarksApiMarksExportGet(.init(query: .init()))
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

  // MARK: - Looks (IMGMGR-382, img-manager v0.21.0)

  /// `GET /api/looks` — the looks this server can apply right now, in its own manifest order. A
  /// look whose asset failed the server's integrity check is simply absent, so the list is
  /// returned as-is: this client neither sorts it nor fills a gap.
  ///
  /// The app never holds a look's colour table. The catalogue is descriptive only (name,
  /// category, source, licence), and every looked pixel comes from `lookedProxy` below.
  func looks() async throws -> [Components.Schemas.LookSummary] {
    let output: Operations.ListLooksApiLooksGet.Output
    do {
      output = try await client.listLooksApiLooksGet(.init())
    } catch {
      throw GridServiceError.unreachable
    }
    guard case .ok(let ok) = output, let body = try? ok.body.json else {
      throw GridServiceError.unreachable
    }
    return body.looks
  }

  /// `GET /api/images/{id}/proxy/{tier}/look/{look_id}?strength=` — the cached proxy for `tier`
  /// with one catalogued look applied at `strength` percent (img-manager v0.24.0; 0 is the proxy,
  /// 100 the look, 200 doubles it). The strength is ALWAYS sent, 100 included, so the request
  /// says what it shows. No `v` is EVER sent, so every response is `no-store`, URLSession's HTTP
  /// cache can never answer it, and there is no 304 here. IMGMGR-544: the 200's `X-Look-Version`
  /// (the server's looked-cache key of these bytes) is handed back as `version`, which is what
  /// `LookedCache` keys bytes by.
  ///
  /// The 404 is NOT the unlooked proxy's 404: nothing is queued by asking for a look, so a caller
  /// that gets `.notFound` asks for the unlooked proxy, which is the request that enqueues one.
  /// The coded 422 (`unknown_look`, `invalid_request`) arrives typed, in the stack-edit
  /// refusals' idiom; an undecodable 422 body, an undeclared status or a transport failure is
  /// `.unreachable`.
  func lookedProxy(imageID: Int, tier: ProxyTier, lookID: String, strength: Int) async throws
    -> LookedProxyFetchResult
  {
    let output: Operations.GetLookedProxyApiImagesImageIdProxyTierLookLookIdGet.Output
    do {
      output = try await client.getLookedProxyApiImagesImageIdProxyTierLookLookIdGet(
        .init(
          path: .init(imageId: imageID, tier: tier.rawValue, lookId: lookID),
          query: .init(strength: strength)))
    } catch {
      throw GridServiceError.unreachable
    }
    switch output {
    case .ok(let ok):
      guard case .jpeg(let body) = ok.body else { throw GridServiceError.unreachable }
      // The same bound as the unlooked proxy: a looked render is the same size of image.
      let data = try await Data(collecting: body, upTo: 30 * 1024 * 1024)
      return .ok(data, version: ok.headers.xLookVersion)
    case .notFound:
      return .notFound
    case .unprocessableContent(let refusal):
      guard let body = try? refusal.body.json else { throw GridServiceError.unreachable }
      return .refused(LookRefusalCode(body.detail.code))
    case .undocumented:
      throw GridServiceError.unreachable
    }
  }

  // MARK: - Saved look (IMGMGR-544, img-manager v0.24.0)

  /// `PUT /api/images/{id}/look` — save `lookID` at `strength` on one photograph (an upsert on
  /// the server, last write wins). Answers the saved `ImageLookView`. Throws `LookWriteError`
  /// only: `.refused`, `.gone` and `.versionConflict` are definite (nothing was written),
  /// `.uncertain` is a transport failure, an undeclared status or an undecodable 200, after which
  /// the server MAY hold it.
  ///
  /// `lookVersion` (IMGMGR-642) is the catalogue `version` of the look the strip previewed; nil
  /// leaves `look_version` out of the body. A 409 says the catalogue serves another version now.
  /// The generated client decodes a JSON body inside the call, so a 409 whose body does not
  /// decode arrives as a `ClientError` carrying the 409 response; it is classified by that status
  /// before the catch-all, and stays definite.
  func putLook(imageID: Int, lookID: String, strength: Int, lookVersion: String?) async throws
    -> Components.Schemas.ImageLookView
  {
    let body = Components.Schemas.ImageLookRequest(
      lookId: lookID, lookVersion: lookVersion, strength: strength)
    let output: Operations.PutImageLookApiImagesImageIdLookPut.Output
    do {
      output = try await client.putImageLookApiImagesImageIdLookPut(
        .init(path: .init(imageId: imageID), body: .json(body)))
    } catch let error as ClientError where error.response?.status.code == 409 {
      throw LookWriteError.versionConflict(current: nil)
    } catch {
      throw LookWriteError.uncertain
    }
    switch output {
    case .ok(let ok):
      guard let view = try? ok.body.json else { throw LookWriteError.uncertain }
      return view
    case .notFound:
      throw LookWriteError.gone
    case .unprocessableContent(let refusal):
      throw LookWriteError.refused(Self.refusalCode(try? refusal.body.json))
    case .conflict(let conflict):
      let current = (try? conflict.body.json)?.detail.currentVersion
      throw LookWriteError.versionConflict(current: current)
    case .undocumented:
      throw LookWriteError.uncertain
    }
  }

  /// `DELETE /api/images/{id}/look` — remove the saved look (204). The same error vocabulary
  /// as `putLook`.
  func deleteLook(imageID: Int) async throws {
    let output: Operations.DeleteImageLookApiImagesImageIdLookDelete.Output
    do {
      output = try await client.deleteImageLookApiImagesImageIdLookDelete(
        .init(path: .init(imageId: imageID)))
    } catch {
      throw LookWriteError.uncertain
    }
    switch output {
    case .noContent:
      return
    case .notFound:
      throw LookWriteError.gone
    case .unprocessableContent(let refusal):
      throw LookWriteError.refused(Self.refusalCode(try? refusal.body.json))
    case .undocumented:
      throw LookWriteError.uncertain
    }
  }

  /// A 422 is a refusal whether or not its body decodes: nothing was written.
  private static func refusalCode(_ body: Components.Schemas.LookRefusalError?)
    -> LookRefusalCode
  {
    body.map { LookRefusalCode($0.detail.code) } ?? .invalidRequest
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

/// Step 3 of `ShareMasterSeam`'s activation list: the share lane's byte source, living where
/// the generated client does rather than in the share lane itself (the seam's own rule —
/// "conformances live wherever the generated client does (`GridService`), never here").
///
/// One request, `content=master`, and NEVER a `rendition`: `ShareVariant` has no case that
/// could name an original, and this method has no parameter that could carry one, so the
/// IMGMGR-196 invariant — a RAW original is never asked for, let alone shared — holds by
/// construction rather than by review. `MasterDownloadTests.masterIsTheOnlyThingEverAskedFor`
/// reads the query string the generated client actually built, so a future edit that adds one
/// fails a named test.
///
/// The bytes are STREAMED to disk through `ShareStreamWriter` under the master lane's named
/// cap: an edited export off a 60 MP frame is far larger than any proxy, and past the cap the
/// partial file is deleted and the export refuses rather than buffering whatever arrives.
extension GridService: MasterDownloading {
  func downloadMaster(imageID: Int, into directory: URL) async -> MasterDownloadOutcome {
    let output: Operations.DownloadImageApiImagesImageIdDownloadGet.Output
    do {
      output = try await client.downloadImageApiImagesImageIdDownloadGet(
        .init(path: .init(imageId: imageID), query: .init(content: .master)))
    } catch {
      // Opaque by construction, exactly as `GridServiceError` is: nothing here can carry server
      // text, a hostname or a transport string into the refusal the user reads.
      return .refused(.notConnected)
    }
    switch output {
    case .ok(let ok):
      let (body, mimeType) = Self.masterBody(ok.body)
      let contentType = ShareExportPlan.contentType(for: mimeType)
      // The SERVER's name (gate correction 5), and only then the typed fallback — never the
      // photograph's own filename, which names the RAW.
      let filename =
        ShareExportPlan.filename(fromContentDisposition: ok.headers.contentDisposition)
        ?? ShareExportPlan.masterFilename(imageID: imageID, contentType: contentType)
      guard
        (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true))
          != nil
      else {
        return .refused(.couldNotPrepare)
      }
      let url = directory.appending(path: filename, directoryHint: .notDirectory)
      do {
        try await ShareStreamWriter.write(body, to: url, cap: ShareExportPlan.masterByteCap)
      } catch ShareStreamWriter.Failure.tooLarge {
        return .refused(.tooLarge)
      } catch {
        return .refused(.couldNotPrepare)
      }
      return .ok(ShareExportFile(url: url, filename: filename, contentType: contentType))
    case .forbidden(let forbidden):
      // A `403` is the RAW-policy answer ONLY with `X-Img-Policy`; a bare one is the proxy or
      // the session refusing. The split lives in `ShareExportPlan.refusal`, not here.
      return .refused(
        ShareExportPlan.refusal(status: 403, policyHeader: forbidden.headers.xImgPolicy?.rawValue))
    case .notFound:
      return .refused(.noMaster)
    case .badRequest, .unprocessableContent, .undocumented:
      // `400` is "a rendition and a content choice at once", which this client cannot produce;
      // it is grouped with the other unexpected answers rather than given copy of its own.
      return .refused(.notConnected)
    }
  }

  /// The `200`'s seven declared bodies, each carrying the same thing — a stream of bytes and the
  /// wire type that names them. Kept next to the request so the ONE place that has to change
  /// when the contract grows an eighth content type is the place that already reads the
  /// contract; `ShareExportPlan` stays free of the generated types, as its own doc comment
  /// requires.
  private static func masterBody(
    _ body: Operations.DownloadImageApiImagesImageIdDownloadGet.Output.Ok.Body
  ) -> (HTTPBody, String) {
    switch body {
    case .binary(let body): return (body, "application/octet-stream")
    case .imageHeic(let body): return (body, "image/heic")
    case .imageHeif(let body): return (body, "image/heif")
    case .jpeg(let body): return (body, "image/jpeg")
    case .png(let body): return (body, "image/png")
    case .imageTiff(let body): return (body, "image/tiff")
    case .imageWebp(let body): return (body, "image/webp")
    }
  }
}

enum MarkTagOperation: Sendable, Equatable { case add, remove }

enum ProxyFetchResult: Equatable, Sendable {
  case ok(Data)
  case notModified
  case notFound
}

/// What `GridService.lookedProxy` answered (IMGMGR-382). No `.notModified`: the looked route
/// never sends a validator.
enum LookedProxyFetchResult: Equatable, Sendable {
  /// `version` is the response's `X-Look-Version`, nil when the header was absent.
  case ok(Data, version: String? = nil)
  /// No proxy is cached for this image and tier — and nothing was queued by asking.
  case notFound
  /// The coded 422.
  case refused(LookRefusalCode)
}

/// `LookRefusal.code`, as this client's own vocabulary — a typed code, never the server's
/// sentence.
enum LookRefusalCode: Sendable, Equatable {
  case unknownLook
  case invalidRequest

  init(_ code: Components.Schemas.LookRefusal.CodePayload) {
    switch code {
    case .unknownLook: self = .unknownLook
    case .invalidRequest: self = .invalidRequest
    }
  }
}

/// What a saved-look write (`putLook`/`deleteLook`, IMGMGR-544) failed with.
enum LookWriteError: Error, Sendable, Equatable {
  /// The coded 422: nothing was written.
  case refused(LookRefusalCode)
  /// 404: no photograph has this id; nothing was written.
  case gone
  /// 409 `look_version_mismatch` (PUT only): the catalogue no longer serves the version the
  /// request named; nothing was written. `current` is the server's version when the body
  /// decoded. Never retried: the reader previews again and presses Apply.
  case versionConflict(current: String?)
  /// Transport, an undeclared status or an undecodable 200: the server MAY have committed.
  case uncertain
}

struct GridImagesPage: Sendable, Equatable {
  var items: [Components.Schemas.ImageSummary]
  var nextCursor: String?
}

/// The one order `GET /api/browse/stacks` serves ("asc or desc over capture time; stack mode has
/// no other order"). A mode-local presentation control, deliberately NOT part of
/// `GridImagesQuery`: the flat endpoint in this client has never had a direction, and adding one
/// there would be a second, unrelated feature riding along on this lane.
enum SceneBrowseDirection: Sendable, Equatable {
  case asc
  case desc

  var payload: Operations.BrowseStacksApiBrowseStacksGet.Input.Query.DirectionPayload {
    switch self {
    case .asc: return .asc
    case .desc: return .desc
    }
  }
}

/// One page of Scene browse, with the wire union already narrowed onto `SceneBrowseRow`.
struct StackBrowsePageResult: Sendable, Equatable {
  var rows: [SceneBrowseRow]
  var nextCursor: String?
}

/// One page of ONE scene's membership. `stackID` is echoed by the server and carried through
/// rather than assumed, so a page can never be spliced into the wrong card.
struct StackMemberPageResult: Sendable, Equatable {
  var stackID: Int
  var items: [Components.Schemas.ImageSummary]
  var nextCursor: String?
}

/// Opaque by construction, same discipline as P3's `APIServiceError`: every case carries zero
/// associated raw data. `.conflict` and `.cursorInvalid` add DISTINGUISHABILITY, not detail —
/// there is still no server body, hostname, or transport string reachable from any case here.
enum GridServiceError: Error, Sendable, Equatable {
  case unreachable
  /// WP442 P12: `GET /api/stacks/{id}` or its members answered 404 — the scene is gone.
  case notFound
  /// 409 on a mark mutation: a named precondition was stale, nothing was applied.
  case conflict
  /// 400 on `GET /api/images`: the cursor-fingerprint refusal (see `images(_:)`'s doc comment).
  case cursorInvalid
  /// 503 `count_cancelled` on a count-bearing read — `GET /api/facets` and
  /// `GET /api/image-groups`, the two this client calls. The server cancelled the count before
  /// it finished, so nothing came back partially and a count that could not be taken is not a
  /// count of zero; it is not a reachability failure either, which is why it is not
  /// `.unreachable`. `Retry-After` is the server's own answer to when it is worth asking again;
  /// nil means it named none.
  case countCancelled(retryAfterSeconds: Int?)
}

/// A scene edit's refusals, as the three DIFFERENT answers they are (WP14 P4, IMGMGR-277).
///
/// Separate from `GridServiceError` rather than folded into it: that type's cases are about
/// reachability and a stale mark precondition, while these are a contract's own vocabulary — a
/// busy folder that says WHEN to ask again, a conflict that names WHY, and a refusal the contract
/// makes. Folding them together would force the surface that renders them to re-derive the
/// distinction it was handed.
///
/// Opaque on the same terms as its sibling: a typed code and an integer, never the server's
/// sentence, body or hostname.
enum StackEditError: Error, Sendable, Equatable {
  /// 503 `stack_edit_busy`, with `Retry-After` if the server named one.
  case busy(retryAfterSeconds: Int?)
  /// 409 — the scene is not in the state the request was written against. Declared on merge,
  /// split, extract and absorb (and on eject, which this client does not map) since v0.20.0; it
  /// was the extraction's alone when this type was written.
  case conflict(SceneEditConflictReason)
  /// 422, and since img-manager v0.20.0 an answer this client can actually read. The recut
  /// declares the coded body these routes always emitted — `StackEditRefusalError { detail:
  /// StackEditRefusal { code, message } }`, ten codes including `too_few_stacks` and
  /// `invalid_request` — on all six stack editors, so the generated client decodes it and the
  /// refusal arrives here as `.refused` instead of the `.unreachable` an undecodable body used to
  /// produce (IMGMGR-371; the position this replaces is recorded in `StackEditContractProbeTests`).
  ///
  /// Deliberately still opaque. Every consumer of this case collapses to the payload-less
  /// `SceneEditFailure.refused` (`SceneEdit.swift`), whose sentence is the one true thing for all
  /// ten codes: nothing was changed. Widening it to carry `StackEditRefusal.CodePayload` is a
  /// one-file change on the day a surface renders a per-code sentence; a value no reader
  /// consumes is not a contract improvement.
  case refused
  /// 404 — the absorb alone (IMGMGR-347): the scene is gone, or a photograph the request named is
  /// not in the library. Kept apart from `.refused` because the reader is told a different thing.
  case vanished
  case unreachable
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
  /// One camera BODY, exactly as `/api/facets` reports it (IMGMGR-376, WP21 P2). An equality on
  /// `images.exif_camera` server-side, so the string travels back verbatim — this client neither
  /// parses it nor derives the value list, which is why there is no enum here.
  ///
  /// Threaded into EVERY projection below, not only the two the popover reads. A filter the grid
  /// applies but the scene band, the stack-row re-read, the loupe's neighbours or the group
  /// headers do not send is a filter that silently no-ops on those surfaces — the reader would
  /// see one camera's photographs and a header count for all of them.
  var camera: String?
  var hasMaster: Bool?
  /// IMGMGR-544: photographs with a SAVED look (`has_look`), whether or not an edit supersedes
  /// its rendering. Uncounted: `/api/facets` has no `has_look` facet.
  var hasLook: Bool?
  var mark: String?
  var dateFrom: Date?
  var dateTo: Date?
  var cameraPreviewOnly: Bool?
  var missing: Bool?

  /// WP13 P5b (IMGMGR-221, part 2): the browse contract's THREE presentation fields, which this
  /// client has been able to send since v0.10 and never did. Raw wire strings, deliberately: the
  /// only writers are `GridStore`'s typed entry points (`setSortKey`, `setSortDirection`,
  /// `selectGrouping`) over `SortKey`/`SortDirection`/`GroupByKey`, and the mappings below round
  /// each value through the GENERATED payload enum — so a value the server does not know cannot
  /// reach the wire, and `SortGroupOptionsTests` proves every offered value survives that trip.
  ///
  /// They live in `GridImagesQuery` (not beside it) because every one of them is inside the
  /// server's cursor fingerprint: live-probed 2026-08-30 against the deployed v0.12.1, replaying
  /// a cursor under a different `sort`, a different `direction`, a different `group_by`, or with
  /// `group_by` dropped, is refused `400 cursor_scope_mismatch` every time. Being query fields is
  /// what routes every change through `applyFilterChange`, which restarts paging from page one —
  /// so the client never replays a cursor across a presentation change and never sees that 400.
  var sort: String?
  var direction: String?
  var groupBy: String?

  init(folderID: Int? = nil) {
    self.folderID = folderID
  }

  func asListImagesQuery(cursor: String? = nil, limit: Int? = nil)
    -> Operations
    .ListImagesApiImagesGet.Input.Query
  {
    .init(
      // IMGMGR-541: only an OFFERED key reaches the wire, so a stray retired `"day"` cannot.
      groupBy: groupBy.flatMap(GroupByKey.init(rawValue:))?.listImagesPayload,
      cursor: cursor, limit: limit, folderId: folderID, ratingMin: ratingMin, good: good,
      label: label, keyword: keyword, q: q, tag: tag, sourceTier: sourceTier?.listImagesPayload,
      tree: tree, ext: ext, camera: camera, hasMaster: hasMaster, hasLook: hasLook,
      mark: mark, dateFrom: dateFrom, dateTo: dateTo, cameraPreviewOnly: cameraPreviewOnly,
      missing: missing,
      sort: sort.flatMap(Operations.ListImagesApiImagesGet.Input.Query.SortPayload.init),
      direction: direction.flatMap(
        Operations.ListImagesApiImagesGet.Input.Query.DirectionPayload.init))
  }

  func asFacetsQuery() -> Operations.ImageFacetsApiFacetsGet.Input.Query {
    .init(
      folderId: folderID, ratingMin: ratingMin, good: good, label: label, keyword: keyword, q: q,
      tag: tag, sourceTier: sourceTier?.facetsPayload, tree: tree, ext: ext, camera: camera,
      hasMaster: hasMaster, hasLook: hasLook, mark: mark, dateFrom: dateFrom, dateTo: dateTo,
      cameraPreviewOnly: cameraPreviewOnly, missing: missing)
  }

  /// WP12: the SAME filter surface `asListImagesQuery` sends, plus the two things Scene browse
  /// has of its own (`direction`, `seekDate`) and WITHOUT the two it does not accept — there is
  /// no sort key and no `group_by` on this endpoint at all (chronological only). The generator
  /// gives every operation its own `Input.Query` type even when the shapes match, which is why
  /// this is a fourth mapping rather than a shared one.
  func asBrowseStacksQuery(
    direction: SceneBrowseDirection, cursor: String?, seekDate: String?, limit: Int
  ) -> Operations.BrowseStacksApiBrowseStacksGet.Input.Query {
    .init(
      direction: direction.payload, cursor: cursor, seekDate: seekDate, limit: limit,
      folderId: folderID, ratingMin: ratingMin, good: good, label: label, keyword: keyword, q: q,
      tag: tag, sourceTier: sourceTier?.browseStacksPayload, tree: tree, ext: ext,
      camera: camera, hasMaster: hasMaster, hasLook: hasLook, mark: mark, dateFrom: dateFrom,
      dateTo: dateTo, cameraPreviewOnly: cameraPreviewOnly, missing: missing)
  }

  /// The filter context ONE card is re-read in (`GET /api/stacks/{id}`) so its `matched_count`
  /// answers the question the reader's current filters are asking. No paging and no direction: a
  /// single row has neither.
  func asStackRowQuery() -> Operations.GetStackApiStacksStackIdGet.Input.Query {
    .init(
      folderId: folderID, ratingMin: ratingMin, good: good, label: label, keyword: keyword, q: q,
      tag: tag, sourceTier: sourceTier?.stackRowPayload, tree: tree, ext: ext,
      camera: camera, hasMaster: hasMaster, hasLook: hasLook, mark: mark, dateFrom: dateFrom,
      dateTo: dateTo, cameraPreviewOnly: cameraPreviewOnly, missing: missing)
  }

  /// P5's own forward-neighbour call shape — the same filter surface as `asListImagesQuery`,
  /// minus `cursor` (the endpoint has none) and with its own `limit` (the loupe's small
  /// prefetch window, never the grid's page size).
  func asNeighboursQuery(limit: Int)
    -> Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query
  {
    .init(
      groupBy: groupBy.flatMap(GroupByKey.init(rawValue:))?.neighboursPayload,
      limit: limit, folderId: folderID, ratingMin: ratingMin, good: good, label: label,
      keyword: keyword, q: q, tag: tag, sourceTier: sourceTier?.neighboursPayload, tree: tree,
      ext: ext, camera: camera, hasMaster: hasMaster, hasLook: hasLook, mark: mark,
      dateFrom: dateFrom, dateTo: dateTo, cameraPreviewOnly: cameraPreviewOnly, missing: missing,
      sort: sort.flatMap(
        Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.SortPayload.init),
      direction: direction.flatMap(
        Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.DirectionPayload.init))
  }

  /// WP13 P5b: the header source, under the SAME filters the page is asking for.
  ///
  /// `sort` and `direction` are absent because the endpoint does not take them — a bucket's
  /// membership and count do not depend on the order rows come back in — and `group_by` is
  /// REQUIRED here rather than optional, which is why it is a parameter of this method instead
  /// of read off `self`: there is no such thing as an ungrouped header fetch.
  func asImageGroupsQuery(groupBy key: GroupByKey)
    -> Operations.ImageGroupsApiImageGroupsGet.Input.Query
  {
    .init(
      groupBy: key.imageGroupsPayload,
      folderId: folderID, ratingMin: ratingMin, good: good, label: label, keyword: keyword, q: q,
      tag: tag, sourceTier: sourceTier?.imageGroupsPayload, tree: tree, ext: ext,
      camera: camera, hasMaster: hasMaster, hasLook: hasLook, mark: mark, dateFrom: dateFrom,
      dateTo: dateTo, cameraPreviewOnly: cameraPreviewOnly, missing: missing)
  }
}
