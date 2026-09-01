#if DEBUG
  import Foundation

  /// DEBUG-ONLY fixture instrumentation, wrapped entirely in `#if DEBUG` exactly like
  /// `DebugStubTransport` — a Release/TestFlight archive contains none of it.
  ///
  /// WP16 P2 (IMGMGR-298) needs to observe, from a UI test, that the facets fetch runs while the
  /// inspector has NEVER been on screen. Showing the inspector is itself what starts that fetch
  /// in the shipped app, so any post-show reading observes a fetch the show began and cannot tell
  /// the two builds apart. Nothing else could carry the observation: `DebugStubTransport` is an
  /// `actor`, so its call counts are actor-isolated and unreachable from a synchronous
  /// accessibility read, and `ImgManagerApp` used to construct it inline with no retained
  /// reference at all.
  ///
  /// `@Observable` is the load-bearing part. `GridView` reads `facetsRequests` inside its body,
  /// which registers the dependency, so SwiftUI re-renders — and republishes the accessibility
  /// value — when the counter moves. A plain counter would be read once and never updated, which
  /// is the mechanism an earlier draft of this phase lacked.
  ///
  /// `@MainActor` for the same reason: the increment happens inside `await MainActor.run { … }`
  /// from the transport's actor, and the read happens in a SwiftUI body, so both ends are on the
  /// one isolation domain and no `nonisolated(unsafe)` is needed anywhere.
  @MainActor
  @Observable
  final class DebugProbe {
    /// The instance the fixture composition retains: `ImgManagerApp` passes it to
    /// `DebugStubTransport`, so the object the transport increments is the object `GridView`
    /// reads. A per-transport instance would publish into an object no view was observing.
    static let shared = DebugProbe()

    /// How many `/api/facets` requests the fixture transport has served this launch.
    var facetsRequests = 0
  }
#endif
