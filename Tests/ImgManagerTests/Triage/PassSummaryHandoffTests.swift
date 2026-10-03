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

/// Polls (bounded) until `condition` holds, so a suspended action is observed mid-flight. Stops
/// at once when the test's task is cancelled.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() {
    if Task.isCancelled { return }
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
    #if DEBUG
      #expect(
        TriageActivity.probeDescription(
          source: "triage", type: activity.activityType, eligible: activity.isEligibleForHandoff,
          userInfo: activity.userInfo)
          == "source=triage;type=live.discomarder.imgmanager.triage;eligible=true;v=1;"
          + "folderID=1;tier=local;imageID=5;index=5;completed=false")
    #endif
  }

  #if DEBUG
    @Test("The launch argument's JSON decodes to the same payload")
    func jsonEntry() {
      let json = #"{"v":1,"folderID":7,"imageID":7015,"index":15,"completed":false}"#
      #expect(
        TriageActivity(userInfo: TriageActivity.userInfo(json: json))
          == TriageActivity(folderID: 7, tier: nil, imageID: 7015, index: 15, completed: false))
    }

    /// Review round 1 (B2): JSON's `true`/`false` arrive as Boolean NSNumbers, which `as? Int`
    /// would read as 1/0 — and an integer NSNumber `as? Bool` would read as a Boolean.
    @Test(
      "JSON: a Boolean where an integer belongs, or an integer where a Boolean belongs, is refused",
      arguments: [
        #"{"v":true,"folderID":7,"imageID":7015,"completed":false}"#,
        #"{"v":1,"folderID":true,"imageID":7015,"completed":false}"#,
        #"{"v":1,"folderID":7,"imageID":true,"completed":false}"#,
        #"{"v":1,"folderID":7,"imageID":7015,"index":true,"completed":false}"#,
        #"{"v":1,"folderID":7,"imageID":7015,"completed":1}"#,
        #"{"v":1,"folderID":7,"imageID":7015,"completed":0}"#,
      ])
    func jsonBooleanIdentity(_ json: String) {
      #expect(TriageActivity(userInfo: TriageActivity.userInfo(json: json)) == nil, "\(json)")
    }
  #endif

  /// Review round 1 (B2): the same identity through a property-list-style dictionary of
  /// NSNumbers — what a Handoff's `userInfo` is once it has crossed devices.
  @Test(
    "Property list: a Boolean NSNumber for an integer, or an integer for a Boolean, is refused",
    arguments: ["v", "folderID", "imageID", "index", "completed 1", "completed 0"])
  func plistBooleanIdentity(_ name: String) {
    var info = Self.plistPayload
    switch name {
    case "completed 1": info[TriageActivity.Key.completed] = NSNumber(value: 1)
    case "completed 0": info[TriageActivity.Key.completed] = NSNumber(value: 0)
    default: info[name] = NSNumber(value: true)
    }
    #expect(TriageActivity(userInfo: info) == nil, "'\(name)' decoded.")
  }

  @Test("Property list: integer NSNumbers and a Boolean NSNumber decode")
  func plistNumbersDecode() {
    var info = Self.plistPayload
    info[TriageActivity.Key.completed] = NSNumber(value: true)
    let expected = TriageActivity(
      folderID: 7, tier: nil, imageID: 7015, index: 15, completed: true)
    #expect(TriageActivity(userInfo: info) == expected)
    #expect(TriageActivity(userInfo: Self.plistPayload)?.completed == false)
  }

  /// Computed, not stored: `[AnyHashable: Any]` is not `Sendable`, so a stored static would be
  /// refused under Swift 6.
  private static var plistPayload: [AnyHashable: Any] {
    [
      TriageActivity.Key.version: NSNumber(value: 1),
      TriageActivity.Key.folderID: NSNumber(value: 7),
      TriageActivity.Key.imageID: NSNumber(value: 7015),
      TriageActivity.Key.index: NSNumber(value: 15),
      TriageActivity.Key.completed: NSNumber(value: false),
    ]
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

  #if DEBUG
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
  #endif
}

