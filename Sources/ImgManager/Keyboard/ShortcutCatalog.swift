import Foundation

/// The web keyboard set this app mirrors verbatim (P3 fold item 1; `frontend/src/lib/keys.ts`
/// in the web repo is the source of truth for what each key means), PLUS the ⌘-modified
/// discovery half of design decision 9 that WP13 P4 adds (`zoomStep`, `sceneToggle`,
/// `groupMode`, and the `⌘/` form of `help`). Deliberately NOT the web's full set: `A`
/// (auto-advance toggle), `Escape` (close), `Tab` (compare-flip) and `C` (compare) are all
/// excluded from the target inventory — `C` because native compare is cancelled outright
/// (Amendment 7; declared NOWHERE, never present-and-dead), `A` because its own surface is
/// WP13 P8's and a present-and-dead key is exactly what this catalog exists to prevent, the
/// other two because the P3 fold's own target inventory line does not name them.
///
/// This enum is the SINGLE inventory: every key equivalent the app declares names one of these
/// cases (`AppCommands.declarations`), and `ShortcutCatalogTests` asserts that correspondence
/// in both directions. There is no second list anywhere.
enum ShortcutID: String, CaseIterable, Sendable {
  case arrowUp = "ArrowUp"
  case arrowDown = "ArrowDown"
  case arrowLeft = "ArrowLeft"
  case arrowRight = "ArrowRight"
  /// Space and Enter both mean "open" on the web (`keys.ts`: `" "`, `"enter"` share one
  /// case) — one catalog entry, not two.
  case openSpaceEnter = "Space/Enter"
  case pick = "P"
  case dislike = "X"
  case clear = "U"
  /// Not a distinct physical key: Shift held on P/X/U means "mark and advance" (the
  /// web's own `CullAction.mark.shift` field). Catalogued separately because the P3
  /// fold's target inventory names it as its own bullet, distinct from the bare P/X/U
  /// marks.
  case shiftAdvance = "Shift+advance"
  case tag = "T"
  case undo = "Z"
  case help = "?"
  /// WP13 P4 (IMGMGR-215): the six `GridRowHeight` steps, published as ⌘1…⌘6 — ONE catalog
  /// entry with six declarations, the same shape `openSpaceEnter` already uses for its two.
  case zoomStep = "⌘1…⌘6"
  /// WP13 P4 (IMGMGR-215): Scene view on/off. `⌘G` is deliberately NOT used — it
  /// conventionally means "Find Next" on Apple platforms and HIG Keyboards warns against
  /// re-binding an established system shortcut, so the Shift-modified form carries it.
  case sceneToggle = "⌘⇧G"
  /// WP13 P4 (IMGMGR-215), diff-gate r1 blocker 1: the View menu's Group single-select pair
  /// (`None` / `Scene`) — ONE catalog entry with two declarations, the shape `zoomStep` and
  /// `openSpaceEnter` already use. It exists because design decision 9's parity rule is "every
  /// menu entry has a declared bare/⌘ equivalent in the single catalog": the pair shipped
  /// unkeyed, which the reconciliation test could not see because it filtered unkeyed
  /// declarations out.
  ///
  /// ASSIGNMENT, and why it collides with nothing (the plan flags the whole ⌘ table OPEN,
  /// `PLAN_2026-08-30_wp13-photoculler-idiom.md` §Phase 4):
  /// - The pair is a view-ARRANGEMENT single-select — the role Finder gives ⌘1/⌘2.
  ///   Those bare digits are already this app's six zoom steps, so the arrangement pair takes
  ///   the same two digits one modifier up: `⌃⌘1` = None, `⌃⌘2` = Scene.
  /// - No iPadOS system default uses ⌃⌘digit: the combinations iPadOS reserves are ⌘Space,
  ///   ⌘Tab, ⌘H, ⌘⌥D, ⌘⇧3/⌘⇧4 and ⌃⌘Space (Apple Support, "Keyboard shortcuts for iPad"),
  ///   plus the ⌘G "Find Next" convention HIG Keyboards warns about. `ShortcutCatalogTests`
  ///   asserts that none of them is bound, with a positive control on the predicate itself.
  /// - No OTHER declaration in this app binds ⌃⌘1/⌃⌘2: the same test file asserts that every
  ///   (key, modifiers) pair across all menus is unique.
  case groupMode = "⌃⌘1 · ⌃⌘2"
  /// WP13 P5b (IMGMGR-221 part 2): the six offered sort keys, published as ⌥⌘1…⌥⌘6 — ONE
  /// catalog entry with six declarations, the shape `zoomStep` and `groupMode` already use.
  /// ⌥⌘digit is the third distinct modifier over the same digits (⌘ zoom, ⌃⌘ arrangement,
  /// ⌥⌘ sort); no iPadOS system default binds it and nothing else in this app does, both
  /// asserted in `ShortcutCatalogTests`.
  case sortKey = "⌥⌘1…⌥⌘6"
  /// WP13 P5b: ascending ⟷ descending, the accelerator form of the Sort menu's direction rows.
  /// `R` for reverse; ⌥⌘R is unbound by iPadOS and by this app.
  case sortDirection = "⌥⌘R"
}

