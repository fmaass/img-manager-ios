/// Diff-gate round-3 closure, B3: the queue's own `QueueStore` degraded-state machine
/// (`.initialLoading`/`.reachable`/`.unreachableNoCache`/`.unreachableStale`) is the ONE
/// adjudicated degraded surface for the sidebar/Queue area — full-surface "Not connected to the
/// home network" + Try Again with no cache, a banner over retained cards with stale data,
/// foreground re-evaluation via `ForegroundRefresh` regardless of connectivity. The legacy
/// `ConnectivityState.status` health check must never stand IN FRONT of that machine: a
/// `.unreachable` initial result used to render a bare, dead copy of the same sentence with no
/// Try Again and no later recheck — `QueueView` (and therefore `QueueStore`) never got a chance
/// to mount at all. `.connected` and `.unreachable` both route to `.queue` here; only
/// `.checking` (the brief window before the FIRST health check resolves, unrelated to this
/// finding) still shows a bare spinner. Pulled out as a pure function — the exact decision
/// `RootView.sidebar` switches on — so a test proves the PRODUCTION routing, not a
/// re-implementation of it, matching `RootRouting`/`LayoutResolver`/`ForegroundRefresh`'s own
/// pulled-out-pure-function discipline.
enum SidebarRouting {
  enum Destination: Equatable {
    case checking
    case queue
  }

  static func destination(for status: ConnectivityState.Status) -> Destination {
    switch status {
    case .checking: return .checking
    case .connected, .unreachable: return .queue
    }
  }
}
