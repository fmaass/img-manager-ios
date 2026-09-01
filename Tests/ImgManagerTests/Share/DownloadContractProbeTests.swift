import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-196's mandated FIRST ACTION: the download endpoint's generated contract, probed
/// through the REAL generated `Client` over `GridStubTransport` — the same discipline as
/// `Grid/GridServiceContractProbeTests.swift`.
///
/// THE FINDING THIS SUITE RECORDED, AND ITS EXPIRY. Until the IMGMGR-249 re-vendor
/// (img-manager `74203992`, 2026-08-31) the contract's `200` declared no `content` at all, so
/// `Output.Ok` was generated as an empty struct and the master export's BYTES were unreachable
/// through the generated client — the master half of this lane stopping at `ShareMasterSeam`
/// with no hand-built request standing in for the missing declaration. The operation now
/// declares binary content, so the tripwire that suite carried has fired exactly as written:
/// `masterBytesAreReachableAtThisContract` below records the new position, and the seam stays
/// off because its steps 3 and 4 are unbuilt, not because the bytes cannot be had.
///
/// The 403 half, by contrast, IS fully expressed by the generated types — including the
/// `X-Img-Policy` header — so the refusal the whole feature exists to respect is already
/// decodable today, and is proven here end to end.
@Suite("Download contract probe (IMGMGR-196 FIRST ACTION)")
struct DownloadContractProbeTests {

  private func makeClient(_ transport: GridStubTransport) -> any APIProtocol {
    ImgManagerAPIClient.make(transport: transport)
  }

  private func download(
    _ client: any APIProtocol, imageID: Int = 1
  ) async throws -> Operations.DownloadImageApiImagesImageIdDownloadGet.Output {
    // The client asks only for `master` — `content=original` is never sent by this app, so a
    // RAW original is never even requested (`ShareVariant` has no case for one).
    try await client.downloadImageApiImagesImageIdDownloadGet(
      .init(path: .init(imageId: imageID), query: .init(content: .master)))
  }

  @Test(
    "403 + X-Img-Policy decodes to the generated .forbidden case, header readable"
  )
  func policyForbiddenDecodesWithItsHeader() async throws {
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(.rawOriginalPolicy)
    let output = try await download(makeClient(transport))

    guard case .forbidden(let forbidden) = output else {
      Issue.record("expected .forbidden, got \(output)")
      return
    }
    #expect(forbidden.headers.xImgPolicy == .rawOriginal)
    #expect(
      ShareExportPlan.refusal(
        status: 403, policyHeader: forbidden.headers.xImgPolicy?.rawValue) == .rawOriginalPolicy)
  }

  @Test("A bare 403 — no X-Img-Policy — is a session refusal, never reported as the RAW policy")
  func bareForbiddenIsNotThePolicyAnswer() async throws {
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(.sessionForbidden)
    let output = try await download(makeClient(transport))

    guard case .forbidden(let forbidden) = output else {
      Issue.record("expected .forbidden, got \(output)")
      return
    }
    #expect(forbidden.headers.xImgPolicy == nil)
    #expect(
      ShareExportPlan.refusal(
        status: 403, policyHeader: forbidden.headers.xImgPolicy?.rawValue) == .notConnected)
  }

  @Test("404 decodes to its own case — 'no master export', never confused with a refusal")
  func notFoundDecodes() async throws {
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(.notFound)
    let output = try await download(makeClient(transport))

    guard case .notFound = output else {
      Issue.record("expected .notFound, got \(output)")
      return
    }
    #expect(ShareExportPlan.refusal(status: 404, policyHeader: nil) == .noMaster)
  }

  /// THE TRIPWIRE FIRED (WP14 lane A, 2026-08-31). This test used to record the opposite: the
  /// `200` declared no `content` at all, `Output.Ok` was an empty struct, and the master's bytes
  /// were unreachable through the generated client. Its own comment named the day it would stop
  /// compiling as the day the seam should be reconsidered — and the IMGMGR-249 re-vendor at
  /// img-manager `74203992` is that day: the operation now declares binary content, so `Ok`
  /// carries a `Body`.
  ///
  /// What that changes is the CONTRACT, which is steps 1 and 2 of `ShareMasterSeam`'s own
  /// activation list. Steps 3 and 4 — a `MasterDownloading` conformance on `GridService`, then
  /// flipping `isAvailable` — are a feature decision with its own lane, so this suite records the
  /// new position rather than taking it: the body exists, and the seam is still off ON PURPOSE.
  @Test("The 200 now DECLARES a body, so the master seam's parked premise no longer holds")
  func masterBytesAreReachableAtThisContract() async throws {
    let transport = GridStubTransport()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
    await transport.setDownloadOutcome(
      .ok(bytes, contentDisposition: "attachment; filename=\"DSC_1234-2.jpg\""))
    let output = try await download(makeClient(transport))

    guard case .ok(let ok) = output else {
      Issue.record("expected .ok, got \(output)")
      return
    }
    // The finding, as a compile-time check rather than a comment: `Ok` has a `body` of the
    // generated `Body` type. A keypath literal into it does not type-check if the property is
    // absent, which is precisely the state this suite recorded before the re-vendor. Deliberately
    // NOT matched against a content-type case — which case a response carries is the downloader's
    // question (step 3), and this probe is about the contract, not about consuming it.
    let bodyKeyPath:
      KeyPath<
        Operations.DownloadImageApiImagesImageIdDownloadGet.Output.Ok,
        Operations.DownloadImageApiImagesImageIdDownloadGet.Output.Ok.Body
      > = \.body
    _ = bodyKeyPath
    _ = ok
    // Still OFF, and now by decision rather than by impossibility: steps 3 and 4 of
    // `ShareMasterSeam`'s activation list are unbuilt, and flipping this without them would
    // route the loupe's master entry at a downloader that does not exist.
    #expect(ShareMasterSeam.isAvailable == false)
  }
}
