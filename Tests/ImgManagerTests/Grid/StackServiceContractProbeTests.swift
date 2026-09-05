import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP12's mandated FIRST ACTION, in the shape `GridServiceContractProbeTests` established: the
/// three stack endpoints exercised through the REAL generated client (`GridService` → `Client` →
/// `Types`/`Operations`) over `GridStubTransport`, so a renamed operation, a moved path or a
/// schema regression breaks these tests at the call site rather than in a parallel hand-written
/// model.
///
/// The load-bearing question this suite answers is the union: `StackBrowsePage.items` is a plain
/// `anyOf` of an image row and a stack row, discriminated by `kind`. What the probe proves is
/// that the discriminator is real in the GENERATED code and not merely in the document — see
/// `unionNarrowsOnKind`.
@Suite("WP12 generated-contract probe — stacks (FIRST ACTION)")
struct StackServiceContractProbeTests {

  private func makeService(_ transport: GridStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  private func makeImage(id: Int, missing: Bool = false, captured: Date? = nil)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, capturedAt: captured, ext: "raf", filename: "DSCF\(id).raf", folderId: 1,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0"), missing: missing,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStackRow(
    id: Int, memberCount: Int = 3, hasPick: Bool = false, matchedCount: Int = 3,
    anchor: Date? = nil, representative: Components.Schemas.ImageSummary
  ) -> Components.Schemas.StackBrowseStackRow {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: anchor, editedCount: 0, hasPick: hasPick, kind: .stack,
      matchedCount: matchedCount,
      memberCount: memberCount, pickedCount: hasPick ? 1 : 0, representative: representative,
      stackId: id)
  }

  @Test(
    "GET /api/browse/stacks: a page of one image row and one stack row decodes and NARROWS on kind"
  )
  func browseStacksNarrowsBothKinds() async throws {
    let transport = GridStubTransport()
    let loose = makeImage(id: 11)
    let cover = makeImage(id: 22)
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let stack = makeStackRow(
      id: 5, memberCount: 4, hasPick: true, matchedCount: 2, anchor: anchor,
      representative: cover)
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: [
          .init(value1: .init(image: loose, kind: .image), value2: nil),
          .init(value1: nil, value2: stack),
        ],
        limit: 100, nextCursor: "opaque-stack-token"))

    let service = makeService(transport)
    let page = try await service.browseStacks(GridImagesQuery(folderID: 1), cursor: nil, limit: 100)

    #expect(page.nextCursor == "opaque-stack-token")
    #expect(page.rows.count == 2)
    guard case .image(let decodedImage) = page.rows[0] else {
      Issue.record("row 0 did not narrow to .image, got \(page.rows[0])")
      return
    }
    #expect(decodedImage.id == 11)
    guard case .stack(let decodedStack) = page.rows[1] else {
      Issue.record("row 1 did not narrow to .stack, got \(page.rows[1])")
      return
    }
    #expect(decodedStack.stackId == 5)
    #expect(decodedStack.memberCount == 4)
    #expect(decodedStack.hasPick)
    #expect(decodedStack.matchedCount == 2)
    #expect(decodedStack.representative.id == 22)
    // The anchor is the scene's stored place in capture order and is the ONLY correct key for
    // date sectioning — `representative.captured_at` cannot answer the same question, because the
    // cover is derived at read time and moves the moment a member is picked.
    #expect(decodedStack.anchorTakenAt == anchor)
    #expect(decodedStack.representative.capturedAt == nil)
  }

  @Test(
    "The generated union's discriminator is enforced by the DECODER: each branch's kind is a one-case enum"
  )
  func unionNarrowsOnKind() {
    // `kind` is `const` in the document, which OpenAPIKit reads as a one-value `enum` and the
    // generator emits as a one-CASE Swift enum. These two assignments therefore type-check ONLY
    // if that is still true — if `kind` ever degraded to a free `String`, or if the two branches
    // ever shared one payload type, this stops compiling, which is the strongest form the check
    // can take. It is also WHY `SceneBrowseRow.narrow` can trust branch identity: a row carrying
    // `"kind": "stack"` cannot decode into `StackBrowseImageRow` at all.
    let imageKind: Components.Schemas.StackBrowseImageRow.KindPayload = .image
    let stackKind: Components.Schemas.StackBrowseStackRow.KindPayload = .stack
    #expect(imageKind.rawValue == "image")
    #expect(stackKind.rawValue == "stack")
  }

  @Test("A row that decodes as NEITHER branch is refused as an unusable page, never dropped")
  func unnarrowableRowIsRefused() async {
    let transport = GridStubTransport()
    // An empty union member: no `image`, no `stack_id` — decodes to neither branch. A client that
    // quietly skipped it would leave a hole in capture order that no count or cursor accounts for.
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: [.init(value1: nil, value2: nil)], limit: 100))
    let service = makeService(transport)
    do {
      _ = try await service.browseStacks(GridImagesQuery(), cursor: nil, limit: 100)
      Issue.record("expected GridServiceError.unreachable for an unnarrowable row")
    } catch GridServiceError.unreachable {
      // expected
    } catch {
      Issue.record("expected .unreachable, got \(error)")
    }
  }

  @Test(
    "Stack cursor mismatch: an undocumented 400 maps to the same .cursorInvalid the flat lane uses")
  func stackCursorMismatchProbe() async {
    let transport = GridStubTransport()
    await transport.setBrowseStacksRejectNonNilCursor(true)
    let service = makeService(transport)
    do {
      _ = try await service.browseStacks(GridImagesQuery(), cursor: "a-flat-cursor", limit: 100)
      Issue.record("expected GridServiceError.cursorInvalid")
    } catch GridServiceError.cursorInvalid {
      // Disposition recorded: `browse_stacks_api_browse_stacks_get` declares 200 and 422 only in
      // the vendored document (verified directly against openapi.json at 5615fd9), so the
      // server's real 400 — `cursor_scope_mismatch`, which is what a cursor minted by
      // `/api/images` gets here — arrives as `.undocumented(statusCode: 400, _)`. Same pinned
      // response as the flat lane: discard the cursor, restart this scope from page one.
    } catch {
      Issue.record("expected .cursorInvalid, got \(error)")
    }
  }

  @Test("A cursor==nil first page is never refused, even with the reject flag armed")
  func stackNilCursorAlwaysSucceeds() async throws {
    let transport = GridStubTransport()
    await transport.setBrowseStacksRejectNonNilCursor(true)
    let service = makeService(transport)
    let page = try await service.browseStacks(GridImagesQuery(), cursor: nil, limit: 100)
    #expect(page.rows.isEmpty)  // stub default page — reaching here at all is the proof
  }

  @Test(
    "GET /api/stacks/{id}/members: one page decodes with its own next_cursor and its tombstones")
  func stackMembersProbe() async throws {
    let transport = GridStubTransport()
    await transport.setStackMemberPage(
      Components.Schemas.StackMemberPage(
        items: [makeImage(id: 1), makeImage(id: 2, missing: true)],
        limit: 100, nextCursor: "members-page-2", stackId: 5),
      forStack: 5)
    let service = makeService(transport)
    let page = try await service.stackMembers(stackID: 5, cursor: nil, limit: 100)

    #expect(page.stackID == 5)
    #expect(page.items.map(\.id) == [1, 2])
    #expect(page.nextCursor == "members-page-2")
    // Tombstones are part of the authoritative membership ("every member of the scene,
    // capture-ordered, tombstones included") and survive decoding as such.
    #expect(page.items[1].missing == true)
  }

  @Test("GET /api/stacks/{id}: the cover-refresh read decodes one whole stack row")
  func stackRowProbe() async throws {
    let transport = GridStubTransport()
    let cover = makeImage(id: 99)
    await transport.setStackRow(
      makeStackRow(id: 5, memberCount: 6, hasPick: true, matchedCount: 6, representative: cover),
      forStack: 5)
    let service = makeService(transport)
    let row = try await service.stackRow(stackID: 5, query: GridImagesQuery(folderID: 1))

    #expect(row.stackId == 5)
    #expect(row.memberCount == 6)
    #expect(row.hasPick)
    #expect(row.representative.id == 99)
  }
}
