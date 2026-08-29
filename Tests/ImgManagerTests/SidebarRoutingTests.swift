import Testing

@testable import ImgManager

/// Diff-gate round-3 closure, B3 — `SidebarRouting.destination(for:)` is the exact decision
/// `RootView.sidebar` switches on. A pure value test (mirrors `RootRoutingTests`/
/// `ForegroundRefreshTests`'s own posture), proving the regression directly: `.unreachable`
/// must route to `.queue`, never to a dead legacy copy that blocks `QueueView`/`QueueStore`'s
/// own already-correct degraded-state machine from ever running.
@Suite("SidebarRouting.destination(for:)")
struct SidebarRoutingTests {
  @Test(".checking routes to .checking (the brief pre-first-check window only)")
  func checking() {
    #expect(SidebarRouting.destination(for: .checking) == .checking)
  }

  @Test(".connected routes to .queue")
  func connected() {
    #expect(SidebarRouting.destination(for: .connected) == .queue)
  }

  @Test(
    ".unreachable ALSO routes to .queue -- an initial health failure must never block QueueView from mounting"
  )
  func unreachableRoutesToQueueNotADeadLegacyCopy() {
    #expect(SidebarRouting.destination(for: .unreachable) == .queue)
  }
}
