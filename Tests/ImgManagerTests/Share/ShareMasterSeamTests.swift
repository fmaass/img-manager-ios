import Foundation
import Testing

@testable import ImgManager

/// The named seam test (gate correction 1). Its whole job is to make activation DELIBERATE:
/// flipping `ShareMasterSeam.isAvailable` without the re-vendored contract behind it turns this
/// suite red, so the master lane cannot switch itself on as a side effect of an unrelated edit.
///
/// The contract HAS since grown a body (IMGMGR-249 re-vendor at img-manager `74203992`), and
/// `DownloadContractProbeTests.masterBytesAreReachableAtThisContract` records that. This suite
/// deliberately did not move with it: the seam is off now because steps 3 and 4 of
/// `ShareMasterSeam`'s activation list are unbuilt, which is a feature decision with its own
/// lane — not something a re-vendor gets to make.
@Suite("Share master seam — OFF until a downloader exists behind it")
struct ShareMasterSeamTests {

  @Test("The seam ships OFF at the current vendored contract")
  func seamIsOff() {
    #expect(ShareMasterSeam.isAvailable == false)
  }

  @Test("The parked downloader refuses in the same shape a real one would, with its own copy")
  func unavailableDownloaderRefusesInShape() async {
    let outcome = await UnavailableMasterDownloader().downloadMaster(
      imageID: 1, into: FileManager.default.temporaryDirectory)

    #expect(outcome == .refused(.masterContractUnavailable))
    #expect(
      ShareRefusal.masterContractUnavailable.copy
        == "Sharing the edited master isn't available in this build yet.")
  }

  @Test("The pieces the master lane needs on activation already exist and already work")
  func activationSurfaceIsAlreadyBuilt() {
    // Naming from the server, refusal mapping, and the named cap — the three things a
    // late, hurried activation would otherwise have to invent against a live endpoint.
    #expect(
      ShareExportPlan.filename(fromContentDisposition: "attachment; filename=\"m.jpg\"")
        == "m.jpg")
    #expect(
      ShareExportPlan.refusal(status: 403, policyHeader: "raw-original") == .rawOriginalPolicy)
    #expect(ShareExportPlan.masterByteCap == 256 * 1024 * 1024)
  }
}
