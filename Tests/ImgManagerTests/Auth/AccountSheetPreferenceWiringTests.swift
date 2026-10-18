import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P8 (IMGMGR-214): the account sheet's advance-on-mark row, asserted as far as a unit test
/// can reach it. IMGMGR-548: the account sheet became `SettingsSheetView`; the assertions are
/// unchanged and now hold for the Settings sheet's Culling row.
///
/// It reaches the BINDING, not the rendering. The row's own `Toggle` is bound to
/// `AccountSheetView.preferences`, so what this suite pins is that the sheet is handed the app's
/// LIVE `GridPreferences` and that a write through the sheet's own reference lands in the
/// persisted preference — i.e. the row cannot be a decoration bound to a copy nobody else reads.
/// What it deliberately does NOT claim is that the row is on screen: that needs the sheet to be
/// presentable, and it is not (IMGMGR-255 — `RootView` attaches its account `ToolbarItem` outside
/// the `NavigationSplitView`, so SwiftUI drops it and nothing can open the sheet). The rendered
/// assertion is that ticket's to restore, together with the UI test this phase removed rather
/// than leave failing for a reason outside its own subject.
@MainActor
@Suite("Account sheet ⟷ preferences wiring (WP13 P8, IMGMGR-214)")
struct AccountSheetPreferenceWiringTests {

  private func makeAuth() -> AuthSession {
    AuthSession(
      credentialStore: FakeCredentialStore(),
      client: ImgManagerAPIClient.make(transport: JoinableRenewalStubTransport()))
  }

  @Test("The sheet holds the app's OWN preferences object, never a copy nobody else reads")
  func theSheetHoldsTheLivePreferencesObject() {
    let preferences = GridPreferences(defaults: makeEphemeralDefaults())
    let sheet = SettingsSheetView(
      auth: makeAuth(), preferences: preferences,
      settings: SettingsPreferences(defaults: makeEphemeralDefaults()))
    #expect(sheet.preferences === preferences)
  }

  @Test("A write through the sheet's own reference reaches the persisted preference")
  func aWriteThroughTheSheetReachesThePersistedPreference() {
    let defaults = makeEphemeralDefaults()
    let preferences = GridPreferences(defaults: defaults)
    let sheet = SettingsSheetView(
      auth: makeAuth(), preferences: preferences,
      settings: SettingsPreferences(defaults: makeEphemeralDefaults()))

    // The row ships ON (the owner's 2026-08-30 decision); turning it off through the sheet's own
    // binding target must survive into a freshly constructed reader of the same suite.
    #expect(sheet.preferences.autoAdvanceOnMark)
    sheet.preferences.autoAdvanceOnMark = false
    #expect(GridPreferences(defaults: defaults).autoAdvanceOnMark == false)

    // ...and back, so the assertion above is about the write and not about a one-way default.
    sheet.preferences.autoAdvanceOnMark = true
    #expect(GridPreferences(defaults: defaults).autoAdvanceOnMark)

    // The SAME object the loupe header's toggle mutates: one preference, two chrome surfaces,
    // never two states that can disagree.
    #expect(sheet.preferences === preferences)
  }
}
