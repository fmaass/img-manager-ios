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
      session.record(.keepLeft, result: result)
      #expect(session.left == 10, "\(result)")
      #expect(session.right == 20, "\(result)")
      #expect(session.history.isEmpty, "\(result)")
    }
  }

  @Test("A partial verb leaves the panes and pushes one history entry")
  func partialPushesHistory() throws {
    var session = try open()
    session.record(.keepLeft, result: .partial)
    #expect(session.left == 10)
    #expect(session.right == 20)
    #expect(session.history.count == 1)
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
    session.record(.keepLeft, result: .committed)
    #expect(session.right == 30)
    session.record(.keepLeft, result: .committed)
    #expect(session.isExhausted)
    #expect(session.right == nil)
    #expect(session.markGroups(for: .keepLeft) == nil)
    #expect(session.title == "Compare · all 3 seen in scene")
    session.undoCompleted(.restoredAll)
    #expect(session.right == 30)
    session.record(.keepLeft, result: .committed)
    session.showOnRight(20)
    #expect(session.right == 20)
    #expect(!session.isExhausted)
  }

  // MARK: - Undo pairing

  @Test("Undo pops the pane history only on .restoredAll")
  func undoPopsOnlyOnRestoredAll() throws {
    var session = try open()
    session.record(.keepRight, result: .committed)
    let advanced = session.panes
    let outcomes: [UndoOutcome] = [.partial, .scopeChanged, .conflict, .refused, .nothingToUndo]
    for outcome in outcomes {
      session.undoCompleted(outcome)
      #expect(session.panes == advanced, "\(outcome)")
      #expect(session.history.count == 1, "\(outcome)")
    }
    session.undoCompleted(.restoredAll)
    #expect(session.left == 10)
    #expect(session.right == 20)
    #expect(session.panes.seen == [10, 20])
    #expect(session.history.isEmpty)
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
