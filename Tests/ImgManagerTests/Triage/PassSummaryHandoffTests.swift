import Foundation
import Testing

@testable import ImgManager

/// A suspension a test controls (`TriageSessionTests`' gate).
@MainActor
private final class PassGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var isWaiting = false

  func wait() async {
    if released { return }
    isWaiting = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    isWaiting = false
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

/// A loaded pool with nothing behind it, a marker that can be suspended, and a one-slot undo.
@MainActor
private final class PassFakeStore: TriageStore {
  var pool: [TriagePoolEntry]
  var markGate: PassGate?
  var undoSlot: UndoEntry?

  init(ids: [Int]) {
    pool = ids.map { TriagePoolEntry(id: $0, isMarked: false) }
  }

  var triagePool: [TriagePoolEntry] { pool }

  func triageSuccessor(after imageID: Int) async -> SuccessorLookup {
    guard let index = pool.firstIndex(where: { $0.id == imageID }) else { return .unresolved }
    return pool.indices.contains(index + 1) ? .found(pool[index + 1].id) : .exhausted
  }

  func triageMark(_ state: MarkStateValue, imageID: Int) async -> TriageMarkOutcome {
    if let markGate { await markGate.wait() }
    let entry = UndoEntry(
      appliedState: state,
      priorStates: [PriorMarkSnapshot(imageID: imageID, state: .none, revisionBefore: "r")])
    undoSlot = entry
    return .committed(entry)
  }

  var triageUndoEntry: UndoEntry? { undoSlot }

  func triageUndo() async -> UndoOutcome {
    undoSlot = nil
    return .restoredAll
  }
}

@MainActor
private func displayAndDecide(_ session: TriageSession, _ verdict: TriageVerdict) async {
  if let cursor = session.cursor { session.didDisplay(cursor) }
  await session.decide(verdict)
}

/// Polls (bounded) until `condition` holds, so a suspended action is observed mid-flight.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() {
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
}

/// WP31 P2 (IMGMGR-461): the pass's own counts and the summary's presentation (plan decision 4).
@MainActor
@Suite("PassSummary — one pass's counts, net of undo")
struct PassSummaryTests {

