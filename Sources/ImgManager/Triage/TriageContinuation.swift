import Foundation

/// WP31 P2 (IMGMGR-461), plan decision 6: how bringing a photograph into the loaded pool ended.
///
/// Four answers, kept apart: `.exhausted` (the active mode's cursor ran out without it — the id
/// is not in this scope) and `.budgetSpent` (the page budget ran out first — a known limit for
/// very large shoots, recorded rather than hidden) are both "not found", for different reasons;
/// `.unresolved` covers a failed page, a scope change and a load still outstanding when the
/// bounded wait expired.
enum ContinuationLookup: Equatable, Sendable {
  case found
  case exhausted
  case budgetSpent
  case unresolved
}

/// The primitives a grid pager exposes to `ContinuationLocator` — the same shape as
/// `SuccessorPager`, asked "is this photograph loaded" instead of "what follows it". `GridStore`
/// conforms through its flat and Scene adapters; a unit test conforms with a fake.
@MainActor
protocol ContinuationPager: AnyObject {
  /// Whether the loaded ACTIONABLE pool holds `imageID`.
  func holds(_ imageID: Int) -> Bool
  /// The cursor the next page would consume; nil once the pager is exhausted.
  var pagerCursor: String? { get }
  /// A page load is outstanding — whoever started it.
  var isPageLoadInFlight: Bool { get }
  /// Changes whenever the pool is replaced (a shoot, filter or mode change).
  var pagerGeneration: Int { get }
  /// Asks for the page after the loaded tail. May return without loading anything.
  func requestNextPage() async
}

/// Decision 6's paging rule, `SuccessorResolver`'s loop asked a different question: page with the
/// grid's own mode-aware pager until the photograph is loaded, the cursor is exhausted, or the
/// page budget is spent. A request counts only when it CONSUMED a page; a load already in flight
/// is waited for (bounded), never counted and never taken for the end.
enum ContinuationLocator {
  /// Decision 6: at most twenty pages per continuation.
  static let defaultPageBudget = 20

  @MainActor
  static func locate(
    imageID: Int, in pager: some ContinuationPager,
    pageBudget: Int = ContinuationLocator.defaultPageBudget,
    waitBudget: Int = SuccessorResolver.defaultWaitBudget,
    pause: (@MainActor () async -> Void)? = nil
  ) async -> ContinuationLookup {
    let generation = pager.pagerGeneration
    var waitsLeft = waitBudget
    var pagesConsumed = 0
    while true {
      guard pager.pagerGeneration == generation else { return .unresolved }
      if pager.holds(imageID) { return .found }
      if pager.isPageLoadInFlight {
        guard waitsLeft > 0 else { return .unresolved }
        waitsLeft -= 1
        if let pause {
          await pause()
        } else {
          try? await Task.sleep(for: .milliseconds(50))
        }
        continue
      }
      guard let cursor = pager.pagerCursor else { return .exhausted }
      guard pagesConsumed < pageBudget else { return .budgetSpent }
      await pager.requestNextPage()
      guard pager.pagerGeneration == generation else { return .unresolved }
      if pager.pagerCursor != cursor {
        pagesConsumed += 1
        continue
      }
      // Nothing consumed. A load now in flight is waited for at the top of the loop; a request
      // that neither loaded nor left a load outstanding failed, and that is not "not found".
      if !pager.isPageLoadInFlight { return .unresolved }
    }
  }
}

/// How one incoming continuation ended (decision 6). Only `.opened` opens anything; every other
/// outcome leaves the grid open on the shoot — never a wrong photograph.
enum ContinuationOutcome: Equatable, Sendable {
  case opened(imageID: Int)
  /// The shoot's cursor ran out without the photograph.
  case notFound
  /// Twenty pages were consumed without reaching the photograph.
  case budgetSpent
  /// A page failed, the wait expired, or the grid no longer shows the requested shoot.
  case unresolved
  /// A newer continuation arrived; this one stopped at its next step.
  case superseded
}

#if DEBUG
  extension ContinuationOutcome {
    /// The DEBUG probe's word for it (`debugProbe.continuation`) — Debug builds only, like its
    /// one caller.
    var probeValue: String {
      switch self {
      case .opened(let id): "opened-\(id)"
      case .notFound: "notFound"
      case .budgetSpent: "budgetSpent"
      case .unresolved: "unresolved"
      case .superseded: "superseded"
      }
    }
  }
