import Foundation
import Testing

@testable import ImgManager

/// A display-row pager with pages and an in-flight state the test controls. An empty page is a
/// page that held only a collapsed scene card: it consumes the cursor and adds no actionable
/// photograph.
@MainActor
private final class FakePager: SuccessorPager {
  var pool: [Int]
  var pages: [[Int]]
  var inFlight = false
  var generation = 0
  /// A request that neither loads nor leaves a load outstanding — a failed page.
  var failsRequests = false
  /// A request that replaces the pool — a scope change racing the page.
  var bumpsGenerationOnRequest = false
  private(set) var requestCalls = 0

  init(pool: [Int], pages: [[Int]]) {
    self.pool = pool
    self.pages = pages
  }

  func loadedSuccessor(after imageID: Int) -> LoadedSuccessor {
    guard let index = pool.firstIndex(of: imageID) else { return .absent }
    return pool.indices.contains(index + 1) ? .next(pool[index + 1]) : .tail
  }

  var pagerCursor: String? { pages.isEmpty ? nil : "cursor-\(pages.count)" }
  var isPageLoadInFlight: Bool { inFlight }
  var pagerGeneration: Int { generation }

  func requestNextPage() async {
    requestCalls += 1
    if bumpsGenerationOnRequest { generation += 1 }
    guard !inFlight, !failsRequests, !pages.isEmpty else { return }
    pool += pages.removeFirst()
  }
}

/// Flat browse for Triage: a pool, the grid's page-load flag, and a neighbours fetch whose answer
/// (and side effects) the test sets.
@MainActor
private final class FakeNeighbourPager: NeighbourPager {
  var pool: [Int]
  var inFlight = false
  var generation = 0
  var answer: NeighbourAnswer = .exhausted
  /// What a fetch appends to the pool before it answers.
  var fetchAppends: [Int] = []
  /// A fetch that leaves a grid page load outstanding — one started while it was on the wire.
  var fetchStartsALoad = false
  private(set) var fetchCalls = 0

  init(pool: [Int]) {
    self.pool = pool
  }

  func loadedSuccessor(after imageID: Int) -> LoadedSuccessor {
    guard let index = pool.firstIndex(of: imageID) else { return .absent }
    return pool.indices.contains(index + 1) ? .next(pool[index + 1]) : .tail
  }

  var isPageLoadInFlight: Bool { inFlight }
  var pagerGeneration: Int { generation }

  func fetchNeighbours(after imageID: Int) async -> NeighbourAnswer {
    fetchCalls += 1
    pool += fetchAppends
    if fetchStartsALoad { inFlight = true }
    return answer
  }
}

/// WP31 P1 (IMGMGR-460), plan decision 1: the Scene paging rule Triage's successor uses.
@MainActor
@Suite("SuccessorResolver — Scene paging for Triage's successor")
struct SuccessorResolverTests {

  @Test("A loaded successor is answered without paging")
  func loadedSuccessorNeedsNoPage() async {
    let pager = FakePager(pool: [1, 2], pages: [[3]])
    let result = await SuccessorResolver.resolve(after: 1, in: pager)
    #expect(result == .found(2))
    #expect(pager.requestCalls == 0)
  }

  @Test("A page holding only a collapsed card is paged past until a photograph arrives")
  func collapsedCardPageIsPagedAgain() async {
    let pager = FakePager(pool: [1], pages: [[], [], [7]])
    let result = await SuccessorResolver.resolve(after: 1, in: pager)
    #expect(result == .found(7))
    #expect(pager.requestCalls == 3)
  }

  @Test("The end is declared only once the cursor is exhausted")
  func exhaustedOnlyWhenTheCursorRunsOut() async {
    let pager = FakePager(pool: [1], pages: [[], []])
    let result = await SuccessorResolver.resolve(after: 1, in: pager)
    #expect(result == .exhausted)
    #expect(pager.requestCalls == 2)
  }

  @Test("A load already in flight is awaited, not counted, and not taken for the end")
  func inFlightLoadIsAwaited() async {
    // The cursor already reads nil while the outstanding load is still on the wire: deciding
    // "exhausted" here would end the pass one page early.
    let pager = FakePager(pool: [1], pages: [])
    pager.inFlight = true
    var pauses = 0
    let result = await SuccessorResolver.resolve(
      after: 1, in: pager,
      pause: {
        pauses += 1
        if pauses == 2 {
          pager.inFlight = false
          pager.pool.append(4)
        }
      })
    #expect(result == .found(4))
    #expect(pauses == 2)
    #expect(pager.requestCalls == 0, "A request was made while a load was in flight")
  }

