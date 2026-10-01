import Testing

@testable import ImgManager

/// WP30 P3 fold round 1, B3: a pane's image load publishes only when it still owns the pane —
/// the latest ticket, not cancelled, and its image still the one the session shows there.
@Suite("ComparePaneLoadGate — superseded and out-of-order pane loads (WP30 P3)")
struct ComparePaneLoadGateTests {
  @Test("Out of order: the newer load lands first, the older one's late answer is refused")
  func outOfOrderCompletions() {
    var gate = ComparePaneLoadGate()
    let older = gate.begin(10)
    let newer = gate.begin(20)
    #expect(gate.accepts(newer, currentImageID: 20, isCancelled: false))
    #expect(!gate.accepts(older, currentImageID: 20, isCancelled: false))
  }

  @Test("In order: the older answer is refused even when it arrives first")
  func supersededLoadArrivingFirst() {
    var gate = ComparePaneLoadGate()
    let older = gate.begin(10)
    let newer = gate.begin(20)
    #expect(!gate.accepts(older, currentImageID: 20, isCancelled: false))
    #expect(gate.accepts(newer, currentImageID: 20, isCancelled: false))
  }

  @Test("A→B→A: only the latest load of the same image publishes")
  func sameImageRequestedAgain() {
    var gate = ComparePaneLoadGate()
    let first = gate.begin(10)
    _ = gate.begin(20)
    let again = gate.begin(10)
    #expect(!gate.accepts(first, currentImageID: 10, isCancelled: false))
    #expect(gate.accepts(again, currentImageID: 10, isCancelled: false))
  }

  @Test("A cancelled load, or one whose pane has moved on, publishes nothing")
  func cancelledOrMovedOn() {
    var gate = ComparePaneLoadGate()
    let ticket = gate.begin(10)
    #expect(!gate.accepts(ticket, currentImageID: 10, isCancelled: true))
    #expect(!gate.accepts(ticket, currentImageID: 30, isCancelled: false))
    #expect(!gate.accepts(ticket, currentImageID: nil, isCancelled: false))
    // Positive control: the same ticket, uncancelled and still owning the pane, publishes.
    #expect(gate.accepts(ticket, currentImageID: 10, isCancelled: false))
  }

  @Test("The end state (no right image) is itself a load that owns the pane")
  func endState() {
    var gate = ComparePaneLoadGate()
    _ = gate.begin(10)
    let empty = gate.begin(nil)
    #expect(gate.accepts(empty, currentImageID: nil, isCancelled: false))
  }
}
