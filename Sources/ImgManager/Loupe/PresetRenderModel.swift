import Foundation
import ImgManagerAPI
import Observation

/// One preset render row (`PresetRenderOut`), as this client reads it (IMGMGR-658). The lane's
/// own error text never reaches the client (the server does not echo it), so there is none here.
struct PresetRenderSnapshot: Equatable, Sendable {
  enum Status: Equatable, Sendable {
    case pending, rendering, ok, failed, evicted
  }

  let imageID: Int
  let presetID: String
  let generation: Int
  let status: Status
  /// Set when `ok`: the hash the file URL is bound to (`?v=`).
  let renderHash: String?
  /// The JPEG's byte count when `ok`, nil otherwise.
  let size: Int?

  init(
    imageID: Int, presetID: String, generation: Int, status: Status, renderHash: String?,
    size: Int? = nil
  ) {
    self.imageID = imageID
    self.presetID = presetID
    self.generation = generation
    self.status = status
    self.renderHash = renderHash
    self.size = size
  }

  init(_ row: Components.Schemas.PresetRenderOut) {
    let status: Status
    switch row.status {
    case .pending: status = .pending
    case .rendering: status = .rendering
    case .ok: status = .ok
    case .failed: status = .failed
    case .evicted: status = .evicted
    }
    self.init(
      imageID: row.imageId, presetID: row.presetId, generation: row.generation, status: status,
      renderHash: row.renderHash, size: row.size)
  }
}

/// What a preset request or status read failed with — this client's own vocabulary, never the
/// server's sentence. The 409 and 422 of the request route carry no documented body, so their
/// codes (`lane_image_not_local`/`lane_source_unavailable`, `unknown_preset`/
/// `lane_preset_unsupported_input`) are told apart by status only.
enum PresetRenderError: Error, Sendable, Equatable {
  /// 404: no such photograph, no render of this preset, or no lane provisioned.
  case gone
  /// 409: the original is another store's, missing or not yet hashed.
  case sourceUnavailable
  /// 422: not an active preset, or an original a preset cannot take (only ARW does).
  case unsupported
  /// Transport, an undeclared status or an undecodable body.
  case unreachable
}

/// What `GridService.presetRenderFile` answered.
enum PresetFileFetchResult: Equatable, Sendable {
  case ok(Data)
  /// The client's validator still names the render (URLCache revalidation).
  case notModified
  /// No `ok` render under this hash any more: evicted, or re-rendered under a new hash.
  case notFound
  /// The body ran past the byte cap; nothing past the cap was read.
  case tooLarge
}

/// The preset lane's fixed numbers (IMGMGR-658, plan Phase 4).
enum PresetRenderPlan {
  /// The status poll's period.
  static let pollInterval: Duration = .seconds(3)
  /// How long a render is polled before the chip offers "Check again".
  static let deadline: Duration = .seconds(180)
  /// The most of one full-size render this client reads, in the loupe or for a share. A 61 MP
  /// JPEG at high quality stays well under it.
  static let fileByteCap = 64 * 1024 * 1024
}

/// The poll's time source, injectable so tests run the 180 s deadline instantly.
struct PresetPollClock: Sendable {
  let now: @Sendable () -> ContinuousClock.Instant
  let sleep: @Sendable (Duration) async throws -> Void
  /// The deadline timer an in-flight request or status read races: it returns when the time it
  /// is given has run out, and is cancelled when the fetch answers first.
  let timeout: @Sendable (Duration) async throws -> Void

  init(
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    timeout: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    self.now = now
    self.sleep = sleep
    self.timeout = timeout
  }

  static let live = PresetPollClock(
    now: { ContinuousClock.now },
    sleep: { try await Task.sleep(for: $0) })
}

/// One preset render for the focused photograph (IMGMGR-658):
/// `idle → requested → pending → ok | failed | timedOut`.
///
/// Holds at most ONE target (photograph + preset). A new request, a focus change and a cancel
/// each bump `generation`; every await re-checks it, so a late answer for a photograph the loupe
/// moved away from never lands on the one it shows now — `GridService` maps a cancelled call to
/// `.unreachable`, so cancellation alone could not tell the two apart.
@Observable
@MainActor
final class PresetRenderModel {
  enum Failure: Equatable, Sendable {
    /// The lane reported the render failed.
    case renderFailed
    case unsupported
    case sourceUnavailable
    case gone
    case unreachable

    init(_ error: PresetRenderError) {
      switch error {
      case .gone: self = .gone
      case .sourceUnavailable: self = .sourceUnavailable
      case .unsupported: self = .unsupported
      case .unreachable: self = .unreachable
      }
    }

