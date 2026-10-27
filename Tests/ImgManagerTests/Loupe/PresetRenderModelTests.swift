import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// A value behind a lock, shared between the test and the model's closures.
private final class PresetLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.withLock { body(&value) }
  }
}

/// A virtual clock: `sleep` advances `now` by the slept duration and returns at once, after
/// running the test's hook with the sleep's ordinal (1-based).
private final class PresetVirtualClock: Sendable {
  private let state = PresetLocked<(offset: Duration, sleeps: Int)>((.zero, 0))
  private let origin = ContinuousClock.now
  let onSleep: @Sendable (Int) async -> Void

  init(onSleep: @escaping @Sendable (Int) async -> Void = { _ in }) {
    self.onSleep = onSleep
  }

  var sleeps: Int { state.withLock { $0.sleeps } }

  var clock: PresetPollClock {
    PresetPollClock(
      now: { self.origin.advanced(by: self.state.withLock { $0.offset }) },
      sleep: { duration in
        let ordinal = self.state.withLock {
          $0.offset += duration
          $0.sleeps += 1
          return $0.sleeps
        }
        await self.onSleep(ordinal)
      })
  }
}

/// Answers a scripted sequence of status reads; the last answer repeats.
private final class PresetScript: Sendable {
  private let state: PresetLocked<(answers: [PresetRenderSnapshot.Status], reads: Int, posts: Int)>

  init(_ answers: [PresetRenderSnapshot.Status]) {
    state = PresetLocked((answers, 0, 0))
  }

  var reads: Int { state.withLock { $0.reads } }
  var posts: Int { state.withLock { $0.posts } }

  func next(post: Bool, imageID: Int, presetID: String) -> PresetRenderSnapshot {
    let status = state.withLock { value in
      if post { value.posts += 1 } else { value.reads += 1 }
      let index = min(value.reads + value.posts - 1, value.answers.count - 1)
      return value.answers[index]
    }
    return PresetRenderSnapshot(
      imageID: imageID, presetID: presetID, generation: 1, status: status,
      renderHash: status == .ok ? "hash-\(imageID)" : nil)
  }
}

/// IMGMGR-658: `PresetRenderModel`'s transitions — `idle → requested → pending → ok | failed |
/// timedOut` — run on a virtual clock, so the 3 s poll and the 180 s deadline cost nothing.
@MainActor
@Suite("Preset render model (IMGMGR-658)")
struct PresetRenderModelTests {
  private func model(_ script: PresetScript, clock: PresetVirtualClock) -> PresetRenderModel {
    PresetRenderModel(
      request: { script.next(post: true, imageID: $0, presetID: $1) },
      status: { script.next(post: false, imageID: $0, presetID: $1) },
      clock: clock.clock)
  }

  @Test("A tap is requested at once; pending polls every 3 s until ok")
  func requestedPendingOk() async {
    let script = PresetScript([.pending, .rendering, .pending, .ok])
    let clock = PresetVirtualClock()
    let model = model(script, clock: clock)
    #expect(model.phase == .idle)

    model.start(imageID: 1, presetID: "p")
    #expect(model.phase == .requested)
    #expect(model.phase(imageID: 1, presetID: "p") == .requested)
    #expect(model.phase(imageID: 1, presetID: "other") == .idle)
    await model.settle()

    guard case .ok(let render) = model.phase else {
      Issue.record("expected .ok, got \(model.phase)")
      return
    }
    #expect(render.renderHash == "hash-1")
    #expect(script.posts == 1)
    #expect(script.reads == 3)
    #expect(clock.sleeps == 3)
    #expect(model.shownRender(imageID: 1) == render)
    model.toggleOverlay()
    #expect(model.shownRender(imageID: 1) == nil)
    model.toggleOverlay()
    #expect(model.shownRender(imageID: 1) == render)
  }

