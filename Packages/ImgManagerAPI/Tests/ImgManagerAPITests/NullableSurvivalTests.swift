import Foundation
import Testing

@testable import ImgManagerAPI

// The OpenAPI generation PROBE (WP8 P0a, plan §Phase 0a), now a permanent regression guard
// (WP8 P1-ios). img-manager's schema used to express nullability as
// `anyOf: [X, {"type": "null"}]`, which swift-openapi-generator silently DROPS instead of
// generating an Optional — confirmed 2026-08-27 against the raw v0.9.0 schema (SHA
// 4b952701ac79a6ec7ac245e8f1bf3b9657ca64c6): all 29 inline-type anyOf-nullable
// component-schema properties vanished from the generated Types.swift, ImagePage.next_cursor
// included. A temporary bridge (tools/normalize-openapi.py) canonicalised the schema into OAS
// 3.1 `type: [X, "null"]` arrays before the generator saw it until img-manager's P1-backend
// started emitting that idiom NATIVELY (v0.9.2, commit eff6a12ddf3c7e2a6f748625747345ca57c86349
// — re-vendoring measured bridge_nullable_rewritten=0, the condition the bridge itself named
// for its own retirement). The bridge and its vendored/bridged file split are deleted
// (docs/OPENAPI_NORMALIZATION_DEBT.md, closed; mirrors memos-ng-ios commit dfc2545): this test
// now runs directly against the single vendored `openapi.json`, unmodified.
//
// Each assertion is a compile-time existence-and-type check: a `WritableKeyPath` literal
// fails to type-check — failing the whole test target's build — if the named property does
// not exist on the generated type, or if its wrapped type is not the Optional shown. This
// is stronger than a runtime string search: it cannot pass by accident, and it is the
// generated INITIALIZER'S contract, not a comment, that is being checked.
@Suite("Nullable property survival (OpenAPI generation probe)")
struct NullableSurvivalTests {

  @Test("ImagePage.next_cursor — named explicitly by the plan gate's unasked finding")
  func imagePageNextCursor() {
    let _: WritableKeyPath<Components.Schemas.ImagePage, Swift.String?> = \.nextCursor
    #expect(Bool(true))  // reaching here means the keypath above type-checked
  }

  @Test("Every other inline-type anyOf-nullable component-schema property (28 remaining)")
  func remainingNullableProperties() {
    let _: WritableKeyPath<Components.Schemas.ApiHealthResponse, Swift.Bool?> = \.tierMounted
    let _: WritableKeyPath<Components.Schemas.FolderNode, Swift.Int?> = \.parentId

    let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.Double?> = \.aspectRatio
    let aspectSourceKP1:
      WritableKeyPath<
        Components.Schemas.ImageDetail, Components.Schemas.ImageDetail.AspectSourcePayload?
      > = \Components.Schemas.ImageDetail.aspectSource
    _ = aspectSourceKP1
    let _: WritableKeyPath<Components.Schemas.ImageDetail, Foundation.Date?> = \.capturedAt
    let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.String?> = \.sourceKind
    let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.String?> = \.sourceLabel
    let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.String?> =
      \.sourceUnavailableReason

    let _: WritableKeyPath<Components.Schemas.ImageSummary, Swift.Double?> = \.aspectRatio
    let aspectSourceKP2:
      WritableKeyPath<
        Components.Schemas.ImageSummary, Components.Schemas.ImageSummary.AspectSourcePayload?
      > = \Components.Schemas.ImageSummary.aspectSource
    _ = aspectSourceKP2
    let _: WritableKeyPath<Components.Schemas.ImageSummary, Foundation.Date?> = \.capturedAt
    let _: WritableKeyPath<Components.Schemas.ImageSummary, Swift.String?> = \.sourceKind
    let _: WritableKeyPath<Components.Schemas.ImageSummary, Swift.String?> = \.sourceLabel

    let _: WritableKeyPath<Components.Schemas.LightroomMeta, Swift.Bool?> = \.good
    let _: WritableKeyPath<Components.Schemas.LightroomMeta, Swift.String?> = \.label
    let _: WritableKeyPath<Components.Schemas.LightroomMeta, Swift.Int?> = \.rating

    let _: WritableKeyPath<Components.Schemas.MaintenanceRunView, Swift.String?> = \.error
    let _: WritableKeyPath<Components.Schemas.MaintenanceRunView, Foundation.Date?> = \.finishedAt

    let _: WritableKeyPath<Components.Schemas.MaintenanceStatus, Foundation.Date?> = \.nextRunAt
    let _: WritableKeyPath<Components.Schemas.MaintenanceStatus, Swift.String?> = \.note
    let _: WritableKeyPath<Components.Schemas.MaintenanceStatus, Swift.String?> = \.tierDetail
    let _: WritableKeyPath<Components.Schemas.MaintenanceStatus, Swift.Bool?> = \.tierMounted

    let _: WritableKeyPath<Components.Schemas.ProxyState, Swift.Int?> = \.height
    let _: WritableKeyPath<Components.Schemas.ProxyState, Swift.String?> = \.url
    let _: WritableKeyPath<Components.Schemas.ProxyState, Swift.Int?> = \.width

    let _: WritableKeyPath<Components.Schemas.StatusResponse, Foundation.Date?> = \.lastIndexedAt

    let _: WritableKeyPath<Components.Schemas.StoreMountHealth, Swift.String?> = \.detail
    let _: WritableKeyPath<Components.Schemas.StoreMountHealth, Swift.Bool?> = \.mounted

    #expect(Bool(true))  // reaching here means every keypath above type-checked
  }