    var copy: String {
      switch self {
      case .renderFailed: "The preset couldn't be rendered for this photo."
      case .unsupported: "This preset can't render this photo. Presets take ARW originals only."
      case .sourceUnavailable: "The original isn't available to render from."
      case .gone: "This photo or preset is no longer available."
      case .unreachable: DegradedStateCopy.notConnected
      }
    }
  }

  enum Phase: Equatable, Sendable {
    case idle
    case requested
    case pending
    case ok(PresetRenderSnapshot)
    case failed(Failure)
    case timedOut
  }

  struct Target: Equatable, Sendable {
    let imageID: Int
    let presetID: String
  }

  /// One request or status read: the row, or why there is none.
  typealias Answer = Result<PresetRenderSnapshot, PresetRenderError>

  private(set) var target: Target?
  private(set) var phase: Phase = .idle
  /// Whether the loupe shows the render in place of the normal preview while it is `ok`.
  private(set) var showsPreset = false

  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  /// The hash whose file answered 404, so a render that keeps vanishing is re-requested once,
  /// not in a loop.
  @ObservationIgnored private var vanishedHash: String?

  private let request: @Sendable (Int, String) async throws -> PresetRenderSnapshot
  private let status: @Sendable (Int, String) async throws -> PresetRenderSnapshot
  private let clock: PresetPollClock
  private let interval: Duration
  private let deadline: Duration

  init(
    request: @escaping @Sendable (Int, String) async throws -> PresetRenderSnapshot,
    status: @escaping @Sendable (Int, String) async throws -> PresetRenderSnapshot,
    clock: PresetPollClock = .live,
    interval: Duration = PresetRenderPlan.pollInterval,
    deadline: Duration = PresetRenderPlan.deadline
  ) {
    self.request = request
    self.status = status
    self.clock = clock
    self.interval = interval
    self.deadline = deadline
  }

  /// The phase of `presetID` on `imageID`: `.idle` for anything but the current target.
  func phase(imageID: Int?, presetID: String) -> Phase {
    guard let target, target.imageID == imageID, target.presetID == presetID else { return .idle }
    return phase
  }

  /// The render the loupe paints in place of the preview, when there is one to show.
  func shownRender(imageID: Int?) -> PresetRenderSnapshot? {
    guard showsPreset, let target, target.imageID == imageID, case .ok(let render) = phase
    else { return nil }
    return render
  }

  /// A chip tap: request the render (POST) and poll it.
  func start(imageID: Int, presetID: String) {
    vanishedHash = nil
    begin(Target(imageID: imageID, presetID: presetID), post: true)
  }

  /// "Check again" after a timeout: read the status (no second POST, which would count a use)
  /// and poll for another deadline.
  func checkAgain() {
    guard let target, phase == .timedOut else { return }
    begin(target, post: false)
  }

  /// Toggles the overlay between the render and the normal preview; only while `ok`.
  func toggleOverlay() {
    guard case .ok = phase else { return }
    showsPreset.toggle()
  }

  /// The loupe moved to `imageID`. A render of any other photograph is abandoned, its poll
  /// cancelled, and nothing it answers later is applied.
  func focusChanged(to imageID: Int?) {
    guard let target, target.imageID != imageID else { return }
    cancel()
  }

  /// Abandons the target entirely (the loupe closed, or the focus moved).
  func cancel() {
    generation &+= 1
    task?.cancel()
    target = nil
    phase = .idle
    showsPreset = false
    vanishedHash = nil
  }

  /// Eviction before download: the `ok` render's file answered 404 — evicted, or replaced by a
  /// re-render — so the render is requested again (the server re-issues an evicted row). A
  /// hash that vanishes a second time fails instead of looping.
  func renderVanished(imageID: Int, presetID: String, renderHash: String) {
    guard let target, target == Target(imageID: imageID, presetID: presetID),
      case .ok(let render) = phase, render.renderHash == renderHash
    else { return }
    guard vanishedHash != renderHash else {
      generation &+= 1
      task?.cancel()
      phase = .failed(.gone)
      showsPreset = false
      return
    }
    vanishedHash = renderHash
    begin(target, post: true)
  }

  /// The share of `renderHash` found the render gone (IMGMGR-658 review): the `ok` this model
  /// holds is stale, so the target is dropped and the next tap on the preset requests again.
  func invalidate(imageID: Int, presetID: String, renderHash: String) {
    guard let target, target == Target(imageID: imageID, presetID: presetID),
      case .ok(let render) = phase, render.renderHash == renderHash
    else { return }
    cancel()
  }

  /// Waits for the running request/poll to end — for tests.
  func settle() async {
    await task?.value
  }

  private func begin(_ target: Target, post: Bool) {
    generation &+= 1
    task?.cancel()
    let token = generation
    self.target = target
    phase = post ? .requested : .pending
    showsPreset = false
    task = Task { await self.run(target, token: token, post: post) }
  }