  @Test("Pick, Dislike, Skip, Pick, Undo → picks 1, dislikes 1, skipped 1; cursor stays put")
  func countsAreNetOfUndo() async throws {
    let store = PassFakeStore(ids: [1, 2, 3, 4, 5, 6])
    let session = TriageSession(store: store)
    await displayAndDecide(session, .pick)
    await displayAndDecide(session, .dislike)
    await displayAndDecide(session, .skip)
    await displayAndDecide(session, .pick)
    #expect(session.canUndo)
    await session.undo()
    #expect(session.cursor == 4)

    let result = session.close()
    let summary = PassSummary(result: result)
    #expect(summary == PassSummary(picks: 1, dislikes: 1, skipped: 1))
    #expect(summary.marked == 2)

    let presentation = try #require(
      PassSummaryPresentation.make(
        result: result, folderID: 9, tier: .local, folderTitle: "Shoot", pool: [1, 2, 3, 4, 5, 6]))
    #expect(presentation.completed == false)
    #expect(presentation.summary == summary)
    let expected = TriageActivity(folderID: 9, tier: .local, imageID: 4, index: 4, completed: false)
    #expect(presentation.handoff == expected)
    #expect(PassSummaryCopy.title(completed: presentation.completed) == "Pass summary")
    #expect(PassSummaryCopy.marked(summary.marked) == "You marked 2 this pass")
  }

  @Test("A mark that commits after the pass closed is not counted (decision 7)")
  func lateCommitIsExcluded() async {
    let store = PassFakeStore(ids: [1, 2, 3])
    let gate = PassGate()
    store.markGate = gate
    let session = TriageSession(store: store)
    session.didDisplay(1)
    let pending = Task { await session.decide(.pick) }
    await waitUntil { gate.isWaiting }
    #expect(gate.isWaiting)

    let result = session.close()
    gate.release()
    await pending.value

    #expect(store.undoSlot != nil, "The late write did commit on the store.")
    #expect(PassSummary(result: result) == PassSummary(picks: 0, dislikes: 0, skipped: 0))
    #expect(session.result == result, "The closed pass's result changed after the late commit.")
    #expect(
      PassSummaryPresentation.make(
        result: result, folderID: 1, tier: nil, folderTitle: "", pool: [1, 2, 3]) == nil,
      "A pass with no completed action still produced a summary.")
  }

  @Test("No action → no summary; the pass just closes (decision 4)")
  func emptyPassHasNoSummary() {
    let session = TriageSession(store: PassFakeStore(ids: [1, 2]))
    let result = session.close()
    #expect(
      PassSummaryPresentation.make(
        result: result, folderID: 1, tier: nil, folderTitle: "", pool: [1, 2]) == nil)
  }

  @Test("Deciding the last photograph by Pick completes the pass at THAT photograph")
  func completedByPickCarriesTheFinalImage() async throws {
    let session = TriageSession(store: PassFakeStore(ids: [1, 2]))
    await displayAndDecide(session, .skip)
    await displayAndDecide(session, .pick)
    let result = try #require(session.result)
    #expect(result.completed)
    #expect(result.continuationImageID == 2)

    let presentation = try #require(
      PassSummaryPresentation.make(
        result: result, folderID: 1, tier: nil, folderTitle: "Shoot", pool: [1, 2]))
    #expect(presentation.summary == PassSummary(picks: 1, dislikes: 0, skipped: 1))
    let expected = TriageActivity(folderID: 1, tier: nil, imageID: 2, index: 2, completed: true)
    #expect(presentation.handoff == expected)
    #expect(PassSummaryCopy.title(completed: presentation.completed) == "Pass finished")
  }

  @Test("Deciding the last photograph by Skip completes the pass too")
  func completedBySkipCarriesTheFinalImage() async throws {
    let session = TriageSession(store: PassFakeStore(ids: [5]))
    await displayAndDecide(session, .skip)
    let result = try #require(session.result)
    let presentation = try #require(
      PassSummaryPresentation.make(
        result: result, folderID: 3, tier: .archive, folderTitle: "", pool: [5]))
    #expect(presentation.summary == PassSummary(picks: 0, dislikes: 0, skipped: 1))
    let expected = TriageActivity(
      folderID: 3, tier: .archive, imageID: 5, index: 1, completed: true)
    #expect(presentation.handoff == expected)
  }
}

/// WP31 P2 (IMGMGR-461): the Handoff payload — versioned, property-list only, refused whole when
/// it is not exactly what this build writes.
@MainActor
@Suite("TriageActivity — the Handoff payload")
struct TriageActivityTests {

  @Test("The declared type is the one project.yml lists under NSUserActivityTypes")
  func activityType() {
    #expect(TriageActivity.activityType == "live.discomarder.imgmanager.triage")
  }

  @Test("Round trip through userInfo, with and without the optional keys")
  func roundTrip() {
    let full = TriageActivity(
      folderID: 7, tier: .archive, imageID: 7015, index: 15, completed: true)
    #expect(TriageActivity(userInfo: full.userInfo) == full)
    #expect(full.userInfo[TriageActivity.Key.version] as? Int == 1)

    let bare = TriageActivity(folderID: 1, tier: nil, imageID: 5, index: nil, completed: false)
    #expect(TriageActivity(userInfo: bare.userInfo) == bare)
    #expect(bare.userInfo[TriageActivity.Key.tier] == nil)
    #expect(bare.userInfo[TriageActivity.Key.index] == nil)
  }

