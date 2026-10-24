import Foundation
import ImgManagerAPI
import Observation

/// The app-owned PRE-FLIGHT (gate correction 3).
///
/// `ShareLink`/`Transferable` resolve their item at PRESENTATION time, so a share built the
/// obvious way would open the system sheet FIRST and only then discover a `403`, a missing
/// preview, or no network — and the refusal would land inside a sheet this app does not own and
/// cannot write copy into. So the file is prepared first: bytes are fetched, capped, and written
/// to disk under a real name, and only a `.ready` state can present the system sheet at all.
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
  /// Increments on every `prepare` and every `finish` — see `prepare` for what it guards.
  private var generation = 0

  /// `masterAvailable` defaults to the seam and is a PARAMETER so a test can pin BOTH sides of
  /// the guard: that a closed seam makes no request at all, and that the same downloader does
  /// reach the wire when it is open. `ShareMasterSeamTests` pins the production default
  /// separately, so the shipped value can never drift as a side effect of a test's needs.
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

  /// A share-lane-private subdirectory of the system temp directory. Each export gets its OWN
  /// numbered subdirectory inside it (see `exportDirectory(for:)`); the root is cleared wholesale
  /// before every export and again when the sheet is done, so at most one prepared export is on
  /// disk at a time.
  static var defaultDirectory: URL {
    FileManager.default.temporaryDirectory.appending(path: "share", directoryHint: .isDirectory)
  }

  /// One directory per generation, and this is load-bearing rather than tidy.
  ///
  /// Filenames are derived from the photograph, so two exports can easily want the SAME name —
  /// the same photograph shared twice, or two photographs whose names sanitize alike. With a
  /// single flat directory they would resolve to one URL, and a stale export finishing late
  /// would write its bytes over the live export's file and then, cleaning itself up, DELETE that
  /// file while `state` still said `.ready` — leaving the next share pointing at nothing, or at
  /// the wrong photograph's bytes. Isolating by generation means a stale export can only ever
  /// write to, and delete, its own path.
  private func exportDirectory(for generation: Int) -> URL {
    directory.appending(path: "\(generation)", directoryHint: .isDirectory)
  }

  var isPreparing: Bool {
    if case .preparing = state { return true }
    return false
  }

  /// Fetches, caps, names and writes the export, then leaves `state` at `.ready` or `.refused`.
  /// Re-entrant taps are refused rather than raced — the same posture as `GridStore`'s
  /// `isMutatingMark` guard, so a double-tap can never leave two writers on one temp path.
  ///
  /// Cancellation is honoured at the one await this method has (and inside it: both byte paths
  /// abort their own reads, `Data(collecting:)` and `ShareStreamWriter`'s streaming loop alike,
  /// and the streaming writer deletes its partial file on the way out). What is left when the
  /// call returns is handled by the cancellation guard below.
  ///
  /// A fetch takes time, and the loupe's focus can move while it is in flight. The generation
  /// captured before the await is what makes that safe: a result that comes back into a
  /// CHANGED generation is discarded and its file deleted, so the status bar can never end up
  /// offering the previous photograph under the new one's chrome. `finish()` bumps the
  /// generation for exactly this reason — cancelling in-flight work is the whole point of it,
  /// not just clearing what has already landed.
  ///
  /// IMGMGR-544: `look` is the photograph's SAVED look (`LookPersistence.savedRender`); with one,
  /// the preview export is the looked render — or a refusal, never the unlooked bytes in its
  /// place. A master export ignores it: the edit supersedes the look.
  func prepare(
    _ variant: ShareVariant, for image: Components.Schemas.ImageSummary,
    look: LookModel.Active? = nil
  ) async {
    guard !isPreparing else { return }
    generation &+= 1
    let requested = generation
    state = .preparing(variant)
    // Safe even with an older export still in flight: that one has not written yet (it is
    // suspended on its fetch, and writing plus the staleness check below happen together with no
    // await between them), and when it does write it writes inside its own generation's
    // directory, not here.
    clearDirectory()
    let destination = exportDirectory(for: requested)
    let outcome: State
    switch variant {
    case .preview:
      outcome = await preparePreview(for: image, in: destination, look: look)
    case .master:
      outcome = await prepareMaster(for: image, in: destination)
    }
    guard requested == generation else {
      // Stale: something moved on while this was in flight. Its bytes name a photograph that is
      // no longer the one on screen, so the WHOLE generation directory goes — never an
      // individual file path, which a live export could by then be using for a same-named
      // export of its own. `state`, already owned by whatever superseded this, is not touched.
      try? FileManager.default.removeItem(at: destination)
      return
    }
    guard !Task.isCancelled else {
      // CANCELLED means the view that asked for this export is gone — the loupe closed while the
      // fetch was in flight — so nothing can present it and nothing will ever dismiss it: no
      // sheet completion, no `onDismiss`, no `finish(_:)` from a user gesture. That makes
      // cancellation an ENDING, and it runs the ending path rather than a second one of its own:
      // `finish(_:)` with this export's own token deletes the prepared file and returns the
      // store to `.idle`, exactly as a cancelled sheet does. Without this a successful prepare
      // landed `.ready` bytes on disk with no live presenter (diff-gate BLOCKING, IMGMGR-348).
      state = outcome
      finish(ShareExportToken(generation: requested))
      return
    }
    state = outcome
  }

  /// The token identifying the export currently on screen. A view captures this when it presents
  /// something that will report back LATER — a share sheet, whose completion can arrive from an
  /// out-of-process target long after the user has moved on — and hands it back to `finish`.
  var currentToken: ShareExportToken { ShareExportToken(generation: generation) }

  /// Ends the export the caller is actually holding, and NOTHING else.
  ///
  /// The gate is the whole point. A share sheet's completion callback can fire arbitrarily late:
  /// the user shares A to an out-of-process target, gets bored, prepares B, and A's callback then
  /// arrives. Ungated, it would delete B's file and reset B's state, leaving the bar offering an
  /// export that is no longer on disk. A token from a superseded generation is therefore ignored
  /// outright, and when the token IS current only that generation's own directory is removed —
  /// never the shared root, which by then may belong to someone else.
  func finish(_ token: ShareExportToken) {
    guard token.generation == generation else { return }
    try? FileManager.default.removeItem(at: exportDirectory(for: generation))
    // Bumping disowns any fetch still in flight AND makes this token stale, so a second delayed
    // callback carrying the same token is a no-op rather than a repeat.
    generation &+= 1
    state = .idle
  }

  /// Abandons whatever is current because the CONTEXT changed — the loupe's focus moved to
  /// another photograph, so no export in progress or on disk belongs to what is on screen.
  ///
  /// Unlike `finish`, this deliberately takes no token: it is the supersede, not a completion,
  /// and it owns every generation by construction — it bumps first, which makes every generation
  /// that exists stale, so the wholesale root clear that follows can only be removing files that
  /// their own stale branches would have removed anyway.
  func supersede() {
    generation &+= 1
    clearDirectory()
    state = .idle
  }

  private func preparePreview(
    for image: Components.Schemas.ImageSummary, in destination: URL, look: LookModel.Active?
  ) async -> State {
    if let look {
      let looked: LookedProxyFetchResult
      do {
        looked = try await service.lookedProxy(
          imageID: image.id, tier: .preview, lookID: look.lookID, strength: look.strength)
      } catch {
        return .refused(.notConnected)
      }
      switch looked {
      case .ok(let data, _):
        // A looked 200 that is not a JPEG (no SOI marker) is not the photograph through its look.
        guard data.starts(with: [0xFF, 0xD8]) else { return .refused(.lookUnavailable) }
        return writePreview(data, for: image, in: destination)
      case .notFound:
        return .refused(.noPreview)
      case .refused:
        return .refused(.lookUnavailable)
      }
    }
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
    return writePreview(data, for: image, in: destination)
  }

  /// The preview export's cap, name and write, looked or not.
  private func writePreview(
    _ data: Data, for image: Components.Schemas.ImageSummary, in destination: URL
  ) -> State {
    guard data.count <= ShareExportPlan.previewByteCap else { return .refused(.tooLarge) }
    let filename = ShareExportPlan.previewFilename(for: image.filename)
    guard let url = write(data, named: filename, in: destination) else {
      return .refused(.couldNotPrepare)
    }
    return .ready(
      ShareExportFile(
        url: url, filename: filename, contentType: ShareExportPlan.previewContentType))
  }

  private func prepareMaster(for image: Components.Schemas.ImageSummary, in destination: URL)
    async -> State
  {
    // The seam, checked in the ONE place a master export can begin — see `ShareMasterSeam`.
    // The loupe already hides the entry while this is off; this is the guard that holds even if
    // a future caller forgets to ask.
    guard masterAvailable else { return .refused(.masterContractUnavailable) }
    guard createDirectory(destination) else { return .refused(.couldNotPrepare) }
    // The downloader is handed THIS generation's directory, so a stale master export streams
    // into its own path too — the isolation is not something only the preview lane gets.
    switch await master.downloadMaster(imageID: image.id, into: destination) {
    case .ok(let file):
      return .ready(file)
    case .refused(let refusal):
      return .refused(refusal)
    }
  }

  private func write(_ data: Data, named filename: String, in destination: URL) -> URL? {
    guard createDirectory(destination) else { return nil }
    let url = destination.appending(path: filename, directoryHint: .notDirectory)
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  private func createDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
  }

  private func clearDirectory() {
    try? FileManager.default.removeItem(at: directory)
  }
}
