import Foundation
import Testing
import UniformTypeIdentifiers

@testable import ImgManager

/// The share lane's pure decisions, tested without SwiftUI, the network or the generated
/// client. Two of these are the causal RED/GREEN for IMGMGR-196: the policy-403 mapping (remove
/// the header check and `policyRefusalNeedsTheHeader` fails, not a comment somewhere) and the
/// preview naming (name the file from `ImageSummary.ext` and `previewFilenameFromStem` fails,
/// which is exactly the mislabelled-RAW bug gate correction 5 exists to prevent).
@Suite("Share export plan — naming, caps, refusal mapping")
struct ShareExportPlanTests {

  @Test("A preview is named from the STEM plus the proxy's own type, never the RAW's extension")
  func previewFilenameFromStem() {
    #expect(ShareExportPlan.previewFilename(for: "DSC_1234.NEF") == "DSC_1234.jpg")
    #expect(ShareExportPlan.previewFilename(for: "DSC_1234.dng") == "DSC_1234.jpg")
    #expect(ShareExportPlan.previewFilename(for: "a.b.c.RAF") == "a.b.c.jpg")
    #expect(ShareExportPlan.previewFilename(for: "no-extension") == "no-extension.jpg")
  }

  @Test("A hostile filename can never escape the share temp directory")
  func previewFilenameCannotEscape() {
    #expect(ShareExportPlan.previewFilename(for: "../../etc/passwd") == "passwd.jpg")
    #expect(ShareExportPlan.previewFilename(for: "/") == "photo.jpg")
    #expect(ShareExportPlan.previewFilename(for: "..") == "photo.jpg")
    #expect(ShareExportPlan.previewFilename(for: "") == "photo.jpg")
  }

  @Test("A master's name is the SERVER's Content-Disposition, plain and RFC 5987 forms")
  func contentDispositionNaming() {
    #expect(
      ShareExportPlan.filename(fromContentDisposition: "attachment; filename=\"DSC_1234-2.jpg\"")
        == "DSC_1234-2.jpg")
    #expect(
      ShareExportPlan.filename(
        fromContentDisposition:
          "attachment; filename=\"fallback.jpg\"; filename*=UTF-8''Sch%C3%B6n.jpg")
        == "Schön.jpg")
    #expect(
      ShareExportPlan.filename(fromContentDisposition: "attachment; filename=\"../../secret\"")
        == "secret")
    #expect(ShareExportPlan.filename(fromContentDisposition: "attachment") == nil)
    #expect(ShareExportPlan.filename(fromContentDisposition: nil) == nil)
  }

  @Test("A 403 is the application's policy answer ONLY when X-Img-Policy is present")
  func policyRefusalNeedsTheHeader() {
    #expect(
      ShareExportPlan.refusal(status: 403, policyHeader: "raw-original") == .rawOriginalPolicy)
    // A bare 403 is the proxy or the session refusing (the schema says so: the header is
    // "absent on a session refusal"), so it must NOT be reported as the RAW policy.
    #expect(ShareExportPlan.refusal(status: 403, policyHeader: nil) == .notConnected)
    #expect(ShareExportPlan.refusal(status: 404, policyHeader: nil) == .noMaster)
    #expect(ShareExportPlan.refusal(status: 500, policyHeader: nil) == .notConnected)
  }

  @Test("Refusal copy: the policy sentence names the alternatives, offline reuses the owned one")
  func refusalCopy() {
    #expect(ShareRefusal.notConnected.copy == DegradedStateCopy.notConnected)
    #expect(
      ShareRefusal.rawOriginalPolicy.copy
        == "RAW originals can't be exported — share the preview or the edited master instead.")
    #expect(ShareRefusal.noMaster.copy == "No edited master for this photo yet.")
  }

  @Test("The master entry is offered only for an edited photo, and only with the seam open")
  func masterEntryVisibility() {
    // hasEdit is additive and often simply absent — nil and false are the same answer.
    #expect(ShareExportPlan.offersMaster(hasEdit: nil, seamAvailable: true) == false)
    #expect(ShareExportPlan.offersMaster(hasEdit: false, seamAvailable: true) == false)
    #expect(ShareExportPlan.offersMaster(hasEdit: true, seamAvailable: true) == true)
    // And at the shipping seam (IMGMGR-279 opened it), an edited photo offers the master.
    #expect(ShareExportPlan.offersMaster(hasEdit: true) == true)
    #expect(ShareExportPlan.offersMaster(hasEdit: false) == false)
  }

  @Test("Both byte caps are named, and the master's is the larger one")
  func namedCaps() {
    // Mirrors GridService.proxy's own 30 MB cap (Grid/GridService.swift:163).
    #expect(ShareExportPlan.previewByteCap == 30 * 1024 * 1024)
    #expect(ShareExportPlan.masterByteCap > ShareExportPlan.previewByteCap)
  }

  /// The `200`'s SEVEN declared bodies, mapped to the type the share sheet registers the item
  /// under. Named constants, never `UTType(mimeType:)`: the system's mime table is not this
  /// app's contract, and a lookup that silently changed under an OS update would change what a
  /// receiving app is told it is being handed.
  @Test(
    "Every content type the download 200 declares maps to its own UTType",
    arguments: [
      ("application/octet-stream", UTType.data),
      ("image/heic", UTType.heic),
      ("image/heif", UTType.heif),
      ("image/jpeg", UTType.jpeg),
      ("image/png", UTType.png),
      ("image/tiff", UTType.tiff),
      ("image/webp", UTType.webP),
    ])
  func contentTypeCoversEveryDeclaredBody(mimeType: String, expected: UTType) {
    #expect(ShareExportPlan.contentType(for: mimeType) == expected)
  }

  @Test("An undeclared content type is opaque data — never guessed into an image type")
  func unknownContentTypeIsData() {
    #expect(ShareExportPlan.contentType(for: "application/pdf") == .data)
    #expect(ShareExportPlan.contentType(for: "") == .data)
  }

  @Test("A master with no server name still gets a real, typed, per-image filename")
  func masterFallbackFilenameIsTypedAndSpecific() {
    #expect(ShareExportPlan.masterFilename(imageID: 42, contentType: .png) == "photo-42.png")
    #expect(ShareExportPlan.masterFilename(imageID: 1, contentType: .jpeg) == "photo-1.jpeg")
    #expect(ShareExportPlan.masterFilename(imageID: 9, contentType: .data) == "photo-9.dat")
  }

  @Test("No share variant can name a RAW original — the request is unrepresentable")
  func noOriginalVariantExists() {
    #expect(ShareVariant.allCases.map(\.rawValue).sorted() == ["master", "preview"])
    #expect(ShareExportPlan.previewContentType == UTType.jpeg)
  }
}