  @Test("Round trip through a configured NSUserActivity, eligible for Handoff")
  func configuredActivity() {
    let payload = TriageActivity(folderID: 1, tier: .local, imageID: 5, index: 5, completed: false)
    let activity = NSUserActivity(activityType: TriageActivity.activityType)
    payload.configure(activity)
    #expect(activity.isEligibleForHandoff)
    #expect(activity.webpageURL == nil)
    #expect(TriageActivity(userInfo: activity.userInfo) == payload)
    #expect(
      TriageActivity.probeDescription(
        source: "triage", type: activity.activityType, eligible: activity.isEligibleForHandoff,
        userInfo: activity.userInfo)
        == "source=triage;type=live.discomarder.imgmanager.triage;eligible=true;v=1;folderID=1;"
        + "tier=local;imageID=5;index=5;completed=false")
  }

  @Test("The launch argument's JSON decodes to the same payload")
  func jsonEntry() {
    let json = #"{"v":1,"folderID":7,"imageID":7015,"index":15,"completed":false}"#
    #expect(
      TriageActivity(userInfo: TriageActivity.userInfo(json: json))
        == TriageActivity(folderID: 7, tier: nil, imageID: 7015, index: 15, completed: false))
  }

  @Test(
    "Malformed or foreign payloads decode to nil",
    arguments: [
      "missing userInfo", "empty", "version 2", "no version", "no folderID", "no imageID",
      "no completed", "imageID as text", "completed as text", "unknown tier", "tier as number",
      "index zero", "folderID zero",
    ])
  func malformedPayloadIsRefused(_ name: String) {
    let base: [AnyHashable: Any] = ["v": 1, "folderID": 1, "imageID": 5, "completed": false]
    var info: [AnyHashable: Any]? = base
    switch name {
    case "missing userInfo": info = nil
    case "empty": info = [:]
    case "version 2": info?["v"] = 2
    case "no version": info?["v"] = nil
    case "no folderID": info?["folderID"] = nil
    case "no imageID": info?["imageID"] = nil
    case "no completed": info?["completed"] = nil
    case "imageID as text": info?["imageID"] = "5"
    case "completed as text": info?["completed"] = "no"
    case "unknown tier": info?["tier"] = "nowhere"
    case "tier as number": info?["tier"] = 3
    case "index zero": info?["index"] = 0
    case "folderID zero": info?["folderID"] = 0
    default: Issue.record("Unknown case \(name)")
    }
    #expect(TriageActivity(userInfo: info) == nil, "'\(name)' decoded.")
  }

  @Test("JSON that is not an object is refused", arguments: ["[1,2]", "not json", "", "7"])
  func malformedJSONIsRefused(_ json: String) {
    #expect(TriageActivity(userInfo: TriageActivity.userInfo(json: json)) == nil)
  }

  @Test("The probe says when a configured activity carries an undecodable payload")
  func probeOnUndecodable() {
    #expect(
      TriageActivity.probeDescription(
        source: "passSummary", type: "x", eligible: false, userInfo: ["v": 9])
        == "source=passSummary;type=x;eligible=false;payload=undecodable")
  }
}

/// A grid pager with loaded ids and pages behind it, an optional endless cursor, an in-flight
/// flag a test sets, and a hook that replaces what a request does.
@MainActor
private final class FakeContinuationPager: ContinuationPager {
  var loaded: Set<Int>
  var pages: [[Int]]
  var endless = false
  var inFlight = false
  var generation = 0
  var onRequest: (@MainActor () -> Void)?
  private var token = 0
  private(set) var requests = 0

  init(loaded: [Int], pages: [[Int]] = []) {
    self.loaded = Set(loaded)
    self.pages = pages
  }

  func holds(_ imageID: Int) -> Bool { loaded.contains(imageID) }
  var pagerCursor: String? { endless || !pages.isEmpty ? "c\(token)" : nil }
  var isPageLoadInFlight: Bool { inFlight }
  var pagerGeneration: Int { generation }

  func requestNextPage() async {
    requests += 1
    if let onRequest {
      onRequest()
      return
    }
    if !pages.isEmpty { loaded.formUnion(pages.removeFirst()) }
    token += 1
  }

  /// A page the GRID's own load delivered, not this pager's request.
  func deliverPageFromElsewhere() {
    inFlight = false
    if !pages.isEmpty { loaded.formUnion(pages.removeFirst()) }
    token += 1
  }
}

