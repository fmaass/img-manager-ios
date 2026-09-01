import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P5a (IMGMGR-221): the More menu's decided set, and the two entries the plan singles out
/// as the ones a wrong implementation would leave inert — Filename plates and Density.
///
/// The menu body renders `GridMoreMenu.entries` and holds no second list, so these tests read
/// the SAME rows the menu renders and invoke each row's OWN closure. A deleted entry fails the
/// inventory test; an entry whose closure does nothing fails `everyEntryDoesSomethingObservable`.
@MainActor
@Suite("Grid More menu — the decided set (WP13 P5a)")
struct GridViewMoreMenuTests {

  private func makeImage(
    id: Int, filename: String = "img.jpg",
    mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0"
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: filename, folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: revision, state: mark),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() -> (GridStore, GridStubTransport, SpyMarksPasteboard, UserDefaults) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let pasteboard = SpyMarksPasteboard()
    let defaults = makeEphemeralDefaults()
    let store = GridStore(
      service: GridService(client: client), preferences: GridPreferences(defaults: defaults),
      pasteboard: pasteboard)
    return (store, transport, pasteboard, defaults)
  }

  @Test("The menu is EXACTLY the owner's decided set, in order, and carries no Download entry")
  func theMoreMenuShowsExactlyTheDecidedSet() {
    let (store, _, _, _) = makeStore()
    #expect(
      GridMoreMenu.entries.map(\.id) == [
        "more.select", "more.clearMark", "more.copyForLightroom", "more.filenamePlates",
        "more.picksInGroups", "more.density", "more.status", "more.openInNewWindow",
      ])

    let titles = GridMoreMenu.entries.map { $0.title(store) }
    #expect(
      titles == [
        "Select", "Clear mark", "Copy for Lightroom", "Filename plates", "Picks in groups",
        "Density: 200 pt", "Status", "Open in New Window",
      ])
    // Positive control for the 0-hit check below (LSN-0033): the titles really were read.
    #expect(titles.contains("Copy for Lightroom"))
    // Owner decision 3: downloads stay loupe-Share-only; no grid or bulk download natively.
    #expect(!titles.contains { $0.lowercased().contains("download") })
  }

  /// The P1 merge contract (IMGMGR-212 x IMGMGR-221): the decided set always renders SIX rows,
  /// and the fold changes the Clear ROW'S IDENTITY rather than adding a second Clear beside it.
  /// Folded, that row is the bar's Clear control and answers to `gridClearButton`; unfolded, the
  /// bar owns that identifier and the menu shows none of it.
  @Test("Folded, the More menu has exactly one Clear; unfolded, none — never two")
  func theFoldMovesClearsIdentityAndNeverAddsASecondClear() {
    let folded = GridMoreMenu.entries.map {
      GridMoreMenu.accessibilityIdentifier(for: $0, foldsClearIntoMore: true)
    }
    let unfolded = GridMoreMenu.entries.map {
      GridMoreMenu.accessibilityIdentifier(for: $0, foldsClearIntoMore: false)
    }
    let barClear = ActionBarMarkControl.clear.accessibilityIdentifier
    #expect(folded.filter { $0 == barClear }.count == 1, "folded: \(folded)")
    #expect(unfolded.filter { $0 == barClear }.count == 0, "unfolded: \(unfolded)")
    // Positive control for the 0-hit line above: the unfolded menu really was enumerated.
    #expect(unfolded.contains("gridMoreMenu.more.clearMark"))
    // The SET of rows never changes with the fold — only that one identifier does.
    #expect(folded.count == unfolded.count && folded.count == GridMoreMenu.entries.count)
    #expect(zip(folded, unfolded).filter { $0 != $1 }.count == 1)
    // P1's own identifier for Select survives the merge, so its menu tests keep resolving it.
    #expect(unfolded.contains("gridSelectCommand"))
  }

  /// One Clear row, whatever the fold: the decided set has exactly one, and it is the same row
  /// the bar hands over.
  @Test("There is exactly one Clear row, and it uses P1's state and disabled rule")
  func exactlyOneClearRowWiredToP1sTableAndRule() async {
    let clears = GridMoreMenu.entries.filter { $0.id == "more.clearMark" }
    #expect(clears.count == 1)
    #expect(GridMoreMenu.clearMark.systemImage == ActionBarMarkControl.clear.systemImage)
    #expect(ActionBarMarkControl.clear.state == MarkStateValue.none)

    let (store, transport, _, _) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .pick)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = nil
    // P1's rule, read off the store rather than re-derived here.
    #expect(store.isMarkActionUnavailable)
    #expect(GridMoreMenu.clearMark.isEnabled(store) == false)
    store.focusedImageID = 1
    #expect(store.isMarkActionUnavailable == false)
    #expect(GridMoreMenu.clearMark.isEnabled(store))
  }

  @Test("Select's title states the way OUT while Select is on, not a second 'Select'")
  func selectEntryNamesTheExit() {
    let (store, _, _, _) = makeStore()
    #expect(GridMoreMenu.select.title(store) == "Select")
    store.enterSelectExplicitly()
    #expect(GridMoreMenu.select.title(store) == "Exit Select")
  }

  /// The "no placeholder rows" AC, as a test that fails for a DELETED entry (the switch's
  /// `default` records an issue for any id it does not know) and for a NO-OPED one (each branch
  /// requires an observable effect of invoking the entry's own closure).
  @Test("Every entry does something observable — no placeholder rows")
  func everyEntryDoesSomethingObservable() async {
    for entry in GridMoreMenu.entries {
      let (store, transport, pasteboard, _) = makeStore()
      await transport.setListImagesPage(
        .init(items: [makeImage(id: 1, mark: .pick)], limit: 100, nextCursor: nil))
      await store.selectShoot(folderID: 1)
      store.focusedImageID = 1

      switch entry.id {
      case "more.select":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.select is not an action entry")
          continue
        }
        #expect(store.selection.mode != .select)
        run(store)
        #expect(store.selection.mode == .select, "Select did not enter Select mode")

      case "more.clearMark":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.clearMark is not an action entry")
          continue
        }
        await transport.setMarkStateOutcome(
          .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
        #expect(entry.isEnabled(store), "Clear mark is disabled with a focused photograph")
        run(store)
        // Compared by RAW VALUE on purpose: `mark.state` is itself optional, so a bare
        // `== .none` would read as "the field is absent" (Optional.none) rather than "the wire
        // value is `none`" — the same trap `GridStore`'s own decoder comments call out.
        await waitFor { store.images.first?.mark.state?.rawValue == "none" }
        #expect(
          store.images.first?.mark.state?.rawValue == "none", "Clear mark left the pick in place")

      case "more.copyForLightroom":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.copyForLightroom is not an action entry")
          continue
        }
        await transport.setMarksExport(
          .init(count: 2, state: ["pick"], stems: ["_AR50001", "_AR50002"], truncated: false))
        run(store)
        await waitFor { !pasteboard.writes.isEmpty }
        #expect(pasteboard.writes == ["_AR50001\n_AR50002"], "nothing reached the pasteboard")
        #expect(store.marksCopyMessage != nil, "the copy said nothing about what it did")

      case "more.filenamePlates":
        guard case .toggle(let isOn, let set) = entry.surface else {
          Issue.record("more.filenamePlates is not a toggle entry")
          continue
        }
        #expect(isOn(store) == false)
        set(store, true)
        #expect(isOn(store), "the plates toggle did not turn on")
        #expect(store.preferences.filenamePlates, "the toggle did not reach the preference")

      case "more.picksInGroups":
        guard case .toggle(let isOn, let set) = entry.surface else {
          Issue.record("more.picksInGroups is not a toggle entry")
          continue
        }
        #expect(isOn(store) == false)
        set(store, true)
        #expect(isOn(store), "the picks-in-groups toggle did not turn on")
        #expect(store.preferences.picksInGroups, "the toggle did not reach the preference")

      case "more.density":
        guard case .rowHeightSteps(let set, let isCurrent) = entry.surface else {
          Issue.record("more.density is not a row-height entry")
          continue
        }
        set(store, .step400)
        #expect(store.rowHeight == .step400, "the Density entry did not move the row height")
        #expect(isCurrent(store, .step400))

      case "more.status":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.status is not an action entry")
          continue
        }
        #expect(store.isStatusPresented == false)
        run(store)
        #expect(store.isStatusPresented, "the Status entry did not raise the sheet")

      case "more.openInNewWindow":
        guard case .sceneWindow(let run) = entry.surface else {
          Issue.record("more.openInNewWindow is not a scene-window entry")
          continue
        }
        // WP13 P11: observable through the injected opener, which is the whole point of
        // injecting it — a no-op row leaves this empty.
        let opened = OpenedShootWindows()
        run(store, ShootWindowOpener { opened.values.append($0) })
        #expect(!opened.values.isEmpty, "the Open in New Window entry opened nothing")

      default:
        // ONE literal, not two concatenated: `Issue.record` takes a `Comment`, and `+` on a
        // Comment is not a string append (gate p5a-red2, GridMoreMenuTests.swift:148).
        Issue.record(
          "More-menu entry '\(entry.id)' has no probe here — a new entry needs one, or it is a placeholder row nothing proves."
        )
      }
    }
  }

  /// The plan's named test. The plate's text IS `ImageSummary.filename`, verbatim, and never
  /// carries a path separator — `ImageSummary` has no path field at all, and nothing here
  /// synthesises one. The rendered half (the plate actually on a tile, on both idioms) is
  /// `GridMoreMenuUITests.testFilenamePlatesToggleOnAndOff`.
  @Test("Filename plates put the FILENAME on every tile, and never a path separator")
  func filenamePlateTogglePutsTheFilenameOnEveryTileAndNeverAPathSeparator() {
    let (store, _, _, _) = makeStore()
    let images = [
      makeImage(id: 1, filename: "_AR50001.ARW"),
      makeImage(id: 2, filename: "DSC_0042.jpg"),
      makeImage(id: 3, filename: "2026-08-30 family walk.heic"),
    ]

    for image in images {
      #expect(
        TileView.plateText(for: image, showsPlate: false) == nil,
        "a plate rendered with the toggle OFF")
      let plate = TileView.plateText(for: image, showsPlate: true)
      // Positive control: the filename string itself is asserted PRESENT, so the two
      // separator checks below cannot pass vacuously on an empty render.
      #expect(plate == image.filename, "the plate is not the filename")
      #expect(plate?.contains("/") == false, "the plate carries a path separator")
      #expect(plate?.contains("\\") == false, "the plate carries a path separator")
    }

    guard case .toggle(let isOn, let set) = GridMoreMenu.filenamePlates.surface else {
      Issue.record("Filename plates is not a toggle entry")
      return
    }
    #expect(isOn(store) == false)
    set(store, true)
    #expect(isOn(store), "the menu toggle did not turn the plates on")
  }

  /// The plan's named test. Density is the SAME six-step row height the Zoom control and
  /// ⌘1…⌘6 move — one state, two entry points — and it brought no second persisted property
  /// with it.
  @Test("The Density entry mutates the same row-height state the Zoom control mutates")
  func theDensityEntryMutatesTheSameRowHeightStateTheZoomControlMutates() {
    let (store, _, _, _) = makeStore()
    guard case .rowHeightSteps(let set, let isCurrent) = GridMoreMenu.density.surface else {
      Issue.record("Density is not a row-height entry")
      return
    }
    #expect(store.rowHeight == .step200)

    set(store, .step400)
    #expect(store.rowHeight == .step400)
    #expect(isCurrent(store, .step400))
    // The other entry point onto the SAME state — the Zoom control's own call target.
    #expect(GridZoomControl.title(for: store.rowHeight) == "Zoom: 400 pt")
    #expect(GridMoreMenu.density.title(store) == "Density: 400 pt")

    store.setRowHeight(.step120)
    #expect(store.rowHeight == .step120)
    #expect(isCurrent(store, .step120))
    #expect(isCurrent(store, .step400) == false)

    // No SECOND persisted density property: the row-height steps are the one density state.
    // Positive control first, so the 0-hit assertion below proves something (LSN-0033).
    #expect(GridPreferences.persistedKeys.contains(GridPreferences.filenamePlatesKey))
    #expect(
      GridPreferences.persistedKeys.allSatisfy { !$0.lowercased().contains("density") },
      "a second persisted density key exists: \(GridPreferences.persistedKeys)")
  }

  /// The Clear entry is a SECOND ENTRY POINT into the store's one clear action, never a second
  /// implementation of the target rule: it dispatches into `GridStore.handleClearShortcut`,
  /// which is where WP13 P1 (IMGMGR-212) widens the target from the focused photograph to
  /// `markTargetImageIDs`. This test pins the dispatch, not a copy of the rule.
  @Test("Clear mark writes `none` through the store's one clear action")
  func clearMarkEntryDispatchesIntoTheStoresOneClearAction() async {
    let (store, transport, _, _) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .pick)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    guard case .action(let run) = GridMoreMenu.clearMark.surface else {
      Issue.record("Clear mark is not an action entry")
      return
    }
    run(store)
    await waitFor { store.images.first?.mark.revision == "r1" }

    let sent = await transport.lastMarkStateRequest
    // By raw value, never `== .none` — see the comment in `everyEntryDoesSomethingObservable`.
    // `MarkStateRequest.state` is NON-optional in the generated client (unlike `MarkView.state`),
    // so there is exactly one `?` here: the optional request itself.
    #expect(sent?.state.rawValue == "none", "Clear mark did not submit the `none` state")
    #expect(sent?.imageIds == [1])
  }

  @Test("With nothing targeted, Clear mark is disabled rather than a silent no-op")
  func clearMarkIsDisabledWithNothingTargeted() async {
    let (store, transport, _, _) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = nil
    #expect(GridMoreMenu.clearMark.isEnabled(store) == false)
    // Positive control: with a focus it IS enabled, so the assertion above is about emptiness.
    store.focusedImageID = 1
    #expect(GridMoreMenu.clearMark.isEnabled(store))
  }

  /// WP13 P11 (IMGMGR-220): the enabled control is not a no-op, and it fires with the CURRENT
  /// scope's own scene value rather than a rebuilt or defaulted one.
  ///
  /// What no unit test can prove is that the system then actually opens a window — that is the
  /// two-shoots-side-by-side device evidence, a named acceptance leg at the TestFlight
  /// checkpoint, and it is not claimed here.
  @Test("The enabled Open in New Window control fires with the current scene value")
  func theEnabledOpenInNewWindowControlFiresWithTheCurrentSceneValue() async {
    let (store, transport, _, _) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 42, sourceTier: .archive)

    let entry = GridMoreMenu.openInNewWindow
    #expect(entry.isEnabled(store), "the control is disabled with a shoot in scope")
    guard case .sceneWindow(let run) = entry.surface else {
      Issue.record("more.openInNewWindow is not a scene-window entry")
      return
    }

    let opened = OpenedShootWindows()
    run(store, ShootWindowOpener { opened.values.append($0) })

    #expect(opened.values.count == 1, "the control fired \(opened.values.count) times, not once")
    #expect(opened.values.first == ShootSceneValue.from(query: store.query))
    #expect(opened.values.first == ShootSceneValue(folderID: 42, sourceTier: .archive))
  }

  /// The control ships in every case — the probe decided only whether `project.yml` needed the
  /// capability key, never whether the affordance exists — so with nothing in scope it is
  /// PRESENT and DISABLED rather than absent.
  @Test("Open in New Window is present and disabled with no shoot selected")
  func openInNewWindowIsPresentAndDisabledWithNoShootSelected() async {
    let (store, _, _, _) = makeStore()
    #expect(store.query.folderID == nil)

    let present = GridMoreMenu.entries.filter { $0.id == "more.openInNewWindow" }
    #expect(present.count == 1, "the More menu does not carry Open in New Window")
    #expect(GridMoreMenu.openInNewWindow.isEnabled(store) == false)

    // A disabled control that still fired would be worse than an absent one.
    guard case .sceneWindow(let run) = GridMoreMenu.openInNewWindow.surface else {
      Issue.record("more.openInNewWindow is not a scene-window entry")
      return
    }
    let opened = OpenedShootWindows()
    run(store, ShootWindowOpener { opened.values.append($0) })
    #expect(opened.values.isEmpty, "the control opened a window with no shoot in scope")
  }

  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

