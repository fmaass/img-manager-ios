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

    /// IMGMGR-347: how many absorb writes the fixture transport has served this launch. Published
    /// for the same reason the counter above is — the transport is an `actor`, so a UI test that
    /// drove the absorb has no other way to observe that the request was really made rather than
    /// that a sheet was dismissed.
    var absorbRequests = 0

    /// WP29 P4 (IMGMGR-455): every split and extract the fixture transport answered, as the WIRE
    /// call it received (`split(stackID: 5000, atImageID: 4)`), so a UI test asserts the payload
    /// Scene ▸ sent rather than a sheet closing.
    var sceneEdits: [String] = []

    /// Final audit F2: how many `/api/folder-summaries` requests the fixture transport has served
    /// this launch — so a UI test observes that the Shoots title menu's Refresh row really
    /// re-fetched, the same way the absorb counter above observes its request.
    var summariesRequests = 0

    /// IMGMGR-499: how many `/api/folders` requests the fixture transport has answered this launch
    /// (one per tier per tree load), so a UI test observes that the home's Refresh row re-ran the
    /// TREE half of `QueueHomeRefresh` and not only the summaries.
    var folderTreeRequests = 0

    /// IMGMGR-502 review r1: how many preview answers `DebugPreviewHold` is parking right now —
    /// the positive signal a UI test waits for before it releases them.
    var heldPreviews = 0

    /// IMGMGR-499 review r1: how many times `RootView.refreshQueueHome()` — the home's
    /// pull-to-refresh and its View-menu twin, and nothing else — finished its summaries half.
    /// Per-trigger, so the launch load and the foreground resume, which fetch the same
    /// endpoints, can never pass for a tap on Refresh.
    var homeRefreshSummaries = 0

    /// IMGMGR-499 review r2: the tree reload token `refreshQueueHome()` last ISSUED (0: none
    /// yet), and the highest token a tree load has COMPLETED for (`FolderTreeSection
    /// .runTreeLoad`). A refresh's tree half is done when the second reaches the first.
    var homeRefreshTreeToken = 0
    var treeLoadCompletedToken = -1

    /// WP31 P1 (IMGMGR-460): how many `POST /api/marks/state` writes the fixture transport has
    /// served this launch — what makes "Skip performs no server write" falsifiable from a UI test.
    var markWrites = 0
    /// WP442 P12: APPEND-ONLY, one `"<state>:<ids,>"` per SetMarkState body, recorded before the
    /// answer and whether or not it changes state.
    var markRequests: [String] = []
    /// WP442 P12: the two scroll slots, mirrored by the active grid instance (`none` = unset).
    var streamAnchor = "none"
    var sceneAnchor = "none"
    /// IMGMGR-542 (R3-22): `GridFrameMonitor`'s counts under `-UITestFrameMonitor` — frames that
    /// missed at least one vsync inside a measured scroll window, and how many windows opened.
    var debugLongFrames = 0
    var debugScrollWindows = 0

    /// IMGMGR-485: every tag edit the fixture transport answered, as the WIRE call it received
    /// (`add(tag: x, imageIDs: [2])`), so a UI test asserts which photograph a tag sheet wrote
    /// rather than that the sheet closed.
    var tagEdits: [String] = []

    /// IMGMGR-483: every hardware key press the app received this launch, as
    /// `<seq>:<key>:<disposition>` (`DebugKeyReceipt`), and whether the grid's key actions are
    /// withheld right now — the disposition each receipt is stamped with.
    var keyReceipts: [String] = []
    /// The probe element's value: `keyReceipts=<seq>:<key>:<disposition>; …`.
    var keyReceiptsValue: String { "keyReceipts=" + keyReceipts.joined(separator: "; ") }
    var gridKeysWithheld = false

    /// WP31 P2 (IMGMGR-461): the activity a surface's `TriageActivityAdvertiser` last made
    /// current — type, Handoff eligibility and the decoded `userInfo` — read back from that
    /// `NSUserActivity` instance (`TriageActivityProbe`), so a UI test reads the activity itself,
    /// not the session.
    var activity = ""

    /// WP31 P2 (IMGMGR-461): how the last Handoff continuation ended
    /// (`ContinuationOutcome.probeValue`) — the positive signal a UI test waits for before it
    /// asserts that NO loupe opened.
    var continuation = ""

    /// WP31 P2 review round 2: which path last settled a presented surface for a Handoff route
    /// (`PresentationDismissalGate`) — `<surface>:onDismiss`, or `<surface>:grace` for a
    /// presentation withdrawn before it ever appeared.
    var dismissal = ""

    /// IMGMGR-501 (review r1): the receiving route's boundary events IN ORDER, newest last —
    /// each gate settlement (`<surface>:<path>`) and the route's loupe open (`openLoupe-<id>`),
    /// joined by `>` and capped at eight. The latest-only probes above cannot show an order;
    /// a UI test reads this one to require the dismissal BEFORE the open.
    var routeEvents = ""

    /// IMGMGR-650: every hold-to-original label the loupe showed, in order (`LoupeOriginal`). A UI
    /// test's long press returns only after the lift, so the label is read back from here.
    var originalLabels: [String] = []

    /// IMGMGR-501 (gate on 1676195): this process's identity. A UI test reads it before and
    /// after a mid-session step; a different value means the app was relaunched in between, and
    /// whatever the probes say afterwards describes a fresh process.
    let launchID = UUID().uuidString

    func recordRouteEvent(_ event: String) {
      var events = routeEvents.split(separator: ">").map(String.init)
      events.append(event)
      routeEvents = events.suffix(8).joined(separator: ">")
    }
  }
#endif
