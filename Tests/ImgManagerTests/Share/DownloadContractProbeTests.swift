import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-196's mandated FIRST ACTION: the download endpoint's generated contract, probed
/// through the REAL generated `Client` over `GridStubTransport` — the same discipline as
/// `Grid/GridServiceContractProbeTests.swift`.
///
/// THE FINDING THIS SUITE RECORDS. `Operations.DownloadImageApiImagesImageIdDownloadGet
/// .Output.Ok` is generated as an EMPTY STRUCT (`public struct Ok { public init() {} }`),
/// because the vendored contract's `200` declares no `content` at all. The master export's
/// BYTES are therefore unreachable through the generated client, and the master half of this
/// lane stops at `ShareMasterSeam` — no hand-built request stands in for the missing
/// declaration. `masterBytesAreUnreachableAtThisContract` below is that finding as a passing
/// test rather than a comment: it goes RED the day the contract grows a body, which is exactly
/// the day the seam should be reconsidered.
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

  @Test(
    "THE PARKED PREMISE: a 200 carrying real bytes still yields an Output.Ok with no body to read"
  )
  func masterBytesAreUnreachableAtThisContract() async throws {
    let transport = GridStubTransport()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
    await transport.setDownloadOutcome(
      .ok(bytes, contentDisposition: "attachment; filename=\"DSC_1234-2.jpg\""))
    let output = try await download(makeClient(transport))

    guard case .ok(let ok) = output else {
      Issue.record("expected .ok, got \(output)")
      return
    }
    // The whole finding in one line: the ONLY thing `Ok` can be compared against is another
    // default-constructed `Ok`, because it has no members at all. The bytes the transport
    // genuinely sent, and the `Content-Disposition` it genuinely set, are both unreachable
    // from here. Give this response a declared body in the contract and this line stops
    // compiling as an equality — which is the intended way to discover that the seam can open.
    #expect(ok == Operations.DownloadImageApiImagesImageIdDownloadGet.Output.Ok())
    #expect(ShareMasterSeam.isAvailable == false)
  }
}
