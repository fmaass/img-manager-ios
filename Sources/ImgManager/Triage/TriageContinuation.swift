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

  /// The DEBUG probe's word for it (`debugProbe.continuation`).
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

/// WP31 P2 (IMGMGR-461), plan decision 6: the receiving route of a Triage Handoff, in order —
/// (a) close Triage and any Pass Summary sheet (the pass ends without a summary; its marks are
/// already committed), (b) open the shoot and AWAIT its load, (c) resolve the photograph by id,
/// paging with the grid's own pager, and only then open the loupe on it. At Compact the loupe
/// opens, never Triage.
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
    isShowingShoot: (Int, GridSourceTier?) -> Bool,
    locate: (Int) async -> ContinuationLookup,
    openLoupe: (Int) -> Void
  ) async -> ContinuationOutcome {
    guard ticket == generation else { return .superseded }
    await dismissPresentations()
    guard ticket == generation else { return .superseded }
    await openShoot(activity.folderID, activity.tier)
    guard ticket == generation else { return .superseded }
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
