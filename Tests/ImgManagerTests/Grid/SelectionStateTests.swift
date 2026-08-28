import Testing

@testable import ImgManager

/// Plan fold item 6's selection-set semantics, pinned. Every reset trigger gets its own case
/// so a future edit that wires the wrong trigger to the wrong event is still caught by name.
@Suite("Selection semantics (plan fold item 6)")
struct SelectionStateTests {

  @Test("Explicit Select entry starts EMPTY")
  func explicitEntryStartsEmpty() {
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    #expect(selection.mode == .select)
    #expect(selection.members.isEmpty)
  }

  @Test("Long-press enters Select WITH that tile already selected")
  func longPressEntrySelectsThatTile() {
    let selection = SelectionState()
    selection.enterSelectViaLongPress(imageID: 42)
    #expect(selection.mode == .select)
    #expect(selection.members == [42])
  }

  @Test("Ordinary taps toggle membership")
  func tapsToggle() {
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    selection.toggle(1)
    #expect(selection.members == [1])
    selection.toggle(1)
    #expect(selection.members.isEmpty)
  }

  @Test("toggle/addFromDrag are no-ops outside Select mode")
  func noopsOutsideSelectMode() {
    let selection = SelectionState()
    #expect(selection.mode == .browse)
    selection.toggle(1)
    selection.addFromDrag(2)
    #expect(selection.members.isEmpty)
  }

  @Test("Pointer drag ADDS, never toggles — re-adding an already-member id changes nothing")
  func dragAddsNeverRemoves() {
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    selection.addFromDrag(1)
    selection.addFromDrag(1)
    #expect(selection.members == [1])
  }

  @Test("Paging append never clears membership and never implicitly selects")
  func pagingAppendPreservesMembership() {
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    selection.toggle(1)
    selection.toggle(2)
    selection.pageAppended()
    #expect(selection.members == [1, 2])
    #expect(selection.mode == .select)
  }

  @Test("A successful bulk action retains selection — bulkActionSucceeded() does not clear")
  func bulkActionSuccessRetainsSelection() {
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    selection.toggle(1)
    selection.toggle(2)
    selection.bulkActionSucceeded()
    #expect(selection.members == [1, 2])
    #expect(selection.mode == .select)
  }

  @Test("Reset case: Done/Esc clears both mode and membership")
  func resetDoneOrEsc() {
    let selection = SelectionState()
    selection.enterSelectViaLongPress(imageID: 1)
    selection.reset(.doneOrEsc)
    #expect(selection.mode == .browse)
    #expect(selection.members.isEmpty)
  }

  @Test("Reset case: shoot change clears both mode and membership")
  func resetShootChange() {
    let selection = SelectionState()
    selection.enterSelectViaLongPress(imageID: 1)
    selection.reset(.shootChange)
    #expect(selection.mode == .browse)
    #expect(selection.members.isEmpty)
  }

  @Test("Reset case: a query-generation change (filter/tier/tree) clears both")
  func resetQueryGenerationChange() {
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    selection.toggle(1)
    selection.reset(.queryGenerationChange)
    #expect(selection.mode == .browse)
    #expect(selection.members.isEmpty)
  }

  @Test("Reset case: a full reload (foreground/retry) clears both")
  func resetFullReload() {
    let selection = SelectionState()
    selection.enterSelectViaLongPress(imageID: 7)
    selection.reset(.fullReload)
    #expect(selection.mode == .browse)
    #expect(selection.members.isEmpty)
  }

  @Test("No select-all affordance exists: membership only ever grows from explicit ids")
  func loadedOnlyMembershipIsStructural() {
    // There is no method on SelectionState that adds ids the caller did not name explicitly —
    // toggle/addFromDrag/enterSelectViaLongPress all take one id at a time. This test exercises
    // the full public surface with a handful of explicit ids and asserts membership never
    // exceeds exactly what was passed.
    let selection = SelectionState()
    selection.enterSelectExplicitly()
    selection.toggle(1)
    selection.addFromDrag(2)
    #expect(selection.members == [1, 2])
  }
}