  @Test("An awaited load that adds nothing is followed by a page of its own")
  func awaitedLoadWithNothingNewIsPagedAgain() async {
    let pager = FakePager(pool: [1], pages: [[5]])
    pager.inFlight = true
    let result = await SuccessorResolver.resolve(
      after: 1, in: pager,
      pause: { pager.inFlight = false })
    #expect(result == .found(5))
    #expect(pager.requestCalls == 1)
  }

  @Test("Wait expiry answers unresolved: no end declared and no tight retry")
  func waitExpiryNeitherCompletesNorSpins() async {
    let pager = FakePager(pool: [1], pages: [])
    pager.inFlight = true
    var pauses = 0
    let result = await SuccessorResolver.resolve(
      after: 1, in: pager, waitBudget: 5,
      pause: { pauses += 1 })
    #expect(result == .unresolved)
    #expect(pauses == 5)
    #expect(pager.requestCalls == 0)
  }

  @Test("A request that neither loads nor stays in flight is unresolved, asked once")
  func failedRequestIsUnresolved() async {
    let pager = FakePager(pool: [1], pages: [[2]])
    pager.failsRequests = true
    let result = await SuccessorResolver.resolve(after: 1, in: pager)
    #expect(result == .unresolved)
    #expect(pager.requestCalls == 1)
  }

  @Test("A scope change during a page is unresolved")
  func generationChangeIsUnresolved() async {
    let pager = FakePager(pool: [1], pages: [[2]])
    pager.bumpsGenerationOnRequest = true
    let result = await SuccessorResolver.resolve(after: 1, in: pager)
    #expect(result == .unresolved)
  }

  @Test("A photograph that is not in the pool is unresolved, never paged for")
  func absentImageIsUnresolved() async {
    let pager = FakePager(pool: [1], pages: [[2]])
    let result = await SuccessorResolver.resolve(after: 9, in: pager)
    #expect(result == .unresolved)
    #expect(pager.requestCalls == 0)
  }

  @Test("The page budget answers unresolved, never exhausted")
  func pageBudgetIsUnresolved() async {
    let pager = FakePager(pool: [1], pages: Array(repeating: [], count: 10))
    let result = await SuccessorResolver.resolve(after: 1, in: pager, pageBudget: 3)
    #expect(result == .unresolved)
    #expect(pager.requestCalls == 3)
  }

  // MARK: - Flat (review B2)

  @Test("Flat: an outstanding grid page is awaited and re-read before the tail answer")
  func flatInFlightPageIsAwaited() async {
    let pager = FakeNeighbourPager(pool: [1])
    pager.inFlight = true
    var pauses = 0
    let result = await SuccessorResolver.resolveFlat(
      after: 1, in: pager,
      pause: {
        pauses += 1
        if pauses == 2 {
          pager.inFlight = false
          pager.pool.append(2)
        }
      })
    #expect(result == .found(2))
    #expect(pauses == 2)
    #expect(pager.fetchCalls == 0, "The neighbours fetch ran while a page load was outstanding")
  }

  @Test("Flat: wait expiry is unresolved, with no fetch and no tight retry")
  func flatWaitExpiryIsUnresolved() async {
    let pager = FakeNeighbourPager(pool: [1])
    pager.inFlight = true
    var pauses = 0
    let result = await SuccessorResolver.resolveFlat(
      after: 1, in: pager, waitBudget: 5,
      pause: { pauses += 1 })
    #expect(result == .unresolved)
    #expect(pauses == 5)
    #expect(pager.fetchCalls == 0)
  }

  @Test("Flat: a page load that starts during the fetch is awaited before exhaustion")
  func flatLoadStartedDuringTheFetchIsAwaited() async {
    let pager = FakeNeighbourPager(pool: [1])
    pager.fetchStartsALoad = true
    let result = await SuccessorResolver.resolveFlat(
      after: 1, in: pager,
      pause: {
        pager.inFlight = false
        pager.pool.append(3)
      })
    #expect(result == .found(3))
    #expect(pager.fetchCalls == 1)
  }

  @Test("Flat: the server's empty answer is the end; a failure is not, and neither repeats")
  func flatTailAnswers() async {
    let ended = FakeNeighbourPager(pool: [1])
    let endedResult = await SuccessorResolver.resolveFlat(after: 1, in: ended)
    #expect(endedResult == .exhausted)
    #expect(ended.fetchCalls == 1)
    let failed = FakeNeighbourPager(pool: [1])
    failed.answer = .failed
    let failedResult = await SuccessorResolver.resolveFlat(after: 1, in: failed)
    #expect(failedResult == .unresolved)
    #expect(failed.fetchCalls == 1)
    let merged = FakeNeighbourPager(pool: [1])
    merged.answer = .merged
    merged.fetchAppends = [4]
    let mergedResult = await SuccessorResolver.resolveFlat(after: 1, in: merged)
    #expect(mergedResult == .found(4))
  }
}