#endif

/// A presented surface the receiving route has to see GONE before it opens anything.
enum TriagePresentedSurface: Hashable, Sendable {
  case triageCover
  case passSummarySheet
}

/// IMGMGR-501 review r2: one presentation of Triage's cover — its item, immutable, carrying the
/// gate generation its request was given.
struct TriagePresentation: Identifiable, Equatable, Sendable {
  let generation: Int
  var id: Int { generation }
}

/// Review rounds 1–2 (B1): dismissal COMPLETION, shared by every incoming route.
///
/// Clearing a presentation flag starts a dismissal; it does not finish one, and UIKit refuses a
/// new presentation while one is still animating. Elapsed time is not completion either. So a
/// surface is registered the moment its presentation is REQUESTED (`requested` — where the flag
/// or item that drives it is set), confirmed by its content's `onAppear` (`presented`, an
/// idempotent re-register), and settled by its presentation's own `onDismiss` (`dismissed`).
/// `settled()` returns only once nothing registered is left. A route that arrives while an
/// EARLIER route's dismissal is still animating, or while a presentation is still on its way in,
/// finds the flags already cleared but the surface still registered — and waits.
///
/// One fallback, so a route never waits forever: a presentation requested and then withdrawn
/// by a route before its content ever appeared may never present at all, and then no
/// `onDismiss` comes. `withdrawUnappeared()` settles exactly those after a bounded grace. A
/// surface that DID appear never takes the fallback; it waits for its `onDismiss`.
@MainActor
final class PresentationDismissalGate {
  /// Which path settled a surface — recorded for the tests and the DEBUG probe.
  enum Path: String, Sendable {
    case onDismiss
    case grace
  }

  struct Settlement: Equatable, Sendable {
    let surface: TriagePresentedSurface
    let path: Path
  }

  /// One presentation request of a surface, by generation. IMGMGR-501: a surface's requests
  /// queue in order, because one presentation of a surface can only follow the one before it.
  /// `requested` hands out the generation and the content's `onAppear` names it back
  /// (`presented(_:generation:)`), so whichever order a successor's `onAppear` and the
  /// outgoing presentation's `onDismiss` arrive in, the visible one is marked appeared. An
  /// `onDismiss` carries no identity, so review r2: the content's `onDisappear` names the
  /// generation that is LEAVING (`disappeared(_:generation:)`), and an `onDismiss` without a
  /// generation settles the oldest leaving request only — never one still on screen. A late
  /// `onDismiss` of a presentation that was replaced before it ever appeared finds nothing
  /// leaving and settles nothing.
  private struct Request {
    let generation: Int
    var appeared = false
    var withdrawn = false
    var graceArmed = false
    /// Review r3: the token of the disappearance in progress; nil while on screen. A
    /// reappearance clears it, so no earlier timer or late `onDismiss` settles it.
    var leavingToken: Int?
    var leaving: Bool { leavingToken != nil }
  }

  private var queues: [TriagePresentedSurface: [Request]] = [:]
  private var requestCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let grace: Duration
  private let sleep: @MainActor (Duration) async -> Void
  private let leavingGrace: Duration
  private var leavingCount = 0
  /// The latest settlements, newest last (a handful kept).
  private(set) var settlements: [Settlement] = []

  /// `grace` and `sleep` are the fallback's bound and its clock — a test injects both.
  /// `leavingGrace` bounds the wait for an `onDismiss` after its content's `onDisappear`, on the
  /// same clock, so a leaving presentation is settled even if its `onDismiss` never names it.
  init(
    grace: Duration = .milliseconds(1500),
    leavingGrace: Duration = .seconds(3),
    sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.grace = grace
    self.leavingGrace = leavingGrace
    self.sleep = sleep
  }

  var isSettled: Bool { queues.isEmpty }

  /// The presentation was asked for: registered before anything can appear. Returns the
  /// generation the presenting view hands back to `presented(_:generation:)`.
  ///
  /// Asking again while the newest request has not appeared (and was not withdrawn) is the same
  /// presentation and changes nothing; asking again after a withdrawal replaces the withdrawn
  /// request, voiding its grace. IMGMGR-501: asking again while the newest request IS on screen
  /// is a re-request — a new presentation queued behind it, with a generation of its own.
  @discardableResult
  func requested(_ surface: TriagePresentedSurface) -> Int {
    var queue = queues[surface] ?? []
    if let last = queue.last, !last.appeared {
      if !last.withdrawn { return last.generation }
      queue.removeLast()
    }
    requestCount += 1
    queue.append(Request(generation: requestCount))
    queues[surface] = queue
    return requestCount
  }

