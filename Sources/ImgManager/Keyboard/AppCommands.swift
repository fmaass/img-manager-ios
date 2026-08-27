import SwiftUI

/// The dispatcher/menu-bar infrastructure P3 fold item 1 requires: the scene-level
/// `Commands` builder every phase's chrome adds its `CommandGroup` into once it lands. A
/// shortcut becomes ACTIVE — declared in `commands(content:)` — only in the same commit
/// that ships its owning phase's persistent-chrome surface (`ShortcutCatalog.swift`).
///
/// P3 ships this with ZERO populated command groups: Queue/Grid/Inspector are still bare
/// placeholders (P0a doc comment on `RootView`), so no shortcut's chrome surface exists
/// yet — `ShortcutCatalog.activeEntries` is empty and this type's body is intentionally
/// empty in lock step with it. The infrastructure (this type, wired into the app's Scene
/// below) is what P3 delivers; populated content is every later phase's job.
struct AppCommands: Commands {
  var body: some Commands {
    // Deliberately empty — see the type doc comment and
    // ShortcutCatalogTests.testZeroActiveShortcutsWithoutChromeSurface.
  }
}
