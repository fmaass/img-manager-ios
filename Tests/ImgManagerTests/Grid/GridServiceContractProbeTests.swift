import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// P4's mandated FIRST ACTION (plan §Phase 4 fold item 1 / Amendment): the generated-contract
/// probe against the vendored v0.9.2 schema — folders, images+paging, facets, detail,
/// proxy-success, mark-state WITH preconditions (including the 409 refusal), and tags, each
/// through the REAL generated client (`GridService` → `Client` → `Types`/`Operations`) over a
/// low-level stub transport (`GridStubTransport`). Every assertion here is decoding/encoding
/// through the actual generated types — a renamed operation, a changed path, or a schema
/// regression breaks these tests at the call site, not a parallel hand-written model.
///
/// This is also where the cursor-fingerprint 400 disposition (the P2-checkpoint residual the
/// plan gate named) is recorded as a passing, evidenced test rather than only a comment.
@Suite("P4 generated-contract probe (FIRST ACTION)")
struct GridServiceContractProbeTests {

  private func makeService(_ transport: GridStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  @Test("Folders: GET /api/folders decodes through the real generated FolderTree")
  func foldersProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    let tree = try await service.folders()
    #expect(tree.items.isEmpty)  // stub default; presence alone proves the real type decoded
  }

  @Test("Images + paging: two pages via a real opaque next_cursor round trip")
  func imagesPagingProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    let image = Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "jpg", filename: "a.jpg", folderId: 1, id: 1,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
    await transport.setListImagesPage(
      Components.Schemas.ImagePage(items: [image], limit: 1, nextCursor: "opaque-token"))

    let page1 = try await service.images(GridImagesQuery(folderID: 1), cursor: nil, limit: 1)
    #expect(page1.items.map(\.id) == [1])
    #expect(page1.nextCursor == "opaque-token")

