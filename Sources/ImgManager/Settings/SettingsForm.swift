import Foundation

/// IMGMGR-548 (R3-4): the Settings sheet's groups, in the design record's order (p4336 R3-4:
/// Account · Sidebar · Library · Lightroom sync · Culling · Grid display · Storage · About).
///
/// Every string the sheet renders lives in this file — section titles and footers here, toggle
/// rows in `SettingsToggle`, the other rows in `SettingsStaticRow` — so a unit test can read all
/// of it, and can drive exactly the getter and setter a row's `Toggle` binds to.
/// No offline row and no offline placeholder anywhere (plan p4337 Decision 5).
enum SettingsSection: String, CaseIterable, Sendable {
  case account
  case sidebar
  case library
  case lightroomSync
  case culling
  case gridDisplay
  case storage
  case about

  /// The EXACT header text; the sheet renders it with `.textCase(nil)` so the label a UI test
  /// reads is this string.
  var title: String {
    switch self {
    case .account: "Account"
    case .sidebar: "Sidebar"
    case .library: "Library"
    case .lightroomSync: "Lightroom Sync"
    case .culling: "Culling"
    case .gridDisplay: "Grid Display"
    case .storage: "Storage"
    case .about: "About"
    }
  }

  var footer: String? {
    switch self {
    case .sidebar: "Untouched, Pinned and Recent appear above Library."
    case .library: "Untouched lists Incoming folders dated on or after this day."
    case .lightroomSync: "Sync from the app is not available yet."
    case .storage: "Hides archive folders whose photos are already in the Incoming library."
    case .account, .culling, .gridDisplay, .about: nil
    }
  }

  var headerIdentifier: String { "settingsSection.\(rawValue)" }
}

/// Every toggle row. The five LEGACY rows bind the 0.14.0 (21) keys through their existing
/// owners (`GridPreferences`, the sidebar flag); the other four bind `SettingsPreferences`.
enum SettingsToggle: CaseIterable, Sendable {
  case sidebarVisible
  case showUntouched
  case showPinned
  case showRecent
  case autoAdvanceOnMark
  case tapToPickDefault
  case filenamePlates
  case picksInGroups
  case pruneMirroredArchive

  /// The five rows over keys an installed build already has on disk.
  static let legacy: [SettingsToggle] = [
    .filenamePlates, .autoAdvanceOnMark, .picksInGroups, .pruneMirroredArchive, .sidebarVisible,
  ]

  var section: SettingsSection {
    switch self {
    case .sidebarVisible, .showUntouched, .showPinned, .showRecent: .sidebar
    case .autoAdvanceOnMark, .tapToPickDefault: .culling
    case .filenamePlates, .picksInGroups: .gridDisplay
    case .pruneMirroredArchive: .storage
    }
  }

  var title: String {
    switch self {
    case .sidebarVisible: "Show Sidebar"
    case .showUntouched: "Untouched"
    case .showPinned: "Pinned"
    case .showRecent: "Recent"
    case .autoAdvanceOnMark: "Advance After Marking"
    case .tapToPickDefault: "Start with Tap to Pick"
    case .filenamePlates: "Filename Plates"
    case .picksInGroups: "Picks in Groups"
    case .pruneMirroredArchive: "Hide Mirrored Archive"
    }
  }

  var caption: String? {
    switch self {
    case .autoAdvanceOnMark: "After a mark lands in the loupe, move to the next photograph."
    case .tapToPickDefault: "Opening a shoot turns Tap to Pick on."
    default: nil
    }
  }

  var identifier: String {
    switch self {
    case .sidebarVisible: "settingsSidebarVisibleToggle"
    case .showUntouched: "settingsShowUntouchedToggle"
    case .showPinned: "settingsShowPinnedToggle"
    case .showRecent: "settingsShowRecentToggle"
    // Kept from the account sheet: `LoupeAutoAdvanceScreenshotUITests` reads this row.
    case .autoAdvanceOnMark: "accountAutoAdvanceToggle"
    case .tapToPickDefault: "settingsTapToPickDefaultToggle"
    case .filenamePlates: "settingsFilenamePlatesToggle"
    case .picksInGroups: "settingsPicksInGroupsToggle"
    case .pruneMirroredArchive: "settingsPruneMirroredToggle"
    }
  }

