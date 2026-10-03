#if DEBUG
  import Foundation

  /// DEBUG-ONLY, fixture-gated (`-UITestHoldPreviewOf <id>`), wrapped in `#if DEBUG` like
  /// `DebugStubTransport` — a Release/TestFlight archive contains none of it.
  ///
  /// IMGMGR-502 review r1: a held preview is released by the TEST, never by a timer. The fixture
  /// transport parks the named photograph's `preview`-tier answer here (`hold()`), and Triage's
  /// fixture-only "Release held preview" control (`TriageView.debugProbeElement`) opens the gate
  /// (`release()`). `release()` is one-way and also lets every LATER hold through.
  ///
  /// Review r2: a parked request whose task is CANCELLED (Triage went away before the release)
  /// leaves at once — its waiter is removed and resumed, and the held count drops — instead of
  /// staying suspended in this singleton until a release that may never come. Each waiter is
  /// keyed by its own id and every resume happens only after `removeValue(forKey:)` on this
  /// actor, so a cancel and a release can never resume the same continuation twice: whichever
  /// runs second finds nothing to remove.
  actor DebugPreviewHold {
    static let shared = DebugPreviewHold(publishesToProbe: true)

    /// Whether the held count is mirrored onto `DebugProbe.heldPreviews` for UI tests. Only the
    /// fixture's shared instance does; a unit test's own instance stays off the global probe.
    private let publishesToProbe: Bool
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// How many callers are inside `hold()` right now.
    private(set) var heldCount = 0
    /// How many continuations are parked right now — the handshake a unit test waits on before
    /// it cancels, so it cancels a hold that is really suspended (review r3).
    var waiterCount: Int { waiters.count }

    init(publishesToProbe: Bool = false) {
      self.publishesToProbe = publishesToProbe
    }

    /// Parks the caller until `release()`, or until its task is cancelled.
    func hold() async {
      guard !isReleased, !Task.isCancelled else { return }
      let id = UUID()
      heldCount += 1
      await publish(+1)
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          // Checked and stored in ONE actor turn: a release or a cancel that already happened
          // lets this through now; one that happens later finds the waiter under `id`.
          if isReleased || Task.isCancelled {
            continuation.resume()
          } else {
            waiters[id] = continuation
          }
        }
      } onCancel: {
        Task { await self.cancel(id) }
      }
      heldCount -= 1
      await publish(-1)
    }

    func release() {
      isReleased = true
      let parked = waiters
      waiters = [:]
      for waiter in parked.values { waiter.resume() }
    }

    private func cancel(_ id: UUID) {
      waiters.removeValue(forKey: id)?.resume()
    }

    /// Review r3: a DELTA applied on the main actor, never a captured count assigned there — two
    /// overlapping publications can land in either order and still sum to the right value.
    private func publish(_ delta: Int) async {
      guard publishesToProbe else { return }
      await MainActor.run { DebugProbe.shared.heldPreviews += delta }
    }
  }
#endif
