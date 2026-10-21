import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-549 (design R3-2, r2 amendment 4): the home's sections in the record's order, each
/// following its Settings toggle — with "hidden" (toggle off) and "empty" (no members) kept
/// apart — plus the section rows' ring, identifiers and summary join.
@Suite("Sidebar sections — Untouched · Pinned · Recent · Library")
struct SidebarSectionsTests {

  private let everyone = SidebarMembership(untouched: 3, pinned: 1, recent: 2)

  @Test("everything on and populated renders in the order Untouched, Pinned, Recent, Library")
  func order() {
    #expect(
      SidebarSections.visible(toggles: .init(), membership: everyone)
        == [.untouched, .pinned, .recent, .library])
    #expect(SidebarSection.allCases == [.untouched, .pinned, .recent, .library])
  }

  @Test("each toggle hides exactly its own section; Library has no toggle")
  func eachToggleHidesItsSection() {
    #expect(
      SidebarSections.visible(toggles: .init(showUntouched: false), membership: everyone)
        == [.pinned, .recent, .library])
    #expect(
      SidebarSections.visible(toggles: .init(showPinned: false), membership: everyone)
        == [.untouched, .recent, .library])
    #expect(
      SidebarSections.visible(toggles: .init(showRecent: false), membership: everyone)
        == [.untouched, .pinned, .library])
    #expect(
      SidebarSections.visible(
        toggles: .init(showUntouched: false, showPinned: false, showRecent: false),
        membership: everyone) == [.library])
  }

  @Test("HIDDEN and EMPTY are different answers, though neither renders")
  func hiddenAndEmptyStayApart() {
    let none = SidebarMembership()
    #expect(
      SidebarSections.state(of: .untouched, toggles: .init(), membership: none) == .empty)
    #expect(
      SidebarSections.state(
        of: .untouched, toggles: .init(showUntouched: false), membership: everyone) == .hidden)
    #expect(
      SidebarSections.state(
        of: .untouched, toggles: .init(showUntouched: false), membership: none) == .hidden)
    #expect(SidebarSections.state(of: .pinned, toggles: .init(), membership: none) == .empty)
    #expect(SidebarSections.state(of: .recent, toggles: .init(), membership: none) == .empty)
    #expect(SidebarSections.state(of: .library, toggles: .init(), membership: none) == .shown)
    #expect(SidebarSections.visible(toggles: .init(), membership: none) == [.library])
  }

  @Test("the Compact Shoots tab is Untouched above Recent — no Pinned, no Library")
  func compactShoots() {
    #expect(
      SidebarSections.visible(toggles: .init(), membership: everyone, in: .compactShoots)
        == [.untouched, .recent])
    #expect(
      SidebarSections.visible(
        toggles: .init(showRecent: false), membership: everyone, in: .compactShoots)
        == [.untouched])
  }

  @MainActor
  @Test("the toggles are read from Settings as stored")
  func togglesReadSettings() {
    let settings = SettingsPreferences(defaults: makeEphemeralDefaults())
    settings.showPinned = false
    #expect(SidebarToggles(settings) == .init(showUntouched: true, showPinned: false))
  }

  @Test("the four headers name the sections, on the identifiers the UI tests address")
  func headers() {
    #expect(
      SidebarSectionHeader.allCases.map(\.title) == ["Untouched", "Pinned", "Recent", "Library"])
    #expect(
      SidebarSectionHeader.allCases.map(\.identifier)
        == ["untouchedSection", "pinnedSection", "recentSection", "sidebarSectionLibrary"])
  }

  // MARK: - Section rows

  private func summary(
    _ folderID: Int, sourceTier: String = "local", untouched: Bool = false
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderID, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "photo_incoming/2026-01-0\(folderID)-x",
      picked: 0, previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!,
      sourceTier: sourceTier, sync: nil, total: 1, unmarked: 1, untouched: untouched,
      withMasters: 0)
  }

  @Test("row and ring identifiers are scoped to their section")
  func rowIdentifiers() {
    #expect(ShootRowsKind.untouched.rowIdentifier(for: 5) == "untouchedRow-5")
    #expect(ShootRowsKind.pinned.rowIdentifier(for: 5) == "pinnedRow-5")
    #expect(ShootRowsKind.recent.rowIdentifier(for: 5) == "recentRow-5")
    #expect(ShootRowsKind.untouched.ringIdentifier(for: 5) == "untouchedRing-untouched-5")
    #expect(ShootRowsKind.recent.ringIdentifier(for: 3) == "untouchedRing-recent-3")
    #expect(FolderTreeRowPresentation.untouchedIdentifier(for: 5) == "folderUntouched-5")
  }

  @Test("a section row shows the ring exactly when the server calls the shoot untouched")
  func sectionRowRing() {
    #expect(ShootRowPresentation.showsUntouchedRing(summary(5, untouched: true)))
    #expect(!ShootRowPresentation.showsUntouchedRing(summary(5, untouched: false)))
  }

  @Test("remembered entries join summaries on folder AND tier, in the entries' order")
  func joinMatchesFolderAndTier() {
    let summaries = [summary(3), summary(5), summary(5, sourceTier: "archive")]
    let entries: [ShootShortcutsStore.Entry] = [
      .init(folderID: 5, sourceTier: "archive"), .init(folderID: 9, sourceTier: "local"),
      .init(folderID: 3, sourceTier: "local"),
    ]
    let joined = ShootRowPresentation.summaries(for: entries, in: summaries)
    #expect(joined.map { "\($0.folderId)|\($0.sourceTier)" } == ["5|archive", "3|local"])
  }
}