  /// The `UserDefaults` key the row reads and writes. `@MainActor` because the key constants
  /// live on the `@MainActor` preference types.
  @MainActor
  var storageKey: String {
    switch self {
    case .sidebarVisible: SidebarVisibilityMemory.hiddenKey
    case .showUntouched: SettingsPreferences.showUntouchedKey
    case .showPinned: SettingsPreferences.showPinnedKey
    case .showRecent: SettingsPreferences.showRecentKey
    case .autoAdvanceOnMark: GridPreferences.autoAdvanceOnMarkKey
    case .tapToPickDefault: SettingsPreferences.tapToPickDefaultKey
    case .filenamePlates: GridPreferences.filenamePlatesKey
    case .picksInGroups: GridPreferences.picksInGroupsKey
    case .pruneMirroredArchive: GridPreferences.pruneMirroredArchiveKey
    }
  }

  /// Regular only: Compact has no sidebar to show.
  var isRegularOnly: Bool { self == .sidebarVisible }

  /// What the row's `Toggle` shows. "Show Sidebar" is the INVERSE of the stored "hidden" flag.
  @MainActor
  func isOn(grid: GridPreferences, settings: SettingsPreferences) -> Bool {
    switch self {
    case .sidebarVisible: !settings.regularSidebarHidden
    case .showUntouched: settings.showUntouched
    case .showPinned: settings.showPinned
    case .showRecent: settings.showRecent
    case .autoAdvanceOnMark: grid.autoAdvanceOnMark
    case .tapToPickDefault: settings.tapToPickDefault
    case .filenamePlates: grid.filenamePlates
    case .picksInGroups: grid.picksInGroups
    case .pruneMirroredArchive: grid.pruneMirroredArchive
    }
  }

  /// What flipping the row's `Toggle` writes — through the SAME objects the menus write.
  @MainActor
  func set(_ isOn: Bool, grid: GridPreferences, settings: SettingsPreferences) {
    switch self {
    case .sidebarVisible: settings.regularSidebarHidden = !isOn
    case .showUntouched: settings.showUntouched = isOn
    case .showPinned: settings.showPinned = isOn
    case .showRecent: settings.showRecent = isOn
    case .autoAdvanceOnMark: grid.autoAdvanceOnMark = isOn
    case .tapToPickDefault: settings.tapToPickDefault = isOn
    case .filenamePlates: grid.filenamePlates = isOn
    case .picksInGroups: grid.picksInGroups = isOn
    case .pruneMirroredArchive: grid.pruneMirroredArchive = isOn
    }
  }

  static func rows(in section: SettingsSection, showsRegularOnly: Bool) -> [SettingsToggle] {
    allCases.filter { $0.section == section && (showsRegularOnly || !$0.isRegularOnly) }
  }
}

/// The non-toggle rows, so their words are scannable beside the toggles'.
enum SettingsStaticRow: CaseIterable, Sendable {
  case signedIn
  case server
  case signOut
  case untouchedSince
  case lightroomMode
  case version

  var title: String {
    switch self {
    case .signedIn: "Signed in"
    case .server: "Server"
    case .signOut: "Sign Out…"
    case .untouchedSince: "Untouched Since"
    case .lightroomMode: "Mode"
    case .version: "Version"
    }
  }

  var identifier: String {
    switch self {
    case .signedIn: "settingsSignedInRow"
    case .server: "settingsServerRow"
    // Scanned with the rest; never attached, the button is found by its title.
    case .signOut: "settingsSignOutButton"
    case .untouchedSince: "settingsUntouchedSincePicker"
    case .lightroomMode: "settingsLightroomModeRow"
    case .version: "settingsAboutVersion"
    }
  }

  /// The inert Lightroom row's value until P17 builds sync.
  static let lightroomModeValue = "On demand"
}

/// About › Version, from the bundle's own Info dictionary (injected for the unit test).
enum SettingsAbout {
  static func versionLine(info: [String: Any]?) -> String {
    guard let short = info?["CFBundleShortVersionString"] as? String,
      let build = info?["CFBundleVersion"] as? String
    else { return "—" }
    return "\(short) (\(build))"
  }
}
