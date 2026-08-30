import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// WP13 P4 (IMGMGR-215): the two view-option controls and the View menu's dispatch into the
/// store. The controls' labels are pure functions precisely so the "value in the label"
/// contract — the discoverability half of this ticket — is testable without a render host.
@MainActor
@Suite("Grid view options (WP13 P4)")
struct GridViewOptionsTests {

  private func makeStore() -> GridStore {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  @Test("Each control's label carries its CURRENT value, never a bare icon word")
  func controlsCarryTheirCurrentValueInTheLabel() {
    #expect(GridGroupControl.title(for: .flat) == "Group: None")
    #expect(GridGroupControl.title(for: .scene) == "Group: Scene")
    for step in GridRowHeight.allCases {
      #expect(GridZoomControl.title(for: step) == "Zoom: \(Int(step.rawValue)) pt")
    }
  }

  @Test("The View menu's zoom entries move the store's real row height")
  func viewMenuZoomEntriesSetTheRowHeight() {
    let store = makeStore()
    let actions = store.keyboardActions
    #expect(store.rowHeight == .step200)

    actions.setRowHeight(.step400)
    #expect(store.rowHeight == .step400)
    #expect(GridZoomControl.title(for: store.rowHeight) == "Zoom: 400 pt")

    actions.setRowHeight(.step120)
    #expect(store.rowHeight == .step120)
  }

  @Test("⌘⇧G toggles Scene view on, then back off — and never latches one way")
  func sceneToggleFlipsBothWays() async {
    let store = makeStore()
    let actions = store.keyboardActions
    #expect(store.displayMode == .flat)

    actions.toggleSceneMode()
    await waitFor { store.displayMode == .scene }
    #expect(store.displayMode == .scene)

    // Read off the store's own current mode, not a snapshot the closure captured: a second
    // press must come BACK, which is what "on/off" means.
    actions.toggleSceneMode()
    await waitFor { store.displayMode == .flat }
    #expect(store.displayMode == .flat)
  }

  @Test("The View menu's Group entries are single-select — each names one arrangement")
  func groupEntriesAreSingleSelect() async {
    let store = makeStore()
    let actions = store.keyboardActions

    actions.setDisplayMode(.scene)
    await waitFor { store.displayMode == .scene }
    #expect(store.displayMode == .scene)

    actions.setDisplayMode(.flat)
    await waitFor { store.displayMode == .flat }
    #expect(store.displayMode == .flat)
  }

  @Test("`?` / ⌘/ raises the help sheet, and it starts down")
  func helpShortcutRaisesTheSheet() {
    let store = makeStore()
    #expect(store.isShortcutHelpPresented == false)
    store.keyboardActions.showShortcutHelp()
    #expect(store.isShortcutHelpPresented == true)
  }

  @Test("Help opens THROUGH each declaration's own run closure — both `?` and ⌘/")
  func helpDeclarationsDispatchThroughTheirOwnRunClosures() {
    // Diff-gate r1 blocker 2: every retained test called `keyboardActions.showShortcutHelp()`
    // directly, so replacing these declarations' `run` closures with no-ops left the suite
    // green — the menu entry the user actually presses was never exercised. This test invokes
    // the DECLARATION, exactly as `AppCommands.entry(_:)`'s Button does.
    for id in ["view.help.question", "view.help.command"] {
      let store = makeStore()
      let declaration = AppCommands.declarations.first { $0.id == id }
      #expect(declaration != nil, "no menu declaration with id \(id)")
      #expect(store.isShortcutHelpPresented == false)
      declaration?.run(store.keyboardActions)
      #expect(store.isShortcutHelpPresented == true, "\(id)'s run closure did not raise the sheet")
    }
  }

  @Test("Each ⌘1…⌘6 declaration sets its OWN step through its own run closure")
  func zoomDeclarationsDispatchThroughTheirOwnRunClosures() {
    let store = makeStore()
    let actions = store.keyboardActions
    let zoom = AppCommands.declarations.filter { $0.shortcut == .zoomStep }
    #expect(zoom.count == GridRowHeight.allCases.count)
    for (step, declaration) in zip(GridRowHeight.allCases, zoom) {
      declaration.run(actions)
      #expect(store.rowHeight == step, "\(declaration.id) did not set \(step)")
    }
  }

  @Test("⌃⌘1 / ⌃⌘2 set the arrangement through their own run closures")
  func groupDeclarationsDispatchThroughTheirOwnRunClosures() async {
    let store = makeStore()
    let actions = store.keyboardActions
    #expect(store.displayMode == .flat)

    let scene = AppCommands.declarations.first { $0.id == "view.group.scene" }
    scene?.run(actions)
    await waitFor { store.displayMode == .scene }
    #expect(store.displayMode == .scene, "the Group: Scene declaration did not switch modes")

    let none = AppCommands.declarations.first { $0.id == "view.group.none" }
    none?.run(actions)
    await waitFor { store.displayMode == .flat }
    #expect(store.displayMode == .flat, "the Group: None declaration did not switch modes")
  }

  /// The two display-mode closures hand off to an async `GridStore.setDisplayMode`, so the
  /// assertion has to outlast the hop. Bounded — a condition that never becomes true fails the
  /// following `#expect` rather than hanging the suite.
  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}