  /// The surface's content appeared (`onAppear`): from here only its `onDismiss` settles it.
  /// `generation` is the one the presenting view captured from `requested`; a generation no
  /// longer registered (its grace ran out before it appeared) is registered again, appeared —
  /// it is on screen. Without a generation (a caller that has none) the oldest unappeared
  /// request is marked while nothing has appeared, or one is registered when nothing is.
  func presented(_ surface: TriagePresentedSurface, generation: Int? = nil) {
    var queue = queues[surface] ?? []
    if let generation {
      if let index = queue.firstIndex(where: { $0.generation == generation }) {
        queue[index].appeared = true
        // Review r3: it is on screen again — no longer leaving, and its timer is void.
        queue[index].leavingToken = nil
      } else {
        queue.append(Request(generation: generation, appeared: true))
      }
    } else if !queue.contains(where: { $0.appeared }),
      let index = queue.firstIndex(where: { !$0.appeared })
    {
      queue[index].appeared = true
    } else if queue.isEmpty {
      requestCount += 1
      queue.append(Request(generation: requestCount, appeared: true))
    }
    queues[surface] = queue
  }

  /// The content of `generation` is leaving (`onDisappear`, the item's own generation): the
  /// next `onDismiss` without a generation settles it. Bounded by `leavingGrace`. A generation
  /// not registered is a no-op.
  func disappeared(_ surface: TriagePresentedSurface, generation: Int? = nil) {
    guard var queue = queues[surface] else { return }
    let found: Int?
    if let generation {
      found = queue.firstIndex(where: { $0.generation == generation })
    } else {
      found = queue.firstIndex(where: { $0.appeared && !$0.leaving })
    }
    guard let index = found, !queue[index].leaving else { return }
    leavingCount += 1
    let token = leavingCount
    queue[index].leavingToken = token
    queues[surface] = queue
    let leaving = queue[index].generation
    Task {
      await self.sleep(self.leavingGrace)
      self.leavingExpired(surface, generation: leaving, token: token)
    }
  }

  /// A surface's `onDismiss`: settles `generation`, or without one the oldest LEAVING request
  /// (`disappeared`). Nothing leaving, or a generation not registered: a no-op — a late
  /// `onDismiss` of a withdrawn predecessor never settles a presentation still on screen. Once
  /// the last surface is gone, every waiting route resumes. A withdrawn re-request queued
  /// behind the settled presentation starts its grace now.
  func dismissed(_ surface: TriagePresentedSurface, generation: Int? = nil) {
    guard var queue = queues[surface] else { return }
    let found: Int?
    if let generation {
      found = queue.firstIndex(where: { $0.generation == generation })
    } else {
      found = queue.firstIndex(where: { $0.leaving })
    }
    guard let index = found else { return }
    queue.remove(at: index)
    queues[surface] = queue.isEmpty ? nil : queue
    armReadyGraces(surface)
    record(surface, .onDismiss)
  }

  /// A route has just cleared the flags. Every request whose content never appeared is settled
  /// after the grace — unless it appears meanwhile, or is requested anew. Calling it again does
  /// not extend a grace already running. A re-request queued behind a presentation still on
  /// screen is marked withdrawn here; its grace starts once that presentation is gone.
  func withdrawUnappeared() {
    for surface in Array(queues.keys) {
      guard var queue = queues[surface] else { continue }
      for index in queue.indices where !queue[index].appeared {
        queue[index].withdrawn = true
      }
      queues[surface] = queue
      armReadyGraces(surface)
    }
  }

  /// Returns at once when nothing is registered; otherwise when the last surface is settled.
  func settled() async {
    guard !queues.isEmpty else { return }
    await withCheckedContinuation { continuation in
      self.waiters.append(continuation)
    }
  }

