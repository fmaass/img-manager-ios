import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P11 (IMGMGR-220): the multi-window scene value, its ONE constructibility predicate, and
/// the routing equality that makes a restored window land in the same grid contract as a queue
/// tap.
@MainActor
@Suite("Multi-window — the scene value, its predicate, and its routing")
struct ShootSceneValueTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  /// The queue's own shape (`QueueCardDestination.route(for:)` returns `(folderId, nil)`), which
  /// is the app's launch surface and its most common navigation. An implementation that defaults
  /// the tier to `.local`, or that force-unwraps it, fails or traps here.
  @Test("A scope with no tier round-trips without inventing one")
  func aScopeWithNoTierRoundTripsWithoutInventingOne() async {
    let source = await makeStore()
    await source.selectShoot(folderID: 7)
    let original = source.query
    #expect(original.folderID == 7)
    #expect(original.sourceTier == nil, "the fixture scope is not the tier-less one it claims")

    let value = ShootSceneValue.from(query: original)
    #expect(value == ShootSceneValue(folderID: 7, sourceTier: nil))

    guard let value else {
      Issue.record("a folder-selected scope produced no scene value")
      return
    }
    let restored = await makeStore()
    await restored.selectShoot(folderID: value.folderID, sourceTier: value.sourceTier)
    #expect(restored.query.sourceTier == nil, "the round trip invented a tier")
    #expect(restored.query == original, "the restored scope is not the scope that was open")

    // Positive control in the same suite: a scope that DOES carry a tier keeps it.
    let archiveSource = await makeStore()
    await archiveSource.selectShoot(folderID: 9, sourceTier: .archive)
    let archiveValue = ShootSceneValue.from(query: archiveSource.query)
    #expect(archiveValue == ShootSceneValue(folderID: 9, sourceTier: .archive))
    let archiveRestored = await makeStore()
    await archiveRestored.selectShoot(
      folderID: 9, sourceTier: archiveValue?.sourceTier)
    #expect(archiveRestored.query.sourceTier == .archive)
    #expect(archiveRestored.query == archiveSource.query)
  }

  /// "The control is enabled" and "the scene value exists" are ONE predicate by construction.
  /// Asserted across both sides — a nil-folder scope and a folder-selected one — so an
  /// implementation that wrote its own `folderID != nil` check beside the function fails the
  /// moment the two can disagree.
  @Test("Constructibility and control enablement are the same predicate")
  func constructibilityAndControlEnablementAreTheSamePredicate() async {
    let empty = await makeStore()
    #expect(empty.query.folderID == nil)
    #expect(ShootSceneValue.from(query: empty.query) == nil)
    #expect(
      GridMoreMenu.openInNewWindow.isEnabled(empty)
        == (ShootSceneValue.from(query: empty.query) != nil))
    #expect(
      GridMoreMenu.openInNewWindow.isEnabled(empty) == false,
      "the control offers itself with no shoot in scope")

    let selected = await makeStore()
    await selected.selectShoot(folderID: 3)
    #expect(ShootSceneValue.from(query: selected.query) != nil)
    #expect(
      GridMoreMenu.openInNewWindow.isEnabled(selected)
        == (ShootSceneValue.from(query: selected.query) != nil))
    #expect(GridMoreMenu.openInNewWindow.isEnabled(selected))
  }

  /// The value is what SwiftUI persists across a scene restore, so it has to survive a real
  /// encode/decode with a `nil` tier still `nil` — not merely compile as `Codable`.
  @Test("The scene value survives the encode/decode SwiftUI puts it through, tier and all")
  func theSceneValueSurvivesACodableRoundTrip() throws {
    for probe in [
      ShootSceneValue(folderID: 4, sourceTier: nil),
      ShootSceneValue(folderID: 4, sourceTier: .local),
      ShootSceneValue(folderID: 4, sourceTier: .archive),
    ] {
      let data = try JSONEncoder().encode(probe)
      let back = try JSONDecoder().decode(ShootSceneValue.self, from: data)
      #expect(back == probe, "the scene value did not survive its own round trip: \(probe)")
      #expect(back.sourceTier == probe.sourceTier)
    }
  }
}