/// Review round 3: the advertising side — the activity is built, held and made current
/// explicitly, never through SwiftUI's `.userActivity` update closure.
@MainActor
@Suite("TriageActivityAdvertiser — the activity made current")
struct TriageActivityAdvertiserTests {
  private func payload(_ session: TriageSession, pool: [Int]) -> TriageActivity? {
    TriageActivity.advertised(
      folderID: 1, tier: .local, imageID: session.continuationImageID, pool: pool,
      completed: session.completed)
  }

  @Test("An open pass: current, eligible, decoding to the cursor; a new position reuses it")
  func openPassFollowsTheCursor() async throws {
    let session = TriageSession(store: PassFakeStore(ids: [1, 2, 3]))
    let advertiser = TriageActivityAdvertiser(source: "triage", currency: TriageActivityCurrency())
    await displayAndDecide(session, .skip)
    advertiser.advertise(payload(session, pool: [1, 2, 3]))

    let activity = try #require(advertiser.activity)
    #expect(advertiser.isCurrent)
    #expect(activity.activityType == TriageActivity.activityType)
    #expect(activity.isEligibleForHandoff)
    let atTwo = TriageActivity(folderID: 1, tier: .local, imageID: 2, index: 2, completed: false)
    #expect(TriageActivity(userInfo: activity.userInfo) == atTwo)

    await displayAndDecide(session, .skip)
    advertiser.advertise(payload(session, pool: [1, 2, 3]))
    #expect(advertiser.activity === activity, "A new position made a second activity.")
    let atThree = TriageActivity(
      folderID: 1, tier: .local, imageID: 3, index: 3, completed: false)
    #expect(TriageActivity(userInfo: activity.userInfo) == atThree)

    advertiser.end()
    #expect(!advertiser.isCurrent)
    #expect(advertiser.activity == nil)
  }

  @Test("A finished pass: the summary's activity carries the final photograph, completed")
  func finishedPassIsCompleted() async throws {
    let session = TriageSession(store: PassFakeStore(ids: [1, 2]))
    await displayAndDecide(session, .skip)
    await displayAndDecide(session, .pick)
    let result = try #require(session.result)
    let presentation = try #require(
      PassSummaryPresentation.make(
        result: result, folderID: 1, tier: .local, folderTitle: "", pool: [1, 2]))
    let advertiser = TriageActivityAdvertiser(
      source: "passSummary", currency: TriageActivityCurrency())
    advertiser.advertise(presentation.handoff)

    let activity = try #require(advertiser.activity)
    #expect(advertiser.isCurrent)
    let finished = TriageActivity(
      folderID: 1, tier: .local, imageID: 2, index: 2, completed: true)
    #expect(TriageActivity(userInfo: activity.userInfo) == finished)

