import Foundation

/// IMGMGR-548 (R3 P9): the preferences the Settings sheet introduces, and nothing else.
///
/// A SEPARATE type from `GridPreferences` on purpose: that type's inventory is asserted exactly
/// (`ArrangeModelTests`, `GridMoreMenuTests`), and these five keys are not grid preferences —
/// three shape the sidebar (P10 reads them), one sets the Untouched horizon (P10), one sets how a
/// shoot opens. Same posture as `GridPreferences`: an injectable `UserDefaults`, guard-typed reads
/// (`GridPreferences.boolPreference`), writes in `didSet`.
///
/// Numeric bridging is accepted on read (an `NSNumber` 0/1 reads as a Bool) exactly as the five
/// existing keys' reader accepts it — one preference-reader semantics in the app, not two.
@Observable
@MainActor
final class SettingsPreferences {
  /// Every key this type owns, in one place. Disjoint from `GridPreferences.persistedKeys` and
  /// from `SidebarVisibilityMemory.hiddenKey` (`SettingsPreferencesTests`).
  static let persistedKeys: [String] = [
    showUntouchedKey, showPinnedKey, showRecentKey, untouchedSinceKey, tapToPickDefaultKey,
  ]

  static let showUntouchedKey = "sidebar.showUntouched"
  static let showPinnedKey = "sidebar.showPinned"
  static let showRecentKey = "sidebar.showRecent"
  /// Each sidebar section shows on a fresh install; the reader hides one in Settings.
  static let sidebarSectionDefault = true

  /// A `Date` at 00:00:00 UTC of the chosen calendar day (`UntouchedSince`). Absent until the
  /// reader picks a day, so the default (1 January of the current year) rolls over by itself.
  static let untouchedSinceKey = "library.untouchedSince"

  static let tapToPickDefaultKey = "culling.tapToPickDefault"
  /// OFF: opening a shoot never latches anything unless the reader asks for it.
  static let tapToPickDefaultDefault = false

  /// Internal, not private: the Settings sheet observes the SAME suite through `@AppStorage`
  /// for the shared sidebar flag (see `regularSidebarHidden`).
  let defaults: UserDefaults
  private let now: @Sendable () -> Date

  var showUntouched: Bool {
    didSet { defaults.set(showUntouched, forKey: Self.showUntouchedKey) }
  }

  var showPinned: Bool {
    didSet { defaults.set(showPinned, forKey: Self.showPinnedKey) }
  }

  var showRecent: Bool {
    didSet { defaults.set(showRecent, forKey: Self.showRecentKey) }
  }

  var tapToPickDefault: Bool {
    didSet { defaults.set(tapToPickDefault, forKey: Self.tapToPickDefaultKey) }
  }

  /// The stored horizon, or the default when none (or a non-`Date`) is stored. Never written by
  /// a read.
  var untouchedSince: Date {
    get {
      access(keyPath: \.untouchedSince)
      return (defaults.object(forKey: Self.untouchedSinceKey) as? Date)
        ?? UntouchedSince.defaultStored(now: now())
    }
    set {
      withMutation(keyPath: \.untouchedSince) {
        defaults.set(newValue, forKey: Self.untouchedSinceKey)
      }
    }
  }

  /// `shell.regularSidebarHidden`, the flag `RootView` keeps through `@AppStorage`. COMPUTED over
  /// the suite, never a cached copy: the split's own toggles write the key while the sheet is
  /// closed, so every read goes to the suite. `access`/`withMutation` make a write through this
  /// property observable; a write made through `@AppStorage` (another window's split) reaches an
  /// open sheet through the sheet's own `@AppStorage` read instead.
  var regularSidebarHidden: Bool {
    get {
      access(keyPath: \.regularSidebarHidden)
      return GridPreferences.boolPreference(
        from: defaults.object(forKey: SidebarVisibilityMemory.hiddenKey),
        default: SidebarVisibilityMemory.hiddenDefault)
    }
    set {
      withMutation(keyPath: \.regularSidebarHidden) {
        defaults.set(newValue, forKey: SidebarVisibilityMemory.hiddenKey)
      }
    }
  }

  init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
    self.defaults = defaults
    self.now = now
    self.showUntouched = GridPreferences.boolPreference(
      from: defaults.object(forKey: Self.showUntouchedKey), default: Self.sidebarSectionDefault)
    self.showPinned = GridPreferences.boolPreference(
      from: defaults.object(forKey: Self.showPinnedKey), default: Self.sidebarSectionDefault)
    self.showRecent = GridPreferences.boolPreference(
      from: defaults.object(forKey: Self.showRecentKey), default: Self.sidebarSectionDefault)
    self.tapToPickDefault = GridPreferences.boolPreference(
      from: defaults.object(forKey: Self.tapToPickDefaultKey),
      default: Self.tapToPickDefaultDefault)
  }
}
