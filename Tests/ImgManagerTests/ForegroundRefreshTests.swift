import ImgManagerAPI
import Testing

@testable import ImgManager

/// A recorder the escaping refresh closures can write to. `ForegroundRefresh` starts the two
/// home refreshes as CHILD TASKS since checkpoint-3 finding F2, so its closures escape and a
/// captured local `var` is no longer the right shape for them.
@MainActor
private final class RefreshLog {
  var events: [String] = []
  func record(_ event: String) { events.append(event) }
}

/// A suspension a test controls: the "hanging `/api/folder-summaries`" of finding F2.
@MainActor
private final class Gate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

/// P7 coexistence, binding adjudication 7a — a pure sequencing/value test (mirrors
/// `RootRoutingTests`'s own posture), never a rendered-view test.
@MainActor
@Suite("ForegroundRefresh — P6/P7 coexistence ordering")
struct ForegroundRefreshTests {

  /// The ORDERED half is unchanged: renewal, then the grid, then the home's own refreshes. What
  /// changed with F2 is that the last two no longer wait on each other, so this pins the prefix
  /// and the membership rather than a total order that no longer exists.
  @Test("Signed in, a shoot selected: renew -> grid refresh -> then BOTH home refreshes")
  func fullOrderWithSelection() async {
    let log = RefreshLog()
    await ForegroundRefresh.run(
      renew: { log.record("renew") },
      isSignedIn: { true },
      hasSelectedShoot: { true },
      refreshGrid: { log.record("grid") },
      refreshQueue: { log.record("queue") },
      refreshTree: { log.record("tree") }
    )
    #expect(log.events.prefix(2) == ["renew", "grid"])
    #expect(Set(log.events) == ["renew", "grid", "queue", "tree"])
    #expect(log.events.count == 4)
  }

  @Test("Signed in, NO shoot selected: both home refreshes still run — only the grid is skipped")
  func queueRefreshesEvenWithoutSelection() async {
    let log = RefreshLog()
    await ForegroundRefresh.run(
      renew: { log.record("renew") },
      isSignedIn: { true },
      hasSelectedShoot: { false },
      refreshGrid: { log.record("grid") },
      refreshQueue: { log.record("queue") },
      refreshTree: { log.record("tree") }
    )
    #expect(log.events.first == "renew")
    #expect(Set(log.events) == ["renew", "queue", "tree"])
    #expect(log.events.count == 3)
  }

  @Test("Not signed in after renewal: nothing refreshes")
  func signedOutSkipsBoth() async {
    let log = RefreshLog()
    await ForegroundRefresh.run(
      renew: { log.record("renew") },
      isSignedIn: { false },
      hasSelectedShoot: { true },
      refreshGrid: { log.record("grid") },
      refreshQueue: { log.record("queue") },
      refreshTree: { log.record("tree") }
    )
    #expect(log.events == ["renew"])
  }

  /// Checkpoint-3 finding F2. The tree refresh ran only after the summaries refresh RETURNED, so
  /// a `/api/folder-summaries` that hangs — the exact failure the home is supposed to survive —
  /// starved the refresh of the home's own data. The two are independent now: this suspends the
  /// summaries indefinitely and requires the tree's three requests to reach the wire anyway.
  @Test("a hanging summaries refresh does not starve the tree refresh")
  func aHangingSummariesRefreshDoesNotStarveTheTree() async {
    let transport = GridStubTransport()
    let service = GridService(client: ImgManagerAPIClient.make(transport: transport))
    let gate = Gate()

    let resume = Task { @MainActor in
      await ForegroundRefresh.run(
        renew: {},
        isSignedIn: { true },
        hasSelectedShoot: { false },
        refreshGrid: {},
        refreshQueue: { await gate.wait() },
        refreshTree: { _ = await FolderTreeLoad.perform(using: service) }
      )
    }

    // Bounded rather than unbounded: a starved tree refresh fails here in a second instead of
    // hanging the suite.
    var queries = await transport.recordedFolderQueries
    for _ in 0..<200 where queries.count < 3 {
      try? await Task.sleep(nanoseconds: 5_000_000)
      queries = await transport.recordedFolderQueries
    }
    #expect(queries.count == 3)
    #expect(queries.map { $0["tree"] } == ["photo_incoming", "photo_edits", nil])

    gate.release()
    await resume.value
  }

  /// Checkpoint-2 finding B2. A resume re-read the summaries and the grid; the FOLDER TREE — the
  /// home since IMGMGR-350 — was the one thing it did not, so a folder added, moved or removed
  /// while the app was backgrounded stayed on screen until the reader pulled to refresh.
  ///
  /// Driven through the REAL load over the stub transport rather than a spy closure, so what this
  /// proves is that a scene-active transition puts `GET /api/folders` requests on the wire — the
  /// recorded queries are the evidence, one per browse tier.
  @MainActor
  @Test("a resume re-reads the FOLDER TREE, not only the summaries")
  func aResumeReReadsTheFolderTree() async {
    let transport = GridStubTransport()
    let service = GridService(client: ImgManagerAPIClient.make(transport: transport))

    await ForegroundRefresh.run(
      renew: {},
      isSignedIn: { true },
      hasSelectedShoot: { false },
      refreshGrid: {},
      refreshQueue: {},
      refreshTree: { _ = await FolderTreeLoad.perform(using: service) }
    )

    let queries = await transport.recordedFolderQueries
    #expect(queries.count == 3)
    #expect(queries.map { $0["tree"] } == ["photo_incoming", "photo_edits", nil])
  }
}
