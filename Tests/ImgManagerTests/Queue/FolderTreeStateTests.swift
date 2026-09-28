import Testing

@testable import ImgManager

/// WP28 P1 (IMGMGR-448): the folder tree's state is hoisted into `RootView`, so it outlives the
/// workspace view that used to own it and has to end with the session, like `QueueStore`. Two
/// halves: the reset (the next account opens on no folders and no expansion) and the fence (a
/// load started under the old session never publishes into the new one).
@MainActor
@Suite("FolderTreeState session boundary")
struct FolderTreeStateTests {
  /// A load that answered, carrying one tier, so "published" and "empty" are distinguishable.
  private let answered = FolderTreeLoad(phase: .loaded, foldersByTier: [.incoming: []])

  @Test("the reset leaves no folders and no expansion behind")
  func endSessionEmptiesTheState() {
    let state = FolderTreeState()
    let generation = state.beginLoad()
    #expect(state.publish(answered, generation: generation, cached: nil))
    state.expandedTiers = [.incoming]
    state.expandedBranches = [.folder(7), .month("2026-09")]
    #expect(state.load.answered(.incoming))

    state.endSession()

    #expect(state.load.phase == .loading)
    #expect(!state.load.answered(.incoming))
    #expect(state.expandedTiers.isEmpty)
    #expect(state.expandedBranches.isEmpty)
  }

  @Test("a load started before the session ended is dropped when it lands")
  func aLoadFromTheOldSessionIsDropped() {
    let state = FolderTreeState()
    let generation = state.beginLoad()

    state.endSession()

    #expect(!state.publish(answered, generation: generation, cached: nil))
    #expect(!state.load.answered(.incoming))
    #expect(state.load.phase == .loading)
  }

  /// The positive controls: the drop above is the fence, not a publish that never works.
  @Test("a current load publishes, before and after a session boundary")
  func aCurrentLoadPublishes() {
    let state = FolderTreeState()
    let first = state.beginLoad()
    #expect(state.publish(answered, generation: first, cached: nil))
    #expect(state.load.answered(.incoming))

    state.endSession()
    let second = state.beginLoad()
    #expect(state.publish(answered, generation: second, cached: nil))
    #expect(state.load.answered(.incoming))
  }
}
