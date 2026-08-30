import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP12 (IMGMGR-199). Every row of the resolver's state table, exercised through the REAL
/// generated client (`GridStubTransport` implements the `ClientTransport` seam, so the fetch
/// path decodes real `FolderSummary` values) and the REAL snapshot store on a throwaway
/// directory — no hand-rolled stand-in for either.
///
/// The WidgetKit provider is a four-line adapter over this type; there is nothing in it to test
/// that is not tested here.
@Suite("ReadinessTimelineResolver — what a widget refresh renders in each state")
struct ReadinessTimelineResolverTests {

  private let now = Date(timeIntervalSince1970: 1_756_000_000)

  private func makeSummary(_ folderId: Int, _ readiness: String)
    -> Components.Schemas.FolderSummary
  {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: readiness)!, sourceTier: "local",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  private func makeSnapshotStore() -> ReadinessSnapshotStore {
    ReadinessSnapshotStore(
      directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("readiness-\(UUID().uuidString)", isDirectory: true))
  }

  private func makeResolver(
    credential: CredentialLoadResult,
    transport: GridStubTransport,
    snapshot: ReadinessSnapshotStore
  ) -> ReadinessTimelineResolver {
    let service = QueueService(client: ImgManagerAPIClient.make(transport: transport))
    return ReadinessTimelineResolver(
      loadCredential: { credential },
      fetchSummaries: { try await service.summaries() },
      readSnapshot: { snapshot.load() },
      writeSnapshot: { snapshot.save($0) },
      clearSnapshot: { snapshot.clear() })
  }

  private func validCredential(expiringAt expiry: Date) -> CredentialLoadResult {
    .present(Credential(token: "t", expiresAt: expiry, subject: "fabian"))
  }

  /// A stored snapshot from an earlier successful refresh, one hour old.
  private func seedSnapshot(_ store: ReadinessSnapshotStore) -> Date {
    let fetchedAt = now.addingTimeInterval(-3600)
    store.save(
      ReadinessEntryBuilder.live(from: [makeSummary(1, "ready_to_review")], fetchedAt: fetchedAt))
    return fetchedAt
  }

  @Test("A valid credential fetches, renders live counts, and replaces the snapshot")
  func validCredentialFetchesLive() async {
    let transport = GridStubTransport()
    await transport.setFolderSummariesResult([
      makeSummary(1, "ready_to_review"), makeSummary(2, "sync_problem"),
    ])
    let snapshot = makeSnapshotStore()
    let resolver = makeResolver(
      credential: validCredential(expiringAt: now.addingTimeInterval(3600)),
      transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .live)
    #expect(resolution.entry.fetchedAt == now)
    #expect(resolution.entry.count(for: .readyToReview) == 1)
    #expect(resolution.entry.syncProblemCount == 1)
    #expect(
      resolution.nextRefresh
        == now.addingTimeInterval(ReadinessTimelineResolver.liveRefreshInterval))
    #expect(snapshot.load()?.fetchedAt == now)
  }

  @Test("No credential: the signed-out entry, no request made, and the snapshot is dropped")
  func absentCredentialSignsOutAndClearsSnapshot() async {
    let transport = GridStubTransport()
    let snapshot = makeSnapshotStore()
    _ = seedSnapshot(snapshot)
    let resolver = makeResolver(credential: .absent, transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .signedOut)
    #expect(resolution.entry.fetchedAt == nil)
    #expect(snapshot.load() == nil)
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 0)
    #expect(
      resolution.nextRefresh
        == now.addingTimeInterval(ReadinessTimelineResolver.retryRefreshInterval))
  }

  /// `CredentialStore.load()` hands back any decodable credential without looking at its expiry
  /// and the transport sends whatever it is given, so the provider does the check — spending a
  /// request to be told 401 would be the alternative, and only the app can renew.
  @Test("An expired credential signs out WITHOUT spending a request")
  func expiredCredentialDoesNotFetch() async {
    let transport = GridStubTransport()
    let snapshot = makeSnapshotStore()
    let resolver = makeResolver(
      credential: validCredential(expiringAt: now.addingTimeInterval(-1)),
      transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .signedOut)
    #expect(resolution.entry.fetchedAt == nil)
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 0)
  }

  /// The locked-device row: the Keychain item is unreadable, which is an ERROR and never
  /// "signed out" — the widget keeps showing the last successful counts with their real age.
  @Test("An unreadable credential shows the last successful counts with their own as-of time")
  func unreadableCredentialShowsLastKnown() async {
    let transport = GridStubTransport()
    let snapshot = makeSnapshotStore()
    let fetchedAt = seedSnapshot(snapshot)
    let resolver = makeResolver(
      credential: .error(.keychain(.notEntitled)), transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .lastKnown)
    #expect(resolution.entry.fetchedAt == fetchedAt)
    #expect(resolution.entry.date == now)
    #expect(resolution.entry.count(for: .readyToReview) == 1)
    #expect(snapshot.load()?.fetchedAt == fetchedAt)
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 0)
  }

  @Test("An unreadable credential with nothing ever fetched is the explicit no-data state")
  func unreadableCredentialWithoutSnapshotIsNoData() async {
    let transport = GridStubTransport()
    let snapshot = makeSnapshotStore()
    let resolver = makeResolver(
      credential: .error(.corrupted), transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .noData)
    #expect(resolution.entry.fetchedAt == nil)
  }

  @Test("A failed fetch keeps the last successful counts and asks again sooner")
  func failedFetchFallsBackToTheSnapshot() async {
    let transport = GridStubTransport()
    await transport.setFolderSummariesShouldFail(true)
    let snapshot = makeSnapshotStore()
    let fetchedAt = seedSnapshot(snapshot)
    let resolver = makeResolver(
      credential: validCredential(expiringAt: now.addingTimeInterval(3600)),
      transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .lastKnown)
    #expect(resolution.entry.fetchedAt == fetchedAt)
    #expect(
      resolution.nextRefresh
        == now.addingTimeInterval(ReadinessTimelineResolver.retryRefreshInterval))
    #expect(snapshot.load()?.fetchedAt == fetchedAt)
  }

  @Test("A failed FIRST fetch is the no-data state — never zeroed counts with a fresh timestamp")
  func failedFetchWithoutSnapshotIsNoData() async {
    let transport = GridStubTransport()
    await transport.setFolderSummariesShouldFail(true)
    let snapshot = makeSnapshotStore()
    let resolver = makeResolver(
      credential: validCredential(expiringAt: now.addingTimeInterval(3600)),
      transport: transport, snapshot: snapshot)

    let resolution = await resolver.resolve(now: now)

    #expect(resolution.entry.state == .noData)
    #expect(resolution.entry.fetchedAt == nil)
    #expect(resolution.entry.totalShoots == 0)
    #expect(snapshot.load() == nil)
  }
}
