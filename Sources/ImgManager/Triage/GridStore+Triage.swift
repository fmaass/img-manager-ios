import Foundation

/// WP31 P1 (IMGMGR-460): Triage's store operations, each the shipped `GridStore` path — marks
/// through `applyMark` (revision preconditions, the undo slot, 409 handling), undo through
/// `undoLastMark`, and the successor through the helper the loupe shares, with Scene paging on.
extension GridStore: TriageStore {
  var triagePool: [TriagePoolEntry] {
    actionableImages.map { image in
      TriagePoolEntry(id: image.id, isMarked: MarkStateValue(image.mark.state) != .none)
    }
  }

  func triageSuccessor(after imageID: Int) async -> SuccessorLookup {
    await successor(after: imageID, pagesScenes: true)
  }

  func triageMark(_ state: MarkStateValue, imageID: Int) async -> TriageMarkOutcome {
    guard await applyMark(state, to: [imageID]) else { return .refused }
    // The entry this write recorded — kept only if it is this one mark, so Undo never restores
    // something else that happened to land in the slot.
    let entry = undo.entry
    let isThisMark = entry?.appliedState == state && entry?.imageIDs == [imageID]
    return .committed(isThisMark ? entry : nil)
  }

  var triageUndoEntry: UndoEntry? { undo.entry }

  func triageUndo() async -> UndoOutcome {
    await undoLastMark()
  }
}