/// WP31 P2 (IMGMGR-461), plan decision 6: bringing a photograph into the loaded pool.
@MainActor
@Suite("ContinuationLocator — paging to a photograph by id")
struct ContinuationLocatorTests {

  @Test("Already loaded: found without a request")
  func foundWithoutPaging() async {
    let pager = FakeContinuationPager(loaded: [1, 2, 3], pages: [[4]])
    #expect(await ContinuationLocator.locate(imageID: 2, in: pager) == .found)
    #expect(pager.requests == 0)
  }

  @Test("Beyond the first page: pages until it is loaded")
  func foundAfterPaging() async {
    let pager = FakeContinuationPager(loaded: [1, 2], pages: [[3, 4], [5, 6]])
    #expect(await ContinuationLocator.locate(imageID: 5, in: pager) == .found)
    #expect(pager.requests == 2)
  }

  @Test("Cursor exhausted without it: exhausted, never found")
  func exhausted() async {
    let pager = FakeContinuationPager(loaded: [1], pages: [[2], [3]])
    #expect(await ContinuationLocator.locate(imageID: 99, in: pager) == .exhausted)
    #expect(pager.requests == 2)
  }

  @Test("A cursor that never ends: the page budget is spent, a distinct outcome")
  func budgetSpent() async {
    let pager = FakeContinuationPager(loaded: [1])
    pager.endless = true
    #expect(await ContinuationLocator.locate(imageID: 99, in: pager, pageBudget: 3) == .budgetSpent)
    #expect(pager.requests == 3)
    #expect(ContinuationLocator.defaultPageBudget == 20)
  }

  @Test("A load already in flight is waited for, not counted, not taken for the end")
  func inFlightLoadIsAwaited() async {
    let pager = FakeContinuationPager(loaded: [1], pages: [[2, 3]])
    pager.inFlight = true
    let result = await ContinuationLocator.locate(
      imageID: 3, in: pager, pageBudget: 0, pause: { pager.deliverPageFromElsewhere() })
    #expect(result == .found)
    #expect(pager.requests == 0)
  }

  @Test("The wait expiring while a load is outstanding is unresolved, not exhausted")
  func waitExpiry() async {
    let pager = FakeContinuationPager(loaded: [1])
    pager.inFlight = true
    var pauses = 0
    let result = await ContinuationLocator.locate(
      imageID: 9, in: pager, waitBudget: 2, pause: { pauses += 1 })
    #expect(result == .unresolved)
    #expect(pauses == 2)
  }

  @Test("A scope change mid-paging is unresolved")
  func generationChange() async {
    let pager = FakeContinuationPager(loaded: [1], pages: [[2]])
    pager.onRequest = { pager.generation += 1 }
    #expect(await ContinuationLocator.locate(imageID: 2, in: pager) == .unresolved)
  }

  @Test("A request that consumed nothing and left nothing in flight is unresolved")
  func failedRequest() async {
    let pager = FakeContinuationPager(loaded: [1], pages: [[2]])
    pager.onRequest = {}
    #expect(await ContinuationLocator.locate(imageID: 2, in: pager) == .unresolved)
    #expect(pager.requests == 1)
  }
}

/// The receiving side's steps, recorded in order. Triage and a Pass Summary can be "open".
@MainActor
private final class FakeContinuationHost {
  var events: [String] = []
  var triageOpen = false
  var summaryOpen = false
  var shownFolder: Int?
  var shownTier: GridSourceTier?
  var lookup: ContinuationLookup = .found
  /// Opens a different shoot than asked — the grid moved under the route.
  var opensOtherShoot = false
  var duringOpenShoot: (@MainActor () -> Void)?
  var duringLocate: (@MainActor () -> Void)?

