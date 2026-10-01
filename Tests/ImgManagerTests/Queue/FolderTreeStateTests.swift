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

/// IMGMGR-462 (WP31 P3): the Compact Library tab opens with the Incoming tier open, so a root
/// shoot is one tap from its grid and two from Triage. One shot per session, additive, Compact
/// only — `LibraryTriageUITests` is the end-to-end proof; these pin the rule's edges.
@MainActor
@Suite("FolderTreeState Compact launch opening")
struct FolderTreeLaunchOpeningTests {
  private let answered = FolderTreeLoad(phase: .loaded, foldersByTier: [.incoming: []])

  private func published(_ load: FolderTreeLoad) -> FolderTreeState {
    let state = FolderTreeState()
    let generation = state.beginLoad()
    #expect(state.publish(load, generation: generation, cached: nil))
    return state
  }

  @Test("a Compact load that answered for Incoming opens Incoming and nothing else")
  func compactOpensIncomingOnly() {
    let state = published(answered)

    state.applyCompactLaunchOpening(layoutMode: .compact)

    #expect(state.expandedTiers == [.incoming])
    #expect(state.expandedBranches.isEmpty)
    #expect(FolderTreeState.compactLaunchTiers == [.incoming])
  }

  /// Scope: the split's sidebar launches exactly as before, and a Regular load leaves the
  /// one-shot armed for a later Compact mount.
  @Test("Regular never opens a tier, and does not consume the Compact opening")
  func regularIsUntouched() {
    let state = published(answered)

    state.applyCompactLaunchOpening(layoutMode: .regular3)
    state.applyCompactLaunchOpening(layoutMode: .regular2)
    #expect(state.expandedTiers.isEmpty)
    #expect(!state.appliedCompactLaunchOpening)

    state.applyCompactLaunchOpening(layoutMode: .compact)
    #expect(state.expandedTiers == [.incoming])
  }

  /// Boundary: nothing published yet (the first frame), so there is no tier to open.
  @Test("before the first load answers, nothing opens and the opening stays armed")
  func nothingBeforeTheLoadAnswers() {
    let state = FolderTreeState()

    state.applyCompactLaunchOpening(layoutMode: .compact)

    #expect(state.expandedTiers.isEmpty)
    #expect(!state.appliedCompactLaunchOpening)
  }

  /// Error path: an Incoming fetch that failed must not swallow the opening — the retry that
  /// answers is the first load that can show the tier.
  @Test("a load whose Incoming tier failed consumes nothing; the answering retry opens it")
  func aFailedIncomingTierWaitsForTheRetry() {
    let state = published(
      FolderTreeLoad(phase: .partiallyFailed([.incoming]), foldersByTier: [.edits: []]))

    state.applyCompactLaunchOpening(layoutMode: .compact)
    #expect(state.expandedTiers.isEmpty)
    #expect(!state.appliedCompactLaunchOpening)

    let retry = state.beginLoad()
    #expect(state.publish(answered, generation: retry, cached: nil))
    state.applyCompactLaunchOpening(layoutMode: .compact)
    #expect(state.expandedTiers == [.incoming])
  }

  /// Concurrency: two mounted sections (Library and Search share this state) and a
  /// pull-to-refresh each publish and each apply — once the reader has closed the tier, none of
  /// them reopens it.
  @Test("one shot: a later publish never reopens a tier the reader closed")
  func theReadersCloseStands() {
    let state = published(answered)
    state.applyCompactLaunchOpening(layoutMode: .compact)
    state.expandedTiers.remove(.incoming)

    let second = state.beginLoad()
    #expect(state.publish(answered, generation: second, cached: nil))
    state.applyCompactLaunchOpening(layoutMode: .compact)
    state.applyCompactLaunchOpening(layoutMode: .compact)

    #expect(state.expandedTiers.isEmpty)
  }

  /// Additive: tiers a reveal already opened stay open beside Incoming.
  @Test("the opening only adds to what is already open")
  func theOpeningIsAdditive() {
    let state = published(answered)
    state.expandedTiers = [.archive]

    state.applyCompactLaunchOpening(layoutMode: .compact)

    #expect(state.expandedTiers == [.archive, .incoming])
  }

  @Test("the session boundary re-arms the opening for the next account")
  func endSessionReArms() {
    let state = published(answered)
    state.applyCompactLaunchOpening(layoutMode: .compact)
    #expect(state.appliedCompactLaunchOpening)

    state.endSession()
    #expect(!state.appliedCompactLaunchOpening)
    let next = state.beginLoad()
    #expect(state.publish(answered, generation: next, cached: nil))
    state.applyCompactLaunchOpening(layoutMode: .compact)
    #expect(state.expandedTiers == [.incoming])
  }
}
