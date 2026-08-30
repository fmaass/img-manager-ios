import Foundation
import Testing

@testable import ImgManager

/// premise.out's five lock pins, each with its own test, plus WP13 P2's verb generalization
/// (IMGMGR-222). The 350/351 ms boundary uses `ContinuousClock.Instant` arithmetic directly (no
/// real sleeping, no flakiness) — every timestamp is constructed by hand from a fixed anchor.
///
/// Every pre-P2 test below is unchanged except for naming its verb at the call site: the pins
/// are the SAME pins, and a generalization that had to weaken one of them would be the wrong
/// generalization.
@Suite("Pick/Dislike Lock state machine (premise.out pins + WP13 P2 verb parity)")
struct PickLockStateTests {

  private func instant(_ base: ContinuousClock.Instant, plus ms: Int) -> ContinuousClock.Instant {
    base.advanced(by: .milliseconds(ms))
  }

  @Test("Pin (a): the FIRST activation always applies Pick immediately, never delayed")
  func firstActivationAppliesImmediately() {
    let state = PickLockState()
    let now = ContinuousClock.now
    let outcome = state.activate(verb: .pick, at: now)
    #expect(outcome == .applyMark)
    #expect(state.state == .idle)
  }

  @Test("Pin (a): a second activation at EXACTLY 350 ms latches — inclusive boundary")
  func exactly350msLatches() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activate(verb: .pick, at: t0) == .applyMark)
    let outcome = state.activate(verb: .pick, at: instant(t0, plus: 350))
    #expect(outcome == .latch)
    #expect(state.state == .latched(.pick))
  }

  @Test("Pin (a): a second activation at 351 ms is an ordinary Pick — never a latch")
  func exactly351msDoesNotLatch() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activate(verb: .pick, at: t0) == .applyMark)
    let outcome = state.activate(verb: .pick, at: instant(t0, plus: 351))
    #expect(outcome == .applyMark)
    #expect(state.state == .idle)
  }

  @Test("Latched: re-tapping the Pick button unlatches, and applies nothing on that tap")
  func retapUnlatches() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    _ = state.activate(verb: .pick, at: t0)
    _ = state.activate(verb: .pick, at: instant(t0, plus: 100))  // latches
    #expect(state.state == .latched(.pick))
    let outcome = state.activate(verb: .pick, at: instant(t0, plus: 200))
    #expect(outcome == .unlatch)
    #expect(state.state == .idle)
  }

  @Test("A stale first tap (well over 350 ms since the prior anchor) is just an ordinary Pick")
  func farApartTapsNeverLatch() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activate(verb: .pick, at: t0) == .applyMark)
    #expect(state.activate(verb: .pick, at: instant(t0, plus: 5000)) == .applyMark)
    #expect(state.state == .idle)
  }

  @Test("Pin: keyboard P never participates in latch detection — before, during, or after")
  func keyboardPNeverParticipates() {
    let state = PickLockState()
    let t0 = ContinuousClock.now

    // A keyboard P does not arm the window: a button tap 100ms later still needs its OWN
    // pairing partner, not the keyboard press, to latch.
    state.activateFromKeyboard()
    let outcome = state.activate(verb: .pick, at: instant(t0, plus: 100))
    #expect(outcome == .applyMark)  // treated as a first tap, not a paired second one
    #expect(state.state == .idle)

    // Keyboard P while genuinely latched does not unlatch and does not read/alter state.
    // Pairs with the t0+100 anchor above (100ms apart, within the 350ms window) to latch.
    _ = state.activate(verb: .pick, at: instant(t0, plus: 200))
    #expect(state.state == .latched(.pick))
    state.activateFromKeyboard()
    #expect(state.state == .latched(.pick))
  }

  @Test("Pin (e), Lock-side: unlatch() resets state and the timing anchor")
  func unlatchResetsAnchor() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    _ = state.activate(verb: .pick, at: t0)
    _ = state.activate(verb: .pick, at: instant(t0, plus: 100))  // latches
    #expect(state.state == .latched(.pick))
    state.unlatch()
    #expect(state.state == .idle)
    // A fresh tap right after unlatch() is a first tap again (no stale anchor survives).
    #expect(state.activate(verb: .pick, at: instant(t0, plus: 105)) == .applyMark)
  }

  @Test("exit() is idempotent and always returns to idle")
  func exitIsIdempotent() {
    let state = PickLockState()
    state.exit()
    #expect(state.state == .idle)
    let t0 = ContinuousClock.now
    _ = state.activate(verb: .pick, at: t0)
    _ = state.activate(verb: .pick, at: instant(t0, plus: 100))
    #expect(state.state == .latched(.pick))
    state.exit()
    #expect(state.state == .idle)
  }

  // MARK: - WP13 P2 (IMGMGR-222): the same machine, the other verb

  @Test("Dislike latches on its OWN double tap inside the window — symmetric with Pick")
  func dislikeLatchesOnItsOwnDoubleTapWithinTheWindow() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activate(verb: .dislike, at: t0) == .applyMark)
    #expect(state.state == .idle)
    #expect(state.activate(verb: .dislike, at: instant(t0, plus: 200)) == .latch)
    #expect(state.state == .latched(.dislike))
    #expect(state.latchedVerb == .dislike)
  }

  @Test("A Pick tap then a Dislike tap inside the window latches NEITHER — two ordinary marks")
  func aPickTapFollowedByADislikeTapWithinTheWindowLatchesNeither() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activate(verb: .pick, at: t0) == .applyMark)
    // 100 ms later, well inside the 350 ms window — but a DIFFERENT control, so it is a first
    // tap of its own, not the second of a pair. A verb-blind anchor would latch Dislike here.
    #expect(state.activate(verb: .dislike, at: instant(t0, plus: 100)) == .applyMark)
    #expect(state.state == .idle)
    #expect(state.latchedVerb == nil)
    // And the mirror: Dislike then Pick.
    let other = PickLockState()
    #expect(other.activate(verb: .dislike, at: t0) == .applyMark)
    #expect(other.activate(verb: .pick, at: instant(t0, plus: 100)) == .applyMark)
    #expect(other.state == .idle)
  }

  @Test("The 350 ms boundary is inclusive and 351 ms is an ordinary mark — for BOTH verbs")
  func the350msBoundaryIsInclusiveForBothVerbs() {
    for verb in LatchVerb.allCases {
      let atBoundary = PickLockState()
      let t0 = ContinuousClock.now
      #expect(atBoundary.activate(verb: verb, at: t0) == .applyMark)
      #expect(atBoundary.activate(verb: verb, at: instant(t0, plus: 350)) == .latch)
      #expect(atBoundary.state == .latched(verb))

      let pastBoundary = PickLockState()
      #expect(pastBoundary.activate(verb: verb, at: t0) == .applyMark)
      #expect(pastBoundary.activate(verb: verb, at: instant(t0, plus: 351)) == .applyMark)
      #expect(pastBoundary.state == .idle)
    }
  }

  @Test("Latched: re-tapping the SAME verb's button unlatches and applies nothing — both verbs")
  func retappingTheLatchedVerbUnlatches() {
    for verb in LatchVerb.allCases {
      let state = PickLockState()
      let t0 = ContinuousClock.now
      _ = state.activate(verb: verb, at: t0)
      _ = state.activate(verb: verb, at: instant(t0, plus: 100))
      #expect(state.state == .latched(verb))
      #expect(state.activate(verb: verb, at: instant(t0, plus: 200)) == .unlatch)
      #expect(state.state == .idle)
    }
  }

  @Test(
    "Pre-decided pivot: pressing the OTHER verb while latched exits the latch and applies once — it never switches the latch"
  )
  func pressingTheOtherVerbWhileLatchedExitsAndAppliesOnce() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    _ = state.activate(verb: .pick, at: t0)
    _ = state.activate(verb: .pick, at: instant(t0, plus: 100))
    #expect(state.state == .latched(.pick))

    #expect(state.activate(verb: .dislike, at: instant(t0, plus: 500)) == .applyMark)
    // Exited, NOT switched: a silent switch would leave `.latched(.dislike)` here and every
    // following tap on a tile would write Dislike without the reader ever asking for that mode.
    #expect(state.state == .idle)
    #expect(state.latchedVerb == nil)
    // That press anchors its own verb, so a deliberate second Dislike press does latch it.
    #expect(state.activate(verb: .dislike, at: instant(t0, plus: 600)) == .latch)
    #expect(state.state == .latched(.dislike))
  }

  @Test("forceLatch takes a verb, and refuses while a lock of the OTHER verb is already on")
  func forceLatchIsVerbedAndMutuallyExclusive() {
    let state = PickLockState()
    state.forceLatch(.dislike)
    #expect(state.state == .latched(.dislike))
    // The two locks cannot coexist: the menu twin is a no-op rather than a switch, which is the
    // same "never switch a mode the reader did not ask to change" rule the button path follows.
    state.forceLatch(.pick)
    #expect(state.state == .latched(.dislike))
    state.exit()
    state.forceLatch(.pick)
    #expect(state.state == .latched(.pick))
  }

  @Test("Keyboard marks never participate in latch detection — for the Dislike verb too")
  func keyboardNeverParticipatesForDislikeEither() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    state.activateFromKeyboard()
    #expect(state.activate(verb: .dislike, at: instant(t0, plus: 100)) == .applyMark)
    #expect(state.state == .idle)
    _ = state.activate(verb: .dislike, at: instant(t0, plus: 200))
    #expect(state.state == .latched(.dislike))
    state.activateFromKeyboard()
    #expect(state.state == .latched(.dislike))
  }
}