  @Test("The pending phase is observable between polls")
  func pendingBetweenPolls() async {
    let seen = PresetLocked<[PresetRenderModel.Phase]>([])
    let script = PresetScript([.pending, .ok])
    let holder = PresetLocked<PresetRenderModel?>(nil)
    let clock = PresetVirtualClock { _ in
      let model = holder.withLock { $0 }
      let phase = await MainActor.run { model?.phase }
      if let phase { seen.withLock { $0.append(phase) } }
    }
    let model = model(script, clock: clock)
    holder.withLock { $0 = model }
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    #expect(seen.withLock { $0 } == [.pending])
  }

  @Test("A lane failure fails the render; its copy is what the long-press shows")
  func failed() async {
    let model = model(PresetScript([.pending, .failed]), clock: PresetVirtualClock())
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    #expect(model.phase == .failed(.renderFailed))
    #expect(!PresetRenderModel.Failure.renderFailed.copy.isEmpty)
  }

  @Test(
    "A refused request fails at once with its reason",
    arguments: [
      (PresetRenderError.unsupported, PresetRenderModel.Failure.unsupported),
      (.sourceUnavailable, .sourceUnavailable), (.gone, .gone), (.unreachable, .unreachable),
    ])
  func refusedRequest(error: PresetRenderError, failure: PresetRenderModel.Failure) async {
    let model = PresetRenderModel(
      request: { _, _ in throw error }, status: { _, _ in throw error },
      clock: PresetVirtualClock().clock)
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    #expect(model.phase == .failed(failure))
  }

  @Test("Still pending at 180 s times out after 60 polls; Check again polls without a POST")
  func timeoutThenCheckAgain() async {
    let script = PresetScript([.pending])
    let clock = PresetVirtualClock()
    let model = model(script, clock: clock)
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    #expect(model.phase == .timedOut)
    // 59 reads at 3…177 s; the 60th sleep reaches 180 s, where no fetch may start.
    #expect(clock.sleeps == 60)
    #expect(script.reads == 59)
    #expect(script.posts == 1)

    model.checkAgain()
    #expect(model.phase == .pending)
    await model.settle()
    #expect(model.phase == .timedOut)
    #expect(script.posts == 1)
    #expect(script.reads == 119)
  }

  @Test(
    "The deadline bounds an in-flight fetch: the timer at 180 s wins, the stalled ok is dropped",
    .timeLimit(.minutes(1)))
  func deadlineBoundsAStalledFetch() async {
    let timedFor = PresetLocked<[Duration]>([])
    let delivered = PresetLocked(false)
    let clock = PresetPollClock(
      now: { ContinuousClock.now }, sleep: { _ in },
      timeout: { duration in timedFor.withLock { $0.append(duration) } })
    let model = PresetRenderModel(
      request: { imageID, presetID in
        try? await Task.sleep(for: .seconds(3600))
        delivered.withLock { $0 = true }
        return PresetRenderSnapshot(
          imageID: imageID, presetID: presetID, generation: 1, status: .ok, renderHash: "late")
      },
      status: { _, _ in throw PresetRenderError.gone },
      clock: clock)

    model.start(imageID: 1, presetID: "p")
    await model.settle()

    #expect(model.phase == .timedOut)
    #expect((timedFor.withLock { $0.first } ?? .zero) > .seconds(179))
    // The task group waited for the cancelled fetch, which answered ok on its way out.
    #expect(delivered.withLock { $0 })
    #expect(model.phase == .timedOut)
    #expect(model.shownRender(imageID: 1) == nil)
  }

  @Test(
    "A fetch that answers after the clock passed the deadline times out, the timer not fired",
    .timeLimit(.minutes(1)))
  func answerPastTheDeadlineIsDropped() async {
    let offset = PresetLocked(Duration.zero)
    let origin = ContinuousClock.now
    let clock = PresetPollClock(
      now: { origin.advanced(by: offset.withLock { $0 }) }, sleep: { _ in },
      timeout: { _ in try await Task.sleep(for: .seconds(3600)) })
    let model = PresetRenderModel(
      request: { imageID, presetID in
        offset.withLock { $0 = .seconds(181) }
        return PresetRenderSnapshot(
          imageID: imageID, presetID: presetID, generation: 1, status: .ok, renderHash: "late")
      },
      status: { _, _ in throw PresetRenderError.gone },
      clock: clock)

    model.start(imageID: 1, presetID: "p")
    await model.settle()

    #expect(model.phase == .timedOut)
    #expect(model.shownRender(imageID: 1) == nil)
  }

