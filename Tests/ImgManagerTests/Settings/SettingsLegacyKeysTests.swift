import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-548 (R3 P9) verification: each of the five keys an installed 0.14.0 (21) build already
/// has on disk, written under that build's LITERAL key string into an injected suite, shows
/// unchanged in the Settings sheet — read through the very getter the row's `Toggle` binds to.
/// Literals, not the constants: a test that asks a constant to describe itself could not tell a
/// rename from a rewrite (`GridMoreMenuTests.theStoreOwnsExactlyTheKeysItDeclares`).
/// A row, the literal key build 21 wrote, a NON-default value, and what the row then shows.
struct LegacyWritten: Sendable, CustomTestStringConvertible {
  let toggle: SettingsToggle
  let key: String
  let stored: Bool
  let shown: Bool
  var testDescription: String { "\(key)=\(stored)" }
}

/// File scope, not static members of the `@MainActor` suite: `@Test(arguments:)` reads them
/// from a nonisolated context.
private let legacyNonDefault: [LegacyWritten] = [
  LegacyWritten(toggle: .filenamePlates, key: "grid.filenamePlates", stored: true, shown: true),
  LegacyWritten(
    toggle: .autoAdvanceOnMark, key: "loupe.autoAdvanceOnMark", stored: false, shown: false),
  LegacyWritten(toggle: .picksInGroups, key: "grid.picksInGroups", stored: true, shown: true),
  LegacyWritten(
    toggle: .pruneMirroredArchive, key: "grid.pruneMirroredArchive", stored: true, shown: true),
  // "Show Sidebar" is the inverse of the stored "hidden" flag.
  LegacyWritten(
    toggle: .sidebarVisible, key: "shell.regularSidebarHidden", stored: true, shown: false),
]

/// The same five at their DEFAULTS, written explicitly — so the non-default case is not passing
/// on a constant.
private let legacyDefaultsWritten: [LegacyWritten] = [
  LegacyWritten(
    toggle: .filenamePlates, key: "grid.filenamePlates", stored: false, shown: false),
  LegacyWritten(
    toggle: .autoAdvanceOnMark, key: "loupe.autoAdvanceOnMark", stored: true, shown: true),
  LegacyWritten(toggle: .picksInGroups, key: "grid.picksInGroups", stored: false, shown: false),
  LegacyWritten(
    toggle: .pruneMirroredArchive, key: "grid.pruneMirroredArchive", stored: false, shown: false),
  LegacyWritten(
    toggle: .sidebarVisible, key: "shell.regularSidebarHidden", stored: false, shown: true),
]

@MainActor
@Suite("Settings — the five 0.14.0 keys read back unchanged (IMGMGR-548)")
struct SettingsLegacyKeysTests {

  private func makeAuth() -> AuthSession {
    AuthSession(
      credentialStore: FakeCredentialStore(),
      client: ImgManagerAPIClient.make(transport: JoinableRenewalStubTransport()))
  }

  private func assertShown(_ written: LegacyWritten) {
    let defaults = makeEphemeralDefaults()
    defaults.set(written.stored, forKey: written.key)
    let sheet = SettingsSheetView(
      auth: makeAuth(), preferences: GridPreferences(defaults: defaults),
      settings: SettingsPreferences(defaults: defaults))

    #expect(written.toggle.isOn(grid: sheet.preferences, settings: sheet.settings) == written.shown)
    // Building the sheet (and reading the row) wrote nothing: the stored object is untouched.
    #expect(defaults.object(forKey: written.key) as? Bool == written.stored)
  }

  @Test(
    "A non-default value build 21 wrote shows unchanged in its Settings row",
    arguments: legacyNonDefault)
  func aNonDefaultValueShowsUnchanged(_ written: LegacyWritten) {
    assertShown(written)
  }

  @Test(
    "A default value build 21 wrote explicitly shows unchanged too",
    arguments: legacyDefaultsWritten)
  func aDefaultValueShowsUnchanged(_ written: LegacyWritten) {
    assertShown(written)
  }

  @Test("The five legacy rows bind the key strings build 21 shipped")
  func theLegacyRowsBindTheShippedKeyStrings() {
    #expect(SettingsToggle.filenamePlates.storageKey == "grid.filenamePlates")
    #expect(SettingsToggle.autoAdvanceOnMark.storageKey == "loupe.autoAdvanceOnMark")
    #expect(SettingsToggle.picksInGroups.storageKey == "grid.picksInGroups")
    #expect(SettingsToggle.pruneMirroredArchive.storageKey == "grid.pruneMirroredArchive")
    #expect(SettingsToggle.sidebarVisible.storageKey == "shell.regularSidebarHidden")
    #expect(Set(SettingsToggle.legacy) == Set(legacyNonDefault.map(\.toggle)))
    #expect(SettingsToggle.legacy.count == 5)
  }
}
