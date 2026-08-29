import Foundation

/// The exact copy premise.out and the plan gate pin verbatim — a persistent mode row directly
/// above the bottom action bar, in every grid layout, `Done` trailing, never overlaying a tile.
enum PickLockCopy {
  static let caption = "Pick Lock — tap photos to apply Pick"
}

/// What the caller should do in response to one activation of the Pick BUTTON control
/// (`PickLockState.activateFromPickButton`). Only the Pick button ever produces `.latch` or
/// `.unlatch` — see that method's doc comment for why keyboard `P` is a completely separate,
/// simpler entry point.
enum PickButtonOutcome: Equatable, Sendable {
  /// Apply Pick to the focused image now. Covers both an ordinary tap (not latched, no recent
  /// sibling tap) and the FIRST tap of a potential pair — the pin is explicit that the first
  /// activation "applies immediately; it is never delayed waiting for a second tap", so there is
  /// no separate "maybe-first-of-a-pair" case: the caller always applies Pick synchronously.
  case applyPick
  /// This activation is consumed SOLELY to latch — the image it landed on already got its Pick
  /// from the FIRST tap's `.applyPick`; nothing further is applied here.
  case latch
  /// Was latched; this tap exits the lock. Mirrors `.latch`: consumed solely to unlatch, no
  /// Pick application (exit is `Done`/re-tap/Esc-equivalent, never itself a mark action).
  case unlatch
}

/// Pick Lock's latch state machine (premise.out's five pins; plan fold item 5). Pure and
/// clock-injectable — no SwiftUI, no networking, no knowledge of which image is "focused" (the
/// caller owns that; this type only ever answers "what does THIS activation mean").
///
/// Deliberately has NO knowledge of Select mode: the mutual-exclusion rule (pin e — "Lock entry
/// disabled while Select is active; entering Select while latched first unlatches") is a
/// cross-cutting concern between this type and `SelectionState`, and lives at the coordinator
/// (`GridStore`) rather than being wired into either leaf type — each stays a simple, narrowly
/// testable state machine, and the coordinator's own tests prove the combined invariant.
@Observable
final class PickLockState {
  enum LockState: Equatable, Sendable { case idle, latched }

  private(set) var state: LockState = .idle
  private var lastPickButtonActivation: ContinuousClock.Instant?
  private let clock: ContinuousClock
  /// Pin (a): 350 ms, INCLUSIVE — an activation at exactly 350 ms since the prior one still
  /// latches; 351 ms is an ordinary Pick.
  static let doubleTapWindow: Duration = .milliseconds(350)

  init(clock: ContinuousClock = ContinuousClock()) {
    self.clock = clock
  }

  /// The Pick BUTTON's own activation path (tap, or a pointer click on the button) — the ONLY
  /// path that can latch or unlatch. `now` is injectable for the 350/351 ms boundary tests;
  /// production call sites omit it and get the real clock.
  @discardableResult
  func activateFromPickButton(at now: ContinuousClock.Instant? = nil) -> PickButtonOutcome {
    let instant = now ?? clock.now
    switch state {
    case .latched:
      state = .idle
      lastPickButtonActivation = nil
      return .unlatch
    case .idle:
      let outcome: PickButtonOutcome
      if let last = lastPickButtonActivation, instant - last <= Self.doubleTapWindow {
        state = .latched
        outcome = .latch
      } else {
        outcome = .applyPick
      }
      // Every idle-state activation becomes the new anchor a FOLLOWING tap is measured
      // against — including the tap that just latched (its own timestamp is irrelevant once
      // latched, but resetting to nil here vs. leaving it stale makes no behavioral
      // difference since `.latched` never reads it again; left as `instant` for clarity that
      // "this control was just touched" remains true).
      lastPickButtonActivation = instant
      return outcome
    }
  }

  /// Keyboard `P`. Pin: "Keyboard P does not participate in latch detection" — this method
  /// reads and writes NOTHING on this type: it neither contributes to nor is affected by the
  /// button's own double-tap window, and it never latches or unlatches regardless of the
  /// current `state`. The caller always applies an ordinary Pick to the focused image.
  func activateFromKeyboard() {
    // Intentionally empty — see the doc comment. Kept as a named method (rather than callers
    // just not calling anything on this type) so the "P never touches Pick Lock" invariant has
    // one call site a test can assert against, and so a future edit that tries to wire P into
    // the latch machinery has to touch this method to do it.
  }

  /// Pin (e), the Lock-side half: Select entry unlatches first. The coordinator calls this
  /// before entering Select — never the other way around (this type never observes Select).
  func unlatch() {
    state = .idle
    lastPickButtonActivation = nil
  }

  /// Grid-only, never the loupe; auto-exit on leaving the shoot. The coordinator calls this on
  /// shoot change, `Done`, and Esc — all three collapse to the same reset.
  func exit() {
    state = .idle
    lastPickButtonActivation = nil
  }
}

/// The amendment's discoverable VISIBLE alternative to the undiscoverable double-tap gesture
/// (functional spec, Pick Lock section: "long-press → 'Lock Pick' as the discoverable visible
/// alternative"; gate's unasked issue). A menu command is an explicit choice, not "the second
/// tap of a pair" — it always latches immediately, no timing window, and is a no-op if already
/// latched (the menu's own "Lock Pick" entry is only offered while idle; this guard is the
/// belt-and-suspenders backstop).
extension PickLockState {
  func forceLatch() {
    guard state == .idle else { return }
    state = .latched
    lastPickButtonActivation = nil
  }
}

/// The Pick button's presentation, pinned as DATA so a test can assert the exact caption and an
/// unmistakable visual-state pair without touching SwiftUI (premise.out pin (b): "the Pick
/// button simultaneously uses an obvious selected/tinted state and an accessibility selected
/// value"). The view consumes this value directly — `isProminent` drives
/// `.buttonStyle(.borderedProminent)` (a real, reliably-visible fill-vs-outline difference, not
/// a tint alone) and `accessibilitySelected` drives `.accessibilityAddTraits(.isSelected)`.
struct PickButtonPresentation: Equatable {
  var isProminent: Bool
  var accessibilitySelected: Bool
  /// The persistent mode-row caption to show ABOVE the action bar — `nil` when not latched.
  var modeRowCaption: String?

  static func `for`(_ lockState: PickLockState.LockState) -> PickButtonPresentation {
    switch lockState {
    case .idle:
      return PickButtonPresentation(
        isProminent: false, accessibilitySelected: false, modeRowCaption: nil)
    case .latched:
      return PickButtonPresentation(
        isProminent: true, accessibilitySelected: true, modeRowCaption: PickLockCopy.caption)
    }
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