/// The routing half: a restored window and a queue tap must produce the SAME grid scope, because
/// they are the same call. Drives the production forwarding decisions on both sides —
/// `InitialShootApplication.apply` and `QueueCardDestination.route(for:)` — never a
/// re-implementation of either.
@MainActor
@Suite("Multi-window — a restored scene lands where a queue tap lands")
struct SceneValueRoutingTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  private func summary(folderID: Int) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderID, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderID)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!, sourceTier: "archive",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  @Test("A restored ShootSceneValue lands in the same grid scope as a queue tap")
  func aRestoredShootSceneValueLandsInTheSameGridScopeAsAQueueTap() async {
    // The queue path, driven through its own production routing function.
    let queueStore = await makeStore()
    let route = QueueCardDestination.route(for: summary(folderID: 12))
    // The fixture summary's OWN tier is "archive" and the route still carries nil — routing's
    // atomic `(folderId, nil)` is exactly why the scene value's tier has to be optional.
    #expect(route.sourceTier == nil)
    await queueStore.selectShoot(folderID: route.folderID, sourceTier: route.sourceTier)

    // The restored-window path, driven through RootView's own production application.
    let windowStore = await makeStore()
    let applied = await InitialShootApplication.apply(
      ShootSceneValue(folderID: route.folderID, sourceTier: route.sourceTier), to: windowStore)

    #expect(applied == route.folderID, "the window path did not report the shoot it opened")
    #expect(windowStore.query == queueStore.query, "the two paths produced different scopes")

    // The archive case, which is where a dropped tier actually shows: a restored archive window
    // must not silently land on the local tier.
    let archiveWindow = await makeStore()
    await InitialShootApplication.apply(
      ShootSceneValue(folderID: 12, sourceTier: .archive), to: archiveWindow)
    #expect(archiveWindow.query.sourceTier == .archive, "the restored window dropped its tier")

    let archiveTap = await makeStore()
    await archiveTap.selectShoot(folderID: 12, sourceTier: .archive)
    #expect(archiveWindow.query == archiveTap.query)

    // Nothing to apply is not an error, and it selects nothing.
    let untouched = await makeStore()
    let none = await InitialShootApplication.apply(nil, to: untouched)
    #expect(none == nil)
    #expect(untouched.query.folderID == nil)
  }
}