  /// The stack-browse document (vendored at img-manager 5615fd9) adds three more properties
  /// whose loss would be silent rather than loud, so they are named here individually — the
  /// same reasoning that put `ImagePage.next_cursor` above. `anchor_taken_at` is the scene's
  /// stored place in capture order and is the ONLY correct key for date sectioning (the cover
  /// moves on a mark, the anchor does not); a dropped Optional here would not fail to compile
  /// at the call site, it would silently section scenes under the wrong day. The two
  /// `next_cursor`s are the paging terminators for the two new paged responses: dropped, the
  /// client would page forever or stop after one page depending on how the absence read.
  @Test("Stack-browse nullable properties survive generation (anchor + both next_cursors)")
  func stackBrowseNullableProperties() {
    let _: WritableKeyPath<Components.Schemas.StackBrowseStackRow, Foundation.Date?> =
      \.anchorTakenAt
    let _: WritableKeyPath<Components.Schemas.StackBrowsePage, Swift.String?> = \.nextCursor
    let _: WritableKeyPath<Components.Schemas.StackMemberPage, Swift.String?> = \.nextCursor
    #expect(Bool(true))  // reaching here means every keypath above type-checked
  }

  /// IMGMGR-249. The one nullability idiom img-manager CANNOT spell as a type array: JSON Schema
  /// has no nullable-`$ref` shorthand, so a nullable model reference is always
  /// `anyOf: [{$ref}, {"type": "null"}]` — and swift-openapi-generator 1.13.0 drops such a
  /// property whole. Measured before the fix, on the gate's own generated `Types.swift` at
  /// 0466798: `activeRun` 0 hits, positive control `lastIndexedAt` 5 hits, and the Status sheet
  /// consequently could not name the job that was running. `scripts/sync-openapi.sh` now
  /// canonicalises that shape to the bare `$ref` at optional sites; all seven are pinned
  /// individually here, because losing one again would be silent.
  @Test("Nullable MODEL references survive generation (all seven anyOf-$ref-null properties)")
  func nullableModelReferencesSurvive() {
    let _:
      WritableKeyPath<Components.Schemas.StatusResponse, Components.Schemas.MaintenanceRunView?> =
        \.activeRun
    let _:
      WritableKeyPath<Components.Schemas.MaintenanceBusy, Components.Schemas.MaintenanceRunView?> =
        \.activeRun
    let _:
      WritableKeyPath<Components.Schemas.ApiHealthResponse, Components.Schemas.MaintenanceStatus?> =
        \.maintenance
    let _:
      WritableKeyPath<Components.Schemas.RunCounters, Components.Schemas.BackfillRunCounters?> =
        \.backfill
    let _: WritableKeyPath<Components.Schemas.RunCounters, Components.Schemas.IndexRunCounters?> =
      \.index
    let _:
      WritableKeyPath<Components.Schemas.RunCounters, Components.Schemas.PrecomputeRunCounters?> =
        \.precompute
    let _: WritableKeyPath<Components.Schemas.RunCounters, Components.Schemas.RunProgress?> =
      \.progress
    #expect(Bool(true))  // reaching here means every keypath above type-checked
  }

