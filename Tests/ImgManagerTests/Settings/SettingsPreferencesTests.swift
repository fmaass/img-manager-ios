import Foundation
import Observation
import Testing

@testable import ImgManager

/// IMGMGR-548 (R3 P9): the five NEW keys, the Untouched Since day arithmetic, the sidebar flag's
/// second writer, the form's groups, and the fixture-launch reset.
@MainActor
@Suite("Settings — new keys, groups and the sidebar flag (IMGMGR-548)")
struct SettingsPreferencesTests {

  /// Sendable by construction and synchronized, so the `@Sendable` observation callback can
  /// record into it from whatever isolation it runs on (`QueueStoreWidgetReloadTests.ReloadSpy`).
  private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
      lock.lock()
      value += 1
      lock.unlock()
    }

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private static var utc: Calendar { UntouchedSince.calendar(in: .gmt) }
  private static var zurich: Calendar {
    UntouchedSince.calendar(in: UntouchedSince.displayTimeZone)
  }

  private static func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
    in calendar: Calendar
  ) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private static func day(_ date: Date, in calendar: Calendar) -> [Int] {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return [parts.year ?? 0, parts.month ?? 0, parts.day ?? 0]
  }

  private static var october18: Date { date(2026, 10, 18, 9, 0, in: utc) }

  // MARK: - New keys

  @Test("On an empty suite every new key reads its default")
  func newKeysReadTheirDefaults() {
    let now = Self.october18
    let settings = SettingsPreferences(defaults: makeEphemeralDefaults(), now: { now })
    #expect(settings.showUntouched)
    #expect(settings.showPinned)
    #expect(settings.showRecent)
    #expect(settings.tapToPickDefault == false)
    #expect(Self.day(settings.untouchedSince, in: Self.utc) == [2026, 1, 1])
  }

  @Test("A wrong-typed stored value reads the default, never a coerced value")
  func wrongTypedValuesReadTheDefault() {
    let defaults = makeEphemeralDefaults()
    // An NSString does not bridge to Bool; `bool(forKey:)` would coerce "NO" to false and "YES"
    // to true — the opposite of each default here.
    for key in [
      SettingsPreferences.showUntouchedKey, SettingsPreferences.showPinnedKey,
      SettingsPreferences.showRecentKey,
    ] {
      defaults.set("NO", forKey: key)
    }
    defaults.set("YES", forKey: SettingsPreferences.tapToPickDefaultKey)
    defaults.set("2020-01-01", forKey: SettingsPreferences.untouchedSinceKey)
    let now = Self.october18
    let settings = SettingsPreferences(defaults: defaults, now: { now })
    #expect(settings.showUntouched)
    #expect(settings.showPinned)
    #expect(settings.showRecent)
    #expect(settings.tapToPickDefault == false)
    #expect(Self.day(settings.untouchedSince, in: Self.utc) == [2026, 1, 1])

    defaults.set(true, forKey: SettingsPreferences.untouchedSinceKey)
    #expect(Self.day(settings.untouchedSince, in: Self.utc) == [2026, 1, 1])
  }

  @Test("A write to every new key survives into a fresh reader of the same suite, and back")
  func newKeysWriteThrough() {
    let defaults = makeEphemeralDefaults()
    let now = Self.october18
    let settings = SettingsPreferences(defaults: defaults, now: { now })
    let picked = Self.date(2025, 6, 1, in: Self.utc)
    settings.showUntouched = false
    settings.showPinned = false
    settings.showRecent = false
    settings.tapToPickDefault = true
    settings.untouchedSince = picked

    var reread = SettingsPreferences(defaults: defaults, now: { now })
    #expect(reread.showUntouched == false)
    #expect(reread.showPinned == false)
    #expect(reread.showRecent == false)
    #expect(reread.tapToPickDefault)
    #expect(Self.day(reread.untouchedSince, in: Self.utc) == [2025, 6, 1])

    settings.showUntouched = true
    settings.showPinned = true
    settings.showRecent = true
    settings.tapToPickDefault = false
    reread = SettingsPreferences(defaults: defaults, now: { now })
    #expect(reread.showUntouched)
    #expect(reread.showPinned)
    #expect(reread.showRecent)
    #expect(reread.tapToPickDefault == false)
  }

  @Test("The new keys are exactly five literals, disjoint from every other owner's keys")
  func theNewKeyInventory() {
    #expect(
      SettingsPreferences.persistedKeys == [
        "sidebar.showUntouched", "sidebar.showPinned", "sidebar.showRecent",
        "library.untouchedSince", "culling.tapToPickDefault",
      ])
    let others = Set(GridPreferences.persistedKeys + [SidebarVisibilityMemory.hiddenKey])
    #expect(others.isDisjoint(with: SettingsPreferences.persistedKeys))
  }

  // MARK: - Untouched Since

  @Test("A picked Zurich day survives the stored UTC midnight at the DST and year boundaries")
  func untouchedSinceRoundTripsCalendarDays() {
    for (year, month, day) in [(2026, 1, 1), (2026, 3, 29), (2026, 10, 25), (2026, 12, 31)] {
      let picked = Self.date(year, month, day, 12, 0, in: Self.zurich)
      let stored = UntouchedSince.storedDate(forDisplayed: picked)
      #expect(Self.day(stored, in: Self.utc) == [year, month, day])
      let time = Self.utc.dateComponents([.hour, .minute], from: stored)
      #expect(time.hour == 0 && time.minute == 0)
      let shown = UntouchedSince.displayedDate(forStored: stored)
      #expect(Self.day(shown, in: Self.zurich) == [year, month, day])
    }
  }

  @Test("Half past midnight in Zurich is that Zurich day, not the UTC day before it")
  func untouchedSinceUsesTheZurichDay() {
    let picked = Self.date(2026, 7, 1, 0, 30, in: Self.zurich)
    let stored = UntouchedSince.storedDate(forDisplayed: picked)
    #expect(Self.day(stored, in: Self.utc) == [2026, 7, 1])
  }

  @Test("The default is 1 January of the current Zurich year")
  func untouchedSinceDefaultFollowsTheZurichYear() {
    // 23:30 UTC on 31 December is already 2027 in Zurich.
    let lateNewYearsEve = Self.date(2026, 12, 31, 23, 30, in: Self.utc)
    let fallback = UntouchedSince.defaultStored(now: lateNewYearsEve)
    #expect(Self.day(fallback, in: Self.utc) == [2027, 1, 1])
    #expect(TimeZone(identifier: "Europe/Zurich") != nil)
  }

  // MARK: - The sidebar flag's second writer

  @Test("The sidebar flag is read fresh from the suite and its writes are observable")
  func theSidebarFlagIsFreshAndObservable() {
    let defaults = makeEphemeralDefaults()
    let settings = SettingsPreferences(defaults: defaults)
    let grid = GridPreferences(defaults: defaults)
    #expect(SettingsToggle.sidebarVisible.isOn(grid: grid, settings: settings))

    // What `RootView`'s `@AppStorage` does: a write straight into the suite.
    defaults.set(true, forKey: "shell.regularSidebarHidden")
    #expect(settings.regularSidebarHidden)
    #expect(SettingsToggle.sidebarVisible.isOn(grid: grid, settings: settings) == false)

    let recorder = ChangeRecorder()
    withObservationTracking {
      _ = settings.regularSidebarHidden
    } onChange: {
      recorder.bump()
    }
    settings.regularSidebarHidden = false
    #expect(recorder.count == 1)
    #expect(defaults.object(forKey: "shell.regularSidebarHidden") as? Bool == false)
  }

  @Test("A flag change moves the split only when the split disagrees, so the writers converge")
  func visibilityAfterFlagChange() {
    typealias Memory = SidebarVisibilityMemory
    let shown3 = LayoutResolver.columnVisibility(for: .regular3)
    #expect(Memory.visibilityAfterFlagChange(shown3, in: .compact, hidden: true) == nil)
    #expect(Memory.visibilityAfterFlagChange(shown3, in: .regular3, hidden: false) == nil)
    #expect(Memory.visibilityAfterFlagChange(shown3, in: .regular3, hidden: true) == .detailOnly)
    #expect(
      Memory.visibilityAfterFlagChange(.detailOnly, in: .regular2, hidden: false)
        == LayoutResolver.columnVisibility(for: .regular2))
    // The echo: the split now records what was written, so the next change answers nil.
    let next = Memory.visibilityAfterFlagChange(shown3, in: .regular3, hidden: true)!
    let echoed = Memory.recordedHidden(next, in: .regular3)!
    #expect(Memory.visibilityAfterFlagChange(next, in: .regular3, hidden: echoed) == nil)
  }

  // MARK: - The form

  @Test("The form has the eight R3-4 groups and Storage holds the prune row, nothing offline")
  func theFormHasTheEightGroupsAndNoOfflineRow() {
    #expect(
      SettingsSection.allCases == [
        .account, .sidebar, .library, .lightroomSync, .culling, .gridDisplay, .storage, .about,
      ])
    #expect(SettingsToggle.rows(in: .storage, showsRegularOnly: true) == [.pruneMirroredArchive])
    let compactSidebar = SettingsToggle.rows(in: .sidebar, showsRegularOnly: false)
    #expect(compactSidebar == [.showUntouched, .showPinned, .showRecent])

    var words: [String] = []
    for section in SettingsSection.allCases {
      words += [section.title, section.headerIdentifier] + [section.footer].compactMap { $0 }
    }
    for toggle in SettingsToggle.allCases {
      words += [toggle.title, toggle.identifier, toggle.storageKey]
      words += [toggle.caption].compactMap { $0 }
    }
    for row in SettingsStaticRow.allCases {
      words += [row.title, row.identifier]
    }
    words.append(SettingsStaticRow.lightroomModeValue)
    let offline = words.filter { $0.lowercased().contains("offline") }
    #expect(offline.isEmpty, "an offline row or placeholder: \(offline)")
  }

  @Test("About reads the version line from the bundle's own Info dictionary")
  func aboutVersionLine() {
    let info: [String: Any] = ["CFBundleShortVersionString": "0.14.0", "CFBundleVersion": "21"]
    #expect(SettingsAbout.versionLine(info: info) == "0.14.0 (21)")
    #expect(SettingsAbout.versionLine(info: nil) == "—")
    #expect(SettingsAbout.versionLine(info: ["CFBundleVersion": "21"]) == "—")
  }

  // MARK: - Fixture launches

  #if DEBUG
    @Test("A fixture launch forgets the Settings keys and nothing else")
    func fixtureLaunchForgetsOnlyTheSettingsKeys() {
      let defaults = makeEphemeralDefaults()
      for key in SettingsPreferences.persistedKeys {
        defaults.set(true, forKey: key)
      }
      let kept = GridPreferences.persistedKeys + [SidebarVisibilityMemory.hiddenKey]
      for key in kept {
        defaults.set(true, forKey: key)
      }
      DebugStubLaunch.forgetSettings(in: defaults)
      for key in SettingsPreferences.persistedKeys {
        #expect(defaults.object(forKey: key) == nil, "\(key) survived the reset")
      }
      for key in kept {
        #expect(defaults.object(forKey: key) as? Bool == true, "\(key) was reset")
      }
    }
  #endif
}
