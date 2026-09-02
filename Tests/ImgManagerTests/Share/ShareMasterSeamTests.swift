import Foundation
import Testing

@testable import ImgManager

/// The named seam test (gate correction 1). Its job is to make the master lane's state
/// DELIBERATE in both directions: the shipped value of `ShareMasterSeam.isAvailable` is pinned
/// here, so neither switching the lane on nor standing it back down can happen as a side effect
/// of an unrelated edit.
///
/// IMGMGR-279 completed the activation list: the contract carries a body (IMGMGR-249 re-vendor
/// at img-manager `74203992`), `GridService.downloadMaster` issues the request, and `RootView`
/// hands that conformance to the store. So the pinned value is now `true`, and
/// `MasterDownloadTests` is where the downloader behind it is proven.
@Suite("Share master seam — ON, with the downloader that earns it")
struct ShareMasterSeamTests {

  @Test("The seam ships ON, now that a real downloader stands behind it")
  func seamIsOn() {
    #expect(ShareMasterSeam.isAvailable == true)
  }

  @Test("The closed-seam downloader refuses in the same shape a real one does, with its own copy")
  func unavailableDownloaderRefusesInShape() async {
    let outcome = await UnavailableMasterDownloader().downloadMaster(
      imageID: 1, into: FileManager.default.temporaryDirectory)

    #expect(outcome == .refused(.masterContractUnavailable))
    #expect(
      ShareRefusal.masterContractUnavailable.copy
        == "Sharing the edited master isn't available in this build yet.")
  }

  @Test("The pieces the master lane runs on are the plan's own, not the downloader's improvised")
  func activationSurfaceIsAlreadyBuilt() {
    // Naming from the server, refusal mapping, and the named cap — the three things a
    // late, hurried activation would otherwise have had to invent against a live endpoint.
    #expect(
      ShareExportPlan.filename(fromContentDisposition: "attachment; filename=\"m.jpg\"")
        == "m.jpg")
    #expect(
      ShareExportPlan.refusal(status: 403, policyHeader: "raw-original") == .rawOriginalPolicy)
    #expect(ShareExportPlan.masterByteCap == 256 * 1024 * 1024)
  }
}