/// WP16 P4 (IMGMGR-297) B8: the two "Open in New Window" entry points share ONE production
/// opening path, and the menu-bar entry is DATA produced by the factory its own view body
/// renders.
///
/// The plan's round-2 finding is what these tests are shaped against: at `4753450` the two
/// entry points did not share a call path (the More row derived the value and called
/// `opener.open` itself; the menu bar called `ShootWindowCommand.run()` on a `@FocusedValue`),
/// so a test that constructed a command by hand proved nothing about the menu-bar wiring. Now
/// BOTH sites route through `ShootWindowAction.open`, and the menu-bar leg drives
/// `AppCommands.makeOpenInNewWindowEntry(command:)` — the same factory the `Commands` body
/// renders — so deleting either call site turns its own assertion RED.
///
/// **Two limits, stated rather than implied.** The menu-bar twin has NO UI leg: the entry
/// deliberately declares no key equivalent (`AppCommands.swift`'s own note), so `typeKey` has
/// nothing to send, and the system menu bar is not a surface XCUITest can open. And with
/// ViewInspector absent from this project, no automated check proves the Button renders
/// `entry.title` and calls `entry.action` — the body is a one-liner by construction, and a
/// Button that bypasses the factory is a diff-gate blocker.
@MainActor
@Suite("Multi-window — one opening path, two entry points (WP16 P4)")
struct ShootWindowEntryTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  /// The acceptance criterion's own words: the More-menu entry AND the menu-bar entry each drive
  /// ONE call on the SAME injected opener with the SAME scene value. One opener, so "the two
  /// entry points agree" is read off a single recording rather than compared across two.
  @Test("Both entry points drive one open each, on one opener, with the same scene value")
  func bothEntryPointsDriveOneOpenEachOnTheSameOpener() async {
    let store = await makeStore()
    await store.selectShoot(folderID: 42, sourceTier: .archive)
    guard let value = ShootSceneValue.from(query: store.query) else {
      Issue.record("a folder-selected scope produced no scene value")
      return
    }

    let opened = OpenedShootWindows()
    let opener = ShootWindowOpener { opened.values.append($0) }

    guard case .sceneWindow(let run) = GridMoreMenu.openInNewWindow.surface else {
      Issue.record("more.openInNewWindow is not a scene-window entry")
      return
    }
    #expect(GridMoreMenu.openInNewWindow.isEnabled(store))
    run(store, opener)
    #expect(
      opened.values == [value], "the More row did not open the scope's own shoot exactly once")

    let entry = AppCommands.makeOpenInNewWindowEntry(
      command: ShootWindowCommand(value: value, opener: opener))
    #expect(entry.title == ShootWindowCopy.title, "the two entry points are spelled differently")
    #expect(entry.isEnabled)
    entry.action()
    #expect(
      opened.values == [value, value],
      "the menu-bar entry opened \(opened.values.count - 1) windows on the second call, not one")
  }

  /// With no workspace scene focused there is no command at all — the `@FocusedValue` is nil.
  /// The factory the body renders must then produce a DISABLED entry whose action opens nothing,
  /// rather than the body deciding that for itself.
  @Test("With no focused command the menu-bar entry is disabled and its action opens nothing")
  func withNoFocusedCommandTheEntryIsDisabledAndOpensNothing() {
    let opened = OpenedShootWindows()
    let absent = AppCommands.makeOpenInNewWindowEntry(command: nil)
    #expect(absent.isEnabled == false)
    #expect(absent.title == ShootWindowCopy.title, "a disabled entry lost its words")
    absent.action()
    #expect(opened.values.isEmpty)

    // Positive control on the SAME spy: over a constructible command the same factory does open.
    let value = ShootSceneValue(folderID: 5, sourceTier: nil)
    let present = AppCommands.makeOpenInNewWindowEntry(
      command: ShootWindowCommand(
        value: value, opener: ShootWindowOpener { opened.values.append($0) }))
    #expect(present.isEnabled)
    present.action()
    #expect(opened.values == [value])
  }

  /// A command with nothing in scope: the entry is disabled AND its action is a no-op, so a
  /// disabled control that somehow fired is harmless rather than a trap — the same rule the More
  /// row has followed since P11, now enforced in one place for both.
  @Test("A command with no shoot in scope is disabled and its action is a no-op")
  func aCommandWithNoShootIsDisabledAndItsActionIsANoOp() {
    let opened = OpenedShootWindows()
    let opener = ShootWindowOpener { opened.values.append($0) }
    let entry = AppCommands.makeOpenInNewWindowEntry(
      command: ShootWindowCommand(value: nil, opener: opener))
    #expect(entry.isEnabled == false)
    entry.action()
    #expect(opened.values.isEmpty, "a disabled entry opened a window")

    // Positive control on the same opener: it really does record when something opens.
    let value = ShootSceneValue(folderID: 8, sourceTier: .local)
    #expect(ShootWindowAction.open(value, using: opener))
    #expect(opened.values == [value])
  }

  /// The ONE guard, tested where it lives: both entry points delegate their nil-check here, so
  /// neither carries a second `folderID != nil` rule that could disagree with the other.
  @Test("The shared opening path is the one guard: nil opens nothing and reports it")
  func theSharedOpeningPathIsTheOneGuard() {
    let opened = OpenedShootWindows()
    let opener = ShootWindowOpener { opened.values.append($0) }
    #expect(ShootWindowAction.open(nil, using: opener) == false)
    #expect(opened.values.isEmpty)

    let value = ShootSceneValue(folderID: 3, sourceTier: .archive)
    #expect(ShootWindowAction.open(value, using: opener))
    #expect(opened.values == [value])
    // Called twice, it opens twice — the guard is the only thing it decides.
    #expect(ShootWindowAction.open(value, using: opener))
    #expect(opened.values == [value, value])
  }
}