    advertiser.end()
    #expect(!advertiser.isCurrent)
    #expect(advertiser.activity == nil)
  }

  @Test("Nothing to continue resigns; ending twice is harmless")
  func nilPayloadResigns() {
    let advertiser = TriageActivityAdvertiser(source: "triage", currency: TriageActivityCurrency())
    advertiser.advertise(
      TriageActivity(folderID: 1, tier: nil, imageID: 5, index: nil, completed: false))
    #expect(advertiser.isCurrent)
    advertiser.advertise(nil)
    #expect(!advertiser.isCurrent)
    #expect(advertiser.activity == nil)
    advertiser.end()
    #expect(!advertiser.isCurrent)
  }

  /// IMGMGR-501: the Triage-to-Summary handover, Triage's content going FIRST — the pass ended
  /// (its advertiser resigned) before the sheet appeared. The sheet's activity is a fresh one:
  /// the resigned activity was invalidated and can never be made current again.
  @Test("Handover, Triage disappears first: the summary's activity is current, and it is new")
  func handoverTriageDisappearsFirst() throws {
    let currency = TriageActivityCurrency()
    let triage = TriageActivityAdvertiser(source: "triage", currency: currency)
    let summary = TriageActivityAdvertiser(source: "passSummary", currency: currency)
    let atTwo = TriageActivity(folderID: 1, tier: .local, imageID: 2, index: 2, completed: false)
    let finished = TriageActivity(
      folderID: 1, tier: .local, imageID: 3, index: 3, completed: true)

    triage.advertise(atTwo)
    let resigned = try #require(triage.activity)
    triage.end()
    #expect(currency.activity == nil, "Triage's end left its activity current.")

    summary.advertise(finished)
    let current = try #require(currency.activity, "No activity is current after the handover.")
    #expect(current !== resigned, "The invalidated activity was made current again.")
    #expect(summary.isCurrent)
    #expect(!triage.isCurrent)
    #expect(TriageActivity(userInfo: current.userInfo) == finished)
  }

  /// IMGMGR-501: the same handover with the sheet's content appearing FIRST, Triage's
  /// disappearing after it. Triage's late `end()` must not resign the activity the summary
  /// made current — one activity, current throughout, carrying the summary's payload.
  @Test("Handover, the summary appears first: Triage's late end resigns nothing")
  func handoverSummaryAppearsFirst() throws {
    let currency = TriageActivityCurrency()
    let triage = TriageActivityAdvertiser(source: "triage", currency: currency)
    let summary = TriageActivityAdvertiser(source: "passSummary", currency: currency)
    let atTwo = TriageActivity(folderID: 1, tier: .local, imageID: 2, index: 2, completed: false)
    let finished = TriageActivity(
      folderID: 1, tier: .local, imageID: 3, index: 3, completed: true)

    triage.advertise(atTwo)
    let first = try #require(currency.activity)
    summary.advertise(finished)
    #expect(currency.activity === first, "The handover made a second activity.")
    #expect(summary.isCurrent)
    #expect(!triage.isCurrent, "Two surfaces own the current activity.")

    triage.end()
    triage.advertise(nil)
    let current = try #require(currency.activity, "Triage's late end resigned the summary's.")
    #expect(current === first)
    #expect(summary.isCurrent)
    #expect(currency.activitiesMade == 1)
    #expect(TriageActivity(userInfo: current.userInfo) == finished)

    summary.end()
    #expect(currency.activity == nil)
    #expect(!summary.isCurrent)
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
  /// When set, the dismissal clears the flags and then awaits this gate's completion — as
  /// `RootView.dismissTriagePresentations` does.
  var dismissalGate: PresentationDismissalGate?

  func run(
    _ router: TriageContinuationRouter, _ activity: TriageActivity, ticket: Int
  ) async -> ContinuationOutcome {
    await router.route(
      activity, ticket: ticket,
      dismissPresentations: {
        self.events.append("dismiss")
        self.triageOpen = false
        self.summaryOpen = false
        self.dismissalGate?.withdrawUnappeared()
        await self.dismissalGate?.settled()
      },
      openShoot: { folderID, tier in
        self.events.append("openShoot:\(folderID)")
        self.duringOpenShoot?()
        await Task.yield()
        self.shownFolder = self.opensOtherShoot ? folderID + 1 : folderID
        self.shownTier = tier
        self.events.append("loaded:\(folderID)")
      },
      showShoot: { folderID in
        self.events.append("show:\(folderID)")
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

  @Test("Dismiss → open shoot → await its load → show it → resolve by id → open the loupe")
  func ordering() async {
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    let outcome = await host.run(router, activity, ticket: router.begin())
    #expect(outcome == .opened(imageID: 7015))
    #expect(
      host.events == [
        "dismiss", "openShoot:7", "loaded:7", "show:7", "locate:7015",
        "openLoupe:7015 triage=false summary=false",
      ])
  }

  /// Review round 1 (B1): route A clears the flags and awaits a dismissal that is still
  /// animating; route B arrives meanwhile, finds the flags already cleared — and still waits,
  /// on the SAME completion. Neither opens a shoot before it; only the newest proceeds after.
  @Test("A route arriving during a pending dismissal waits for it; only the newest proceeds")
  func secondRouteWaitsForThePendingDismissal() async {
    let router = TriageContinuationRouter()
    let gate = PresentationDismissalGate()
    gate.presented(.triageCover)
    let host = FakeContinuationHost()
    host.triageOpen = true
    host.dismissalGate = gate

    let olderTicket = router.begin()
    let older = Task { await host.run(router, activity, ticket: olderTicket) }
    await waitUntil { host.events == ["dismiss"] }
    #expect(!host.triageOpen, "The flags are cleared before the dismissal completes.")

    let newer = TriageActivity(folderID: 8, tier: nil, imageID: 8003, index: nil, completed: false)
    let newerTicket = router.begin()
    let newest = Task { await host.run(router, newer, ticket: newerTicket) }
    await waitUntil { host.events.count == 2 }
    // Both are parked on the gate: give either every chance to run on — neither may.
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(host.events == ["dismiss", "dismiss"])

    gate.disappeared(.triageCover)

    gate.dismissed(.triageCover)
    #expect(await older.value == .superseded)
    #expect(await newest.value == .opened(imageID: 8003))
    #expect(
      host.events == [
        "dismiss", "dismiss", "openShoot:8", "loaded:8", "show:8", "locate:8003",
        "openLoupe:8003 triage=false summary=false",
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
    // Review round 1: no navigation either — `show` follows the ticket check.
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

/// The gate's grace clock, held by the test: a sleep returns only when the test elapses it.
@MainActor
private final class FakeGraceClock {
  private var sleepers: [CheckedContinuation<Void, Never>] = []
  private(set) var sleeps: [Duration] = []

  func sleep(_ duration: Duration) async {
    sleeps.append(duration)
    await withCheckedContinuation { continuation in
      self.sleepers.append(continuation)
    }
  }

  func elapse() {
    let resumed = sleepers
    sleepers = []
    for sleeper in resumed { sleeper.resume() }
  }

  /// Review r3: only the oldest pending sleep runs out.
  func elapseOldest() {
    guard !sleepers.isEmpty else { return }
    sleepers.removeFirst().resume()
  }

  /// The withdrawal graces asked for, without the leaving graces (`.seconds(3)` by default).
  var withdrawalGraces: Int { sleeps.filter { $0 == .milliseconds(1500) }.count }
}

/// Review round 1 (B1): the dismissal completion every incoming route awaits.
@MainActor
@Suite("PresentationDismissalGate — dismissal completion, not elapsed time")
struct PresentationDismissalGateTests {
  private typealias Settlement = PresentationDismissalGate.Settlement
  private let activity = TriageActivity(
    folderID: 7, tier: .local, imageID: 7015, index: 15, completed: false)

  /// How many waiters have come back from `settled()`.
  @MainActor
  private final class Resumed {
    var count = 0
  }

  private func park(_ gate: PresentationDismissalGate, _ resumed: Resumed) -> Task<Void, Never> {
    Task {
      await gate.settled()
      resumed.count += 1
    }
  }

  @Test("Nothing on screen: settled at once")
  func settledWhenNothingIsUp() async {
    let gate = PresentationDismissalGate()
    #expect(gate.isSettled)
    await gate.settled()
  }

  @Test("Waits until EVERY reported surface is dismissed, then resumes every waiter")
  func waitsForEverySurface() async {
    let gate = PresentationDismissalGate()
    let resumed = Resumed()
    gate.presented(.triageCover)
    gate.presented(.passSummarySheet)
    let first = park(gate, resumed)
    let second = park(gate, resumed)
    for _ in 0..<20 { await Task.yield() }
    #expect(resumed.count == 0)

    gate.disappeared(.triageCover)

    gate.dismissed(.triageCover)
    for _ in 0..<20 { await Task.yield() }
    #expect(resumed.count == 0, "The sheet is still on screen.")

    gate.disappeared(.passSummarySheet)

    gate.dismissed(.passSummarySheet)
    await first.value
    await second.value
    #expect(resumed.count == 2)
    #expect(gate.isSettled)
  }

  @Test("Dismissing a surface that was never reported settles nothing")
  func unreportedDismissalIsANoOp() async {
    let gate = PresentationDismissalGate()
    let resumed = Resumed()
    gate.presented(.triageCover)
    let waiter = park(gate, resumed)
    gate.disappeared(.passSummarySheet)
    gate.dismissed(.passSummarySheet)
    for _ in 0..<20 { await Task.yield() }
    #expect(resumed.count == 0)
    #expect(!gate.isSettled)

    gate.disappeared(.triageCover)

    gate.dismissed(.triageCover)
    await waiter.value
    #expect(resumed.count == 1)
  }

  /// Review round 2 (1): requested → a route arrives BEFORE the content appears → the content
  /// appears late → dismissal. The route waits for the dismissal; the grace running out after
  /// the appearance settles nothing.
  @Test("Requested, route arrives before appearance, late appearance: waits for the dismissal")
  func routeBeforeAppearanceWaitsForTheDismissal() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate(grace: .milliseconds(1500)) { await clock.sleep($0) }
    gate.requested(.triageCover)
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.triageOpen = true
    host.dismissalGate = gate

    let ticket = router.begin()
    let route = Task { await host.run(router, activity, ticket: ticket) }
    await waitUntil { host.events == ["dismiss"] && clock.sleeps.count == 1 }
    #expect(clock.sleeps == [.milliseconds(1500)], "The withdrawn request takes the grace.")

    gate.presented(.triageCover)
    clock.elapse()
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(host.events == ["dismiss"], "A surface that appeared must wait for its onDismiss.")
    #expect(!gate.isSettled)

    gate.disappeared(.triageCover)

    gate.dismissed(.triageCover)
    #expect(await route.value == .opened(imageID: 7015))
    #expect(gate.settlements == [Settlement(surface: .triageCover, path: .onDismiss)])
  }

  /// Review round 2 (2): requested, then withdrawn by the route before anything appeared — no
  /// `onDismiss` will ever come. The route proceeds after the grace: not before, not never.
  @Test("Requested then cancelled before appearance: the route proceeds after the grace only")
  func cancelledRequestSettlesAfterTheGrace() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate(grace: .milliseconds(1500)) { await clock.sleep($0) }
    gate.requested(.triageCover)
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.dismissalGate = gate

    let ticket = router.begin()
    let route = Task { await host.run(router, activity, ticket: ticket) }
    await waitUntil { host.events == ["dismiss"] && clock.sleeps.count == 1 }
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(host.events == ["dismiss"], "Proceeded before the grace ran out.")

    clock.elapse()
    #expect(await route.value == .opened(imageID: 7015))
    #expect(gate.settlements == [Settlement(surface: .triageCover, path: .grace)])
  }

  @Test("A second withdrawal does not restart a running grace; a fresh request voids it")
  func graceIsNotExtendedAndAFreshRequestVoidsIt() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    gate.requested(.passSummarySheet)
    gate.withdrawUnappeared()
    gate.withdrawUnappeared()
    await waitUntil { clock.sleeps.count == 1 }
    for _ in 0..<20 { await Task.yield() }
    #expect(clock.sleeps.count == 1)

    gate.requested(.passSummarySheet)
    clock.elapse()
    for _ in 0..<20 { await Task.yield() }
    #expect(!gate.isSettled, "The old grace settled a NEW request.")
    #expect(gate.settlements.isEmpty)
  }

  /// IMGMGR-501: a re-request made while the surface is still on screen (or animating away) is
  /// a NEW generation. The `onDismiss` that follows belongs to the presentation that was up; it
  /// settles that one and never the request queued behind it.
  @Test("A stale presentation's onDismiss does not settle a re-request made while it was up")
  func staleDismissalDoesNotSettleAReRequest() async {
    let gate = PresentationDismissalGate()
    let resumed = Resumed()
    let first = gate.requested(.triageCover)
    gate.presented(.triageCover)
    let second = gate.requested(.triageCover)
    #expect(second > first, "The re-request shares the generation of the presentation on screen.")
    #expect(gate.requested(.triageCover) == second, "Asking again minted a third generation.")
    let waiter = park(gate, resumed)

    gate.disappeared(.triageCover)

    gate.dismissed(.triageCover)
    for _ in 0..<20 { await Task.yield() }
    #expect(!gate.isSettled, "The old presentation's onDismiss settled the re-request.")
    #expect(resumed.count == 0)

    gate.presented(.triageCover)
    gate.disappeared(.triageCover)
    gate.dismissed(.triageCover)
    await waiter.value
    #expect(resumed.count == 1)
    #expect(
      gate.settlements == [
        Settlement(surface: .triageCover, path: .onDismiss),
        Settlement(surface: .triageCover, path: .onDismiss),
      ])
  }

  /// IMGMGR-501: a route withdraws a re-request that is still queued behind the presentation on
  /// screen. That re-request will never present, so it takes the grace — counted from the old
  /// presentation's `onDismiss`, never settled by it outright, and never waited on forever.
  @Test("A withdrawn re-request takes the grace once the presentation before it is gone")
  func withdrawnReRequestTakesTheGraceAfterTheOldDismissal() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    gate.requested(.passSummarySheet)
    gate.presented(.passSummarySheet)
    gate.requested(.passSummarySheet)
    gate.withdrawUnappeared()
    for _ in 0..<20 { await Task.yield() }
    #expect(clock.sleeps.isEmpty, "The grace started while the old presentation was still up.")

    gate.disappeared(.passSummarySheet)

    gate.dismissed(.passSummarySheet)
    #expect(!gate.isSettled, "The old onDismiss settled the withdrawn re-request outright.")
    await waitUntil { clock.withdrawalGraces == 1 }
    #expect(clock.withdrawalGraces == 1, "The withdrawn re-request never took the grace.")

    clock.elapse()
    await waitUntil { gate.isSettled }
    #expect(gate.isSettled)
    #expect(
      gate.settlements == [
        Settlement(surface: .passSummarySheet, path: .onDismiss),
        Settlement(surface: .passSummarySheet, path: .grace),
      ])
  }

  /// IMGMGR-501 (review r1): the UNFAVOURABLE order — the successor's `onAppear` arrives before
  /// the outgoing presentation's `onDismiss`. The successor names its generation, so it stays
  /// marked as on screen: a later withdrawal arms no grace for it, and only its own `onDismiss`
  /// settles it.
  @Test("A successor that appears before the old onDismiss is never given the grace")
  func successorAppearingBeforeTheOldDismissalKeepsWaiting() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    let first = gate.requested(.passSummarySheet)
    gate.presented(.passSummarySheet, generation: first)
    let second = gate.requested(.passSummarySheet)
    gate.presented(.passSummarySheet, generation: second)
    gate.disappeared(.passSummarySheet)
    gate.dismissed(.passSummarySheet)
    #expect(!gate.isSettled, "The old onDismiss settled the visible successor.")

    gate.withdrawUnappeared()
    for _ in 0..<20 { await Task.yield() }
    #expect(clock.withdrawalGraces == 0, "A successor on screen was given the grace.")
    clock.elapse()
    for _ in 0..<20 { await Task.yield() }
    #expect(!gate.isSettled)

    gate.disappeared(.passSummarySheet)

    gate.dismissed(.passSummarySheet)
    #expect(gate.isSettled)
    #expect(
      gate.settlements == [
        Settlement(surface: .passSummarySheet, path: .onDismiss),
        Settlement(surface: .passSummarySheet, path: .onDismiss),
      ])
  }

  /// IMGMGR-501 review r2 (1): A is withdrawn before it appears, B replaces it and appears, and
  /// A's late `onDismiss` arrives. Nothing is leaving, so it settles nothing: B waits for its
  /// own `onDisappear` + `onDismiss`, and A's grace expiring touches B neither.
  @Test("A withdrawn predecessor's late onDismiss does not settle the presentation on screen")
  func latePredecessorDismissalLeavesTheVisibleOneWaiting() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    let first = gate.requested(.passSummarySheet)
    gate.withdrawUnappeared()
    await waitUntil { clock.sleeps.count == 1 }
    let second = gate.requested(.passSummarySheet)
    #expect(second != first, "The replacement shares the withdrawn request's generation.")
    gate.presented(.passSummarySheet, generation: second)

    gate.dismissed(.passSummarySheet)
    #expect(!gate.isSettled, "The predecessor's late onDismiss settled the visible one.")
    clock.elapse()
    for _ in 0..<20 { await Task.yield() }
    #expect(!gate.isSettled, "The predecessor's grace settled the visible one.")

    gate.disappeared(.passSummarySheet, generation: second)
    gate.dismissed(.passSummarySheet)
    #expect(gate.isSettled)
    #expect(gate.settlements == [Settlement(surface: .passSummarySheet, path: .onDismiss)])
  }

  /// IMGMGR-501 review r3: the same item disappears and appears again (still on screen). Its
  /// leaving grace running out settles nothing.
  @Test("Disappear, reappear, the leaving grace elapses: still registered")
  func reappearanceVoidsTheLeavingGrace() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    let generation = gate.requested(.triageCover)
    gate.presented(.triageCover, generation: generation)
    gate.disappeared(.triageCover, generation: generation)
    await waitUntil { clock.sleeps.count == 1 }
    gate.presented(.triageCover, generation: generation)
    clock.elapse()
    for _ in 0..<20 { await Task.yield() }
    #expect(!gate.isSettled, "The leaving grace settled a presentation back on screen.")
    #expect(gate.settlements.isEmpty)
  }

  /// IMGMGR-501 review r3: the same reappearance, then an identity-free `onDismiss` arrives
  /// late. Nothing is leaving any more, so it settles nothing.
  @Test("Disappear, reappear, a late identity-free onDismiss: still registered")
  func reappearanceIgnoresALateDismissal() {
    let gate = PresentationDismissalGate()
    let generation = gate.requested(.triageCover)
    gate.presented(.triageCover, generation: generation)
    gate.disappeared(.triageCover, generation: generation)
    gate.presented(.triageCover, generation: generation)
    gate.dismissed(.triageCover)
    #expect(!gate.isSettled, "A late onDismiss settled a presentation back on screen.")
    #expect(gate.settlements.isEmpty)
  }

  /// IMGMGR-501 review r3: disappear, reappear, disappear again. The FIRST disappearance's
  /// timer running out settles nothing; the second one's does.
  @Test("An earlier disappearance's timer cannot expire a later disappearance")
  func onlyTheCurrentDisappearanceExpires() async throws {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    let generation = gate.requested(.passSummarySheet)
    gate.presented(.passSummarySheet, generation: generation)
    gate.disappeared(.passSummarySheet, generation: generation)
    // Post-r3 advisory: each timer is an unstructured task, and nothing orders when two of them
    // reach the clock. The first one's sleep is registered BEFORE the second disappearance starts
    // its own, so `elapseOldest()` really runs out the first disappearance's timer.
    await waitUntil { clock.sleeps.count == 1 }
    try #require(clock.sleeps.count == 1, "The first disappearance's timer never registered.")
    gate.presented(.passSummarySheet, generation: generation)
    gate.disappeared(.passSummarySheet, generation: generation)
    await waitUntil { clock.sleeps.count == 2 }
    try #require(clock.sleeps.count == 2, "The second disappearance's timer never registered.")

    clock.elapseOldest()
    for _ in 0..<20 { await Task.yield() }
    #expect(!gate.isSettled, "The first disappearance's timer settled the second.")

    clock.elapseOldest()
    await waitUntil { gate.isSettled }
    #expect(gate.isSettled, "The current disappearance's timer settled nothing.")
    #expect(gate.settlements == [Settlement(surface: .passSummarySheet, path: .grace)])
  }

  /// IMGMGR-501 gate 2 on da41ad4 and the review of ada3ad8 (REVISE, blocking): the gate's
  /// route events (`triageCover:grace>passSummarySheet:grace>openLoupe-3`) are consistent with an
  /// identity-free `onDismiss` arriving before its content's `onDisappear`. Such an `onDismiss`
  /// carries no generation, so it cannot be told apart from a withdrawn predecessor's late one:
  /// holding it for the next `onDisappear` (ada3ad8) let a successor's brief disappearance be
  /// settled by the predecessor's callback. Until `onDismiss` carries its generation, the
  /// leaving grace is the safe fallback, and this test PINS it: the unattributed dismissal
  /// settles nothing, the disappearance arms the leaving grace, and the grace settles it.
  @Test("onDismiss before the content's onDisappear: not trusted, the leaving grace settles it")
  func unattributedDismissalBeforeDisappearanceFallsBackToTheGrace() async throws {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    let generation = gate.requested(.triageCover)
    gate.presented(.triageCover, generation: generation)
    gate.dismissed(.triageCover)
    #expect(!gate.isSettled, "An identity-free onDismiss settled a request nothing marked leaving.")
    gate.disappeared(.triageCover, generation: generation)
    #expect(!gate.isSettled, "The disappearance consumed the unattributed onDismiss.")
    #expect(gate.settlements.isEmpty)
    await waitUntil { clock.sleeps.count == 1 }
    try #require(clock.sleeps == [.seconds(3)], "The leaving grace was not armed.")
    clock.elapse()
    await waitUntil { gate.isSettled }
    #expect(gate.isSettled, "The leaving grace did not settle the presentation.")
    #expect(gate.settlements == [Settlement(surface: .triageCover, path: .grace)])
  }

  /// IMGMGR-501 review r2 (2): SwiftUI may run a content's `onAppear` more than once.
  @Test("A repeated onAppear for the same item is idempotent")
  func repeatedAppearanceIsIdempotent() {
    let gate = PresentationDismissalGate()
    let generation = gate.requested(.triageCover)
    gate.presented(.triageCover, generation: generation)
    gate.presented(.triageCover, generation: generation)
    gate.disappeared(.triageCover, generation: generation)
    gate.dismissed(.triageCover)
    #expect(gate.isSettled, "A repeated onAppear registered a second presentation.")
    #expect(gate.settlements == [Settlement(surface: .triageCover, path: .onDismiss)])
  }

  /// IMGMGR-501 review r2 (3): the route withdraws a request that never appeared, and the flag
  /// comes back (coalesced) before the grace runs out — one presentation, anew. The route waits
  /// for THAT presentation's dismissal and then completes; it neither hangs nor slips through.
  @Test("A withdrawal coalesced with a re-presentation still completes the route")
  func coalescedWithdrawalAndRePresentationCompletesTheRoute() async {
    let clock = FakeGraceClock()
    let gate = PresentationDismissalGate { await clock.sleep($0) }
    gate.requested(.triageCover)
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.dismissalGate = gate

    let ticket = router.begin()
    let route = Task { await host.run(router, activity, ticket: ticket) }
    await waitUntil { host.events == ["dismiss"] && clock.sleeps.count == 1 }
    let again = gate.requested(.triageCover)
    gate.presented(.triageCover, generation: again)
    clock.elapse()
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(host.events == ["dismiss"], "The route moved on while the re-presentation was up.")

    gate.disappeared(.triageCover, generation: again)
    gate.dismissed(.triageCover)
    #expect(await route.value == .opened(imageID: 7015))
    #expect(gate.settlements == [Settlement(surface: .triageCover, path: .onDismiss)])
  }

  /// IMGMGR-501 (review r1): the route over a Pass Summary that is up, its dismissal HELD. Nothing
  /// past the dismissal step runs until the sheet's own `onDismiss` settles the gate.
  @Test("A route over the Pass Summary opens the loupe only after the sheet's onDismiss")
  func routeOverThePassSummaryWaitsForItsDismissal() async {
    let gate = PresentationDismissalGate()
    let sheet = gate.requested(.passSummarySheet)
    gate.presented(.passSummarySheet, generation: sheet)
    let router = TriageContinuationRouter()
    let host = FakeContinuationHost()
    host.summaryOpen = true
    host.dismissalGate = gate

    let ticket = router.begin()
    let route = Task { await host.run(router, activity, ticket: ticket) }
    await waitUntil { host.events == ["dismiss"] }
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(host.events == ["dismiss"], "The route moved on while the sheet was still up.")

    gate.disappeared(.passSummarySheet)

    gate.dismissed(.passSummarySheet)
    #expect(await route.value == .opened(imageID: 7015))
    #expect(host.events.last == "openLoupe:7015 triage=false summary=false")
    #expect(gate.settlements == [Settlement(surface: .passSummarySheet, path: .onDismiss)])
  }

  @Test("The default clock's grace is real and bounded")
  func realGraceIsBounded() async {
    let gate = PresentationDismissalGate(grace: .milliseconds(50))
    gate.requested(.triageCover)
    let started = ContinuousClock.now
    gate.withdrawUnappeared()
    await gate.settled()
    #expect(ContinuousClock.now - started >= .milliseconds(50))
    #expect(gate.settlements == [Settlement(surface: .triageCover, path: .grace)])
  }
}
