import Foundation

/// Which mark a latch applies. WP13 P2 (IMGMGR-222) — the owner's 2026-08-30 reversal of the WP8
/// P4 fold pin "(c) v1 is PICK-ONLY — Dislike never latches, no Lock in its long-press menu":
/// rejecting a run of frames has to cost what picking one costs, so the latch is ONE machine
/// parameterised by its verb rather than a second machine copied for Dislike. Mutual exclusion
/// between Pick Lock and Dislike Lock is therefore structural — a single `LockState` cannot hold
/// two verbs at once — not a rule some coordinator has to remember to enforce.
enum LatchVerb: String, Equatable, Sendable, CaseIterable {
  case pick
  case dislike

  /// The mark this verb writes. `MarkStateValue` lives in the same module (`UndoStack.swift`), so
  /// naming it here costs no import and keeps "the latched verb decides the mark" a single fact
  /// instead of a `switch` repeated at every latched call site in `GridStore`.
  var markState: MarkStateValue {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    }
  }
}

/// The exact copy premise.out and the plan gate pin verbatim — a persistent mode row directly
/// above the bottom action bar, in every grid layout, `Done` trailing, never overlaying a tile.
/// The Pick wording is unchanged from the shipped pin; Dislike's is its symmetric twin.
enum PickLockCopy {
  static func caption(for verb: LatchVerb) -> String {
    switch verb {
    case .pick: return "Pick Lock — tap photos to apply Pick"
    case .dislike: return "Dislike Lock — tap photos to apply Dislike"
    }
  }
}

/// What the caller should do in response to one activation of a latch-capable BUTTON control
/// (`PickLockState.activate(verb:at:)`). Only those buttons ever produce `.latch` or `.unlatch` —
/// see that method's doc comment for why keyboard `P`/`X` are a completely separate, simpler
/// entry point.
enum LatchButtonOutcome: Equatable, Sendable {
  /// Apply the activated verb's mark to the current target now. Covers an ordinary tap (not
  /// latched, no recent sibling tap on the SAME control), the FIRST tap of a potential pair —
  /// the pin is explicit that the first activation "applies immediately; it is never delayed
  /// waiting for a second tap" — and the cross-verb press that exits a latch (see `activate`).
  case applyMark
  /// This activation is consumed SOLELY to latch — the image it landed on already got its mark
  /// from the FIRST tap's `.applyMark`; nothing further is applied here.
  case latch
  /// Was latched on THIS verb; this tap exits the lock. Mirrors `.latch`: consumed solely to
  /// unlatch, no mark applied (exit is `Done`/re-tap/Esc-equivalent, never itself a mark action).
  case unlatch
}

/// The latch state machine (premise.out's five pins; plan fold item 5), now carrying a verb.
/// Pure and clock-injectable — no SwiftUI, no networking, no knowledge of which image is
/// "focused" (the caller owns that; this type only ever answers "what does THIS activation
/// mean").
///
/// Deliberately has NO knowledge of Select mode: the mutual-exclusion rule (pin e — "Lock entry
/// disabled while Select is active; entering Select while latched first unlatches") is a
/// cross-cutting concern between this type and `SelectionState`, and lives at the coordinator
/// (`GridStore`) rather than being wired into either leaf type — each stays a simple, narrowly
/// testable state machine, and the coordinator's own tests prove the combined invariant.
@Observable
final class PickLockState {
  enum LockState: Equatable, Sendable {
    case idle
    case latched(LatchVerb)
  }

  private(set) var state: LockState = .idle
  /// The anchor a following activation is measured against, keyed by the VERB that set it: a
  /// Pick tap followed within the window by a Dislike tap is two ordinary marks, never a latch,
  /// because the two taps are not activations of the same control.
  private var lastButtonActivation: (verb: LatchVerb, instant: ContinuousClock.Instant)?
  private let clock: ContinuousClock
  /// Pin (a): 350 ms, INCLUSIVE — an activation at exactly 350 ms since the prior one still
  /// latches; 351 ms is an ordinary mark. Identical for both verbs.
  static let doubleTapWindow: Duration = .milliseconds(350)

  init(clock: ContinuousClock = ContinuousClock()) {
    self.clock = clock
  }

  /// The latched verb, or `nil` when idle — the read every caller actually wants ("is a lock on,
  /// and which mark does a tap apply?") expressed once instead of a `case` match repeated at
  /// every call site.
  var latchedVerb: LatchVerb? {
    if case .latched(let verb) = state { return verb }
    return nil
  }

  /// A latch-capable BUTTON's own activation path (tap, or a pointer click on the button) — the
  /// ONLY path that can latch or unlatch. `now` is injectable for the 350/351 ms boundary tests;
  /// production call sites omit it and get the real clock.
  ///
  /// Pressing the OTHER verb's button while latched **exits the latch and applies that verb
  /// once** (plan Phase 2, pre-decided pivot): it never silently switches the latch, because a
  /// mode the reader did not ask to change is worse than one press that lands where it looks
  /// like it lands. That press then becomes the new anchor, exactly as any first tap does — so a
  /// reader who really wants the other lock gets it with a second, deliberate tap.
  @discardableResult
  func activate(verb: LatchVerb, at now: ContinuousClock.Instant? = nil) -> LatchButtonOutcome {
    let instant = now ?? clock.now
    switch state {
    case .latched(let latched) where latched == verb:
      state = .idle
      lastButtonActivation = nil
      return .unlatch
    case .latched:
      state = .idle
      lastButtonActivation = (verb, instant)
      return .applyMark
    case .idle:
      let outcome: LatchButtonOutcome
      if let last = lastButtonActivation, last.verb == verb,
        instant - last.instant <= Self.doubleTapWindow
      {
        state = .latched(verb)
        outcome = .latch
      } else {
        outcome = .applyMark
      }
      // Every idle-state activation becomes the new anchor a FOLLOWING tap is measured
      // against — including the tap that just latched (its own timestamp is irrelevant once
      // latched, but resetting to nil here vs. leaving it stale makes no behavioral
      // difference since `.latched` never reads it again; left as `instant` for clarity that
      // "this control was just touched" remains true).
      lastButtonActivation = (verb, instant)
      return outcome
    }
  }