  private func isCurrent(_ token: Int) -> Bool { token == generation }

  /// `fetch(_:reissue:)` raced against `remaining` on the clock's deadline timer, as two
  /// unstructured tasks: the first to finish answers and the other is cancelled, and a cancelled
  /// poll cancels both and answers nil at once. nil when the timer wins — at once, even when the
  /// fetch ignores its cancellation and never returns (IMGMGR-676: a task group would wait for
  /// it to drain). The abandoned fetch's late answer goes nowhere.
  private func fetch(_ target: Target, reissue: Bool, within remaining: Duration) async
    -> Answer?
  {
    let timeout = clock.timeout
    let race = PresetFetchRace()
    let fetcher = Task {
      let answer = await self.fetch(target, reissue: reissue)
      race.offer(answer)
    }
    let timer = Task {
      _ = try? await timeout(remaining)
      race.offer(nil)
    }
    let first = await withTaskCancellationHandler {
      await race.first()
    } onCancel: {
      race.offer(nil)
    }
    fetcher.cancel()
    timer.cancel()
    return first
  }

  /// One request (`reissue`) or status read, its error in this client's vocabulary.
  private func fetch(_ target: Target, reissue: Bool) async
    -> Result<PresetRenderSnapshot, PresetRenderError>
  {
    do {
      if reissue {
        return .success(try await request(target.imageID, target.presetID))
      }
      return .success(try await status(target.imageID, target.presetID))
    } catch let error as PresetRenderError {
      return .failure(error)
    } catch {
      return .failure(.unreachable)
    }
  }

  private func run(_ target: Target, token: Int, post: Bool) async {
    let end = clock.now().advanced(by: deadline)
    var reissue = post
    while true {
      // The deadline bounds the fetch itself, not only the sleeps between fetches, and it is
      // decided by the clock, not by which racer won: no fetch starts at or past it, and an
      // answer that arrives at or past it is dropped.
      let remaining = clock.now().duration(to: end)
      var answer: Answer?
      if remaining > .zero {
        answer = await fetch(target, reissue: reissue, within: remaining)
      }
      guard isCurrent(token) else { return }
      guard let answer, clock.now() < end else {
        phase = .timedOut
        return
      }
      let snapshot: PresetRenderSnapshot
      switch answer {
      case .success(let row):
        snapshot = row
      case .failure(let error) where error == .unreachable && phase != .requested:
        // A blip while polling is polled through; a definite answer ends the render.
        snapshot = PresetRenderSnapshot(
          imageID: target.imageID, presetID: target.presetID, generation: 0, status: .pending,
          renderHash: nil)
      case .failure(let error):
        phase = .failed(Failure(error))
        return
      }
      reissue = false
      switch snapshot.status {
      case .ok where snapshot.renderHash != nil:
        phase = .ok(snapshot)
        showsPreset = true
        return
      case .failed:
        phase = .failed(.renderFailed)
        return
      case .evicted:
        // An evicted row renders again only once it is re-issued.
        reissue = true
        phase = .pending
      case .ok, .pending, .rendering:
        phase = .pending
      }
      guard clock.now().advanced(by: interval) <= end else {
        phase = .timedOut
        return
      }
      do {
        try await clock.sleep(interval)
      } catch {
        return
      }
      guard isCurrent(token) else { return }
    }
  }
}

/// The first answer of `PresetRenderModel`'s fetch-versus-timer race (IMGMGR-676), delivered
/// exactly once: whichever offers first — the fetch, the timer, or the poll's cancellation —
/// resumes the waiting poll, and every later offer is dropped. A lock rather than an actor, so
/// the synchronous cancellation handler can offer too.
private final class PresetFetchRace: @unchecked Sendable {
  private enum State {
    case open
    case waiting(CheckedContinuation<PresetRenderModel.Answer?, Never>)
    case answered(PresetRenderModel.Answer?)
    case delivered
  }

  private let lock = NSLock()
  private var state = State.open

  /// The first offer, at once when it is already in.
  func first() async -> PresetRenderModel.Answer? {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock { () -> PresetRenderModel.Answer?? in
        guard case .answered(let answer) = state else {
          state = .waiting(continuation)
          return nil
        }
        state = .delivered
        return .some(answer)
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }

  /// Offers an answer (nil: the timer, or a cancelled poll); only the first offer counts.
  func offer(_ answer: PresetRenderModel.Answer?) {
    let waiting = lock.withLock { () -> CheckedContinuation<PresetRenderModel.Answer?, Never>? in
      switch state {
      case .open:
        state = .answered(answer)
        return nil
      case .waiting(let continuation):
        state = .delivered
        return continuation
      case .answered, .delivered:
        return nil
      }
    }
    waiting?.resume(returning: answer)
  }
}
