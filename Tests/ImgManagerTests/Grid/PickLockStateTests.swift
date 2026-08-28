import Foundation
import Testing

@testable import ImgManager

/// premise.out's five Pick Lock pins, each with its own test. The 350/351 ms boundary uses
/// `ContinuousClock.Instant` arithmetic directly (no real sleeping, no flakiness) — every
/// timestamp is constructed by hand from a fixed anchor.
@Suite("Pick Lock state machine (premise.out pins)")
struct PickLockStateTests {

  private func instant(_ base: ContinuousClock.Instant, plus ms: Int) -> ContinuousClock.Instant {
    base.advanced(by: .milliseconds(ms))
  }

  @Test("Pin (a): the FIRST activation always applies Pick immediately, never delayed")
  func firstActivationAppliesImmediately() {
    let state = PickLockState()
    let now = ContinuousClock.now
    let outcome = state.activateFromPickButton(at: now)
    #expect(outcome == .applyPick)
    #expect(state.state == .idle)
  }

  @Test("Pin (a): a second activation at EXACTLY 350 ms latches — inclusive boundary")
  func exactly350msLatches() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activateFromPickButton(at: t0) == .applyPick)
    let outcome = state.activateFromPickButton(at: instant(t0, plus: 350))
    #expect(outcome == .latch)
    #expect(state.state == .latched)
  }

  @Test("Pin (a): a second activation at 351 ms is an ordinary Pick — never a latch")
  func exactly351msDoesNotLatch() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activateFromPickButton(at: t0) == .applyPick)
    let outcome = state.activateFromPickButton(at: instant(t0, plus: 351))
    #expect(outcome == .applyPick)
    #expect(state.state == .idle)
  }

  @Test("Latched: re-tapping the Pick button unlatches, and applies nothing on that tap")
  func retapUnlatches() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    _ = state.activateFromPickButton(at: t0)
    _ = state.activateFromPickButton(at: instant(t0, plus: 100))  // latches
    #expect(state.state == .latched)
    let outcome = state.activateFromPickButton(at: instant(t0, plus: 200))
    #expect(outcome == .unlatch)
    #expect(state.state == .idle)
  }

  @Test("A stale first tap (well over 350 ms since the prior anchor) is just an ordinary Pick")
  func farApartTapsNeverLatch() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    #expect(state.activateFromPickButton(at: t0) == .applyPick)
    #expect(state.activateFromPickButton(at: instant(t0, plus: 5000)) == .applyPick)
    #expect(state.state == .idle)
  }

  @Test("Pin: keyboard P never participates in latch detection — before, during, or after")
  func keyboardPNeverParticipates() {
    let state = PickLockState()
    let t0 = ContinuousClock.now

    // A keyboard P does not arm the window: a button tap 100ms later still needs its OWN
    // pairing partner, not the keyboard press, to latch.
    state.activateFromKeyboard()
    let outcome = state.activateFromPickButton(at: instant(t0, plus: 100))
    #expect(outcome == .applyPick)  // treated as a first tap, not a paired second one
    #expect(state.state == .idle)

    // Keyboard P while genuinely latched does not unlatch and does not read/alter state.
    // Pairs with the t0+100 anchor above (100ms apart, within the 350ms window) to latch.
    _ = state.activateFromPickButton(at: instant(t0, plus: 200))
    #expect(state.state == .latched)
    state.activateFromKeyboard()
    #expect(state.state == .latched)
  }

  @Test("Pin (e), Lock-side: unlatch() resets state and the timing anchor")
  func unlatchResetsAnchor() {
    let state = PickLockState()
    let t0 = ContinuousClock.now
    _ = state.activateFromPickButton(at: t0)
    _ = state.activateFromPickButton(at: instant(t0, plus: 100))  // latches
    #expect(state.state == .latched)
    state.unlatch()
    #expect(state.state == .idle)
    // A fresh tap right after unlatch() is a first tap again (no stale anchor survives).
    #expect(state.activateFromPickButton(at: instant(t0, plus: 105)) == .applyPick)
  }

  @Test("exit() is idempotent and always returns to idle")
  func exitIsIdempotent() {
    let state = PickLockState()
    state.exit()
    #expect(state.state == .idle)
    let t0 = ContinuousClock.now
    _ = state.activateFromPickButton(at: t0)
    _ = state.activateFromPickButton(at: instant(t0, plus: 100))
    #expect(state.state == .latched)
    state.exit()
    #expect(state.state == .idle)
  }
}

@Suite("DragPaintSession — apply once per crossed tile per drag (pin d / selection semantics)")
struct DragPaintSessionTests {
  @Test("The first crossing of a tile returns true; re-entry during the same drag returns false")
  func onceEver() {
    var session = DragPaintSession()
    #expect(session.crossedTile(1) == true)
    #expect(session.crossedTile(1) == false)
    #expect(session.crossedTile(1) == false)
  }

  @Test("Distinct tiles are each true on their own first crossing")
  func distinctTilesEachOnce() {
    var session = DragPaintSession()
    #expect(session.crossedTile(1) == true)
    #expect(session.crossedTile(2) == true)
    #expect(session.crossedTile(1) == false)
    #expect(session.crossedTile(3) == true)
  }

  @Test("A fresh session (a new drag) forgets prior crossings")
  func freshSessionForgets() {
    var first = DragPaintSession()
    #expect(first.crossedTile(1) == true)
    var second = DragPaintSession()
    #expect(second.crossedTile(1) == true)
  }
}
