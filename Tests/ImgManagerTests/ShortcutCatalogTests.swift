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

  @Test("WP8 P4: the active set is EXACTLY arrows/P/X/Shift+advance/T/Z — no more, no less")
  func p4ActivatesExactlyItsOwnSet() {
    // Plan §Phase 4 fold item 3 + Amendment: "P4 activates: arrows, P, X, Shift+advance, T,
    // Z(Undo). U(Clear) stays P5." Space/Enter (`openSpaceEnter`) stays planned too — both the
    // original fold and its delta round defer second-tap AND keyboard Open to P5 (no loupe
    // destination exists in P4). `help` (`?`) stays P3's own unresolved item, untouched here.
    let expectedActive: Set<ShortcutID> = [
      .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
      .pick, .dislike, .shiftAdvance, .tag, .undo,
    ]
    let actualActive = Set(ShortcutCatalog.activeEntries.map(\.id))
    #expect(actualActive == expectedActive)

    let expectedInactive: Set<ShortcutID> = [.openSpaceEnter, .clear, .help]
    let actualInactive = Set(
      ShortcutCatalog.entries.filter { !$0.isActive }.map(\.id))
    #expect(actualInactive == expectedInactive)
  }

  @Test("Space/Enter (open) is NOT active in P4 — no loupe destination exists yet")
  func openStaysPlannedInP4() {
    let entry = ShortcutCatalog.entries.first { $0.id == .openSpaceEnter }
    #expect(entry?.hasChromeSurface == false)
    #expect(entry?.isActive == false)
  }

  @Test("Clear (U) is NOT active in P4 — it stays P5's own")
  func clearStaysPlannedInP4() {
    let entry = ShortcutCatalog.entries.first { $0.id == .clear }
    #expect(entry?.owningPhase == .p5)
    #expect(entry?.isActive == false)
  }
}
