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

/// What `GridStore.undoLastMarkReporting()` answers (IMGMGR-482): the outcome, and the token of
/// the entry the undo read from the slot, so a caller that paired its own state with an entry
/// (Compare's pending pane snapshot) acts only on an outcome for THAT entry. Nil when the call
/// read no entry (`.refused`, `.nothingToUndo`).
struct UndoReport: Equatable, Sendable {
  let outcome: UndoOutcome
  let entryToken: UUID?
}

/// What `GridStore.applyCompoundMarkReporting(_:)` answers (IMGMGR-482, review round 1): the
/// verb's result and, when it recorded an undo entry (`.committed`, `.partial`), that entry's
/// token — taken where the entry is built, so a caller never re-reads the mutable slot for it.
struct CompoundMarkReport: Equatable, Sendable {
  let result: CompoundMarkResult
  let entryToken: UUID?
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
