import ImgManagerAPI
import Testing

@testable import ImgManager

/// P7 coexistence, binding adjudication 7a — a pure sequencing/value test (mirrors
/// `RootRoutingTests`'s own posture), never a rendered-view test.
@Suite("ForegroundRefresh — P6/P7 coexistence ordering")
struct ForegroundRefreshTests {

  @Test("Signed in, a shoot selected: renew -> grid refresh -> queue refresh, IN THAT ORDER")
  func fullOrderWithSelection() async {
    var events: [String] = []
    await ForegroundRefresh.run(
      renew: { events.append("renew") },
      isSignedIn: { true },
      hasSelectedShoot: { true },
      refreshGrid: { events.append("grid") },
      refreshQueue: { events.append("queue") },
      refreshTree: { events.append("tree") }
    )
    #expect(events == ["renew", "grid", "queue", "tree"])
  }

  @Test("Signed in, NO shoot selected: the queue still refreshes — grid is skipped, not queue")
  func queueRefreshesEvenWithoutSelection() async {
    var events: [String] = []
    await ForegroundRefresh.run(
      renew: { events.append("renew") },
      isSignedIn: { true },
      hasSelectedShoot: { false },
      refreshGrid: { events.append("grid") },
      refreshQueue: { events.append("queue") },
      refreshTree: { events.append("tree") }
    )
    #expect(events == ["renew", "queue", "tree"])
  }

  @Test("Not signed in after renewal: neither grid nor queue refreshes")
  func signedOutSkipsBoth() async {
    var events: [String] = []
    await ForegroundRefresh.run(
      renew: { events.append("renew") },
      isSignedIn: { false },
      hasSelectedShoot: { true },
      refreshGrid: { events.append("grid") },
      refreshQueue: { events.append("queue") },
      refreshTree: { events.append("tree") }
    )
    #expect(events == ["renew"])
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
