import Testing

@testable import ImgManager

@Suite("UndoStack — one slot, truthful prior state")
struct UndoStackTests {

  @Test("One slot: recording a new entry OVERWRITES the previous one, not a push")
  func oneSlotOverwrites() {
    let stack = UndoStack()
    let first = UndoEntry(
      appliedState: .pick,
      priorStates: [PriorMarkSnapshot(imageID: 1, state: .none, revisionBefore: "r1")])
    let second = UndoEntry(
      appliedState: .dislike,
      priorStates: [PriorMarkSnapshot(imageID: 2, state: .pick, revisionBefore: "r2")])
    stack.record(first)
    stack.record(second)
    #expect(stack.entry == second)
  }

  @Test(
    "Truthful prior state: whatever was recorded is returned VERBATIM, never a guessed opposite")
  func truthfulPriorState() {
    let stack = UndoStack()
    // The applied state is `.pick`, but the TRUE prior state was `.dislike` — a naive "flip
    // the opposite of what was applied" implementation would restore `.none` or invent a
    // wrong value; this asserts the exact recorded truth survives untouched.
    let entry = UndoEntry(
      appliedState: .pick,
      priorStates: [PriorMarkSnapshot(imageID: 9, state: .dislike, revisionBefore: "r-real")])
    stack.record(entry)
    let consumed = stack.consume()
    #expect(consumed?.priorStates.first?.state == .dislike)
    #expect(consumed?.priorStates.first?.revisionBefore == "r-real")
  }

  @Test("consume() empties the slot — a second consume finds nothing")
  func consumeEmptiesSlot() {
    let stack = UndoStack()
    stack.record(
      UndoEntry(
        appliedState: .pick,
        priorStates: [PriorMarkSnapshot(imageID: 1, state: .none, revisionBefore: "r1")]))
    #expect(stack.canUndo)
    let first = stack.consume()
    #expect(first != nil)
    #expect(!stack.canUndo)
    #expect(stack.consume() == nil)
  }

  @Test("clear() empties the slot without returning anything")
  func clearEmptiesSlot() {
    let stack = UndoStack()
    stack.record(
      UndoEntry(
        appliedState: .pick,
        priorStates: [PriorMarkSnapshot(imageID: 1, state: .none, revisionBefore: "r1")]))
    stack.clear()
    #expect(!stack.canUndo)
  }

  @Test("A batch's prior states can differ per image — undo restores each one individually")
  func mixedPriorStatesInOneBatch() {
    let stack = UndoStack()
    let entry = UndoEntry(
      appliedState: .pick,
      priorStates: [
        PriorMarkSnapshot(imageID: 1, state: .none, revisionBefore: "a"),
        PriorMarkSnapshot(imageID: 2, state: .dislike, revisionBefore: "b"),
      ])
    stack.record(entry)
    let consumed = stack.consume()
    #expect(consumed?.imageIDs.sorted() == [1, 2])
    let byID = Dictionary(
      uniqueKeysWithValues: (consumed?.priorStates ?? []).map { ($0.imageID, $0.state) })
    // Type-qualified — `MarkStateValue` itself has a case named `none`, so a bare `.none` here
    // would match `Optional.none` (nil), not `.some(MarkStateValue.none)`.
    #expect(byID[1] == MarkStateValue.none)
    #expect(byID[2] == .dislike)
  }
}
