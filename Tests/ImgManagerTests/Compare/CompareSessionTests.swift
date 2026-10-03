import Foundation
import Testing

@testable import ImgManager

/// WP30 P3 (IMGMGR-458): the Compare state machine, pure — plan decision 1 (verbs, progression,
/// left ≠ right, exhaustion) and decision 6's pane half of Undo (pop only on `.restoredAll`).
@Suite("CompareSession — verbs, pane progression, Undo pairing (WP30 P3)")
struct CompareSessionTests {
  private let scope = [10, 20, 30, 40, 50]

  private func open(_ candidates: [Int]? = nil, focused: Int = 10, pinned: Bool = false) throws
    -> CompareSession
  {
    let ids = candidates ?? scope
    var session = try #require(CompareSession(candidates: ids, focused: focused, isSceneBand: true))
    session.isPinned = pinned
    return session
  }

  // MARK: - Verbs

  @Test("Exactly three verbs, and none of them is Swap")
  func exactlyThreeVerbsNoSwap() {
    #expect(CompareVerb.allCases == [.keepLeft, .both, .keepRight])
    #expect(!CompareVerb.allCases.contains { $0.title.localizedCaseInsensitiveContains("swap") })
    let identifiers = CompareVerb.allCases.map { $0.accessibilityIdentifier }
    #expect(identifiers == ["compareKeepLeft", "compareBoth", "compareKeepRight"])
  }

  @Test("Each verb's mark targets for a concrete pair")
  func verbMarkTargets() {
    let pickLeft = CompoundMarkGroup(state: .pick, imageIDs: [10])
    let dislikeRight = CompoundMarkGroup(state: .dislike, imageIDs: [20])
    let pickRight = CompoundMarkGroup(state: .pick, imageIDs: [20])
    let dislikeLeft = CompoundMarkGroup(state: .dislike, imageIDs: [10])
    let pickBoth = CompoundMarkGroup(state: .pick, imageIDs: [10, 20])
    #expect(CompareVerb.keepLeft.markGroups(left: 10, right: 20) == [pickLeft, dislikeRight])
    #expect(CompareVerb.keepRight.markGroups(left: 10, right: 20) == [pickRight, dislikeLeft])
    #expect(CompareVerb.both.markGroups(left: 10, right: 20) == [pickBoth])
  }

  // MARK: - Opening

  @Test("Opens on the focused image and the next one; the last image pairs with its previous")
  func opening() throws {
    let first = try open(focused: 10)
    #expect(first.left == 10)
    #expect(first.right == 20)
    #expect(first.panes.seen == [10, 20])
    let last = try open(focused: 50)
    #expect(last.left == 50)
    #expect(last.right == 40)
  }

  @Test("Fewer than two candidates, or a focus outside the scope, opens nothing")
  func refusesToOpen() {
    #expect(CompareSession(candidates: [10], focused: 10, isSceneBand: false) == nil)
    #expect(CompareSession(candidates: [10, 10], focused: 10, isSceneBand: false) == nil)
    #expect(CompareSession(candidates: [10, 20], focused: 99, isSceneBand: false) == nil)
    #expect(CompareSession(scope: .hidden, focused: 10) == nil)
  }

  // MARK: - Progression, all three verbs × Pin

  @Test("Pin off: Keep left and Both keep the left pane; Keep right promotes the right image")
  func progressionPinOff() throws {
    var keepLeft = try open()
    keepLeft.record(.keepLeft, result: .committed)
    #expect(keepLeft.left == 10)
    #expect(keepLeft.right == 30)
    var both = try open()
    both.record(.both, result: .committed)
    #expect(both.left == 10)
    #expect(both.right == 30)
    var keepRight = try open()
    keepRight.record(.keepRight, result: .committed)
    #expect(keepRight.left == 20)
    #expect(keepRight.right == 30)
  }

  @Test("Pin on: the left pane never changes; every verb advances only the right pane")
  func progressionPinOn() throws {
    for verb in CompareVerb.allCases {
      var session = try open(pinned: true)
      session.record(verb, result: .committed)
      #expect(session.left == 10, "\(verb)")
      #expect(session.right == 30, "\(verb)")
      session.record(verb, result: .committed)
      #expect(session.left == 10, "\(verb)")
      #expect(session.right == 40, "\(verb)")
    }
  }

