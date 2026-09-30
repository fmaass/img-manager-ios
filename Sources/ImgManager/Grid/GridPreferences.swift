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
/// (IMGMGR-214) added `autoAdvanceOnMark` here, exactly as this comment anticipated — never a
/// second preference mechanism; a persisted sort key arrives only if P5b's premise gate or the
/// owner asks for one.
///
/// The STANDARD suite, and only from the app: the widget extension is a separate process with
/// its own container and must not read this (no app group is declared for preferences, so it
/// physically cannot see these keys — that is the intent, not an accident).
@Observable
@MainActor
final class GridPreferences {
  /// Every key this type owns, in one place. `GridMoreMenuTests` and `ArrangeModelTests` assert
  /// against this that no density, sort or grouping key was ever persisted — the grid's six
  /// row-height steps are the one density state (`GridRowHeight`, reached from the Arrange
  /// popover and ⌘1…⌘6 since WP29 P2), never two properties that can disagree.
  static let persistedKeys: [String] = [
    filenamePlatesKey, autoAdvanceOnMarkKey, picksInGroupsKey, pruneMirroredArchiveKey,
  ]

  static let filenamePlatesKey = "grid.filenamePlates"
  static let filenamePlatesDefault = false

  static let autoAdvanceOnMarkKey = "loupe.autoAdvanceOnMark"
  /// ON, and that is an OWNER decision of 2026-08-30 (epic IMGMGR-211 comment 2106, restated on
  /// IMGMGR-214 comment 2107) which supersedes the ticket's own "off by default unless the owner
  /// says otherwise" clause. Recorded here rather than only in a plan, because this constant is
  /// the thing the decision actually is.
  static let autoAdvanceOnMarkDefault = true

  static let picksInGroupsKey = "grid.picksInGroups"
  /// OFF, and here the ticket's own default stands (IMGMGR-261 AC 1): this one ADDS ink to every
  /// collapsed card and costs a membership request per visible scene, so the reader asks for it.
  static let picksInGroupsDefault = false

  static let pruneMirroredArchiveKey = "grid.pruneMirroredArchive"
  /// OFF, and that is an OWNER decision (design note /link/3396 §6 Q6, WP21): the archive's
  /// mirrored folders are HIDDEN only when the reader asks, so the tree a reader already knows is
  /// what the app opens with. The web ships the same switch in the opposite sense
  /// ("Show mirrored folders"); the KEY here is named for what turning it on does, so the stored
  /// value and the row's words cannot disagree.
  static let pruneMirroredArchiveDefault = false

  private let defaults: UserDefaults

  /// Show each tile's filename under it. FILENAME ONLY — never a path (p3220 §4.5); the plate's
  /// text is `ImageSummary.filename` verbatim, the same string the inspector already renders.
  var filenamePlates: Bool {
    didSet { defaults.set(filenamePlates, forKey: Self.filenamePlatesKey) }
  }

  /// WP13 P8 (IMGMGR-214): after a committed mark in the LOUPE, move to the next frame — the
  /// culling cadence "judge, advance, judge". ON by default, which is an owner decision of
  /// 2026-08-30 (epic IMGMGR-211 comment 2106) that supersedes the ticket's own
  /// "off by default unless the owner says otherwise" clause. Never read by any grid path:
  /// Shift+P/X/U is the grid's own deliberate mark-and-advance and this preference does not
  /// touch it.
  var autoAdvanceOnMark: Bool {
    didSet { defaults.set(autoAdvanceOnMark, forKey: Self.autoAdvanceOnMarkKey) }
  }

  /// IMGMGR-261: show the picks a COLLAPSED scene holds, inside the card's own region.
  ///
  /// A view option, so it lives where the app's other view options already live — the More menu's
  /// view cluster — and not in a settings panel. (The web sibling needs a panel because the web
  /// has no such menu; that difference is the disposition, not a divergence.) DISPLAY-only: what
  /// this switches on is drawn, never made actionable, and it never enters `sceneMembers`.
  var picksInGroups: Bool {
    didSet { defaults.set(picksInGroups, forKey: Self.picksInGroupsKey) }
  }

  /// IMGMGR-362 (WP21 P3): hide the archive folders the incoming library already holds — every
  /// folder whose dedup-adjusted count is zero (`FolderTreeModel.pruneMirrored`, the web's
  /// `folderTree.ts:188-197`). A VIEW option over the folder tree, so it lives with the app's
  /// other view options — the More menu's View section — and never in a settings panel of its
  /// own. This type is the ONE place the switch is stored. WP29 P2 (IMGMGR-453): its one entry
  /// point is the tree home's View menu; the grid's More menu no longer carries it.
  var pruneMirroredArchive: Bool {
    didSet { defaults.set(pruneMirroredArchive, forKey: Self.pruneMirroredArchiveKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.filenamePlates = Self.boolPreference(
      from: defaults.object(forKey: Self.filenamePlatesKey),
      default: Self.filenamePlatesDefault)
    self.autoAdvanceOnMark = Self.boolPreference(
      from: defaults.object(forKey: Self.autoAdvanceOnMarkKey),
      default: Self.autoAdvanceOnMarkDefault)
    self.picksInGroups = Self.boolPreference(
      from: defaults.object(forKey: Self.picksInGroupsKey),
      default: Self.picksInGroupsDefault)
    self.pruneMirroredArchive = Self.boolPreference(
      from: defaults.object(forKey: Self.pruneMirroredArchiveKey),
      default: Self.pruneMirroredArchiveDefault)
  }

  /// GUARD-TYPED, never `UserDefaults.bool(forKey:)`: that accessor COERCES — it reads a string
  /// through `NSString.boolValue` and answers `false` for anything it cannot parse, so a value
  /// written by another build (or a future type change) silently becomes a real `false` instead
  /// of "no preference". This reads the stored object and accepts it only if it IS a boolean;
  /// anything else falls back to the declared default. Same posture the web client already uses
  /// (`frontend/src/lib/usePersistedPref.ts`).
  static func boolPreference(from stored: Any?, default fallback: Bool) -> Bool {
    (stored as? Bool) ?? fallback
  }
}