  /// Keyboard `P` and `X`. Pin: "Keyboard P does not participate in latch detection", and the
  /// owner's Dislike-Lock reversal changes nothing about it — `X` is the same kind of entry, so
  /// the invariant now reads "no keyboard mark participates in latch detection, either verb".
  /// This method reads and writes NOTHING on this type: it neither contributes to nor is
  /// affected by a button's double-tap window, and it never latches or unlatches regardless of
  /// the current `state`. The caller always applies an ordinary mark to its current target.
  func activateFromKeyboard() {
    // Intentionally empty — see the doc comment. Kept as a named method (rather than callers
    // just not calling anything on this type) so the "P/X never touch the latch" invariant has
    // one call site a test can assert against, and so a future edit that tries to wire a key
    // into the latch machinery has to touch this method to do it.
  }

  /// Pin (e), the Lock-side half: Select entry unlatches first. The coordinator calls this
  /// before entering Select — never the other way around (this type never observes Select).
  func unlatch() {
    state = .idle
    lastButtonActivation = nil
  }

  /// Grid-only, never the loupe; auto-exit on leaving the shoot. The coordinator calls this on
  /// shoot change, `Done`, and Esc — all three collapse to the same reset.
  func exit() {
    state = .idle
    lastButtonActivation = nil
  }
}

/// The amendment's discoverable VISIBLE alternative to the undiscoverable double-tap gesture
/// (functional spec, Pick Lock section: "long-press → 'Lock Pick' as the discoverable visible
/// alternative"; gate's unasked issue), now offered for both verbs — "Lock Pick" on the Pick
/// button, "Lock Dislike" on the Dislike button. A menu command is an explicit choice, not "the
/// second tap of a pair": it always latches immediately, no timing window, and is a no-op if a
/// lock is ALREADY on (either verb — the menu's entry is only offered while idle; this guard is
/// the belt-and-suspenders backstop, and it is what keeps the two locks mutually exclusive on
/// this path without a second rule to remember).
extension PickLockState {
  func forceLatch(_ verb: LatchVerb) {
    guard state == .idle else { return }
    state = .latched(verb)
    lastButtonActivation = nil
  }
}

/// A latch-capable button's presentation, pinned as DATA so a test can assert the exact caption
/// and an unmistakable visual-state pair without touching SwiftUI (premise.out pin (b): "the Pick
/// button simultaneously uses an obvious selected/tinted state and an accessibility selected
/// value"). The view consumes this value directly — `isProminent` drives
/// `.buttonStyle(.borderedProminent)` (a real, reliably-visible fill-vs-outline difference, not
/// a tint alone) and `accessibilitySelected` drives `.accessibilityAddTraits(.isSelected)`.
///
/// It is computed PER CONTROL: while Dislike is latched, the Dislike button is the prominent,
/// selected one and the Pick button is plain — the alternative (a lock state that lights both
/// buttons) would state the mode without ever saying which mark a tap now applies.
struct PickButtonPresentation: Equatable {
  var isProminent: Bool
  var accessibilitySelected: Bool
  /// The persistent mode-row caption to show ABOVE the action bar — `nil` unless THIS control is
  /// the latched one.
  var modeRowCaption: String?

  static func `for`(_ lockState: PickLockState.LockState, control: LatchVerb)
    -> PickButtonPresentation
  {
    guard case .latched(let latched) = lockState, latched == control else {
      return PickButtonPresentation(
        isProminent: false, accessibilitySelected: false, modeRowCaption: nil)
    }
    return PickButtonPresentation(
      isProminent: true, accessibilitySelected: true,
      modeRowCaption: PickLockCopy.caption(for: latched))
  }
}

/// Pin (d)'s per-drag "apply once per crossed tile" dedup, and the identical rule selection
/// drag uses ("pointer selection drag adds each crossed tile once"). Shared by both because the
/// semantics are byte-for-byte the same: a `Set` of ids already acted on THIS drag gesture: a
/// completed touch/Pencil tap never constructs one of these at all (pin d: "touch/Pencil drag
/// never paints" — there is no touch-driven call site for this type, by construction; only a
/// pointer-hover-drag gesture recognizer, wired for iPad pointer input only, ever calls it).
struct DragPaintSession: Sendable {
  private var crossed: Set<GridDisplayID> = []

  /// Returns `true` the FIRST time `id` is crossed in this session (the caller should apply its
  /// action then), and `false` on every re-entry of the same cell during the same drag.
  ///
  /// WP12: keyed by `GridDisplayID` rather than a bare `Int` so a scene card and a photograph
  /// that happen to share a number are two different cells here, as they are everywhere else.
  mutating func crossedTile(_ id: GridDisplayID) -> Bool {
    guard !crossed.contains(id) else { return false }
    crossed.insert(id)
    return true
  }
}
