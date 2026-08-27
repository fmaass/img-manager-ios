import Foundation
import Testing

@testable import ImgManagerAPI

// The OpenAPI generation PROBE (WP8 P0a, plan §Phase 0a). img-manager's schema expresses
// nullability as `anyOf: [X, {"type": "null"}]`. swift-openapi-generator silently DROPS a
// property written that way instead of generating it as Optional — confirmed 2026-08-27
// against the raw v0.9.0 schema (SHA 4b952701ac79a6ec7ac245e8f1bf3b9657ca64c6): all 29
// inline-type anyOf-nullable component-schema properties vanished from the generated
// Types.swift, ImagePage.next_cursor included (see .phase-ledger.md for the grep evidence
// against the unbridged build). tools/normalize-openapi.py bridges the schema before the
// generator sees it (scripts/sync-openapi.sh), so this test runs against the BRIDGED
// output and must therefore pass — it is the regression guard for that bridge staying
// wired, not a test of the generator's behavior against the raw schema.
//
// Each assertion is a compile-time existence-and-type check: a `WritableKeyPath` literal
// fails to type-check — failing the whole test target's build — if the named property does
// not exist on the generated type, or if its wrapped type is not the Optional shown. This
// is stronger than a runtime string search: it cannot pass by accident, and it is the
// generated INITIALIZER'S contract, not a comment, that is being checked.
//
// PINNED DEBT: this bridge is temporary. When img-manager's P1-backend phase emits
// `type: [X, "null"]` natively (the OAS 3.1 idiom, lossless and directly supported), the
// bridge is deleted and this test is re-pointed at the (now unbridged) vendored schema
// directly. See docs/OPENAPI_NORMALIZATION_DEBT.md.
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
        let aspectSourceKP1: WritableKeyPath<
            Components.Schemas.ImageDetail, Components.Schemas.ImageDetail.AspectSourcePayload?
        > = \Components.Schemas.ImageDetail.aspectSource
        _ = aspectSourceKP1
        let _: WritableKeyPath<Components.Schemas.ImageDetail, Foundation.Date?> = \.capturedAt
        let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.String?> = \.sourceKind
        let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.String?> = \.sourceLabel
        let _: WritableKeyPath<Components.Schemas.ImageDetail, Swift.String?> = \.sourceUnavailableReason

        let _: WritableKeyPath<Components.Schemas.ImageSummary, Swift.Double?> = \.aspectRatio
        let aspectSourceKP2: WritableKeyPath<
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
}