extension ShortcutID {
  /// How the shortcut is WRITTEN for a reader — the help sheet's key column. Lives on the id
  /// itself so the catalog stays the single inventory; `AppCommands` binds the real
  /// `KeyEquivalent`s and a test asserts the two agree entry-for-entry.
  var keyLabel: String {
    switch self {
    case .arrowUp: return "↑"
    case .arrowDown: return "↓"
    case .arrowLeft: return "←"
    case .arrowRight: return "→"
    case .openSpaceEnter: return "Space or Return"
    case .pick: return "P"
    case .dislike: return "X"
    case .clear: return "U"
    case .shiftAdvance: return "⇧P · ⇧X · ⇧U"
    case .tag: return "T"
    case .undo: return "Z"
    case .help: return "? or ⌘/"
    case .zoomStep: return "⌘1 … ⌘6"
    case .sceneToggle: return "⌘⇧G"
    case .groupMode: return "⌃⌘1 · ⌃⌘2"
    case .sortKey: return "⌥⌘1 … ⌥⌘6"
    case .sortDirection: return "⌥⌘R"
    }
  }

  /// A stable ASCII handle for this entry — the accessibility identifier the help sheet's
  /// row carries, and the only thing a UI test can address it by. Derived from the CASE NAME
  /// rather than `rawValue`, because the raw values are display strings made of ⌘/⇧
  /// glyphs, which make miserable identifiers. Renaming a case therefore breaks the UI test
  /// loudly rather than silently.
  var accessibilityToken: String { String(describing: self) }

  /// What pressing it does, in the reader's words — the help sheet's meaning column.
  var meaning: String {
    switch self {
    case .arrowUp: return "Move the focus up a row"
    case .arrowDown: return "Move the focus down a row"
    case .arrowLeft: return "Move the focus to the previous photograph"
    case .arrowRight: return "Move the focus to the next photograph"
    case .openSpaceEnter: return "Open the focused photograph"
    case .pick: return "Pick"
    case .dislike: return "Dislike"
    case .clear: return "Clear the mark"
    case .shiftAdvance: return "Mark and advance to the next photograph"
    case .tag: return "Add a tag"
    case .undo: return "Undo the last mark"
    case .help: return "Show this list of keyboard shortcuts"
    case .zoomStep: return "Set the grid zoom step (120 pt … 400 pt)"
    case .sceneToggle: return "Turn Scene view on or off"
    case .groupMode: return "Choose the grid arrangement — ⌃⌘1 None, ⌃⌘2 Scene"
    case .sortKey: return "Sort the grid — Date, Filename, Rating, ISO, Camera, Lens"
    case .sortDirection: return "Reverse the sort direction"
    }
  }
}

