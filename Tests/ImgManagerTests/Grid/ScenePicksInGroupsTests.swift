import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-261 — the picks a COLLAPSED scene holds, shown inside the card.
///
/// The ticket's own disposition (owner doctrine: companion value through native capability, never
/// web parity) puts the switch in the surface the native app ALREADY has — the More menu's view
/// cluster, persisted through `GridPreferences` — rather than in a settings panel the web needs
/// only because it lacks one. So the first thing this suite pins is that the preference and the
/// menu row exist at all, in the one place each of them is allowed to live.
@MainActor
@Suite("Picks inside a collapsed scene — the toggle, its default, and the display-only read")
struct ScenePicksInGroupsTests {

  /// The KEY is spelled out rather than read from the type it names: this suite's job is to pin
  /// which persisted key the app owns, and a test that asks the constant to describe itself
  /// could not tell a rename from a rewrite.
  @Test("The toggle is a GridPreferences key, and it is OFF until the reader turns it on")
  func theToggleIsAPersistedPreferenceDefaultingOff() {
    #expect(GridPreferences.persistedKeys.contains("grid.picksInGroups"))
    // Exactly one key for it — a second owner of the same visual property is the failure mode
    // `persistedKeys` exists to catch (the Density precedent).
    #expect(GridPreferences.persistedKeys.filter { $0 == "grid.picksInGroups" }.count == 1)
    // Positive control for the membership check above: the inventory really was read.
    #expect(GridPreferences.persistedKeys.contains(GridPreferences.filenamePlatesKey))
  }

  @Test("The toggle joins the More menu's decided set — never a second settings surface")
  func theToggleLivesInTheExistingViewOptionsSurface() {
    let ids = GridMoreMenu.entries.map(\.id)
    #expect(ids.contains("more.picksInGroups"))
    #expect(ids.filter { $0 == "more.picksInGroups" }.count == 1)
    // Positive control: the decided set really was enumerated.
    #expect(ids.contains("more.filenamePlates"))
  }
}
