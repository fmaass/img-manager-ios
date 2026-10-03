import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-501: Triage's cover is presented at Compact only (`RootView`'s cover binding reads
/// `isTriagePresented && layoutMode == .compact`). A Triage request at Regular would register a
/// cover with the Handoff gate that never appears, and the next incoming route would wait out
/// the gate's whole grace for nothing. `GridStore.hostsTriageCover`, kept in step with the
/// layout by `RootView.applyWidth`, makes `openTriage()` refuse there instead.
@MainActor
@Suite("Triage's cover host — a Regular request costs a Handoff route no grace")
struct TriageCoverHostTests {
  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await store.selectShoot(folderID: 1)
    return store
  }

  @Test("Regular: Triage refuses, the gate stays settled, and a route waits out no grace")
  func regularRequestRegistersNothing() async {
    let store = await makeStore()
    #expect(store.canOpenTriage, "The fixture has nothing actionable; the test proves nothing.")
    store.hostsTriageCover = false

    store.openTriage()
    #expect(!store.isTriagePresented, "Triage opened at a width that hosts no cover.")
    #expect(store.presentationGate.isSettled, "A cover that never presents was registered.")

    // What `RootView.dismissTriagePresentations` does when a Handoff arrives.
    store.closeTriage()
    store.presentationGate.withdrawUnappeared()
    await store.presentationGate.settled()
    #expect(store.presentationGate.settlements.isEmpty, "The route waited out a grace.")
  }

  /// Review r1: the mapping `RootView.applyWidth` applies AND the cover's binding reads.
  @Test("Only Compact hosts Triage's cover")
  func onlyCompactHostsTheCover() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      #expect(GridStore.triageCoverIsHosted(in: mode) == (mode == .compact), "At \(mode)")
    }
  }

  @Test("Compact: the same request opens Triage and registers its cover")
  func compactRequestRegistersTheCover() async {
    let store = await makeStore()
    #expect(store.hostsTriageCover, "Compact is the initial layout, so the cover is hosted.")

    store.openTriage()
    #expect(store.isTriagePresented)
    #expect(!store.presentationGate.isSettled, "Compact's request was not registered.")
  }
}

/// IMGMGR-501: the DEBUG mid-session continuation the Pass Summary UI test drives
/// (`imgmanager://uitest-continue-activity?json=…`). It shares `onOpenURL` with the sign-in
/// callback, so it must take only its own URL, and only in a fixture launch.
@Suite("DEBUG continuation URL — its own host, fixture launches only")
struct DebugContinuationURLTests {
  #if DEBUG
    private let json = #"{"v":1,"folderID":1,"imageID":3,"completed":false}"#

    private func url(scheme: String = "imgmanager", host: String) -> URL? {
      var components = URLComponents()
      components.scheme = scheme
      components.host = host
      components.queryItems = [URLQueryItem(name: "json", value: json)]
      return components.url
    }

    @Test("The fixture's own URL yields its payload, decoded intact")
    func ownURLYieldsThePayload() throws {
      let own = try #require(url(host: DebugStubLaunch.continueActivityURLHost))
      #expect(DebugStubLaunch.midSessionContinuationJSON(from: own, isFixture: true) == json)
    }

    @Test("Not a fixture launch, the sign-in host or another scheme: nothing is taken")
    func everythingElseIsLeftAlone() throws {
      let own = try #require(url(host: DebugStubLaunch.continueActivityURLHost))
      #expect(DebugStubLaunch.midSessionContinuationJSON(from: own, isFixture: false) == nil)
      let callback = try #require(url(host: "auth-callback"))
      #expect(
        DebugStubLaunch.midSessionContinuationJSON(from: callback, isFixture: true) == nil)
      let web = try #require(
        url(scheme: "https", host: DebugStubLaunch.continueActivityURLHost))
      #expect(DebugStubLaunch.midSessionContinuationJSON(from: web, isFixture: true) == nil)
    }
  #endif
}