    let page2Image = Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "jpg", filename: "b.jpg", folderId: 1, id: 2,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
    await transport.setListImagesPage(
      Components.Schemas.ImagePage(items: [page2Image], limit: 1, nextCursor: nil))
    let page2 = try await service.images(
      GridImagesQuery(folderID: 1), cursor: page1.nextCursor, limit: 1)
    #expect(page2.items.map(\.id) == [2])
    #expect(page2.nextCursor == nil)
  }

  @Test(
    "Cursor-fingerprint 400: undeclared in the vendored schema, but the STATUS CODE is a distinguishable refusal"
  )
  func cursorFingerprint400Probe() async {
    let transport = GridStubTransport()
    let service = makeService(transport)
    await transport.setListImagesRejectNonNilCursor(true)
    do {
      _ = try await service.images(GridImagesQuery(), cursor: "stale", limit: 100)
      Issue.record("expected GridServiceError.cursorInvalid")
    } catch GridServiceError.cursorInvalid {
      // Disposition recorded: GET /api/images declares only 200+422 for this vendored schema
      // (no 400 response object at all — verified directly against openapi.json), so the
      // generated `Output` carries a real backend 400 as `.undocumented(statusCode: 400, _)`
      // rather than a named case. The backend's OWN test suite
      // (tests/test_api_images_cursor_fingerprint.py, app/api/cursor.py) confirms it returns
      // 400 UNIFORMLY for every invalid/stale/mismatched cursor on this endpoint — so the
      // status code alone, with no typed body needed, is a clean, always-distinguishable
      // signal. Pinned: "discard the old cursor and restart the same scope from page one."
    } catch {
      Issue.record("expected GridServiceError.cursorInvalid, got \(error)")
    }
  }

  @Test("A cursor==nil first-page request is NEVER refused, even with the reject-flag armed")
  func nilCursorAlwaysSucceeds() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    await transport.setListImagesRejectNonNilCursor(true)
    let page = try await service.images(GridImagesQuery(), cursor: nil, limit: 100)
    #expect(page.items.isEmpty)  // stub default page — reaching here at all is the proof
  }

  @Test(
    "P5 FIRST ACTION: Neighbours — GET /api/images/{id}/neighbours decodes through the real generated ImagePage, merges into the same shape `images()` returns"
  )
  func neighboursProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    let image = Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "jpg", filename: "b.jpg", folderId: 1, id: 2,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceKind: "web_preview", sourceTier: "local")
    await transport.setNeighboursPage(
      Components.Schemas.ImagePage(items: [image], limit: 5, nextCursor: nil))

    let page = try await service.neighbours(after: 1, query: GridImagesQuery(folderID: 1), limit: 5)

    #expect(page.items.map(\.id) == [2])
    #expect(page.items.first?.sourceKind == "web_preview")
  }

  @Test("Facets: GET /api/facets decodes the real ImageFacets shape")
  func facetsProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    await transport.setFacetsResult(
      Components.Schemas.ImageFacets(
        mark: [.init(count: 3, value: "pick")], total: 10))
    let facets = try await service.facets(GridImagesQuery())
    #expect(facets.total == 10)
    #expect(facets.mark?.first?.value == "pick")
    #expect(facets.mark?.first?.count == 3)
  }

  @Test("Detail: GET /api/images/{id} decodes ImageDetail including the generic EXIF dictionary")
  func detailProbe() async throws {
    let transport = GridStubTransport()
    let exif = Components.Schemas.ImageDetail.ExifPayload(additionalProperties: [
      "Make": .init(value1: "Fujifilm", value2: nil, value3: nil)
    ])
    await transport.setDetailResult(
      Components.Schemas.ImageDetail(
        exif: exif, ext: "jpg", fileSize: 4_096, filename: "a.jpg", folderId: 1, id: 1,
        lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
        proxies: .init(additionalProperties: [:]), sourceTier: "local"))
    let service = makeService(transport)
    let detail = try await service.detail(imageID: 1)
    #expect(detail.filename == "a.jpg")
    #expect(detail.exif?.additionalProperties["Make"]?.value1 == "Fujifilm")
  }

  @Test(
    "Proxy bytes: the 200 declares image/jpeg binary (fold item 2, closed 770786a) and is consumable as Data"
  )
  func proxyBytesProbe() async throws {
    let transport = GridStubTransport()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    await transport.setProxyOutcome(.ok(bytes))
    let service = makeService(transport)
    let result = try await service.proxy(imageID: 1, tier: .grid, v: "abc123")
    guard case .ok(let data) = result else {
      Issue.record("expected .ok, got \(result)")
      return
    }
    #expect(data == bytes)
  }

  @Test("Proxy 404/304 decode to their own distinguishable outcomes, never mistaken for bytes")
  func proxyNotFoundAndNotModifiedProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)

    await transport.setProxyOutcome(.notFound)
    #expect(try await service.proxy(imageID: 1, tier: .grid, v: nil) == .notFound)

    await transport.setProxyOutcome(.notModified)
    #expect(try await service.proxy(imageID: 1, tier: .preview, v: "x") == .notModified)
  }

  @Test(
    "Mark state WITH preconditions: the request round-trips through the real MarkStateRequest/MarkPrecondition types"
  )
  func markStateWithPreconditionsProbe() async throws {
    let transport = GridStubTransport()
    await transport.setMarkStateOutcome(
      .success(
        Components.Schemas.MarksApplied(
          applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    let service = makeService(transport)
    let applied = try await service.setMarkState(
      imageIDs: [1], state: .pick,
      preconditions: [Components.Schemas.MarkPrecondition(imageId: 1, revision: "r0")])
    #expect(applied.applied == 1)
    #expect(applied.revisions?.first?.revision == "r1")

    let sentRequest = await transport.lastMarkStateRequest
    #expect(sentRequest?.imageIds == [1])
    #expect(sentRequest?.state == .pick)
    #expect(sentRequest?.preconditions?.first?.revision == "r0")
  }

  @Test("Mark state 409: nothing applied, refused as a clean distinguishable conflict")
  func markState409Probe() async {
    let transport = GridStubTransport()
    await transport.setMarkStateOutcome(.conflict)
    let service = makeService(transport)
    do {
      _ = try await service.setMarkState(
        imageIDs: [1], state: .pick,
        preconditions: [Components.Schemas.MarkPrecondition(imageId: 1, revision: "stale")])
      Issue.record("expected GridServiceError.conflict")
    } catch GridServiceError.conflict {
      // expected
    } catch {
      Issue.record("expected .conflict, got \(error)")
    }
  }

  @Test("Tags: the real MarkTagsRequest/operation payload round-trips, including its own 409")
  func tagsProbe() async throws {
    let transport = GridStubTransport()
    await transport.setTagsOutcome(
      .success(Components.Schemas.MarksApplied(applied: 1, requested: 1, revisions: [])))
    let service = makeService(transport)
    _ = try await service.editMarkTags(
      imageIDs: [1], operation: .add, tag: "favorite",
      preconditions: [Components.Schemas.MarkPrecondition(imageId: 1, revision: "r0")])
    let sent = await transport.lastTagsRequest
    #expect(sent?.tag == "favorite")
    #expect(sent?.operation == .add)

    await transport.setTagsOutcome(.conflict)
    do {
      _ = try await service.editMarkTags(
        imageIDs: [1], operation: .remove, tag: "favorite",
        preconditions: [Components.Schemas.MarkPrecondition(imageId: 1, revision: "stale")])
      Issue.record("expected GridServiceError.conflict")
    } catch GridServiceError.conflict {
      // expected
    } catch {
      Issue.record("expected .conflict, got \(error)")
    }
  }

  // MARK: - WP13 P5b (IMGMGR-221 part 2): sort / direction / group_by on the wire

  /// The presentation this phase adds, as the wire sees it.
  private func presentationQuery() -> GridImagesQuery {
    var query = GridImagesQuery(folderID: 1)
    query.sort = SortKey.rating.rawValue
    query.direction = SortDirection.desc.rawValue
    query.groupBy = GroupByKey.camera.rawValue
    return query
  }

  @Test("GET /api/images carries sort, direction and group_by")
  func listImagesCarriesSortDirectionAndGroupBy() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    _ = try await service.images(presentationQuery(), cursor: nil, limit: 10)

    let sent = await transport.lastListImagesQuery
    // The WIRE's own names, read off the URL the REAL generated client built — never the Swift
    // property names, which is what makes this a contract check.
    #expect(sent?["sort"] == "rating")
    #expect(sent?["direction"] == "desc")
    #expect(sent?["group_by"] == "camera")
    // POSITIVE CONTROL, same recording: a parameter that has always been sent is still there,
    // so three hits above prove the fields were added rather than that the URL was rebuilt.
    #expect(sent?["folder_id"] == "1")
  }

  @Test("Neighbours carries the SAME sort, direction and group_by as the grid")
  func neighboursCarriesTheSameSortDirectionAndGroupByAsTheGrid() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    let query = presentationQuery()

    _ = try await service.images(query, cursor: nil, limit: 10)
    _ = try await service.neighbours(after: 7, query: query, limit: 5)

    let grid = await transport.lastListImagesQuery
    let loupe = await transport.lastNeighboursQuery
    // The loupe-divergence guard: if the loupe omitted these, "next" would advance in capture
    // order while the grid showed rating order — the same photographs in two different orders,
    // which is exactly the bug this asserts against.
    for field in ["sort", "direction", "group_by"] {
      let gridValue = String(describing: grid?[field])
      let loupeValue = String(describing: loupe?[field])
      #expect(
        grid?[field] == loupe?[field],
        "grid and loupe disagree on \(field): \(gridValue) vs \(loupeValue)")
      #expect(loupe?[field] != nil, "the loupe sent no \(field) at all")
    }
    #expect(loupe?["sort"] == "rating")
    #expect(loupe?["group_by"] == "camera")
  }

  @Test("Browse stacks carries NEITHER sort NOR group_by — stack mode is chronological only")
  func browseStacksCarriesNeitherSortNorGroupBy() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    // The query DOES carry all three; the mapping must drop them for this endpoint (ADR-0005
    // decision 1: "a stack carries ONE stored capture-order anchor").
    _ = try? await service.browseStacks(
      presentationQuery(), direction: .asc, cursor: nil, limit: 10)

    let sent = await transport.lastBrowseStacksQuery
    #expect(sent?["sort"] == nil)
    #expect(sent?["group_by"] == nil)
    // Its OWN direction, from the scene-browse enum — not the flat query's `desc`, which would
    // be the same leak wearing a name this endpoint happens to accept.
    #expect(sent?["direction"] == "asc")
    // POSITIVE CONTROL: the filters DID reach it, so the two nils are dropped parameters rather
    // than an unrecorded request.
    #expect(sent?["folder_id"] == "1")
  }

  @Test("GET /api/image-groups decodes headers, timezone and total through the generated type")
  func imageGroupsDecodesThroughTheGeneratedType() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [
          .init(count: 36568, key: "SONY ILCE-7RM5", label: "SONY ILCE-7RM5"),
          .init(count: 213, key: nil, label: "Unknown"),
        ], timezone: nil, total: 36781))

    let groups = try await service.imageGroups(GridImagesQuery(folderID: 1), groupBy: .camera)
    #expect(groups.total == 36781)
    #expect(groups.headers?.count == 2)
    // The Unknown bucket is `key: null` with the SERVER's own label — the shape the live probe
    // returned for `group_by=location` on 2026-08-30.
    #expect(groups.headers?.last?.key == nil)
    #expect(groups.headers?.last?.label == "Unknown")
    #expect(groups.headers?.map(\.count).reduce(0, +) == groups.total)

    let sent = await transport.lastImageGroupsQuery
    #expect(sent?["group_by"] == "camera")
    // The endpoint takes no order at all — a header list is neither paged nor sorted.
    #expect(sent?["sort"] == nil)
    #expect(sent?["cursor"] == nil)
  }

  // MARK: - WP21 P2: the `camera` filter reaches EVERY projection (plan AC 12)

  /// The filter set travels on six different query shapes, and the generator gives each operation
  /// its OWN `Input.Query` type even where the shapes match — so "the client can send `camera`"
  /// has to be asked six times, once per mapping. A dimension threaded into `asListImagesQuery`
  /// alone would look correct in the grid and silently no-op the moment the reader opened a
  /// scene, refreshed a card, stepped through the loupe, or read a group header count.
  ///
  /// Read off the WIRE the real generated `Client` built, not off a Swift property: the names
  /// asserted are the contract's own (`camera`, as `/api/images`, `/api/facets`,
  /// `/api/browse/stacks`, `/api/images/{id}/neighbours` and `/api/image-groups` all declare it,
  /// between `ext` and `has_master`).
  @Test(
    "`camera` is emitted by every recorded projection: images, facets, scenes, neighbours, groups"
  )
  func cameraReachesEveryRecordedProjection() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    var query = GridImagesQuery(folderID: 1)
    query.camera = "SONY ILCE-7RM5"

    _ = try await service.images(query, cursor: nil, limit: 10)
    _ = try await service.facets(query)
    _ = try await service.browseStacks(query, direction: .asc, cursor: nil, limit: 10)
    _ = try await service.neighbours(after: 7, query: query, limit: 5)
    _ = try await service.imageGroups(query, groupBy: .camera)

    let listImages = await transport.lastListImagesQuery
    let facets = await transport.lastFacetsQuery
    let browseStacks = await transport.lastBrowseStacksQuery
    let neighbours = await transport.lastNeighboursQuery
    let imageGroups = await transport.lastImageGroupsQuery
    let recorded: [(String, [String: String]?)] = [
      ("list-images", listImages), ("facets", facets), ("scene browse", browseStacks),
      ("neighbours", neighbours), ("group headers", imageGroups),
    ]
    for (surface, sent) in recorded {
      #expect(
        sent?["camera"] == "SONY ILCE-7RM5",
        "\(surface) dropped the camera filter: \(String(describing: sent?["camera"]))")
      // POSITIVE CONTROL per surface: a parameter that has always been sent is on the SAME
      // recording, so a hit above is the field being added rather than the request being
      // recorded at all.
      #expect(sent?["folder_id"] == "1", "\(surface) recorded no request, so its check is vacuous")
    }
  }

  /// The SIXTH projection, asserted on the generated `Input.Query` rather than on the wire: the
  /// shared `GridStubTransport` records no query for `GET /api/stacks/{id}` (it reads only the id
  /// out of the path), and that file is outside this phase's scope fence. The value still passes
  /// through the real generated type, so a mapping that forgot `camera` fails here — and the five
  /// wire assertions above are what prove that type serialises it.
  @Test("The stack-row refresh projection carries `camera` — the sixth filter surface")
  func theStackRowProjectionCarriesCamera() {
    var query = GridImagesQuery(folderID: 1)
    query.camera = "FUJIFILM X-T2"

    let stackRow = query.asStackRowQuery()
    #expect(stackRow.camera == "FUJIFILM X-T2")
    #expect(stackRow.folderId == 1)  // positive control: the projection was built at all

    // The other five at the same level, so all six mappings are named in one place and a new
    // projection added without `camera` has an obvious gap to fall into.
    #expect(query.asListImagesQuery().camera == "FUJIFILM X-T2")
    #expect(query.asFacetsQuery().camera == "FUJIFILM X-T2")
    #expect(
      query.asBrowseStacksQuery(direction: .asc, cursor: nil, seekDate: nil, limit: 10).camera
        == "FUJIFILM X-T2")
    #expect(query.asNeighboursQuery(limit: 5).camera == "FUJIFILM X-T2")
    #expect(query.asImageGroupsQuery(groupBy: .camera).camera == "FUJIFILM X-T2")

    // ...and nil stays nil: an unset dimension must not become an empty-string filter.
    let unfiltered = GridImagesQuery(folderID: 1)
    #expect(unfiltered.asStackRowQuery().camera == nil)
    #expect(unfiltered.asListImagesQuery().camera == nil)
  }

  // MARK: - IMGMGR-544: the Has-look filter on every projection

  @Test("`has_look=true` reaches the wire on every recorded projection; unset sends none")
  func hasLookReachesEverySurface() async throws {
    for value: Bool? in [true, nil] {
      let transport = GridStubTransport()
      let service = makeService(transport)
      var query = GridImagesQuery(folderID: 1)
      query.hasLook = value

      _ = try await service.images(query, cursor: nil, limit: 10)
      _ = try await service.facets(query)
      _ = try await service.browseStacks(query, direction: .asc, cursor: nil, limit: 10)
      _ = try await service.neighbours(after: 7, query: query, limit: 5)
      _ = try await service.imageGroups(query, groupBy: .camera)

      let recorded: [(String, [String: String]?)] = [
        ("list-images", await transport.lastListImagesQuery),
        ("facets", await transport.lastFacetsQuery),
        ("scene browse", await transport.lastBrowseStacksQuery),
        ("neighbours", await transport.lastNeighboursQuery),
        ("group headers", await transport.lastImageGroupsQuery),
      ]
      for (surface, sent) in recorded {
        #expect(sent?["has_look"] == value.map { String($0) }, "\(surface): has_look")
        #expect(sent?["folder_id"] == "1", "\(surface) recorded no request")
      }
      // The sixth, on the generated type (the stub records no stack-row query).
      #expect(query.asStackRowQuery().hasLook == value)
      #expect(query.asStackRowQuery().folderId == 1)
      // No path at all carries the name when the filter is unset (literal-in-string guard).
      if value == nil {
        #expect(await transport.recordedWire.allSatisfy { !$0.path.contains("has_look") })
      }
    }
  }

  // MARK: - IMGMGR-382: the v0.21.0 look operations

  static func look(_ id: String, name: String, category: String = "Film")
    -> Components.Schemas.LookSummary
  {
    Components.Schemas.LookSummary(
      category: category, id: id, licence: "test licence", name: name, source: "test",
      sourceUrl: "https://example.invalid/\(id)")
  }

  @Test("Looks: GET /api/looks decodes the real LookList, in the server's own order")
  func looksProbe() async throws {
    let transport = GridStubTransport()
    let catalogue = [
      Self.look("b-look", name: "B"), Self.look("a-look", name: "A", category: "Creative"),
    ]
    await transport.setLooksCatalogue(catalogue)
    let looks = try await makeService(transport).looks()
    #expect(looks.map(\.id) == ["b-look", "a-look"])  // manifest order, never re-sorted
    #expect(looks[1].category == "Creative")
    #expect(looks[0].sourceUrl == "https://example.invalid/b-look")
  }

  @Test("Looks: a transport failure is .unreachable, never an empty catalogue")
  func looksUnreachableProbe() async {
    let transport = GridStubTransport()
    await transport.setLooksShouldFail(true)
    await #expect(throws: GridServiceError.unreachable) {
      _ = try await makeService(transport).looks()
    }
  }

  @Test("Looked proxy: the 200 is image/jpeg bytes, on the tier and look the caller named")
  func lookedProxyBytesProbe() async throws {
    let transport = GridStubTransport()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x20])
    await transport.setLookedProxyOutcome(.ok(bytes))
    let result = try await makeService(transport).lookedProxy(
      imageID: 7, tier: .preview, lookID: "warm-film", strength: 100)
    #expect(result == .ok(bytes))
    let paths = await transport.recordedLookedProxyRequests
    #expect(paths.count == 1)
    let route = paths.first.flatMap { URLComponents(string: $0)?.path } ?? ""
    #expect(route.hasSuffix("/api/images/7/proxy/preview/look/warm-film"))
    // IMGMGR-543 (v0.24.0): the strength travels, 100 included; no `v` is sent (P16b's).
    #expect(
      paths.first.flatMap { URLComponents(string: $0)?.queryItems }
        == [URLQueryItem(name: "strength", value: "100")])
    // It is not the unlooked operation.
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 0)
  }

  @Test("Looked proxy: 404 and each coded 422 decode to their own typed outcomes")
  func lookedProxyRefusalsProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)

    await transport.setLookedProxyOutcome(.notFound)
    #expect(
      try await service.lookedProxy(imageID: 1, tier: .preview, lookID: "x", strength: 100)
        == .notFound)

    await transport.setLookedProxyOutcome(.refused(code: "unknown_look"))
    #expect(
      try await service.lookedProxy(imageID: 1, tier: .preview, lookID: "x", strength: 100)
        == .refused(.unknownLook))

    await transport.setLookedProxyOutcome(.refused(code: "invalid_request"))
    #expect(
      try await service.lookedProxy(imageID: 1, tier: .grid, lookID: "x", strength: 100)
        == .refused(.invalidRequest))
  }

  @Test("Looked proxy: the 200's X-Look-Version comes back as the version; absent is nil")
  func lookedProxyVersionProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE1])
    await transport.setLookedProxyOutcome(.ok(bytes))
    await transport.setLookedProxyVersion("0123456789abcdef0123456789abcdef")
    #expect(
      try await service.lookedProxy(imageID: 7, tier: .grid, lookID: "warm-film", strength: 120)
        == .ok(bytes, version: "0123456789abcdef0123456789abcdef"))
    await transport.setLookedProxyVersion(nil)
    #expect(
      try await service.lookedProxy(imageID: 7, tier: .grid, lookID: "warm-film", strength: 120)
        == .ok(bytes, version: nil))
    // `v` is never sent: the strength is the one query item, every time.
    for path in await transport.recordedLookedProxyRequests {
      #expect(
        URLComponents(string: path)?.queryItems == [URLQueryItem(name: "strength", value: "120")])
    }
  }

  @Test("Saved look: PUT carries exactly look_id and strength and decodes the ImageLookView")
  func putLookProbe() async throws {
    let transport = GridStubTransport()
    let view = try await makeService(transport).putLook(
      imageID: 1, lookID: "warm-film", strength: 120)
    #expect(view.lookId == "warm-film")
    #expect(view.strength == 120)
    let writes = await transport.recordedLookWrites
    #expect(writes.count == 1)
    #expect(writes.first?.method == "PUT")
    #expect(writes.first.flatMap { URLComponents(string: $0.path)?.path } == "/api/images/1/look")
    let body = try #require(writes.first?.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == ["look_id", "strength"])
    #expect(json["look_id"] as? String == "warm-film")
    #expect(json["strength"] as? Int == 120)
  }

  @Test("Saved look: DELETE is a 204; 404 is .gone, 422 .refused, transport .uncertain")
  func deleteLookProbe() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    try await service.deleteLook(imageID: 3)
    let writes = await transport.recordedLookWrites
    #expect(writes.map(\.method) == ["DELETE"])
    #expect(writes.first.flatMap { URLComponents(string: $0.path)?.path } == "/api/images/3/look")
    #expect(writes.first?.body.isEmpty == true)

    await transport.enqueueLookWriteOutcomes([
      .notFound, .refused(code: "unknown_look"), .transportFailure, .notFound,
      .refused(code: "invalid_request"), .undecodable, .transportFailure,
    ])
    await #expect(throws: LookWriteError.gone) { try await service.deleteLook(imageID: 3) }
    await #expect(throws: LookWriteError.refused(.unknownLook)) {
      try await service.deleteLook(imageID: 3)
    }
    await #expect(throws: LookWriteError.uncertain) { try await service.deleteLook(imageID: 3) }
    await #expect(throws: LookWriteError.gone) {
      _ = try await service.putLook(imageID: 3, lookID: "x", strength: 100)
    }
    await #expect(throws: LookWriteError.refused(.invalidRequest)) {
      _ = try await service.putLook(imageID: 3, lookID: "x", strength: 100)
    }
    await #expect(throws: LookWriteError.uncertain) {
      _ = try await service.putLook(imageID: 3, lookID: "x", strength: 100)
    }
    await #expect(throws: LookWriteError.uncertain) {
      _ = try await service.putLook(imageID: 3, lookID: "x", strength: 100)
    }
  }

  @Test("Looked proxy: a transport failure is .unreachable")
  func lookedProxyUnreachableProbe() async {
    let transport = GridStubTransport()
    await transport.setLookedProxyShouldFail(true)
    await #expect(throws: GridServiceError.unreachable) {
      _ = try await makeService(transport).lookedProxy(
        imageID: 1, tier: .preview, lookID: "x", strength: 100)
    }
  }
}
