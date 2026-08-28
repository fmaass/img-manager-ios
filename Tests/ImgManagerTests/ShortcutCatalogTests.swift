import Testing

@testable import ImgManager

/// P3 fold item 1's three assertions, verbatim: the exact target inventory minus `C`; no
/// `C` anywhere; zero active shortcuts without a chrome surface.
@Suite("Shortcut catalog (P3 fold item 1)")
struct ShortcutCatalogTests {

  @Test("Catalog is exactly the P3 target inventory, minus C")
  func exactTargetInventoryMinusC() {
    let expected: Set<ShortcutID> = [
      .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
      .openSpaceEnter,
      .pick, .dislike, .clear, .shiftAdvance,
      .tag, .undo, .help,
    ]
    let actual = Set(ShortcutCatalog.entries.map(\.id))
    #expect(actual == expected)
    #expect(ShortcutCatalog.entries.count == 12)
  }

  @Test("No C anywhere in the catalog")
  func noCAnywhere() {
    for entry in ShortcutCatalog.entries {
      #expect(entry.id.rawValue.uppercased() != "C")
    }
    // A structural guarantee, not just a per-entry scan over the current data: no case
    // in the enum itself is named for the letter C or "compare" — ShortcutID's own case
    // list is the thing a future edit would have to touch to reintroduce it, and this
    // assertion covers that list directly, independent of what ShortcutCatalog.entries
    // happens to contain.
    let allRawValues = ShortcutID.allCases.map { $0.rawValue.uppercased() }
    #expect(!allRawValues.contains("C"))
    #expect(!allRawValues.contains("COMPARE"))
  }

  @Test("No entry is active without a chrome surface (isActive implies hasChromeSurface)")
  func noEntryActiveWithoutChromeSurface() {
    // Trivially true by construction (isActive IS hasChromeSurface) but asserted directly so
    // a future edit that decouples the two still has a test catching the drift.
    #expect(ShortcutCatalog.entries.allSatisfy { !$0.isActive || $0.hasChromeSurface })
  }

  @Test("P4's OWN entries (owningPhase == .p4) are all active — scoped by owner, durable across later phases")
  func p4OwnEntriesAreActive() {
    // Plan §Phase 4 fold item 3 + Amendment: "P4 activates: arrows, P, X, Shift+advance, T,
    // Z(Undo)." Scoped to `owningPhase == .p4` (rather than the raw global active set) so a
    // LATER phase activating its OWN entries — P5's `openSpaceEnter`/`clear` below — cannot
    // make this assertion stale; the original (pre-P5) single-set assertion did exactly that
    // and had to be split when P5 shipped.
    let p4Owned = ShortcutCatalog.entries.filter { $0.owningPhase == .p4 }
    let expectedP4Active: Set<ShortcutID> = [
      .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .openSpaceEnter,
      .pick, .dislike, .shiftAdvance, .tag, .undo,
    ]
    #expect(Set(p4Owned.map(\.id)) == expectedP4Active)
    #expect(p4Owned.allSatisfy { $0.isActive })
  }

  @Test("WP8 P5: Space/Enter (open) and U (Clear) are now active — the loupe destination and its mark bar both ship")
  func p5ActivatesOpenAndClear() {
    let open = ShortcutCatalog.entries.first { $0.id == .openSpaceEnter }
    #expect(open?.hasChromeSurface == true)
    #expect(open?.isActive == true)

    let clear = ShortcutCatalog.entries.first { $0.id == .clear }
    #expect(clear?.owningPhase == .p5)
    #expect(clear?.hasChromeSurface == true)
    #expect(clear?.isActive == true)
  }

  @Test("`?` (help) is the ONE entry still inactive — P3's own unresolved item, untouched by P4 or P5")
  func onlyHelpStaysInactive() {
    let inactive = Set(ShortcutCatalog.entries.filter { !$0.isActive }.map(\.id))
    #expect(inactive == [.help])
  }
}