  @Test("Winner stays left across repeated Keep right, and next-unseen wraps")
  func kingOfTheHillAndWrap() throws {
    var session = try open()
    session.record(.keepRight, result: .committed)
    session.record(.keepRight, result: .committed)
    #expect(session.left == 30)
    #expect(session.right == 40)

    var wrapping = try open(focused: 40)
    #expect(wrapping.right == 50)
    wrapping.record(.keepLeft, result: .committed)
    #expect(wrapping.left == 40)
    #expect(wrapping.right == 10)
  }

  @Test("Only a committed verb advances; any other outcome changes nothing")
  func onlyCommittedAdvances() throws {
    let results: [CompoundMarkResult] = [.failed, .conflict, .scopeChanged, .refused]
    for result in results {
      var session = try open()
      session.record(.keepLeft, result: result, entryToken: UUID())
      #expect(session.left == 10, "\(result)")
      #expect(session.right == 20, "\(result)")
      #expect(session.pendingUndo == nil, "\(result)")
    }
  }

  @Test("A partial verb leaves the panes and keys the one pending snapshot to its entry")
  func partialKeysThePendingSnapshot() throws {
    var session = try open()
    let entry = UUID()
    session.record(.keepLeft, result: .partial, entryToken: entry)
    #expect(session.left == 10)
    #expect(session.right == 20)
    #expect(session.pendingUndo?.entryToken == entry)
    #expect(session.pendingUndo?.panes == session.panes)
  }

  // MARK: - Left ≠ right

  @Test("Strip taps never put the left image on the right")
  func stripTapsKeepTheInvariant() throws {
    var session = try open()
    session.showOnRight(10)
    #expect(session.right == 20)
    session.showOnRight(99)
    #expect(session.right == 20)
    session.showOnRight(40)
    #expect(session.right == 40)
    #expect(session.panes.seen.contains(40))
  }

  @Test("Swipes step the right pane in scope order, wrapping, skipping the left image")
  func swipesKeepTheInvariant() throws {
    var session = try open(focused: 30)
    var visited: [Int] = []
    for _ in 0..<5 {
      session.stepRight(forward: true)
      visited.append(session.right ?? -1)
    }
    #expect(visited == [50, 10, 20, 40, 50])
    session.stepRight(forward: false)
    #expect(session.right == 40)
    session.stepRight(forward: false)
    #expect(session.right == 20)

    var pair = try open([10, 20])
    pair.stepRight(forward: true)
    #expect(pair.right == 20)
    pair.stepRight(forward: false)
    #expect(pair.right == 20)
  }

  // MARK: - Exhaustion

  @Test("Exhaustion: no unseen candidate left → end state, verbs off, Undo and strip still live")
  func exhaustion() throws {
    var session = try open([10, 20, 30])
    session.record(.keepLeft, result: .committed, entryToken: UUID())
    #expect(session.right == 30)
    let last = UUID()
    session.record(.keepLeft, result: .committed, entryToken: last)
    #expect(session.isExhausted)
    #expect(session.right == nil)
    #expect(session.markGroups(for: .keepLeft) == nil)
    #expect(session.title == "Compare · all 3 seen in scene")
    session.undoCompleted(UndoReport(outcome: .restoredAll, entryToken: last))
    #expect(session.right == 30)
    session.record(.keepLeft, result: .committed)
    session.showOnRight(20)
    #expect(session.right == 20)
    #expect(!session.isExhausted)
  }

  // MARK: - Undo pairing

  @Test("Undo restores the panes only on .restoredAll of the entry the snapshot is keyed by")
  func undoRestoresOnlyOnRestoredAllOfItsEntry() throws {
    var session = try open()
    let entry = UUID()
    session.record(.keepRight, result: .committed, entryToken: entry)
    let advanced = session.panes
    let outcomes: [UndoOutcome] = [.partial, .scopeChanged, .refused]
    for outcome in outcomes {
      session.undoCompleted(UndoReport(outcome: outcome, entryToken: entry))
      #expect(session.panes == advanced, "\(outcome)")
      #expect(session.pendingUndo?.entryToken == entry, "\(outcome)")
    }
    session.undoCompleted(UndoReport(outcome: .restoredAll, entryToken: entry))
    #expect(session.left == 10)
    #expect(session.right == 20)
    #expect(session.panes.seen == [10, 20])
    #expect(session.pendingUndo == nil)
  }

