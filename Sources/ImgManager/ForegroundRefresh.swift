/// WP8 P7 coexistence (binding adjudication 7a): the foreground ordering — renew, THEN the
/// grid's own `authoritativeRefresh()` IF a shoot is selected, THEN the queue's summary
/// refresh UNCONDITIONALLY (even with nothing selected) — pulled out of `RootView`'s
/// `onChange(of: scenePhase)` closure so the ORDER itself is a value/sequencing test, not a
/// rendered-view test. Mirrors `RootRouting.destination(for:)`'s own "pulled out as a pure
/// function" posture (that type's own doc comment).
enum ForegroundRefresh {
  @MainActor
  static func run(
    renew: () async -> Void,
    isSignedIn: () -> Bool,
    hasSelectedShoot: () -> Bool,
    refreshGrid: () async -> Void,
    refreshQueue: @escaping @MainActor () async -> Void,
    refreshTree: @escaping @MainActor () async -> Void
  ) async {
    await renew()
    guard isSignedIn() else { return }
    if hasSelectedShoot() {
      await refreshGrid()
    }
    // Both unconditional, both AFTER the lane-ordered grid refresh (neither publishes
    // pre-mutation summary state afterward), and — checkpoint-3 finding F2 — INDEPENDENT of each
    // other. Sequencing them made the tree's refresh wait on `/api/folder-summaries`, so a
    // hanging summaries endpoint starved the refresh of the home's own data: the one failure the
    // tree home is meant to survive. Two child tasks, and this returns when both have.
    async let summaries: Void = refreshQueue()
    async let tree: Void = refreshTree()
    _ = await (summaries, tree)
  }
}
