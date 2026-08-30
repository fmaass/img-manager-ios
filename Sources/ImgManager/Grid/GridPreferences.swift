import Foundation

/// WP13 P5a (IMGMGR-221): the app's FIRST persisted scalar-preference store, and it says so.
///
/// Verified 2026-08-30 against this tree: there was no `@AppStorage`, no `UserDefaults` and no
/// `@SceneStorage` anywhere under `Sources/` (0 hits; positive control — `Keychain` hit
/// `RootView.swift`, `CredentialStore.swift` and the widget in the same invocation). The only
/// persistence before this file was the Keychain for credentials and one JSON file in
/// Application Support for the queue's cached answer, whose own doc comment says "never
/// `UserDefaults` — this is a payload, not a preference" (`QueueSnapshotStore.swift:29`). That
/// is a rule about PAYLOADS. A boolean the reader flipped in a menu is not a payload, and this
/// is the type that holds it.
///
/// Deliberately small: two scalars' worth of surface, one guard-typed read, an inventory of the
/// keys it owns, and an injectable `UserDefaults` so every test runs in its own suite. P8
/// (IMGMGR-214) adds `autoAdvanceOnMark` here; a persisted sort key arrives only if P5b's
/// premise gate or the owner asks for one.
///
/// The STANDARD suite, and only from the app: the widget extension is a separate process with
/// its own container and must not read this (no app group is declared for preferences, so it
/// physically cannot see these keys — that is the intent, not an accident).
@Observable
@MainActor
final class GridPreferences {
  /// Every key this type owns, in one place. `GridMoreMenuTests` asserts against this that the
  /// Density entry did NOT bring a second persisted density property with it — the grid's six
  /// row-height steps are the one density state (`GridRowHeight`), reached from two entry
  /// points (the Zoom control and the More menu), never two properties that can disagree.
  static let persistedKeys: [String] = [filenamePlatesKey]

  static let filenamePlatesKey = "grid.filenamePlates"
  static let filenamePlatesDefault = false

  private let defaults: UserDefaults

  /// Show each tile's filename under it. FILENAME ONLY — never a path (p3220 §4.5); the plate's
  /// text is `ImageSummary.filename` verbatim, the same string the inspector already renders.
  var filenamePlates: Bool {
    didSet { defaults.set(filenamePlates, forKey: Self.filenamePlatesKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.filenamePlates = Self.boolPreference(
      from: defaults.object(forKey: Self.filenamePlatesKey),
      default: Self.filenamePlatesDefault)
  }

  /// GUARD-TYPED, never `UserDefaults.bool(forKey:)`: that accessor COERCES — it reads a string
  /// through `NSString.boolValue` and answers `false` for anything it cannot parse, so a value
  /// written by another build (or a future type change) silently becomes a real `false` instead
  /// of "no preference". This reads the stored object and accepts it only if it IS a boolean;
  /// anything else falls back to the declared default. Same posture the web client already uses
  /// (`frontend/src/lib/usePersistedPref.ts`).
  static func boolPreference(from stored: Any?, default fallback: Bool) -> Bool {
    _ = fallback
    return (stored as? Bool) ?? false  // RED stub
  }
}
