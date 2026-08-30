import Foundation
import Testing

@testable import ImgManager

/// The named seam test (gate correction 1). Its whole job is to make activation DELIBERATE:
/// flipping `ShareMasterSeam.isAvailable` without the re-vendored contract behind it turns this
/// suite red, so the master lane cannot switch itself on as a side effect of an unrelated edit.
///
/// When the contract does grow a body, this suite is the thing to update — alongside
/// `DownloadContractProbeTests.masterBytesAreUnreachableAtThisContract`, which is the other half
/// of the same fact and fails at the same moment.
@Suite("Share master seam — OFF until the contract carries a body")
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
