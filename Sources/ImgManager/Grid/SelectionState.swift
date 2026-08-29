import Foundation

/// The mode a grid screen is in — mutually exclusive with Pick Lock (premise.out pin e; enforced
/// at the coordinator, `GridStore`, never here — see `PickLockState`'s doc comment).
enum GridInteractionMode: Equatable, Sendable {
  case browse
  case select
}

/// Why a reset happened — kept as data (not just "reset()") so a test on the coordinator can
/// assert the RIGHT trigger fired the reset, and so `.bulkActionSucceeded` vs a query-generation
/// reload are visibly different call sites rather than both routing through one bare `reset()`.
///
/// Pin: "reset on Done, leaving/changing the shoot, any effective filter/tier/tree change,
/// foreground/retry full reload, or entering the loupe. A successful bulk action retains
/// selection for another bulk action; an ensuing query-generation reload then applies the reset
/// rule." — `.doneOrEsc` covers the explicit exit affordance (Done / Esc, mirroring Pick Lock's
/// own exits); `.queryGenerationChange` covers "any effective filter/tier/tree change" AND the
/// "ensuing query-generation reload" half of the bulk-action sentence; `.fullReload` covers
/// foreground/retry; `.enteredLoupe` has no reachable call site in P4 (no loupe exists yet —
/// P5) but is kept in the enum so the type is already complete for when P5 wires it, rather than
/// growing this enum later and re-touching every exhaustive switch over it.
enum SelectionResetTrigger: Equatable, Sendable {
  case doneOrEsc
  case shootChange
  case queryGenerationChange
  case fullReload
  case enteredLoupe
}

/// Selection-set semantics (plan fold item 6, the P4-owned OPEN item, now pinned). Scope is one
/// shoot + filter/query generation; membership is a set of stable image ids. This type owns
/// exactly that set plus the browse/select mode — it has NO knowledge of Pick Lock, paging, or
/// the network; `GridStore` composes it with everything else.
///
/// "Loaded-only membership (no select-all-matching)" is a structural guarantee, not a runtime
/// check: there is no method on this type that takes anything but an explicit, already-loaded
/// image id — no "select all matching the current filter" entry point exists to add one that
/// was never actually paged in.
@Observable
final class SelectionState {
  private(set) var mode: GridInteractionMode = .browse
  private(set) var members: Set<Int> = []

  /// An explicit Select entry (e.g. an action-bar "Select" control) starts EMPTY.
  func enterSelectExplicitly() {
    mode = .select
    members = []
  }

  /// Long-press enters Select WITH that tile already selected.
  func enterSelectViaLongPress(imageID: Int) {
    mode = .select
    members = [imageID]
  }

  /// An ordinary click/tap while in Select mode: toggles. No-op outside Select mode — the
  /// caller is expected not to route ordinary taps here while in `.browse`, but this stays
  /// defensive so a caller bug degrades to "did nothing" rather than a silent membership leak.
  func toggle(_ imageID: Int) {
    guard mode == .select else { return }
    if members.contains(imageID) {
      members.remove(imageID)
    } else {
      members.insert(imageID)
    }
  }

  /// Pointer drag: adds, never removes, and — via the caller's `DragPaintSession` — only once
  /// per crossed tile per drag. No-op outside Select mode, same reasoning as `toggle`.
  func addFromDrag(_ imageID: Int) {
    guard mode == .select else { return }
    members.insert(imageID)
  }

  /// WP12: photographs that have just STOPPED being visible leave the selection with them —
  /// collapsing a scene hides its members, and a selection the reader can no longer see is both a
  /// dishonest count in the action bar and a write target for the next Pick they press. Removes
  /// only the named ids; a selection made elsewhere in the stream is untouched. Never adds, and
  /// never changes the mode — collapsing a card is not leaving Select.
  func removeHidden(_ imageIDs: [Int]) {
    guard !members.isEmpty else { return }
    members.subtract(imageIDs)
  }

  /// Paging append / virtualization: deliberately does nothing. Kept as a named, called entry
  /// point (rather than no call site at all) so "paging never clears and never implicitly
  /// selects" has one place a test asserts against directly, and a future edit that tries to
  /// touch membership here has to edit this specific, doc-commented no-op to do it.
  func pageAppended() {}

  /// A successful bulk action retains selection for a subsequent bulk action — also
  /// deliberately a no-op, same reasoning as `pageAppended`.
  func bulkActionSucceeded() {}

  func reset(_ trigger: SelectionResetTrigger) {
    mode = .browse
    members = []
  }
}
