import Foundation
import Observation

/// IMGMGR-545: one presentation of the Sync form. Built fresh per presentation (and per Summary
/// push), so nothing — above all the "Lightroom is closed" confirmation — outlives it.
///
/// Every network call is owned by a task the VIEW owns: `start()` and `poll()` run in the
/// form's `.task`s, and the one submission task is cancelled by `cancel()` when the form goes
/// away. Every result is applied only if its task was not cancelled and nothing newer started
/// meanwhile (`epoch` for status reads, the watched id for request reads).
@MainActor
@Observable
final class SyncSheetModel {
  /// Why the form is watching a request.
  enum Origin: Sendable, Equatable {
    /// This form's own request (201).
    case submitted
    /// A run already active when the form opened; the reader submitted nothing.
    case observed
    /// A run that rejected this form's request with 409; `requested` is what was asked for.
    case overlap(requested: SyncTarget)
  }

  struct Watched: Sendable, Equatable {
    var request: SyncRequest
    let origin: Origin
  }

  let folderID: Int?
  var target: SyncTarget
  /// Per request, never remembered: reset after every submission, whatever its outcome.
  var lightroomClosed = false
  private(set) var isSubmitting = false
  private(set) var watched: Watched?
  private(set) var status: SyncStatus?
  private(set) var statusFailure: SyncFailure?
  /// The mapped message of the last refusal or conflict, if any.
  private(set) var notice: String?
  @ObservationIgnored private(set) var submission: Task<Void, Never>?

  private let service: SyncService
  private let pollInterval: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  /// Bumped by every submission; a status read started under an older epoch is dropped.
  @ObservationIgnored private var epoch = 0

  /// 3 s is a PROVISIONAL cadence: the P5b measurement the plan cites is not in this repo.
  nonisolated static let defaultPollInterval: Duration = .seconds(3)

  init(
    service: SyncService, folderID: Int?,
    pollInterval: Duration = SyncSheetModel.defaultPollInterval,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.service = service
    self.folderID = folderID
    self.target = folderID.map { .shoot($0) } ?? .library
    self.pollInterval = pollInterval
    self.sleep = sleep
  }

  var targets: [SyncTarget] {
    folderID.map { [.shoot($0), .library] } ?? [.library]
  }

  private var isWatchingActiveRun: Bool { watched?.request.state.isActive ?? false }

  var canSyncNow: Bool { lightroomClosed && !isSubmitting && !isWatchingActiveRun }
  var isTargetLocked: Bool { isSubmitting || isWatchingActiveRun }

  var statusLine: String {
    guard folderID != nil else { return SyncCopy.libraryOnlyStatusLine }
    if let status { return SyncCopy.statusLine(status) }
    if let statusFailure { return SyncCopy.message(for: statusFailure, during: .status) }
    return SyncCopy.readingStatusLine
  }

  var stateLine: String? {
    watched.map {
      SyncCopy.stateLine($0.request, origin: $0.origin, presentationFolderID: folderID)
    }
  }

  // MARK: - Lifecycle

  /// The form appeared: read the shoot's status, and watch a run already active there.
  func start() async {
    await readStatus(observingActiveRun: true)
  }

  /// Sync now. A no-op unless `canSyncNow` — the button's `.disabled` is not the only guard.
  func syncNow() {
    guard canSyncNow else { return }
    isSubmitting = true
    epoch &+= 1
    notice = nil
    let requested = target
    submission = Task { await self.submit(requested) }
  }

  /// The form went away: the submission stops here, and its late answer is not acted on.
  func cancel() {
    submission?.cancel()
  }

  /// Watch the current request until it is terminal, then refresh the shoot's status once.
  /// Runs in the view's `.task(id:)`, so it ends when the form does.
  func poll() async {
    guard let first = watched else { return }
    let id = first.request.id
    var state = first.request.state
    while state.isActive {
      do {
        try await sleep(pollInterval)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      do {
        let next = try await service.request(id: id)
        guard !Task.isCancelled, watched?.request.id == id else { return }
        watched?.request = next
        state = next.state
      } catch let failure as SyncFailure {
        guard !Task.isCancelled, watched?.request.id == id else { return }
        notice = SyncCopy.message(for: failure, during: .read)
        return
      } catch {
        return
      }
    }
    guard !Task.isCancelled else { return }
    await readStatus(observingActiveRun: false)
  }

  // MARK: - Private

  private func submit(_ requested: SyncTarget) async {
    defer {
      lightroomClosed = false
      isSubmitting = false
    }
    do {
      let request = try await service.requestSync(target: requested)
      guard !Task.isCancelled else { return }
      watched = Watched(request: request, origin: .submitted)
    } catch SyncFailure.inProgress(let id) {
      guard !Task.isCancelled else { return }
      notice = SyncCopy.message(for: .inProgress(requestID: id), during: .create)
      await adopt(id, requested: requested)
    } catch let failure as SyncFailure {
      guard !Task.isCancelled else { return }
      notice = SyncCopy.message(for: failure, during: .create)
      // IMGMGR-641: this submission moved the epoch, so an opening status read still in
      // flight is dropped — and a failure leaves no watched run to refresh the status at its
      // end. Read it once more under the current epoch, unless a status (or its failure) is
      // already shown. A success and an adopted 409 leave that refresh to the watched run's
      // `poll()`.
      if status == nil, statusFailure == nil {
        await readStatus(observingActiveRun: false)
      }
    } catch {
      return
    }
  }

  /// A 409 names the overlapping run by id only: read it, and watch it with its REAL target.
  private func adopt(_ id: Int, requested: SyncTarget) async {
    do {
      let request = try await service.request(id: id)
      guard !Task.isCancelled else { return }
      watched = Watched(request: request, origin: .overlap(requested: requested))
    } catch is SyncFailure {
      guard !Task.isCancelled else { return }
      notice = SyncCopy.overlapUnreadable
    } catch {
      return
    }
  }

  private func readStatus(observingActiveRun: Bool) async {
    guard let folderID else { return }
    let startedUnder = epoch
    do {
      let read = try await service.status(folderID: folderID)
      guard !Task.isCancelled, epoch == startedUnder else { return }
      status = read
      statusFailure = nil
      if observingActiveRun, watched == nil, let latest = read.latest, latest.state.isActive {
        watched = Watched(request: latest, origin: .observed)
      }
    } catch let failure as SyncFailure {
      guard !Task.isCancelled, epoch == startedUnder else { return }
      statusFailure = failure
    } catch {
      return
    }
  }
}
