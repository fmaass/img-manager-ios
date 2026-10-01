import Foundation

/// WP31 P1 (IMGMGR-460): the three decisions Triage offers. Skip is UI-only — it writes nothing
/// to the server (ticket 460).
enum TriageVerdict: Equatable, Sendable {
  case pick
  case dislike
  case skip

  /// The mark a verdict writes; nil for Skip, which writes nothing.
  var markState: MarkStateValue? {
    switch self {
    case .pick: .pick
    case .dislike: .dislike
    case .skip: nil
    }
  }
}

/// One entry of the pass log: what was decided, on which photograph, and — for a mark — the undo
/// slot's entry the write recorded, so Undo can tell whether the slot still holds THIS mark.
struct TriagePassAction: Equatable, Sendable {
  let verdict: TriageVerdict
  let imageID: Int
  let undoEntry: UndoEntry?
}

/// What a pass hands its host when it ends (plan decision 4). P2's summary reads it.
struct TriagePassResult: Equatable, Sendable {
  let actions: [TriagePassAction]
  /// The last photograph displayed — on a completed pass the final one, never "one past it".
  let continuationImageID: Int?
  let completed: Bool
}

/// One photograph of the live pool, as Triage needs it.
struct TriagePoolEntry: Equatable, Sendable {
  let id: Int
  let isMarked: Bool
}

/// How a Triage mark write ended.
enum TriageMarkOutcome: Equatable, Sendable {
  /// The write committed; the undo slot's entry it recorded, if the slot holds one for it.
  case committed(UndoEntry?)
  /// Refused, rolled back or conflicted — the store's own error surface says why.
  case refused
}

/// The store-facing operations a Triage pass uses. `GridStore` conforms (`GridStore+Triage`); a
/// unit test conforms with a fake marker and pager it can suspend.
@MainActor
protocol TriageStore: AnyObject {
  /// The live actionable pool, in display order.
  var triagePool: [TriagePoolEntry] { get }
  func triageSuccessor(after imageID: Int) async -> SuccessorLookup
  func triageMark(_ state: MarkStateValue, imageID: Int) async -> TriageMarkOutcome
  /// What the one-slot undo store holds right now.
  var triageUndoEntry: UndoEntry? { get }
  func triageUndo() async -> UndoOutcome
}

/// WP31 P1 (IMGMGR-460): one Triage pass — plan decisions 1, 2, 3, 4 and 7.
///
/// The cursor is an image id over the store's LIVE pool, never a frozen list; the successor is
/// resolved BEFORE a write, so a filter that drops a marked photograph cannot lose the place.
/// One action at a time: `busy` is set the moment an action starts and every await is followed
/// by a re-validation of the pass id and the cursor — a closed pass or a moved cursor stops the
/// action there, with no write submitted, no advance and nothing logged.
@MainActor
@Observable
final class TriageSession {
  private let store: any TriageStore

  /// The photograph on screen.
  private(set) var cursor: Int?
  /// Bumped when the pass ends; an action that started under an older value does nothing more.
  private(set) var passID = 0
  private(set) var log: [TriagePassAction] = []
  private(set) var busy = false
  /// The last photograph was decided and nothing follows it.
  private(set) var completed = false
  private(set) var isClosed = false
  /// Set once, when the pass ends — by Back/Done or by completing.
  private(set) var result: TriagePassResult?
  /// WP31 P1 review (B1): the photograph the screen is actually SHOWING. Decisions wait until it
  /// is the cursor's — a reader must see what they Pick, Dislike or Skip, never the previous
  /// photograph while the next preview loads.
  private(set) var displayedImageID: Int?
  /// Committed marks this pass — the haptic's trigger (review A1): a Skip or an Undo is not one.
  private(set) var committedMarks = 0

  init(store: any TriageStore, startAt imageID: Int? = nil) {
    self.store = store
    cursor = imageID ?? Self.startPosition(in: store.triagePool)
  }

