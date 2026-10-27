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

/// The first of two racers to finish wins, exactly once: the in-flight fetch (an answer) or the
/// deadline timer (nil). The loser is cancelled, and whatever it delivers later is dropped.
private final class PresetDeadlineRace: @unchecked Sendable {
  typealias Answer = Result<PresetRenderSnapshot, PresetRenderError>?

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Answer, Never>?
  private var racers: [Task<Void, Never>] = []

  init(_ continuation: CheckedContinuation<Answer, Never>) {
    self.continuation = continuation
  }

  func add(_ racer: Task<Void, Never>) {
    let finished = lock.withLock {
      guard continuation != nil else { return true }
      racers.append(racer)
      return false
    }
    if finished { racer.cancel() }
  }

  func finish(_ answer: Answer) {
    let (winner, losers) = lock.withLock {
      let taken = (continuation, racers)
      continuation = nil
      racers = []
      return taken
    }
    guard let winner else { return }
    losers.forEach { $0.cancel() }
    winner.resume(returning: answer)
  }
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
    task = nil
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

  /// `fetch(_:reissue:)` raced against `remaining` on the clock's deadline timer; nil when the
  /// timer wins.
  private func fetch(_ target: Target, reissue: Bool, within remaining: Duration) async
    -> Result<PresetRenderSnapshot, PresetRenderError>?
  {
    let timeout = clock.timeout
    return await withCheckedContinuation { continuation in
      let race = PresetDeadlineRace(continuation)
      race.add(Task { race.finish(await self.fetch(target, reissue: reissue)) })
      race.add(
        Task {
          guard (try? await timeout(remaining)) != nil else { return }
          race.finish(nil)
        })
    }
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
    let started = clock.now()
    var reissue = post
    while true {
      // The deadline bounds the fetch itself, not only the sleeps between fetches: a request
      // still on the wire when the time runs out is cancelled, and its late answer dropped.
      let remaining = deadline - started.duration(to: clock.now())
      guard remaining > .zero, let answer = await fetch(target, reissue: reissue, within: remaining)
      else {
        guard isCurrent(token) else { return }
        phase = .timedOut
        return
      }
      guard isCurrent(token) else { return }
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
      let elapsed = started.duration(to: clock.now())
      guard elapsed + interval <= deadline else {
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