/// Which phase owns the persistent-chrome surface a shortcut attaches to. Assigned
/// from each phase's own Approach text (not the phase titles alone — the diff-gate
/// reconciliation below caught two entries assigned from title/scope-line guesswork
/// that disagreed with the actual persistent-bar contents written into the phases
/// themselves):
/// - `.p4` ("Shoot grid, inspector, selection") owns grid navigation, the Pick/Dislike
///   marks and **undo** (P4's Approach text: "persistent bottom action bar (Pick ·
///   Dislike · Undo · Tag · More)" — undo's chrome surface exists starting here, not
///   P6; Pick Lock's "Dislike Lock parity" amendment additionally confirms P4 owns the
///   mark buttons), the tag popover, and the grid->loupe "open" action.
/// - `.p5` ("Loupe / cull") owns **clear**: P5's own bar (Pick · Dislike · Clear · Undo) is where
///   `U` first got a chrome surface, and OWNERSHIP is historical — it records which phase
///   shipped the surface that activated the shortcut, not every surface that exists now.
///   WP13 P1 added a Clear control to the GRID action bar as well (the ticket names
///   Pick/Dislike/Clear as the Select-mode actions), so the parenthetical this line used to
///   carry — "P4's own bar has no Clear button" — is no longer true and has been removed
///   rather than left standing as a stale fact about shipped chrome.
///
/// The first three cases are WP8 phases; `.wp13p4` is WP13's view-options phase.
enum OwningPhase: String, Sendable {
  case p4 = "P4 — Shoot grid, inspector, selection"
  case p5 = "P5 — Loupe / cull"
  /// `?` (help) is infrastructure, not a product action — its natural home is the
  /// dispatcher/menu-bar surface P3 itself builds (fold item 1), not a downstream screen.
  /// It stayed PLANNED through WP8 because P3's own chrome was the bare menu bar and a
  /// working "list every shortcut" sheet was a product decision P3's Do-NOT list did not
  /// grant. WP13 P4 (IMGMGR-215) is the phase that grants it: `ShortcutHelpSheet` is that
  /// surface, and this entry flips ACTIVE in the same commit that ships it — the rule below,
  /// not an exception to it.
  case p3 = "P3 — Shell (dispatcher/menu-bar infrastructure itself)"
  /// WP13 P4 (IMGMGR-215): the grid options row on Compact, the `.primaryAction` Group/Zoom
  /// controls on Regular, and the menu-bar View menu — the chrome surface the ⌘ view-option
  /// equivalents attach to.
  case wp13p4 = "WP13 P4 — View options (options row, View menu, shortcut help)"
  /// WP13 P5b (IMGMGR-221 part 2): the Sort control — a `.primaryAction` toolbar item on
  /// Regular and a third menu on Compact's persistent options row — plus the View menu's own
  /// Sort group. The chrome ships in the same commit these entries flip active in.
  case wp13p5b = "WP13 P5b — Sort and group parity (Sort control, View menu Sort group)"
}

/// One entry in the shortcut catalog fold item 1 requires: a PLANNED record of every
/// target shortcut and the phase whose chrome surface it waits on. A shortcut is ACTIVE
/// — and only then eligible for `commands(content:)` — once `hasChromeSurface` flips to
/// true, which happens in the same commit that ships its owning phase's actual chrome
/// (never before; see `AppCommands.swift`).
struct ShortcutCatalogEntry: Sendable {
  let id: ShortcutID
  let owningPhase: OwningPhase
  /// Flips to `true` only in the commit that ships the owning phase's chrome.
  let hasChromeSurface: Bool

  var isActive: Bool { hasChromeSurface }
}

enum ShortcutCatalog {
  /// WP8 P4 (IMGMGR-116): P4's own chrome — the persistent grid, action bar, and
  /// `GridKeyboardActions` wired to real `GridStore` calls — now exists, so P4's OWN entries
  /// flip `hasChromeSurface: true` here in the SAME commit that ships that chrome (the type
  /// doc comment's own rule).
  ///
  /// WP8 P5 (IMGMGR-116): the loupe destination now exists, so `openSpaceEnter` (the grid's own
  /// second-tap AND keyboard Open both land on it) and `clear` (its chrome surface is the
  /// loupe's own mark bar, `Pick · Dislike · Clear · Undo`) both flip `hasChromeSurface: true`
  /// here too, in this same commit.
  ///
  /// WP13 P4 (IMGMGR-215): `help` finally gets its surface (`ShortcutHelpSheet`), and the three
  /// view-option entries arrive already active because their chrome — the Compact grid options
  /// row, the Regular `.primaryAction` controls and the menu-bar View menu — ships in this same
  /// commit. Nothing here is present-and-dead.
  static let entries: [ShortcutCatalogEntry] = [
    ShortcutCatalogEntry(id: .arrowUp, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .arrowDown, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .arrowLeft, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .arrowRight, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .openSpaceEnter, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .pick, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .dislike, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .clear, owningPhase: .p5, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .shiftAdvance, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .tag, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .undo, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .help, owningPhase: .p3, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .zoomStep, owningPhase: .wp13p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .sceneToggle, owningPhase: .wp13p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .groupMode, owningPhase: .wp13p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .sortKey, owningPhase: .wp13p5b, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .sortDirection, owningPhase: .wp13p5b, hasChromeSurface: true),
  ]

  static var activeEntries: [ShortcutCatalogEntry] { entries.filter(\.isActive) }
}