  /// Plan decision 2: the first unmarked photograph in the loaded pool, else the first one.
  static func startPosition(in pool: [TriagePoolEntry]) -> Int? {
    pool.first { !$0.isMarked }?.id ?? pool.first?.id
  }

  /// The continuation position (plan decision 4) — the photograph last displayed.
  var continuationImageID: Int? { cursor }

  /// The cursor's 1-based index in the live pool; nil while it is not in it.
  var position: Int? {
    guard let cursor, let index = store.triagePool.firstIndex(where: { $0.id == cursor }) else {
      return nil
    }
    return index + 1
  }

  /// Whether Pick, Dislike and Skip (buttons and gestures alike) can act now: idle, open, and
  /// the photograph on screen is the cursor's.
  var canDecide: Bool {
    !busy && !isClosed && cursor != nil && displayedImageID == cursor
  }

  /// The view reports the photograph it now shows (its preview, or the placeholder that states
  /// none could be loaded) — always for the id it was loaded for.
  func didDisplay(_ imageID: Int) {
    displayedImageID = imageID
  }

  /// Plan decision 3: Undo acts on the LAST pass-log action — a Skip always, a mark only while
  /// the store's one undo slot still holds that mark's entry.
  var canUndo: Bool {
    guard !busy, !isClosed, let last = log.last else { return false }
    guard last.verdict.markState != nil else { return true }
    guard let entry = last.undoEntry else { return false }
    return store.triageUndoEntry == entry
  }

  /// Pick, Dislike or Skip the photograph on screen, then advance. A mark advances only on a
  /// COMMITTED write; Skip makes no store call at all. An unresolved successor (a failed page, or
  /// a load still outstanding when the bounded wait expired) ends the action with nothing done.
  func decide(_ verdict: TriageVerdict) async {
    guard canDecide, let current = cursor else { return }
    busy = true
    let pass = passID
    defer { if pass == passID { busy = false } }

    let next = await store.triageSuccessor(after: current)
    guard isStill(pass, on: current) else { return }
    if next == .unresolved { return }

    var undoEntry: UndoEntry?
    if let state = verdict.markState {
      let outcome = await store.triageMark(state, imageID: current)
      guard isStill(pass, on: current) else { return }
      guard case .committed(let entry) = outcome else { return }
      undoEntry = entry
      committedMarks += 1
    }

    // Logged before the cursor moves, so a summary never counts an uncommitted mark.
    log.append(TriagePassAction(verdict: verdict, imageID: current, undoEntry: undoEntry))
    switch next {
    case .found(let id):
      cursor = id
    case .exhausted:
      completed = true
      close()
    case .unresolved:
      break
    }
  }

  /// Plan decision 3. A Skip is undone UI-only; a mark through the store's `undoLastMark`, and the
  /// cursor steps back only once that restore is complete.
  func undo() async {
    guard canUndo, let last = log.last else { return }
    guard last.verdict.markState != nil else {
      log.removeLast()
      cursor = last.imageID
      return
    }
    busy = true
    let pass = passID
    let startedOn = cursor
    defer { if pass == passID { busy = false } }

    let outcome = await store.triageUndo()
    guard pass == passID, !isClosed, cursor == startedOn else { return }
    guard outcome == .restoredAll else { return }
    log.removeLast()
    cursor = last.imageID
  }

  /// Ends the pass — Back/Done, a completed pass, or the cover going away. Never blocked by an
  /// action in flight: it bumps the pass id, so that action's late completion does nothing.
  /// Idempotent; the first call's result stands.
  @discardableResult
  func close() -> TriagePassResult {
    if let result { return result }
    isClosed = true
    busy = false
    passID += 1
    let ended = TriagePassResult(
      actions: log, continuationImageID: cursor, completed: completed)
    result = ended
    return ended
  }

  private func isStill(_ pass: Int, on imageID: Int) -> Bool {
    pass == passID && !isClosed && cursor == imageID
  }
}