  @Test(
    "A cancelled poll cancels its stalled fetch and returns at once, changing nothing",
    .timeLimit(.minutes(1)))
  func cancelledPollCancelsTheFetch() async {
    let entered = PresetLocked(false)
    let sawCancel = PresetLocked(false)
    let clock = PresetPollClock(
      now: { ContinuousClock.now }, sleep: { _ in },
      timeout: { _ in try await Task.sleep(for: .seconds(3600)) })
    let model = PresetRenderModel(
      request: { imageID, presetID in
        entered.withLock { $0 = true }
        do {
          try await Task.sleep(for: .seconds(3600))
        } catch {
          sawCancel.withLock { $0 = true }
        }
        return PresetRenderSnapshot(
          imageID: imageID, presetID: presetID, generation: 1, status: .ok, renderHash: "late")
      },
      status: { _, _ in throw PresetRenderError.gone },
      clock: clock)

    model.start(imageID: 1, presetID: "p")
    while !entered.withLock({ $0 }) { await Task.yield() }
    model.focusChanged(to: 2)
    await model.settle()

    #expect(sawCancel.withLock { $0 })
    #expect(model.phase == .idle)
    #expect(model.target == nil)
    for _ in 0..<10 { await Task.yield() }
    #expect(model.phase == .idle)
    #expect(model.shownRender(imageID: 1) == nil)
  }

  @Test("A focus change while polling cancels the poll; the late ok never lands")
  func focusChangeDuringPolling() async {
    let holder = PresetLocked<PresetRenderModel?>(nil)
    let script = PresetScript([.pending, .pending, .ok])
    let clock = PresetVirtualClock { ordinal in
      guard ordinal == 1 else { return }
      let model = holder.withLock { $0 }
      await MainActor.run { model?.focusChanged(to: 2) }
    }
    let model = model(script, clock: clock)
    holder.withLock { $0 = model }
    model.start(imageID: 1, presetID: "p")
    await model.settle()

    #expect(model.phase == .idle)
    #expect(model.target == nil)
    #expect(model.phase(imageID: 2, presetID: "p") == .idle)
    #expect(model.shownRender(imageID: 2) == nil)
    #expect(clock.sleeps == 1)
    #expect(script.reads == 0)
  }

  @Test("A focus change to the same photograph keeps the render")
  func sameFocusKeeps() async {
    let model = model(PresetScript([.ok]), clock: PresetVirtualClock())
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    model.focusChanged(to: 1)
    #expect(model.phase(imageID: 1, presetID: "p") != .idle)
  }

  @Test("An evicted row is re-issued with a POST and polled to ok")
  func evictedIsReissued() async {
    let script = PresetScript([.pending, .evicted, .pending, .ok])
    let model = model(script, clock: PresetVirtualClock())
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    #expect(script.posts == 2)
    guard case .ok = model.phase else {
      Issue.record("expected .ok, got \(model.phase)")
      return
    }
  }

  @Test("Eviction before download: a vanished file re-requests once, then fails")
  func vanishedRenderReRequestsOnce() async {
    let script = PresetScript([.ok])
    let model = model(script, clock: PresetVirtualClock())
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    model.renderVanished(imageID: 1, presetID: "p", renderHash: "hash-1")
    #expect(model.phase == .requested)
    await model.settle()
    #expect(script.posts == 2)
    model.renderVanished(imageID: 1, presetID: "p", renderHash: "hash-1")
    #expect(model.phase == .failed(.gone))
    #expect(script.posts == 2)
  }

  @Test("A vanished file of another target or hash changes nothing")
  func vanishedOtherIgnored() async {
    let model = model(PresetScript([.ok]), clock: PresetVirtualClock())
    model.start(imageID: 1, presetID: "p")
    await model.settle()
    let before = model.phase
    model.renderVanished(imageID: 1, presetID: "p", renderHash: "stale")
    model.renderVanished(imageID: 2, presetID: "p", renderHash: "hash-1")
    #expect(model.phase == before)
  }
}
