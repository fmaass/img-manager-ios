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

  @Test("Zero active shortcuts without a chrome surface — currently zero active, period")
  func zeroActiveShortcutsWithoutChromeSurface() {
    // The invariant fold item 1 states: isActive implies hasChromeSurface. Trivially
    // true by construction (isActive IS hasChromeSurface), but P3 additionally commits
    // to the CURRENT state being zero active entries at all — no grid/inspector/loupe
    // chrome has landed yet (Do-NOT), so nothing may claim activation.
    #expect(ShortcutCatalog.entries.allSatisfy { !$0.isActive || $0.hasChromeSurface })
    #expect(ShortcutCatalog.activeEntries.isEmpty)
  }
}