  func run(
    _ router: TriageContinuationRouter, _ activity: TriageActivity, ticket: Int
  ) async -> ContinuationOutcome {
    await router.route(
      activity, ticket: ticket,
      dismissPresentations: {
        self.events.append("dismiss")
        self.triageOpen = false
        self.summaryOpen = false
      },
      openShoot: { folderID, tier in
        self.events.append("openShoot:\(folderID)")
        self.duringOpenShoot?()
        await Task.yield()
        self.shownFolder = self.opensOtherShoot ? folderID + 1 : folderID
        self.shownTier = tier
        self.events.append("loaded:\(folderID)")
      },
      isShowingShoot: { folderID, tier in
        self.shownFolder == folderID && self.shownTier == tier
      },
      locate: { imageID in
        self.events.append("locate:\(imageID)")
        self.duringLocate?()
        return self.lookup
      },
      openLoupe: { imageID in
        self.events.append(
          "openLoupe:\(imageID) triage=\(self.triageOpen) summary=\(self.summaryOpen)")
      })
  }
}

/// WP31 P2 (IMGMGR-461), plan decision 6: the receiving route's order and its fences.
@MainActor
@Suite("TriageContinuationRouter — the receiving route")
struct TriageContinuationRouterTests {
  private let activity = TriageActivity(
    folderID: 7, tier: .local, imageID: 7015, index: 15, completed: false)

  @Test("Dismiss → open shoot → await its load → resolve by id → open the loupe")
  func ordering() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    let outcome = await host.run(router, activity, ticket: router.begin())
    #expect(outcome == .opened(imageID: 7015))
    #expect(
      host.events == [
        "dismiss", "openShoot:7", "loaded:7", "locate:7015",
        "openLoupe:7015 triage=false summary=false",
      ])
  }

  @Test("Arriving while Triage and a Pass Summary are open: both close before anything opens")
  func arrivesWhileTriageIsOpen() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.triageOpen = true
    host.summaryOpen = true
    let outcome = await host.run(router, activity, ticket: router.begin())
    #expect(outcome == .opened(imageID: 7015))
    #expect(host.events.first == "dismiss")
    #expect(host.events.last == "openLoupe:7015 triage=false summary=false")
  }

  @Test("An older ticket does nothing at all")
  func staleTicketDoesNothing() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    let older = router.begin()
    _ = router.begin()
    #expect(await host.run(router, activity, ticket: older) == .superseded)
    #expect(host.events.isEmpty)
  }

  @Test("A newer arrival during the shoot's load supersedes: no lookup, no loupe")
  func supersededDuringLoad() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.duringOpenShoot = { _ = router.begin() }
    #expect(await host.run(router, activity, ticket: router.begin()) == .superseded)
    #expect(host.events == ["dismiss", "openShoot:7", "loaded:7"])
  }

  @Test("A newer arrival during paging supersedes: no loupe")
  func supersededDuringLocate() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.duringLocate = { _ = router.begin() }
    #expect(await host.run(router, activity, ticket: router.begin()) == .superseded)
    #expect(!host.events.contains { $0.hasPrefix("openLoupe") })
  }

  @Test("Not found, budget spent and unresolved are distinct outcomes, and none opens the loupe")
  func notFoundOutcomes() async {
    let cases: [(ContinuationLookup, ContinuationOutcome)] = [
      (.exhausted, .notFound), (.budgetSpent, .budgetSpent), (.unresolved, .unresolved),
    ]
    for (lookup, expected) in cases {
      let router = TriageContinuationRouter()
      let host = FakeContinuationHost()
      host.lookup = lookup
      #expect(await host.run(router, activity, ticket: router.begin()) == expected)
      #expect(!host.events.contains { $0.hasPrefix("openLoupe") }, "\(lookup) opened the loupe.")
      #expect(host.events.contains("loaded:7"), "The grid did not open on the shoot.")
    }
  }

  @Test("The grid showing another shoot after the load: unresolved, no lookup, no loupe")
  func otherShootIsNeverSearched() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.opensOtherShoot = true
    #expect(await host.run(router, activity, ticket: router.begin()) == .unresolved)
    #expect(!host.events.contains { $0.hasPrefix("locate") || $0.hasPrefix("openLoupe") })
  }
}