/// WP13 P5a (IMGMGR-221): the app's first persisted preference store.
@MainActor
@Suite("GridPreferences — the first persisted preference (WP13 P5a)")
struct GridPreferencesTests {

  /// The plan's named test. `UserDefaults.bool(forKey:)` COERCES — it would answer `false` for
  /// the string below and there would be no way to tell that from a real stored `false`. The
  /// guard-typed read answers the DECLARED DEFAULT instead, which is why the two assertions use
  /// opposite defaults: only a guard-typed read can satisfy both.
  @Test("An unparseable stored value falls back to the default")
  func anUnparseableStoredValueFallsBackToTheDefault() {
    #expect(GridPreferences.boolPreference(from: "definitely", default: true) == true)
    #expect(GridPreferences.boolPreference(from: "definitely", default: false) == false)
    #expect(GridPreferences.boolPreference(from: nil, default: true) == true)
    // Positive control: a real stored boolean still WINS over the default, so the fallbacks
    // above are not simply "always return the default".
    #expect(GridPreferences.boolPreference(from: true, default: false) == true)
    #expect(GridPreferences.boolPreference(from: false, default: true) == false)

    let defaults = makeEphemeralDefaults()
    defaults.set("definitely", forKey: GridPreferences.filenamePlatesKey)
    #expect(
      GridPreferences(defaults: defaults).filenamePlates == GridPreferences.filenamePlatesDefault)
  }

  @Test("A flipped preference survives a new store over the same suite")
  func aFlippedPreferenceIsPersisted() {
    let defaults = makeEphemeralDefaults()
    let first = GridPreferences(defaults: defaults)
    #expect(first.filenamePlates == false)
    first.filenamePlates = true
    #expect(GridPreferences(defaults: defaults).filenamePlates == true)
  }

  @Test("The store owns exactly the keys it declares")
  func theStoreOwnsExactlyTheKeysItDeclares() {
    // WP13 P8 (IMGMGR-214) added the second key this type owns and IMGMGR-261 the third; the
    // inventory is asserted exactly, so a fourth arriving silently is a failure here rather than
    // a surprise later.
    let owned = [
      GridPreferences.filenamePlatesKey, GridPreferences.autoAdvanceOnMarkKey,
      GridPreferences.picksInGroupsKey,
    ]
    #expect(GridPreferences.persistedKeys == owned)
    #expect(GridPreferences.filenamePlatesKey == "grid.filenamePlates")
    #expect(GridPreferences.autoAdvanceOnMarkKey == "loupe.autoAdvanceOnMark")
    #expect(GridPreferences.picksInGroupsKey == "grid.picksInGroups")
  }

}

/// A reference box for the spy: `ShootWindowOpener.open` is an escaping `@Sendable` closure, so it
/// cannot capture a local `var` array.
@MainActor
final class OpenedShootWindows {
  var values: [ShootSceneValue] = []
}
