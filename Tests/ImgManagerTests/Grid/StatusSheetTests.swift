import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P5a (IMGMGR-221): the More menu's Status sheet — a READ of `GET /api/status`, rendered,
/// with no control that mutates anything.
@MainActor
@Suite("Status sheet (WP13 P5a)")
struct StatusSheetTests {

  /// Shaped from the live 2026-08-30 probe of the deployed backend, with fixed timestamps.
  /// `2026-08-30T19:51:32Z` is `21:51` in Europe/Zurich (CEST, UTC+2), which is what makes the
  /// zone assertion below falsifiable rather than trivially true.
  private static let indexedAt = Date(timeIntervalSince1970: 1_788_119_492)
  private static let nextRunAt = Date(timeIntervalSince1970: 1_788_120_392)
  private static let runStartedAt = Date(timeIntervalSince1970: 1_788_119_480)

  private func status() -> Components.Schemas.StatusResponse {
    Components.Schemas.StatusResponse(
      coverage: .init(
        imagesActive: 202_572, imagesMissing: 7_154,
        tiers: [
          .init(coveragePercent: 97.825, failed: 4_406, ok: 198_166, pending: 0, tier: "grid"),
          .init(coveragePercent: 97.544, failed: 4_976, ok: 197_596, pending: 0, tier: "preview"),
        ]),
      lastIndexedAt: Self.indexedAt,
      maintenance: .init(
        enabled: true, executorLock: .free, nextRunAt: Self.nextRunAt, note: "idle",
        tierDetail: "the photo library is mounted and verified", tierMounted: true),
      runs: [
        .init(
          finishedAt: Self.indexedAt, id: 1_985, startedAt: Self.runStartedAt, state: "succeeded",
          trigger: "interval")
      ],
      stores: [
        .init(health: .mounted, indexed: true, mounted: true, store: "local"),
        .init(health: .mounted, indexed: true, mounted: true, store: "archive"),
      ])
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(
      service: GridService(client: client),
      preferences: GridPreferences(defaults: makeEphemeralDefaults()),
      pasteboard: SpyMarksPasteboard())
    return (store, transport)
  }

  /// The plan's named test. "No mutating control" is asserted where it can actually fail: the
  /// sheet's whole lifecycle runs and the ONE maintenance mutation this API offers
  /// (`POST /api/reindex`) is never called — with a positive control proving the counter works.
  @Test("The Status sheet renders a read, and no control on it mutates anything")
  func rendersStatusWithNoMutatingControl() async {
    let (store, transport) = makeStore()
    await transport.setStatusResponse(status())

    store.presentStatus()
    #expect(store.isStatusPresented)
    await store.loadStatus()

    #expect(store.statusSnapshot != nil, "the sheet has nothing to render")
    #expect(store.statusReadFailed == false)

    let sections = StatusSheetModel.sections(store.statusSnapshot!)
    #expect(sections.map(\.id) == ["maintenance", "stores", "coverage", "runs"])
    let rows = sections.flatMap(\.rows)
    #expect(rows.contains { $0.id == "store.local" && $0.value.contains("Mounted") })
    #expect(rows.contains { $0.id == "coverage.images" && $0.value.contains("202572") })
    #expect(rows.contains { $0.id == "run.1985" })

    // Positive control for the 0-call assertion below (LSN-0033): the counter DID observe the
    // status read this test performed.
    let statusCalls = await transport.callCount(Operations.StatusApiStatusGet.id)
    #expect(statusCalls >= 1, "the sheet never read GET /api/status")
    let reindexCalls = await transport.callCount(Operations.ReindexApiReindexPost.id)
    #expect(reindexCalls == 0, "the Status sheet triggered a maintenance mutation")
  }

