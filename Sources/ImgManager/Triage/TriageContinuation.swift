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

/// Review round 1 (B1): dismissal COMPLETION, shared by every incoming route.
///
/// Clearing a presentation flag starts a dismissal; it does not finish one, and UIKit refuses a
/// new presentation while one is still animating. Elapsed time is not completion either. So the
/// host reports each surface when it appears (its content's `onAppear`) and when it is gone (the
/// presentation's own `onDismiss`), and `settled()` returns only once nothing reported is still
/// on screen or on its way off it. A route that arrives while an EARLIER route's dismissal is
/// still animating finds the flags already cleared, but the surface still here — and waits for
/// the same completion.
@MainActor
final class PresentationDismissalGate {
  private var onScreen: Set<TriagePresentedSurface> = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isSettled: Bool { onScreen.isEmpty }

  func presented(_ surface: TriagePresentedSurface) {
    onScreen.insert(surface)
  }

  /// A surface's `onDismiss`. Once the last one is gone, every waiting route resumes. A surface
  /// that was never reported is a no-op.
  func dismissed(_ surface: TriagePresentedSurface) {
    onScreen.remove(surface)
    guard onScreen.isEmpty else { return }
    let resumed = waiters
    waiters = []
    for waiter in resumed { waiter.resume() }
  }

  /// Returns at once when nothing is on screen; otherwise when the last surface is dismissed.
  func settled() async {
    guard !onScreen.isEmpty else { return }
    await withCheckedContinuation { continuation in
      self.waiters.append(continuation)
    }
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
