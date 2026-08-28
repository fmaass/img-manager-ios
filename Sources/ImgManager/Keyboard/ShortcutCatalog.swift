import Foundation

/// The web keyboard set this app mirrors verbatim (P3 fold item 1; `frontend/src/lib/keys.ts`
/// in the web repo is the source of truth for what each key means). Deliberately NOT the
/// web's full set: `A` (auto-advance toggle), `Escape` (close), `Tab` (compare-flip) and
/// `C` (compare) are all excluded from the target inventory — `C` because native compare
/// is cancelled outright (Amendment 7; declared NOWHERE, never present-and-dead), the
/// other three because the P3 fold's own target inventory line does not name them.
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
}

/// Which WP8 phase owns the persistent-chrome surface a shortcut attaches to. Assigned
/// from each phase's own Approach text (not the phase titles alone — the diff-gate
/// reconciliation below caught two entries assigned from title/scope-line guesswork
/// that disagreed with the actual persistent-bar contents written into the phases
/// themselves):
/// - `.p4` ("Shoot grid, inspector, selection") owns grid navigation, the Pick/Dislike
///   marks and **undo** (P4's Approach text: "persistent bottom action bar (Pick ·
///   Dislike · Undo · Tag · More)" — undo's chrome surface exists starting here, not
///   P6; Pick Lock's "Dislike Lock parity" amendment additionally confirms P4 owns the
///   mark buttons), the tag popover, and the grid->loupe "open" action.
/// - `.p5` ("Loupe / cull") owns **clear** (P5's Approach text: "persistent bottom mark
///   bar (Pick · Dislike · Clear · Undo)" — Clear's chrome surface is P5's bar; P4's own
///   bar has no Clear button).
enum OwningPhase: String, Sendable {
  case p4 = "P4 — Shoot grid, inspector, selection"
  case p5 = "P5 — Loupe / cull"
  /// `?` (help) is infrastructure, not a product action — its natural home is the
  /// dispatcher/menu-bar surface P3 itself builds (fold item 1), not a downstream
  /// screen. It stays PLANNED rather than ACTIVE here even so: P3's own chrome is the
  /// bare menu bar with zero populated command groups (`AppCommands.swift`), and a
  /// working "list every shortcut" sheet is a product decision this phase's Do-NOT list
  /// does not clearly grant — kept inert and flagged as an open question rather than
  /// asserted.
  case p3 = "P3 — Shell (dispatcher/menu-bar infrastructure itself)"
}

/// One entry in the shortcut catalog fold item 1 requires: a PLANNED record of every
/// target shortcut and the phase whose chrome surface it waits on. A shortcut is ACTIVE
/// — and only then eligible for `commands(content:)` — once `hasChromeSurface` flips to
/// true, which happens in the same commit that ships its owning phase's actual chrome
/// (never before; see `AppCommands.swift`).
struct ShortcutCatalogEntry: Sendable {
  let id: ShortcutID
  let owningPhase: OwningPhase
  /// Flips to `true` only in the commit that ships the owning phase's chrome. P3 ships
  /// none of P4/P5/P6's chrome (Do-NOT: "no grid, inspector, compare or loupe content
  /// yet"), so every entry is `false` here — this is a data fact the tests assert, not
  /// an oversight.
  let hasChromeSurface: Bool

  var isActive: Bool { hasChromeSurface }
}

enum ShortcutCatalog {
  /// WP8 P4 (IMGMGR-116): P4's own chrome — the persistent grid, action bar, and
  /// `GridKeyboardActions` wired to real `GridStore` calls — now exists, so P4's OWN entries
  /// flip `hasChromeSurface: true` here in the SAME commit that ships that chrome (the type
  /// doc comment's own rule). `openSpaceEnter` stays `false`: the plan's P4 fold item 3 and its
  /// delta round both defer BOTH second-tap and keyboard Open to P5 — no loupe destination
  /// exists in P4, so there is nothing for `Space`/`Enter` to do yet. `clear` (`U`) stays P5's,
  /// unchanged, per the same fold.
  static let entries: [ShortcutCatalogEntry] = [
    ShortcutCatalogEntry(id: .arrowUp, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .arrowDown, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .arrowLeft, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .arrowRight, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .openSpaceEnter, owningPhase: .p4, hasChromeSurface: false),
    ShortcutCatalogEntry(id: .pick, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .dislike, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .clear, owningPhase: .p5, hasChromeSurface: false),
    ShortcutCatalogEntry(id: .shiftAdvance, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .tag, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .undo, owningPhase: .p4, hasChromeSurface: true),
    ShortcutCatalogEntry(id: .help, owningPhase: .p3, hasChromeSurface: false),
  ]

  static var activeEntries: [ShortcutCatalogEntry] { entries.filter(\.isActive) }
}
