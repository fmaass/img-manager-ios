import Foundation
import ImgManagerAPI
import Observation

/// The app-owned PRE-FLIGHT (gate correction 3).
///
/// `ShareLink`/`Transferable` resolve their item at PRESENTATION time, so a share built the
/// obvious way would open the system sheet FIRST and only then discover a `403`, a missing
/// preview, or no network — and the refusal would land inside a sheet this app does not own and
/// cannot write copy into. So the file is prepared first: bytes are fetched, capped, and written
/// to disk under a real name, and only a `.ready` state ever puts a `ShareLink` on screen.
/// Nothing in this type presents anything; the view does, and only from `.ready`.
///
/// Bytes come from the EXISTING proxy path (`GridService.proxy`, the same operation and the same
/// 30 MB cap the loupe's own render already uses). `GridStore`'s per-launch proxy cache is left
/// exactly as it is — this type neither reads nor fills it, so nothing about the grid's caching
/// behaviour changes because sharing exists.
@MainActor
@Observable
final class ShareExportStore {
  enum State: Equatable {
    case idle
    case preparing(ShareVariant)
    case ready(ShareExportFile)
    case refused(ShareRefusal)
  }

  private(set) var state: State = .idle

  private let service: GridService
  private let master: any MasterDownloading
  private let masterAvailable: Bool
  private let directory: URL

  /// `masterAvailable` defaults to the seam and is a PARAMETER only so the master pipeline can
  /// be exercised end-to-end (refusal mapping, naming, `.ready`) while the seam itself stays
  /// off in production — a parked lane that no test ever runs is a lane that will not work on
  /// the day it is switched on. `ShareMasterSeamTests` pins the production default separately.
  init(
    service: GridService,
    master: any MasterDownloading = UnavailableMasterDownloader(),
    masterAvailable: Bool = ShareMasterSeam.isAvailable,
    directory: URL = ShareExportStore.defaultDirectory
  ) {
    self.service = service
    self.master = master
    self.masterAvailable = masterAvailable
    self.directory = directory
  }

  /// A share-lane-private subdirectory of the system temp directory: it is cleared wholesale
  /// before every export and again when the sheet is done with it, so at most one prepared
  /// export exists on disk at a time.
  static var defaultDirectory: URL {
    FileManager.default.temporaryDirectory.appending(path: "share", directoryHint: .isDirectory)
  }

  var isPreparing: Bool {
    if case .preparing = state { return true }
    return false
  }

  /// Fetches, caps, names and writes the export, then leaves `state` at `.ready` or `.refused`.
  /// Re-entrant taps are refused rather than raced — the same posture as `GridStore`'s
  /// `isMutatingMark` guard, so a double-tap can never leave two writers on one temp path.
  func prepare(_ variant: ShareVariant, for image: Components.Schemas.ImageSummary) async {
    guard !isPreparing else { return }
    state = .preparing(variant)
    clearDirectory()
    switch variant {
    case .preview:
      state = await preparePreview(for: image)
    case .master:
      state = await prepareMaster(for: image)
    }
  }

  /// Called when the share sheet is done with the file, when the loupe's focus moves, and when
  /// the user dismisses a refusal. The temp file is the only copy of those bytes outside the
  /// cache and it does not outlive the sheet that needed it (gate correction 4).
  func finish() {
    clearDirectory()
    state = .idle
  }

  private func preparePreview(for image: Components.Schemas.ImageSummary) async -> State {
    let token = ProxyIdentity.token(
      from: image.proxies.additionalProperties[ProxyTier.preview.rawValue]?.url)
    let outcome: ProxyFetchResult
    do {
      outcome = try await service.proxy(imageID: image.id, tier: .preview, v: token)
    } catch {
      // `GridServiceError` is opaque by construction — there is nothing bound here for server
      // text or a hostname to be copied out of, even by mistake.
      return .refused(.notConnected)
    }
    guard case .ok(let data) = outcome else {
      // `.notFound` (the tier has no preview yet) and `.notModified` (only reachable for a
      // conditional request this call never makes) both mean the same thing to a share: there
      // are no bytes to hand over.
      return .refused(.noPreview)
    }
    guard data.count <= ShareExportPlan.previewByteCap else { return .refused(.tooLarge) }
    let filename = ShareExportPlan.previewFilename(for: image.filename)
    guard let url = write(data, named: filename) else { return .refused(.couldNotPrepare) }
    return .ready(
      ShareExportFile(
        url: url, filename: filename, contentType: ShareExportPlan.previewContentType))
  }

  private func prepareMaster(for image: Components.Schemas.ImageSummary) async -> State {
    // The seam, checked in the ONE place a master export can begin — see `ShareMasterSeam`.
    // The loupe already hides the entry while this is off; this is the guard that holds even if
    // a future caller forgets to ask.
    guard masterAvailable else { return .refused(.masterContractUnavailable) }
    guard createDirectory() else { return .refused(.couldNotPrepare) }
    switch await master.downloadMaster(imageID: image.id, into: directory) {
    case .ok(let file):
      return .ready(file)
    case .refused(let refusal):
      return .refused(refusal)
    }
  }

  private func write(_ data: Data, named filename: String) -> URL? {
    guard createDirectory() else { return nil }
    let url = directory.appending(path: filename, directoryHint: .notDirectory)
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  @discardableResult
  private func createDirectory() -> Bool {
    (try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)) != nil
  }

  private func clearDirectory() {
    try? FileManager.default.removeItem(at: directory)
  }
}
