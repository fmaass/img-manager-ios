import Foundation

/// WP30 P3 (IMGMGR-458): Compare's three decision verbs. No Swap: p4128 D8 replaced it with Pin.
enum CompareVerb: CaseIterable, Hashable, Sendable {
  case keepLeft
  case both
  case keepRight

  var title: String {
    switch self {
    case .keepLeft: "Keep left"
    case .both: "Both"
    case .keepRight: "Keep right"
    }
  }

  var systemImage: String {
    switch self {
    case .keepLeft: "rectangle.lefthalf.inset.filled"
    case .both: "rectangle.split.2x1.fill"
    case .keepRight: "rectangle.righthalf.inset.filled"
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .keepLeft: "compareKeepLeft"
    case .both: "compareBoth"
    case .keepRight: "compareKeepRight"
    }
  }

  /// Plan decision 1, the verb → marks table. Keep left = Pick left + Dislike right; Keep right =
  /// Pick right + Dislike left; Both = Pick both, as ONE homogeneous group. Pick is always the
  /// first group, so a failure of the second leaves the kept photograph picked.
  func markGroups(left: Int, right: Int) -> [CompoundMarkGroup] {
    switch self {
    case .keepLeft:
      [
        CompoundMarkGroup(state: .pick, imageIDs: [left]),
        CompoundMarkGroup(state: .dislike, imageIDs: [right]),
      ]
    case .both:
      [CompoundMarkGroup(state: .pick, imageIDs: [left, right])]
    case .keepRight:
      [
        CompoundMarkGroup(state: .pick, imageIDs: [right]),
        CompoundMarkGroup(state: .dislike, imageIDs: [left]),
      ]
    }
  }
}

/// WP30 P3 (IMGMGR-458): the Compare state machine, pure. It holds ids only — marks stay server
/// state (ADR-0004) and are read from the store when drawn.
///
/// Invariant: left ≠ right, always. Pane progression (plan decision 1):
/// - Pin off: Keep left and Both leave the left pane; Keep right moves the right image into it.
///   The right pane then takes the next UNSEEN candidate ("winner stays left").
/// - Pin on: the left pane never changes; every verb advances only the right pane.
/// - "Next unseen": the first scope image after the current right image, in scope order and
///   wrapping, that has not occupied either pane this session. None left → `right == nil`, the
///   end state: the verbs disable, Undo, Back and strip taps stay live.
struct CompareSession: Equatable, Sendable {
  /// What Undo restores: the pane pair and the seen set.
  struct Panes: Equatable, Sendable {
    var left: Int
    var right: Int?
    var seen: Set<Int>
  }

  /// This session's identity (fold round 1, A1). Equality alone is not identity: Back and a
  /// reopen on the same pair build an EQUAL session, and a verb still in flight from the first
  /// must not advance the second. Copies of one session keep it; a new session never shares it.
  let token = UUID()
  /// The scope's ids, in scope order, at the moment Compare opened.
  let candidates: [Int]
  /// Whether the scope is a scene band (the title then reads "in scene").
  let isSceneBand: Bool
  private(set) var panes: Panes
  var isPinned = false
  /// One snapshot per verb that left an undo entry in the store's slot, newest last.
  private(set) var history: [Panes] = []

  var left: Int { panes.left }
  var right: Int? { panes.right }
  var isExhausted: Bool { panes.right == nil }

  /// Left = `focused`; right = the next scope image after it, or the previous one when `focused`
  /// is last. Nil when the scope holds fewer than 2 images or does not hold `focused`.
  init?(candidates: [Int], focused: Int, isSceneBand: Bool) {
    var unique: [Int] = []
    var present = Set<Int>()
    for id in candidates where present.insert(id).inserted { unique.append(id) }
    guard unique.count >= 2, let index = unique.firstIndex(of: focused) else { return nil }
    let right = unique.indices.contains(index + 1) ? unique[index + 1] : unique[index - 1]
    self.candidates = unique
    self.isSceneBand = isSceneBand
    self.panes = Panes(left: focused, right: right, seen: [focused, right])
  }

  /// The same, over the loupe's filmstrip scope (plan decision 2).
  init?(scope: FilmstripScope, focused: Int) {
    let isSceneBand: Bool
    switch scope {
    case .members: isSceneBand = true
    case .sequence: isSceneBand = false
    case .hidden: return nil
    }
    self.init(candidates: scope.frames.map { $0.id }, focused: focused, isSceneBand: isSceneBand)
  }

  /// The compound mark `verb` writes for the current pair; nil in the end state.
  func markGroups(for verb: CompareVerb) -> [CompoundMarkGroup]? {
    guard let right = panes.right else { return nil }
    return verb.markGroups(left: panes.left, right: right)
  }

  /// Applies a verb's store outcome (plan decision 6): only `.committed` advances the panes. A
  /// `.partial` verb left an entry too, so it records the (unchanged) pair for Undo to pop with
  /// that entry; every other outcome left no entry of its own and changes nothing.
  mutating func record(_ verb: CompareVerb, result: CompoundMarkResult) {
    switch result {
    case .committed:
      history.append(panes)
      advance(after: verb)
    case .partial:
      history.append(panes)
    case .failed, .conflict, .scopeChanged, .refused:
      break
    }
  }

  /// Undo's pane half: the prior pair comes back only when the store restored the whole entry.
  mutating func undoCompleted(_ outcome: UndoOutcome) {
    guard outcome == .restoredAll, let prior = history.popLast() else { return }
    panes = prior
  }

  /// A strip tap: `imageID` goes to the right pane and joins the seen set. The left image (whose
  /// thumbnail is disabled) and ids outside the scope are refused.
  mutating func showOnRight(_ imageID: Int) {
    guard imageID != panes.left, candidates.contains(imageID) else { return }
    panes.right = imageID
    panes.seen.insert(imageID)
  }

  /// A swipe on the right pane: the next (or previous) scope image, wrapping, skipping the left
  /// image. From the end state it starts at the left image's position.
  mutating func stepRight(forward: Bool) {
    guard let origin = candidates.firstIndex(of: panes.right ?? panes.left) else { return }
    let count = candidates.count
    for offset in 1..<count {
      let index = (origin + (forward ? offset : count - offset)) % count
      let id = candidates[index]
      guard id != panes.left else { continue }
      panes.right = id
      panes.seen.insert(id)
      return
    }
  }

  /// The right pane's 1-based position in the scope, or nil in the end state.
  var rightPosition: Int? {
    guard let right = panes.right, let index = candidates.firstIndex(of: right) else {
      return nil
    }
    return index + 1
  }

  /// "Compare · n of m in scene" / "Compare · n of m"; the end state names the scope alone.
  var title: String {
    let suffix = isSceneBand ? " in scene" : ""
    guard let position = rightPosition else {
      return "Compare · all \(candidates.count) seen\(suffix)"
    }
    return "Compare · \(position) of \(candidates.count)\(suffix)"
  }

  private mutating func advance(after verb: CompareVerb) {
    guard let right = panes.right else { return }
    if !isPinned && verb == .keepRight { panes.left = right }
    panes.right = nextUnseen(after: right)
    if let next = panes.right { panes.seen.insert(next) }
  }

  private func nextUnseen(after id: Int) -> Int? {
    guard let origin = candidates.firstIndex(of: id) else { return nil }
    let count = candidates.count
    for offset in 1..<count {
      let candidate = candidates[(origin + offset) % count]
      if candidate != panes.left && !panes.seen.contains(candidate) { return candidate }
    }
    return nil
  }
}
