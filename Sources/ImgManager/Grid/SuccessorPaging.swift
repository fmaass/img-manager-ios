import Foundation

/// WP31 P1 (IMGMGR-460), plan decision 1: what "the photograph after this one" resolved to.
///
/// Three answers, never two: `.exhausted` is the server's word that nothing follows (the active
/// mode's cursor ran out), while `.unresolved` covers every way of NOT knowing — a failed page,
/// a scope change, a load still outstanding when the bounded wait expired. A caller that folded
/// the second into the first would end a pass at a loaded-page boundary.
enum SuccessorLookup: Equatable, Sendable {
  case found(Int)
  case exhausted
  case unresolved
}

/// Where a photograph sits in the loaded pool, asked before any paging.
enum LoadedSuccessor: Equatable, Sendable {
  /// The pool holds a photograph after it.
  case next(Int)
  /// It is the pool's last photograph.
  case tail
  /// It is not in the pool at all — paging cannot answer a question about it.
  case absent
}

/// The primitives a display-row pager exposes to `SuccessorResolver`. `GridStore` conforms
/// through a private Scene adapter; a unit test conforms with a fake that holds pages and an
/// in-flight state.
@MainActor
protocol SuccessorPager: AnyObject {
  func loadedSuccessor(after imageID: Int) -> LoadedSuccessor
  /// The cursor the next page would consume; nil once the pager is exhausted.
  var pagerCursor: String? { get }
  /// A page load is outstanding — whoever started it.
  var isPageLoadInFlight: Bool { get }
  /// Changes whenever the pool is replaced (a shoot, filter or mode change).
  var pagerGeneration: Int { get }
  /// Asks for the page after the loaded tail. May return without loading anything.
  func requestNextPage() async
}

/// Plan decision 1's paging rule, kept apart from `GridStore` so every branch is a unit test.
///
/// A request counts as progress only when it CONSUMED a page — the cursor changed or became nil.
/// A request that returned early because a load was already in flight is not progress: the
/// resolver waits for that load (bounded) and reads the pool again before deciding. A page that
/// adds no new actionable photograph (a collapsed scene card) is paged past. The end is declared
/// only when the cursor is exhausted with no successor loaded, never while a load is outstanding.
enum SuccessorResolver {
  /// How many waits for an outstanding load one resolution may spend (with the default pause,
  /// five seconds in all).
  static let defaultWaitBudget = 100
  /// A ceiling on consumed pages per resolution, against a server that never stops minting
  /// cursors. Spending it answers `.unresolved`, never `.exhausted`.
  static let defaultPageBudget = 50

  @MainActor
  static func resolve(
    after imageID: Int, in pager: some SuccessorPager,
    waitBudget: Int = SuccessorResolver.defaultWaitBudget,
    pageBudget: Int = SuccessorResolver.defaultPageBudget,
    pause: (@MainActor () async -> Void)? = nil
  ) async -> SuccessorLookup {
    let generation = pager.pagerGeneration
    var waitsLeft = waitBudget
    var pagesConsumed = 0
    while true {
      guard pager.pagerGeneration == generation else { return .unresolved }
      switch pager.loadedSuccessor(after: imageID) {
      case .next(let id): return .found(id)
      case .absent: return .unresolved
      case .tail: break
      }
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
      guard pagesConsumed < pageBudget else { return .unresolved }
      await pager.requestNextPage()
      guard pager.pagerGeneration == generation else { return .unresolved }
      if pager.pagerCursor != cursor {
        pagesConsumed += 1
        continue
      }
      // Nothing consumed. A load that is now in flight is waited for at the top of the loop; a
      // request that neither loaded nor left a load outstanding failed, and that is not the end.
      if !pager.isPageLoadInFlight { return .unresolved }
    }
  }
}

/// How one flat forward-neighbour fetch ended, as `SuccessorResolver.resolveFlat` reads it.
enum NeighbourAnswer: Equatable, Sendable {
  case merged
  /// The server's word that nothing follows.
  case exhausted
  case failed
}

/// Flat browse's primitives for Triage's successor: the loaded pool, the grid's own page-load
/// flag, and the loupe's forward-neighbour fetch.
@MainActor
protocol NeighbourPager: AnyObject {
  func loadedSuccessor(after imageID: Int) -> LoadedSuccessor
  /// A flat grid page load is outstanding.
  var isPageLoadInFlight: Bool { get }
  var pagerGeneration: Int { get }
  func fetchNeighbours(after imageID: Int) async -> NeighbourAnswer
}

extension SuccessorResolver {
  /// WP31 P1 review (B2): flat mode's successor for Triage, under the same fence as Scene
  /// paging. A grid page load outstanding before or after the neighbours fetch is waited for
  /// (bounded) and the pool re-read before the tail answer is trusted; the fetch itself runs at
  /// most once, so nothing spins. Wait expiry answers `.unresolved`, never `.exhausted`.
  @MainActor
  static func resolveFlat(
    after imageID: Int, in pager: some NeighbourPager,
    waitBudget: Int = SuccessorResolver.defaultWaitBudget,
    pause: (@MainActor () async -> Void)? = nil
  ) async -> SuccessorLookup {
    let generation = pager.pagerGeneration
    var waitsLeft = waitBudget
    var answer: NeighbourAnswer?
    while true {
      guard pager.pagerGeneration == generation else { return .unresolved }
      switch pager.loadedSuccessor(after: imageID) {
      case .next(let id): return .found(id)
      case .absent: return .unresolved
      case .tail: break
      }
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
      if let answer { return answer == .exhausted ? .exhausted : .unresolved }
      answer = await pager.fetchNeighbours(after: imageID)
    }
  }
}
