import Foundation

/// IMGMGR-650: the Looks strip's in-flight cap — at most `capacity` looked tile renders on the
/// wire at once (`GridStore.lookTile`), the rest waiting in arrival order (FIFO) and starting as
/// slots free. A strip opens every tile at once, and each is a server render, so without the cap
/// a dozen renders would race the loupe's own preview for the same server.
///
/// A slot is handed from a finishing render straight to the oldest waiter, so `inFlight` never
/// exceeds `capacity`. A waiter whose task is cancelled (its tile left the screen, its strip
/// closed) leaves the queue holding nothing: `acquire` answers false and the caller must not
/// `release`. Every `true` must be paired with exactly one `release` — the caller's `defer`.
@MainActor
final class LookTileSlots {
  private struct Waiter {
    let ticket: Int
    let continuation: CheckedContinuation<Bool, Never>
  }

  let capacity: Int
  /// The slots taken: renders on the wire, plus a slot just handed to a waiter that has not yet
  /// run.
  private(set) var inFlight = 0
  private var waiters: [Waiter] = []
  private var nextTicket = 0

  /// The renders waiting for a slot.
  var waitingCount: Int { waiters.count }

  init(capacity: Int) {
    self.capacity = capacity
  }

  /// Takes a slot, waiting for one when all are taken. False when the task was cancelled before
  /// it got one; it then holds no slot.
  func acquire() async -> Bool {
    if Task.isCancelled { return false }
    if inFlight < capacity, waiters.isEmpty {
      inFlight += 1
      return true
    }
    let ticket = nextTicket
    nextTicket += 1
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(Waiter(ticket: ticket, continuation: continuation))
      }
    } onCancel: {
      // The handler may run on any thread, and before the waiter is queued; the hop to the main
      // actor runs after this synchronous enqueue either way.
      Task { @MainActor in self.abandon(ticket) }
    }
  }

  /// Gives a slot back: to the oldest waiter when there is one (`inFlight` unchanged — the slot
  /// moves), else to the pool.
  func release() {
    guard !waiters.isEmpty else {
      inFlight = max(inFlight - 1, 0)
      return
    }
    waiters.removeFirst().continuation.resume(returning: true)
  }

  /// A cancelled waiter leaves the queue without a slot. One already handed a slot is not here
  /// any more: it got `true`, sees its own cancellation and releases.
  private func abandon(_ ticket: Int) {
    guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }
}