@Suite("DragPaintSession — apply once per crossed tile per drag (pin d / selection semantics)")
struct DragPaintSessionTests {
  @Test("The first crossing of a tile returns true; re-entry during the same drag returns false")
  func onceEver() {
    var session = DragPaintSession()
    #expect(session.crossedTile(.image(1)) == true)
    #expect(session.crossedTile(.image(1)) == false)
    #expect(session.crossedTile(.image(1)) == false)
  }

  @Test("Distinct tiles are each true on their own first crossing")
  func distinctTilesEachOnce() {
    var session = DragPaintSession()
    #expect(session.crossedTile(.image(1)) == true)
    #expect(session.crossedTile(.image(2)) == true)
    #expect(session.crossedTile(.image(1)) == false)
    #expect(session.crossedTile(.image(3)) == true)
  }

  @Test("WP12: a scene card and a photograph that share a number are two different cells")
  func stackAndImageWithTheSameNumberAreDistinct() {
    // The dedup set is keyed by display id, not by a bare Int, so crossing card 7 does not make
    // photograph 7 look already-crossed — which would silently skip a real mark.
    var session = DragPaintSession()
    #expect(session.crossedTile(.stack(7)) == true)
    #expect(session.crossedTile(.image(7)) == true)
    #expect(session.crossedTile(.stack(7)) == false)
    #expect(session.crossedTile(.image(7)) == false)
  }

