import CoreGraphics
import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// IMGMGR-495 (owner ruling, comment 10230): "⌘0 alone toggles Fit/100% in the loupe and in
/// Compare". The menu bar's ⌘0 row dispatches into `ViewerZoomCommand` — the mounted viewer's
/// own zoom toggle — and not into `GridKeyboardActions`, so these tests drive the DECLARATION
/// exactly as `AppCommands.entry(_:)`'s Button does (`isEnabled` for `.disabled`, `perform` for
/// the action), against each combination of focused values the scene can publish.
@MainActor
@Suite("⌘0 — Fit / 100 % in the loupe and in Compare (IMGMGR-495)")
struct ViewerZoomCommandTests {
  /// Counts what a published `ViewerZoomCommand` was asked to do.
  private final class ToggleSpy {
    var count = 0
  }

  private func makeStore() -> GridStore {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  private func toggleRow() -> MenuCommandDeclaration? {
    AppCommands.declarations.first { $0.shortcut == .viewerZoomToggle }
  }

  @Test("Disabled on the bare grid; live in the loupe and in Compare")
  func enabledExactlyWhileAViewerIsMounted() {
    let row = toggleRow()
    #expect(row != nil, "no ⌘0 declaration")
    let grid = makeStore().keyboardActions
    let viewer = ViewerZoomCommand(toggle: {})

    // Bare grid: the grid's actions are published, no viewer is.
    #expect(row?.isEnabled(grid: grid, viewerZoom: nil) == false)
    // Loupe: both are published.
    #expect(row?.isEnabled(grid: grid, viewerZoom: viewer) == true)
    // Compare: the grid's actions are nil (decision 7), the viewer is published.
    #expect(row?.isEnabled(grid: nil, viewerZoom: viewer) == true)
    // No workspace scene focused at all.
    #expect(row?.isEnabled(grid: nil, viewerZoom: nil) == false)

    // Decision 7 is untouched: a GRID row stays disabled in Compare even though a viewer is
    // published there — the positive control that `isEnabled` reads the row's own target.
    let commandOne = AppCommands.declarations.first {
      $0.key == KeyEquivalent("1") && $0.modifiers == EventModifiers.command
    }
    #expect(commandOne?.isEnabled(grid: nil, viewerZoom: viewer) == false)
    #expect(commandOne?.isEnabled(grid: grid, viewerZoom: nil) == true)
  }

  @Test("⌘0 dispatches into the viewer's toggle and never into the grid's actions")
  func dispatchesIntoTheViewerOnly() {
    let row = toggleRow()
    let store = makeStore()
    let before = store.rowHeight
    let spy = ToggleSpy()
    let viewer = ViewerZoomCommand(toggle: { spy.count += 1 })

    row?.perform(grid: store.keyboardActions, viewerZoom: viewer)
    #expect(spy.count == 1, "⌘0 did not reach the published viewer's toggle")
    row?.perform(grid: nil, viewerZoom: viewer)
    #expect(spy.count == 2, "⌘0 did not reach the viewer while the grid's actions were nil")

    // The grid-actions call shape is a no-op on this row, and nothing on the grid moved.
    row?.run(store.keyboardActions)
    row?.perform(grid: store.keyboardActions, viewerZoom: nil)
    #expect(spy.count == 2)
    #expect(store.rowHeight == before)
  }

  @Test("⌘1 still sets the grid's first zoom step, through the SAME perform path")
  func commandOneStillSetsTheFirstStep() {
    let store = makeStore()
    let first = GridRowHeight.allCases[0]
    #expect(store.rowHeight != first, "the fixture must not already sit on the first step")
    let commandOne = AppCommands.declarations.first {
      $0.key == KeyEquivalent("1") && $0.modifiers == EventModifiers.command
    }
    commandOne?.perform(grid: store.keyboardActions, viewerZoom: ViewerZoomCommand(toggle: {}))
    #expect(store.rowHeight == first)
  }

  @Test("In the loupe, ⌘0 round-trips Fit → 100 % → Fit through LoupeZoomState.toggle()")
  func loupeRoundTrip() {
    // The loupe publishes `{ mutateZoom { $0.toggle() } }`; the same mutation over the same model
    // type, so the round trip is the production value's, not a second target.
    let model = LoupeZoomModel()
    model.state.updateGeometry(
      proxyPixels: CGSize(width: 1600, height: 1067), viewport: CGSize(width: 400, height: 300),
      displayScale: 2)
    #expect(model.state.isZoomAvailable)
    let viewer = ViewerZoomCommand(toggle: { model.state.toggle() })
    let row = toggleRow()

    #expect(model.state.accessibilityValue == "zoom fit, pan 0, 0")
    row?.perform(grid: nil, viewerZoom: viewer)
    #expect(model.state.scale == model.state.oneToOneScale)
    #expect(model.state.accessibilityValue == "zoom 100 %, pan 0, 0")
    row?.perform(grid: nil, viewerZoom: viewer)
    #expect(model.state.accessibilityValue == "zoom fit, pan 0, 0")
  }
}