  /// Arms the grace of each withdrawn request with no appeared presentation in front of it.
  private func armReadyGraces(_ surface: TriagePresentedSurface) {
    guard var queue = queues[surface] else { return }
    for index in queue.indices {
      if queue[index].appeared { break }
      guard queue[index].withdrawn, !queue[index].graceArmed else { continue }
      queue[index].graceArmed = true
      let generation = queue[index].generation
      Task {
        await self.sleep(self.grace)
        self.graceExpired(surface, generation: generation)
      }
    }
    queues[surface] = queue
  }

  private func leavingExpired(_ surface: TriagePresentedSurface, generation: Int, token: Int) {
    guard var queue = queues[surface],
      let index = queue.firstIndex(where: {
        $0.generation == generation && $0.leavingToken == token
      })
    else { return }
    queue.remove(at: index)
    queues[surface] = queue.isEmpty ? nil : queue
    armReadyGraces(surface)
    record(surface, .grace)
  }

  private func graceExpired(_ surface: TriagePresentedSurface, generation: Int) {
    guard var queue = queues[surface],
      let index = queue.firstIndex(where: { $0.generation == generation }),
      !queue[index].appeared
    else { return }
    queue.remove(at: index)
    queues[surface] = queue.isEmpty ? nil : queue
    record(surface, .grace)
  }

  private func record(_ surface: TriagePresentedSurface, _ path: Path) {
    settlements.append(Settlement(surface: surface, path: path))
    if settlements.count > 8 { settlements.removeFirst() }
    #if DEBUG
      DebugProbe.shared.dismissal = "\(surface):\(path.rawValue)"
      DebugProbe.shared.recordRouteEvent("\(surface):\(path.rawValue)")
    #endif
    guard queues.isEmpty else { return }
    let resumed = waiters
    waiters = []
    for waiter in resumed { waiter.resume() }
  }
}

/// WP31 P2 (IMGMGR-461), plan decision 6: the receiving route of a Triage Handoff, in order —
/// (a) close Triage and any Pass Summary sheet (the pass ends without a summary; its marks are
/// already committed) and AWAIT that dismissal's completion (`PresentationDismissalGate`), (b)
/// open the shoot and AWAIT its load, then — only while still the newest route — show it, (c)
/// resolve the photograph by id, paging with the grid's own pager, and only then open the loupe
/// on it. At Compact the loupe opens, never Triage.
///
/// ONE function serves both entries — `.onContinueUserActivity` and the DEBUG
/// `-UITestContinueActivity` launch argument — and its steps are closures, so a unit test drives
/// the order with fakes (`ForegroundRefresh.run`'s posture). A newer route supersedes an older
/// one: `begin()` issues a ticket synchronously, at the moment the activity arrives, and a route
/// whose ticket is no longer the newest stops at its next step.
@MainActor
final class TriageContinuationRouter {
  private(set) var generation = 0

  /// Issues the ticket of the newest route, retiring every older one.
  func begin() -> Int {
    generation += 1
    return generation
  }

  func route(
    _ activity: TriageActivity,
    ticket: Int,
    dismissPresentations: () async -> Void,
    openShoot: (Int, GridSourceTier?) async -> Void,
    showShoot: (Int) -> Void,
    isShowingShoot: (Int, GridSourceTier?) -> Bool,
    locate: (Int) async -> ContinuationLookup,
    openLoupe: (Int) -> Void
  ) async -> ContinuationOutcome {
    guard ticket == generation else { return .superseded }
    await dismissPresentations()
    guard ticket == generation else { return .superseded }
    await openShoot(activity.folderID, activity.tier)
    guard ticket == generation else { return .superseded }
    // Review round 1: the navigation follows the ticket check, so a superseded route never moves
    // the tabs or the sidebar selection after a newer one did.
    showShoot(activity.folderID)
    guard isShowingShoot(activity.folderID, activity.tier) else { return .unresolved }
    let lookup = await locate(activity.imageID)
    guard ticket == generation else { return .superseded }
    switch lookup {
    case .found:
      // Re-checked after the paging await: a shoot change while it ran must not open this id
      // in another shoot's grid.
      guard isShowingShoot(activity.folderID, activity.tier) else { return .unresolved }
      openLoupe(activity.imageID)
      return .opened(imageID: activity.imageID)
    case .exhausted:
      return .notFound
    case .budgetSpent:
      return .budgetSpent
    case .unresolved:
      return .unresolved
    }
  }
}