  @Test("A fresh session (a new drag) forgets prior crossings")
  func freshSessionForgets() {
    var first = DragPaintSession()
    #expect(first.crossedTile(.image(1)) == true)
    var second = DragPaintSession()
    #expect(second.crossedTile(.image(1)) == true)
  }
}

@Suite("Latch button presentation (diff-gate round 2, blocker 4: caption + unmistakable state)")
struct PickButtonPresentationTests {
  @Test("Idle: neither control is prominent, accessibility-selected, or captioned")
  func idlePresentation() {
    for verb in LatchVerb.allCases {
      let presentation = PickButtonPresentation.for(.idle, control: verb)
      #expect(presentation.isProminent == false)
      #expect(presentation.accessibilitySelected == false)
      #expect(presentation.modeRowCaption == nil)
    }
  }

  @Test("Latched: prominent AND accessibility-selected AND the exact pinned caption — both verbs")
  func latchedPresentation() {
    let pick = PickButtonPresentation.for(.latched(.pick), control: .pick)
    #expect(pick.isProminent == true)
    #expect(pick.accessibilitySelected == true)
    #expect(pick.modeRowCaption == "Pick Lock — tap photos to apply Pick")

    let dislike = PickButtonPresentation.for(.latched(.dislike), control: .dislike)
    #expect(dislike.isProminent == true)
    #expect(dislike.accessibilitySelected == true)
    #expect(dislike.modeRowCaption == "Dislike Lock — tap photos to apply Dislike")
  }

  @Test("A latch lights ONLY its own control — the other stays plain and uncaptioned")
  func theOtherControlIsNotLit() {
    let pickWhileDislikeLatched = PickButtonPresentation.for(.latched(.dislike), control: .pick)
    #expect(pickWhileDislikeLatched.isProminent == false)
    #expect(pickWhileDislikeLatched.accessibilitySelected == false)
    #expect(pickWhileDislikeLatched.modeRowCaption == nil)

    let dislikeWhilePickLatched = PickButtonPresentation.for(.latched(.pick), control: .dislike)
    #expect(dislikeWhilePickLatched.isProminent == false)
    #expect(dislikeWhilePickLatched.accessibilitySelected == false)
    #expect(dislikeWhilePickLatched.modeRowCaption == nil)
  }

  @Test("The exact caption constants match the pin and its symmetric twin verbatim")
  func captionConstantIsExact() {
    #expect(PickLockCopy.caption(for: .pick) == "Pick Lock — tap photos to apply Pick")
    #expect(PickLockCopy.caption(for: .dislike) == "Dislike Lock — tap photos to apply Dislike")
  }

  @Test("Each verb writes its own mark — the one mapping every latched call site reads")
  func verbMarkStates() {
    #expect(LatchVerb.pick.markState == .pick)
    #expect(LatchVerb.dislike.markState == .dislike)
  }
}
