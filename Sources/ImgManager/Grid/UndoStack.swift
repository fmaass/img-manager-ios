import Foundation

/// The tri-state mark value this screen ever applies — mirrors `MarkView.state`/
/// `MarkStateRequest.state` (ADR-0001: the model does not change).
enum MarkStateValue: String, Sendable, Equatable {
  case pick
  case dislike
  case none
}

/// One image's ACTUAL state immediately before a mutation was applied — captured from the
/// currently-loaded `MarkView`, never synthesized. "Truthful prior state, stated not implied"
/// (functional spec, P6-era text; P4 must not get this wrong just because P6 hasn't landed the
/// read-back yet — undo still has to restore what was really there a moment ago, e.g. `dislike`,
/// not blindly assume the opposite of what was just applied).
struct PriorMarkSnapshot: Sendable, Equatable {
  var imageID: Int
  var state: MarkStateValue
  /// The revision the image carried BEFORE this mutation — used to build the precondition for
  /// the undo write itself (undo is a mutation like any other: it goes through the same
  /// revision-precondition path, never unconditional).
  var revisionBefore: String
}

/// One undoable batch: the mark state that was just applied, and every image's truthful prior
/// state so undo can restore each one exactly, not just flip a single tri-state back.
struct UndoEntry: Sendable, Equatable {
  var appliedState: MarkStateValue
  var priorStates: [PriorMarkSnapshot]
  /// This entry's identity (IMGMGR-482). Two entries with equal states and priors are still two
  /// entries; a caller that pairs its own state with an entry (Compare's pending pane snapshot)
  /// keys it by this. A partial undo's remainder is the SAME entry and keeps its token.
  var token = UUID()

  var imageIDs: [Int] { priorStates.map(\.imageID) }
}

/// One slot, serialized (functional spec, P6-era language, honored here since Z is P4-active):
/// a new mutation overwrites whatever was in the slot: there is no undo history, only "the last
/// thing that happened". Pure storage — the actual undo WRITE (calling `GridService` again with
/// `priorStates` as the new target and building fresh preconditions) lives in `GridStore`, which
/// also owns rolling optimistic UI state back on a 409.
@Observable
final class UndoStack {
  private(set) var entry: UndoEntry?

  var canUndo: Bool { entry != nil }

  /// Overwrites whatever was there — "one slot", not a push.
  func record(_ entry: UndoEntry) {
    self.entry = entry
  }

  /// Consumes the slot: a `Z` that fires twice without an intervening mutation finds nothing
  /// the second time (one-slot semantics), never re-applies the same undo.
  func consume() -> UndoEntry? {
    defer { entry = nil }
    return entry
  }

  func clear() {
    entry = nil
  }
}
