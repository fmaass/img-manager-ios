import Foundation

/// WP30 P3 (IMGMGR-458), plan decision 6: what `GridStore.undoLastMark()` reports. Fenced to the
/// entry and the `loadGeneration` captured when the call started, so a caller that has to know
/// whether the WHOLE entry came back (Compare pops its pane history on that answer alone) never
/// reads success into a run whose scope moved under it.
enum UndoOutcome: Equatable, Sendable {
  /// Every group of the entry was written back, in the scope the call started in.
  case restoredAll
  /// Some of the entry is still pending: a group failed (rolled back, `lastMutationError` set),
  /// or a group had nothing loaded to restore. The slot holds exactly the remainder.
  case partial
  /// A group's write was refused as stale; `handleConflict` owns the slot now (it cleared it).
  case conflict
  /// The generation moved while the undo ran — never `.restoredAll`, whatever landed.
  case scopeChanged
  /// The mark lane was busy; nothing was attempted.
  case refused
  /// The slot was empty.
  case nothingToUndo
}

/// One homogeneous write of a compound verb: `state` applied to `imageIDs` in one call.
struct CompoundMarkGroup: Equatable, Sendable {
  let state: MarkStateValue
  let imageIDs: [Int]
}

/// What `GridStore.applyCompoundMark(_:)` reports (plan decision 6's outcome table).
enum CompoundMarkResult: Equatable, Sendable {
  /// Every group committed; ONE undo entry covers them all.
  case committed
  /// At least one group committed and a later one failed (not a conflict). The one undo entry
  /// covers exactly the committed groups; `lastMutationError` is set. Nothing is compensated.
  case partial
  /// The first group failed: nothing committed, no entry recorded.
  case failed
  /// A group was refused as stale; the existing `handleConflict` machine ran and cleared the slot.
  case conflict
  /// The generation moved during the verb.
  case scopeChanged
  /// The lane was busy, or none of the ids is loaded: nothing was attempted.
  case refused

  /// Whether this verb left an undo entry of its own in the store's slot.
  var recordedUndoEntry: Bool { self == .committed || self == .partial }
}
