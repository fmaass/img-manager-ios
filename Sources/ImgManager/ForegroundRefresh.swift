/// WP8 P7 coexistence (binding adjudication 7a): the foreground ordering — renew, THEN the
/// grid's own `authoritativeRefresh()` IF a shoot is selected, THEN the queue's summary
/// refresh UNCONDITIONALLY (even with nothing selected) — pulled out of `RootView`'s
/// `onChange(of: scenePhase)` closure so the ORDER itself is a value/sequencing test, not a
/// rendered-view test. Mirrors `RootRouting.destination(for:)`'s own "pulled out as a pure
/// function" posture (that type's own doc comment).
enum ForegroundRefresh {
  static func run(
    renew: () async -> Void,
    isSignedIn: () -> Bool,
    hasSelectedShoot: () -> Bool,
    refreshGrid: () async -> Void,
    refreshQueue: () async -> Void
  ) async {
    await renew()
    guard isSignedIn() else { return }
    if hasSelectedShoot() {
      await refreshGrid()
    }
    // Unconditional and LAST: the queue refreshes on foreground even with no shoot selected,
    // and never ahead of a lane-ordered grid refresh that just ran (never publishes
    // pre-mutation summary state afterward).
    await refreshQueue()
  }
}
