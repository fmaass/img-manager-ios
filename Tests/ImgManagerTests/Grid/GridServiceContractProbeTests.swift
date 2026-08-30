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
}