  @Test("IMGMGR-482: a conflicted verb drops the snapshot; a failed or refused one keeps it")
  func nonRecordingVerbsKeepOrDropTheSnapshot() throws {
    var session = try open()
    let entry = UUID()
    session.record(.keepRight, result: .committed, entryToken: entry)
    for result: CompoundMarkResult in [.failed, .scopeChanged, .refused] {
      session.record(.keepLeft, result: result, entryToken: nil)
      #expect(session.pendingUndo?.entryToken == entry, "\(result)")
    }
    session.record(.keepLeft, result: .conflict, entryToken: nil)
    #expect(session.pendingUndo == nil)
  }

  @Test("IMGMGR-482: no stale snapshot after a conflict, a second verb or another entry's Undo")
  func staleSnapshotIsNeverRestored() throws {
    // After a conflict (handleConflict cleared the slot), a later .restoredAll of some other
    // entry leaves the panes where they are. The pre-fix history popped the stale pair here.
    var afterConflict = try open()
    let first = UUID()
    afterConflict.record(.keepRight, result: .committed, entryToken: first)
    let advanced = afterConflict.panes
    afterConflict.undoCompleted(UndoReport(outcome: .conflict, entryToken: first))
    #expect(afterConflict.panes == advanced)
    #expect(afterConflict.pendingUndo == nil)
    afterConflict.undoCompleted(UndoReport(outcome: .restoredAll, entryToken: UUID()))
    #expect(afterConflict.panes == advanced)

    // After a second verb, only the second verb's pair is pending: its Undo restores it, and a
    // further .restoredAll (of any entry) never reaches back to the first verb's pair.
    var twoVerbs = try open()
    let beforeFirst = twoVerbs.panes
    twoVerbs.record(.keepLeft, result: .committed, entryToken: UUID())
    let beforeSecond = twoVerbs.panes
    let second = UUID()
    twoVerbs.record(.keepLeft, result: .committed, entryToken: second)
    let pending = CompareSession.PendingUndo(entryToken: second, panes: beforeSecond)
    #expect(twoVerbs.pendingUndo == pending)
    twoVerbs.undoCompleted(UndoReport(outcome: .restoredAll, entryToken: second))
    #expect(twoVerbs.panes == beforeSecond)
    twoVerbs.undoCompleted(UndoReport(outcome: .restoredAll, entryToken: UUID()))
    #expect(twoVerbs.panes == beforeSecond)
    #expect(twoVerbs.panes != beforeFirst)

    // Another entry's .restoredAll while this session's snapshot is pending: the panes stay
    // and the snapshot is dropped (its entry has left the slot).
    var otherEntry = try open()
    otherEntry.record(.keepLeft, result: .committed, entryToken: UUID())
    let advancedAgain = otherEntry.panes
    otherEntry.undoCompleted(UndoReport(outcome: .restoredAll, entryToken: UUID()))
    #expect(otherEntry.panes == advancedAgain)
    #expect(otherEntry.pendingUndo == nil)
  }

  // MARK: - Title

  @Test("Title: n is the right pane's position; 'in scene' only for a scene band")
  func title() throws {
    #expect(try open().title == "Compare · 2 of 5 in scene")
    let flat = try #require(CompareSession(candidates: scope, focused: 30, isSceneBand: false))
    #expect(flat.title == "Compare · 4 of 5")
  }

  // MARK: - Keyboard isolation (decision 7)

  @MainActor
  @Test("While Compare is open the scene publishes no keyboard actions; after Back it does")
  func keyboardIsolation() {
    let (store, _) = makeCompareTestStore()
    let actions = store.keyboardActions
    let whileOpen = CompareKeyboardIsolation.published(actions, isCompareOpen: true)
    let afterBack = CompareKeyboardIsolation.published(actions, isCompareOpen: false)
    let isWithheld = whileOpen == nil
    let isPublished = afterBack != nil
    #expect(isWithheld)
    #expect(isPublished)
  }
}