  /// The plan's named test (estate ADR-0007, [/link/2553](/link/2553)): every rendered timestamp
  /// is Europe/Zurich AND carries its zone. `19:51Z` → `21:51` proves the CONVERSION happened,
  /// so a formatter left on UTC fails rather than merely rendering an unlabelled clock.
  @Test("Every timestamp renders in Europe/Zurich and is labelled")
  func everyTimestampRendersInEuropeZurichAndIsLabelled() {
    #expect(StatusSheetModel.timestamp(Self.indexedAt) == "30 Aug 2026, 21:51 Europe/Zurich")
    #expect(StatusSheetModel.zone.identifier == "Europe/Zurich")

    let rows = StatusSheetModel.sections(status()).flatMap(\.rows)
    let timestamped = rows.filter {
      $0.value.range(of: #"\d{2}:\d{2}"#, options: .regularExpression) != nil
    }
    // Positive control: there ARE timestamp-bearing rows, so the sweep below is not vacuous.
    #expect(timestamped.count >= 3, "no timestamp rows were rendered at all")
    for row in timestamped {
      #expect(
        row.value.contains("Europe/Zurich"),
        "row \(row.id) renders '\(row.value)' — an unlabelled clock")
      #expect(!row.value.contains("UTC") && !row.value.contains("GMT"))
    }
    // The ISO wire form never reaches a rendered value.
    #expect(!rows.contains { $0.value.contains("T19:51") || $0.value.hasSuffix("Z") })
  }

  @Test("A failed read is a failed READ — the sheet says so and offers only another read")
  func aFailedReadIsReportedAndRetriable() async {
    let (store, transport) = makeStore()
    await transport.setStatusShouldFail(true)

    await store.loadStatus()
    #expect(store.statusSnapshot == nil)
    #expect(store.statusReadFailed)

    await transport.setStatusResponse(status())
    await store.loadStatus()
    #expect(store.statusSnapshot != nil)
    #expect(store.statusReadFailed == false)

    let reindexCalls = await transport.callCount(Operations.ReindexApiReindexPost.id)
    #expect(reindexCalls == 0, "the retry path triggered a maintenance mutation")
  }

  @Test("An absent optional field simply omits its row, rather than rendering a placeholder")
  func absentFieldsOmitTheirRows() {
    let sparse = Components.Schemas.StatusResponse(
      coverage: .init(imagesActive: 0, imagesMissing: 0, tiers: []),
      maintenance: .init(enabled: false), runs: [])
    let sections = StatusSheetModel.sections(sparse)
    #expect(sections.map(\.id) == ["maintenance", "coverage"])
    let rows = sections.flatMap(\.rows)
    #expect(rows.contains { $0.id == "maintenance.enabled" && $0.value == "Disabled" })
    #expect(!rows.contains { $0.id == "maintenance.lastIndexed" })
    #expect(rows.contains { $0.id == "coverage.images" })
    // IMGMGR-249: nothing running is no row — never a placeholder, and never the newest entry of
    // `runs` standing in for a run that has already finished.
    #expect(!rows.contains { $0.id == "maintenance.activeRun" })
  }

  /// IMGMGR-249. The sheet could not express this at all until the re-vendor: `active_run` is a
  /// nullable model reference, which swift-openapi-generator dropped from the generated
  /// `StatusResponse` entirely. The row names the run that is ACTUALLY in flight, which is a
  /// different question from "the most recent run" — this fixture makes them differ on purpose.
  @Test("A running maintenance job is named from active_run, not from the newest finished run")
  func anActiveRunIsRenderedFromItsOwnField() {
    var running = status()
    running.activeRun = .init(
      finishedAt: nil, id: 1_986, startedAt: Self.indexedAt, state: "running", trigger: "manual")
    let rows = StatusSheetModel.sections(running).flatMap(\.rows)

    let active = rows.first { $0.id == "maintenance.activeRun" }
    #expect(active?.label == "Running now")
    #expect(active?.value.contains("manual") == true)
    #expect(active?.value.contains("running") == true)
    #expect(active?.value.contains(StatusSheetModel.timestamp(Self.indexedAt)) == true)
    // The finished run in `runs` is still listed as history, and is NOT what the row above says.
    #expect(rows.contains { $0.id == "run.1985" })
    #expect(active?.value.contains("succeeded") == false)
  }
}