  @Test("ImagePage round-trips a present and an absent next_cursor through Codable")
  func imagePageRoundTrip() throws {
    let withCursor = Components.Schemas.ImagePage(
      items: [], limit: 50, nextCursor: "abc123")
    let encoded = try JSONEncoder().encode(withCursor)
    let decoded = try JSONDecoder().decode(Components.Schemas.ImagePage.self, from: encoded)
    #expect(decoded.nextCursor == "abc123")

    let withoutCursor = Components.Schemas.ImagePage(items: [], limit: 50, nextCursor: nil)
    let encodedNil = try JSONEncoder().encode(withoutCursor)
    let decodedNil = try JSONDecoder().decode(
      Components.Schemas.ImagePage.self, from: encodedNil)
    #expect(decodedNil.nextCursor == nil)
  }

  /// The parameter-schema gap docs/OPENAPI_NORMALIZATION_DEBT.md named at closure: the retired
  /// bridge fixed 88 `#/paths/*` query/path parameter schemas by the same rewrite as the 29
  /// component-schema properties above, but no test here named one individually. `tree` on
  /// `GET /api/folders` is the one `ImgManagerAPIClient.folders()` already constructs
  /// (`tree: nil`), so a regression here would already be caught by TransportStateTests
  /// failing to compile — this test additionally proves it takes a real value, not only `nil`,
  /// and that the generated `Input.Query` initializer's contract is what is being checked.
  @Test("GET /api/folders — tree query parameter survives as an optional (parameter-schema gap)")
  func folderTreeQueryParameterIsOptional() {
    let withValue = Operations.FolderTreeApiFoldersGet.Input.Query(
      sourceTier: .local, tree: "2026/08")
    #expect(withValue.tree == "2026/08")
    let withoutValue = Operations.FolderTreeApiFoldersGet.Input.Query(
      sourceTier: .local, tree: nil)
    #expect(withoutValue.tree == nil)
  }
}

/// WP8 P1-ios acceptance (plan p3226 / p1-spec-rev2 §5): the raw generated client, vendored
/// straight from v0.9.2 with no bridge in front of it, exposes the three native-auth
/// operations the pinned port contract names — and their bodies' own nullable-shaped fields —
/// without any rewriting. Each assertion is the same compile-time existence-and-type check as
/// `NullableSurvivalTests`: a keypath or an initializer argument that does not type-check fails
/// the whole test target's build.
@Suite("Native-auth operations are exposed by the raw generated client")
struct NativeAuthOperationsExposedTests {

  @Test("POST /api/auth/native/exchange exists, takes NativeExchangeIn, returns NativeTokenOut")
  func exchangeOperationShape() {
    let body = Components.Schemas.NativeExchangeIn(code: "handoff", codeVerifier: "verifier")
    #expect(body.code == "handoff")
    #expect(body.codeVerifier == "verifier")
    let token = Components.Schemas.NativeTokenOut(
      expiresAt: Date(), subject: "sub", token: "tok")
    #expect(token.token == "tok")
    // Type-checks only if the operation exists on APIProtocol with this Input/Output shape —
    // never called, so a compile failure here (not a runtime one) IS the proof.
    let exchange = { (client: any APIProtocol) in client.nativeExchangeApiAuthNativeExchangePost }
    _ = exchange
    #expect(Bool(true))
  }

  @Test("POST /api/auth/native/renew and POST /api/auth/native/logout exist on the client")
  func renewAndLogoutOperationsExist() {
    let renew = { (client: any APIProtocol) in client.nativeRenewApiAuthNativeRenewPost }
    let logout = { (client: any APIProtocol) in client.nativeLogoutApiAuthNativeLogoutPost }
    _ = renew
    _ = logout
    #expect(Bool(true))
  }
}
