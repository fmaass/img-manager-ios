import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-548: interaction level — a Settings row's setter lands in the key its menu twin writes,
/// and the app's grid store is wired to "Start with Tap to Pick".
@MainActor
@Suite("Settings — rows write their keys; Tap to Pick reaches the grid (IMGMGR-548)")
struct SettingsInteractionTests {

  private func makeAuth() -> AuthSession {
    AuthSession(
      credentialStore: FakeCredentialStore(),
      client: ImgManagerAPIClient.make(transport: JoinableRenewalStubTransport()))
  }

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func storeWithOneShoot(_ store: (GridService) -> GridStore) async -> GridStore {
    let transport = GridStubTransport()
    let made = store(GridService(client: ImgManagerAPIClient.make(transport: transport)))
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await made.selectShoot(folderID: 1)
    return made
  }

  @Test("Flipping every row through the sheet's objects writes its own key, under its literal")
  func everyRowWritesItsOwnKey() {
    let literal: [SettingsToggle: String] = [
      .sidebarVisible: "shell.regularSidebarHidden",
      .showUntouched: "sidebar.showUntouched",
      .showPinned: "sidebar.showPinned",
      .showRecent: "sidebar.showRecent",
      .autoAdvanceOnMark: "loupe.autoAdvanceOnMark",
      .tapToPickDefault: "culling.tapToPickDefault",
      .filenamePlates: "grid.filenamePlates",
      .picksInGroups: "grid.picksInGroups",
      .pruneMirroredArchive: "grid.pruneMirroredArchive",
    ]
    #expect(literal.count == SettingsToggle.allCases.count)
    for toggle in SettingsToggle.allCases {
      let defaults = makeEphemeralDefaults()
      let sheet = SettingsSheetView(
        auth: makeAuth(), preferences: GridPreferences(defaults: defaults),
        settings: SettingsPreferences(defaults: defaults))
      let key = literal[toggle] ?? "?"
      let snapshot = knownValues(defaults)
      let before = toggle.isOn(grid: sheet.preferences, settings: sheet.settings)
      toggle.set(!before, grid: sheet.preferences, settings: sheet.settings)

      #expect(toggle.isOn(grid: sheet.preferences, settings: sheet.settings) == !before)
      // "Show Sidebar" stores the inverse ("hidden"); every other row stores what it shows.
      let stored = toggle == .sidebarVisible ? before : !before
      #expect(defaults.object(forKey: key) as? Bool == stored, "\(toggle) did not write \(key)")
      // ...and ONLY that key: one row, one key.
      let after = knownValues(defaults)
      let changed = after.keys.filter { after[$0] != snapshot[$0] }
      #expect(changed == [key], "\(toggle) wrote \(changed)")
    }
  }

  /// The value of every key any Settings row may write (absent reads as nil), so a diff names
  /// exactly the keys one flip changed.
  private func knownValues(_ defaults: UserDefaults) -> [String: Bool?] {
    var keys = SettingsPreferences.persistedKeys + GridPreferences.persistedKeys
    keys.append(SidebarVisibilityMemory.hiddenKey)
    var values: [String: Bool?] = [:]
    for key in keys {
      values[key] = defaults.object(forKey: key) as? Bool
    }
    return values
  }

  @Test("The app's grid store opens a shoot latched on Pick when the reader asked for it")
  func theAppsStoreHonoursStartWithTapToPick() async {
    let settings = SettingsPreferences(defaults: makeEphemeralDefaults())
    settings.tapToPickDefault = true
    let store = await storeWithOneShoot { RootView.makeGridStore(service: $0, settings: settings) }
    #expect(store.pickLock.latchedVerb == .pick)
  }

  @Test("Off, or with no wire at all, opening a shoot latches nothing")
  func noLatchWhenOffOrUnwired() async {
    let settings = SettingsPreferences(defaults: makeEphemeralDefaults())
    let off = await storeWithOneShoot { RootView.makeGridStore(service: $0, settings: settings) }
    #expect(off.pickLock.latchedVerb == nil)
    let unwired = await storeWithOneShoot { GridStore(service: $0) }
    #expect(unwired.pickLock.latchedVerb == nil)
  }

  @Test("A re-select of the open shoot is not a shoot change, so it latches nothing new")
  func reselectingTheOpenShootLatchesNothing() async {
    let store = await storeWithOneShoot { GridStore(service: $0, startsWithTapToPick: { true }) }
    #expect(store.pickLock.latchedVerb == .pick)
    store.pickLock.exit()
    await store.selectShoot(folderID: 1)
    #expect(store.pickLock.latchedVerb == nil)
  }
}
