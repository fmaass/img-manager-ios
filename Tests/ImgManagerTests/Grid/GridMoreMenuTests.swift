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
        // WP29 P1 (IMGMGR-452): "more.select" left for the grid's bar (`GridSelectCommand`).
        // WP29 P2 (IMGMGR-453): "more.density" left for the Arrange popover and
        // "more.pruneMirroredArchive" for the tree's View menu, its one home.
        // WP29 P4 (IMGMGR-455): the four scene edits left for the Select bar's Scene ▸.
        // WP29 P3 (IMGMGR-454): the ticket's order — View · Actions · Shoot.
        // IMGMGR-539 (R3-5): Filename plates moved into the Tile overlays submenu.
        "more.tileOverlays", "more.picksInGroups", "more.collapseAllBands",
        "more.clearMark", "more.copyForLightroom", "more.openInNewWindow",
        "more.status",
      ])

    let titles = GridMoreMenu.entries.map { $0.title(store) }
    #expect(
      titles == [
        "Tile overlays", "Picks in groups", "Collapse all", "Clear mark", "Copy for Lightroom",
        "Open in New Window", "Status",
      ])
    // Positive control for the 0-hit check below (LSN-0033): the titles really were read.
    #expect(titles.contains("Copy for Lightroom"))
    // Owner decision 3: downloads stay loupe-Share-only; no grid or bulk download natively.
    #expect(!titles.contains { $0.lowercased().contains("download") })
  }

  /// WP29 P3 (IMGMGR-454) acceptance probe: six rows, exactly three groups, an icon on every row,
  /// no duplicate title, and Hide mirrored archive absent (its one home is the tree's View menu).
  /// IMGMGR-542 (R3-22) added Collapse all to View: seven rows.
  @Test("More: 7 rows in exactly 3 groups, every row an icon, no duplicate title, no prune")
  func moreMenuMeetsTheTicketShape() {
    let (store, _, _, _) = makeStore()
    #expect(GridMoreMenu.sections.count == 3)
    #expect(GridMoreMenu.entries.count == 7)
    #expect(GridMoreMenu.entries.allSatisfy { !$0.systemImage.isEmpty })
    let titles = GridMoreMenu.entries.map { $0.title(store) }
    // Positive control: the titles really were read, so uniqueness is not about an empty list.
    #expect(titles.contains("Clear mark"))
    #expect(Set(titles).count == titles.count)
    #expect(Set(GridMoreMenu.sections.map(\.title)).count == GridMoreMenu.sections.count)
    #expect(!titles.contains(GridMoreMenu.pruneMirroredArchive.title(store)))
    #expect(!GridMoreMenu.entries.contains { $0.id == GridMoreMenu.pruneMirroredArchive.id })
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
    // WP29 P1 (IMGMGR-452): Select is the bar's now — no row answers to its identifier.
    #expect(!unfolded.contains("gridSelectCommand"))
    #expect(!folded.contains("gridSelectCommand"))
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
    // WP29 P1 (IMGMGR-452): TRANSFERRED from the More row to the bar's `GridSelectCommand`.
    let (store, _, _, _) = makeStore()
    #expect(GridSelectCommand.title(store) == "Select")
    store.enterSelectExplicitly()
    #expect(GridSelectCommand.title(store) == "Exit Select")
  }

  @Test("The bar's Select enters Select mode, and pressed again leaves it")
  func barSelectEntersAndLeavesSelectMode() async {
    // WP29 P1 (IMGMGR-452): the observable effect the More row's own closure was held to, now
    // on the bar command that replaced it — plus the exit, which the title promises.
    let (store, transport, _, _) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .pick)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    #expect(store.selection.mode != .select)
    GridSelectCommand.run(store)
    #expect(store.selection.mode == .select, "Select did not enter Select mode")
    GridSelectCommand.run(store)
    #expect(store.selection.mode != .select, "Exit Select did not leave Select mode")
    #expect(GridSelectCommand.accessibilityIdentifier == "gridSelectCommand")
  }

  /// The "no placeholder rows" AC, as a test that fails for a DELETED entry (the switch's
  /// `default` records an issue for any id it does not know) and for a NO-OPED one (each branch
  /// requires an observable effect of invoking the entry's own closure).
  @Test("Every entry does something observable — no placeholder rows")
  func everyEntryDoesSomethingObservable() async {
    // IMGMGR-539: `allEntries`, so the walk reaches the Tile overlays submenu's leaves too — a
    // walk over the top-level `entries` alone would skip all five overlay toggles.
    var overlayLeavesProbed = 0
    for entry in GridMoreMenu.allEntries {
      let (store, transport, pasteboard, _) = makeStore()
      await transport.setListImagesPage(
        .init(items: [makeImage(id: 1, mark: .pick)], limit: 100, nextCursor: nil))
      await store.selectShoot(folderID: 1)
      store.focusedImageID = 1

      switch entry.id {
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
        overlayLeavesProbed += 1

      case "more.tileOverlays":
        guard case .submenu(let children) = entry.surface else {
          Issue.record("more.tileOverlays is not a submenu entry")
          continue
        }
        #expect(
          children.map(\.id) == [
            "more.overlayMarks", "more.overlayEdited", "more.overlayLightroomRating",
            "more.overlaySourceKind", "more.filenamePlates",
          ])

      case "more.overlayMarks", "more.overlayEdited", "more.overlayLightroomRating",
        "more.overlaySourceKind":
        guard case .toggle(let isOn, let set) = entry.surface else {
          Issue.record("\(entry.id) is not a toggle entry")
          continue
        }
        let preference: [String: Bool] = [
          "more.overlayMarks": store.preferences.overlayMarks,
          "more.overlayEdited": store.preferences.overlayEdited,
          "more.overlayLightroomRating": store.preferences.overlayLightroomRating,
          "more.overlaySourceKind": store.preferences.overlaySourceKind,
        ]
        let before = isOn(store)
        #expect(before == preference[entry.id], "\(entry.id) does not read its preference")
        set(store, !before)
        #expect(isOn(store) == !before, "\(entry.id) did not flip")
        let after: [String: Bool] = [
          "more.overlayMarks": store.preferences.overlayMarks,
          "more.overlayEdited": store.preferences.overlayEdited,
          "more.overlayLightroomRating": store.preferences.overlayLightroomRating,
          "more.overlaySourceKind": store.preferences.overlaySourceKind,
        ]
        #expect(after[entry.id] == !before, "\(entry.id) did not reach its preference")
        overlayLeavesProbed += 1

      case "more.picksInGroups":
        guard case .toggle(let isOn, let set) = entry.surface else {
          Issue.record("more.picksInGroups is not a toggle entry")
          continue
        }
        #expect(isOn(store) == false)
        set(store, true)
        #expect(isOn(store), "the picks-in-groups toggle did not turn on")
        #expect(store.preferences.picksInGroups, "the toggle did not reach the preference")

      case "more.collapseAllBands":
        // IMGMGR-542: its closing effect needs an open band, which `PeekBandTests` drives
        // (`collapseAllClosesEveryBand`); here: an action, disabled while no band is open.
        guard case .action = entry.surface else {
          Issue.record("more.collapseAllBands is not an action entry")
          continue
        }
        #expect(entry.isEnabled(store) == false, "Collapse all is enabled with no band open")

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
    #expect(overlayLeavesProbed == 5, "the walk did not reach the five Tile overlays toggles")
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

  /// WP29 P2 (IMGMGR-453): Density and Hide mirrored archive left the More menu. Density's
  /// state is the Arrange popover's thumbnail size (`ArrangeModelTests`); the prune's entry stays
  /// declared, and the tree's View menu renders it (`RootView.folderTreeViewMenuItem`).
  @Test("More carries neither Density nor the prune; the prune entry still reaches its key")
  func moreCarriesNeitherDensityNorThePrune() {
    let ids = GridMoreMenu.entries.map(\.id)
    // Positive control: the entries really were read.
    #expect(ids.contains("more.status"))
    #expect(!ids.contains("more.density"))
    #expect(!ids.contains(GridMoreMenu.pruneMirroredArchive.id))

    let (store, _, _, _) = makeStore()
    guard case .toggle(let isOn, let set) = GridMoreMenu.pruneMirroredArchive.surface else {
      Issue.record("more.pruneMirroredArchive is not a toggle entry")
      return
    }
    // IMGMGR-362: default OFF, and the entry reaches the ONE persisted property the tree reads.
    #expect(isOn(store) == false)
    set(store, true)
    #expect(isOn(store), "the mirrored-archive toggle did not turn on")
    #expect(store.preferences.pruneMirroredArchive, "the toggle did not reach the preference")
    let pruneIdentifier = GridMoreMenu.pruneMirroredArchive.accessibilityIdentifier
    #expect(pruneIdentifier == "gridMoreMenu.more.pruneMirroredArchive")
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

  /// WP29 P4 (IMGMGR-455): the four scene rows moved from More to the Select bar's Scene ▸ with
  /// their probes — each still does something observable, from a selection that AGREES with the
  /// focused subject (`SceneSelectionAgreement`).
  @Test("Every Scene ▸ row does something observable — no placeholder rows")
  func everySceneRowDoesSomethingObservable() async {
    #expect(SelectBarSceneMenu.entries.count == 4)
    for entry in SelectBarSceneMenu.entries {
      let (store, transport, _, _) = makeStore()
      switch entry.id {
      case "selectBar.scene.merge":
        guard case .action(let run) = entry.surface else {
          Issue.record("selectBar.scene.merge is not an action entry")
          continue
        }
        await loadSceneEditFixture(store, transport)
        agreeingSelection([2], store)
        #expect(entry.isEnabled(store), "Merge into… is disabled with a focused scene member")
        #expect(store.isSceneMergePickerPresented == false)
        run(store)
        #expect(store.isSceneMergePickerPresented, "Merge into… raised no target sheet")

      case "selectBar.scene.split":
        guard case .action(let run) = entry.surface else {
          Issue.record("selectBar.scene.split is not an action entry")
          continue
        }
        await loadSceneEditFixture(store, transport)
        agreeingSelection([2], store)
        #expect(entry.isEnabled(store), "Split here is disabled at a splittable member")
        run(store)
        await waitForEdits(transport, count: 1)
        #expect(await transport.recordedStackEdits.count == 1, "Split here sent nothing")

      case "selectBar.scene.extract":
        guard case .action(let run) = entry.surface else {
          Issue.record("selectBar.scene.extract is not an action entry")
          continue
        }
        await loadSceneEditFixture(store, transport)
        agreeingSelection([2], store)
        #expect(entry.isEnabled(store), "Extract selected is disabled with a member selected")
        run(store)
        await waitForEdits(transport, count: 1)
        #expect(await transport.recordedStackEdits.count == 1, "Extract selected sent nothing")

      case "selectBar.scene.absorb":
        guard case .action(let run) = entry.surface else {
          Issue.record("selectBar.scene.absorb is not an action entry")
          continue
        }
        await loadLooseAbsorbFixture(store, transport)
        agreeingSelection([20], store)
        #expect(entry.isEnabled(store), "Add to scene… is disabled with a loose photograph focused")
        #expect(store.isSceneAbsorbPickerPresented == false)
        run(store)
        #expect(store.isSceneAbsorbPickerPresented, "Add to scene… raised no target sheet")

      default:
        Issue.record("Scene ▸ row '\(entry.id)' has no probe here.")
      }
    }
  }

  /// Select mode holding exactly `ids`, the focus untouched.
  private func agreeingSelection(_ ids: [Int], _ store: GridStore) {
    store.selection.enterSelectExplicitly()
    for id in ids { store.selection.toggle(id) }
  }

  /// IMGMGR-347 ACCEPTANCE PROBE, written RED: before the row existed this failed on the first
  /// expectation, which is the owner's device finding stated as a test — the More menu had
  /// nothing that acts on a LOOSE photograph.
  ///
  /// Both states are asserted from the SAME row, because the AC is about the row never being
  /// inert: with nothing focused it is present, disabled, and its own words say what is missing;
  /// with a loose photograph focused in a folder that has a scene, it is offered.
  @Test("The absorb row is offered on a loose photograph and states its reason otherwise")
  func theAbsorbRowIsOfferedOnALoosePhotographAndStatesItsReasonOtherwise() async {
    let (store, transport, _, _) = makeStore()

    // WP29 P4 (IMGMGR-455): TRANSFERRED to the Select bar's Scene ▸, where the row also needs
    // the selection to agree (S == {f}).
    let matches = SelectBarSceneMenu.entries.filter {
      $0.accessibilityIdentifier == "selectBar.scene.absorb"
    }
    #expect(matches.count == 1, "Scene ▸ carries no absorb row")
    guard let entry = matches.first else { return }

    #expect(entry.isEnabled(store) == false, "the absorb row is live with nothing focused")
    #expect(
      entry.title(store).localizedCaseInsensitiveContains("loose"),
      "the disabled row does not say what is missing: '\(entry.title(store))'")

    await loadLooseAbsorbFixture(store, transport)
    agreeingSelection([20], store)
    #expect(entry.isEnabled(store), "the absorb row is dead with a loose photograph focused")
    #expect(entry.title(store) == "Add to scene…")
  }

  /// IMGMGR-347: a Scene window holding one scene and one LOOSE photograph of the same folder,
  /// with the focus on the loose photograph — the state the absorb is offered in.
  private func loadLooseAbsorbFixture(_ store: GridStore, _ transport: GridStubTransport) async {
    let row = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0, hasPick: false,
      kind: .stack,
      matchedCount: 3, memberCount: 3, pickedCount: 0, representative: makeImage(id: 1),
      stackId: 5)
    await transport.setBrowseStacksPage(
      .init(
        items: [
          .init(value1: nil, value2: row),
          .init(value1: .init(image: makeImage(id: 20), kind: .image), value2: nil),
        ], limit: 100))
    await store.setDisplayMode(.scene)
    store.focusedImageID = 20
  }

  /// WP14 P4: a Scene window with one open scene and the focus on its SECOND member — the state
  /// in which all three scene-edit rows have a subject (plan Decision 2). Built on the store the
  /// enclosing loop already made, so each entry's probe still runs against its own store.
  private func loadSceneEditFixture(_ store: GridStore, _ transport: GridStubTransport) async {
    let row = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0, hasPick: false,
      kind: .stack,
      matchedCount: 3, memberCount: 3, pickedCount: 0, representative: makeImage(id: 1),
      stackId: 5)
    let other = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: 1_700_003_600), editedCount: 0, hasPick: false,
      kind: .stack,
      matchedCount: 2, memberCount: 2, pickedCount: 0, representative: makeImage(id: 7), stackId: 6)
    await transport.setBrowseStacksPage(
      .init(
        items: [.init(value1: nil, value2: row), .init(value1: nil, value2: other)], limit: 100))
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3)], limit: 100, stackId: 5),
      forStack: 5)
    await store.setDisplayMode(.scene)
    await store.enterScene(5)
    store.focusedImageID = 2
  }

  private func waitForEdits(_ transport: GridStubTransport, count: Int) async {
    for _ in 0..<200 {
      if await transport.recordedStackEdits.count >= count { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

/// WP16 P4 (IMGMGR-297, p3332 decision 3): the More menu's decided set reads as four labelled
/// groups — "organization only, no new entries". The discipline that makes that impossible to
/// get wrong is that `sections` is the SINGLE inventory and `entries` is DERIVED from it, so
/// there is no second list to drift; these tests read the derived list and the partition that
/// produced it.
@MainActor
@Suite("Grid More menu — the grouped sections (WP16 P4)")
struct GridMoreMenuSectionsTests {

  /// The six ids (WP29 P4 took the Scene group to Scene ▸; WP29 P1 took "more.select" to the
  /// bar; WP29 P2 took "more.density" to the
  /// Arrange popover and "more.pruneMirroredArchive" to the tree's View menu), in the order the
  /// owner decided
  /// (WP13 kickoff decision 2, epic
  /// IMGMGR-211 comment 2106; P11, WP14 P4, IMGMGR-347 and IMGMGR-362 APPENDED — the last of them
  /// into the View section's own run, which moved no existing pair). Grouping is a
  /// CONTIGUOUS partition over exactly this sequence, so a reorder, a drop or a duplicate fails
  /// element-wise here.
  /// WP29 P3 (IMGMGR-454) reordered the same six ids into the ticket's shape.
  private let shippedOrder = [
    // IMGMGR-539 (R3-5): the Tile overlays submenu took Filename plates' place in View.
    "more.tileOverlays", "more.picksInGroups", "more.collapseAllBands",
    "more.clearMark", "more.copyForLightroom", "more.openInNewWindow",
    "more.status",
  ]

  @Test("`entries` is the sections flattened — one inventory, never a second hand-written list")
  func entriesAreDerivedFromTheSections() {
    #expect(GridMoreMenu.entries.map(\.id) == GridMoreMenu.sections.flatMap(\.entries).map(\.id))
    let counted = GridMoreMenu.sections.reduce(0) { $0 + $1.entries.count }
    #expect(GridMoreMenu.entries.count == counted)
    // Positive control for the equalities above: there really are sections and entries to
    // compare, so neither line can pass on two empty arrays.
    // WP29 P4 (IMGMGR-455): three, the Scene group having left for Scene ▸.
    #expect(GridMoreMenu.sections.count == 3)
    // WP29 P1 (IMGMGR-452): 13 → 12, Select having left for the bar. WP29 P2 (IMGMGR-453):
    // 12 → 10, Density and the archive prune having left.
    // WP29 P4 (IMGMGR-455): 10 → 6, the Scene group having left — the ≤ 6 row budget.
    // IMGMGR-542 (R3-22): 6 → 7, Collapse all joining View for the peek bands.
    #expect(GridMoreMenu.entries.count == 7)
    #expect(GridMoreMenu.entries.count <= 7)
  }

  /// WP29 P4 (IMGMGR-455): no scene edit is left in More, and every one is reachable from the
  /// Select bar's Scene ▸ — nothing shipped is dropped.
  @Test("No scene id in More; every scene command is reachable from selectBarSceneMenu")
  func sceneCommandsLiveOnlyInSceneMenu() {
    let moreIDs = GridMoreMenu.entries.map(\.accessibilityIdentifier)
    #expect(!moreIDs.contains { $0.localizedCaseInsensitiveContains("scene") })
    #expect(moreIDs.contains("gridMoreMenu.more.status"))
    #expect(
      SelectBarSceneMenu.entries.map(\.accessibilityIdentifier) == [
        "selectBar.scene.merge", "selectBar.scene.split", "selectBar.scene.extract",
        "selectBar.scene.absorb",
      ])
    #expect(
      SelectBarSceneMenu.entries.map(\.systemImage) == [
        "arrow.triangle.merge", "scissors", "square.on.square.dashed",
        "rectangle.stack.badge.plus",
      ])
    #expect(SelectBarSceneMenu.accessibilityIdentifier == "selectBarSceneMenu")
    #expect(SelectBarSceneMenu.entries.count <= 6)
  }

  @Test("Grouping changed nothing about the set: the six ids, in the shipped order")
  func groupingKeptTheDecidedSetAndItsOrder() {
    #expect(GridMoreMenu.sections.flatMap(\.entries).map(\.id) == shippedOrder)
    #expect(GridMoreMenu.entries.map(\.id) == shippedOrder)
    // No entry appears in two sections, and none was dropped on the way in.
    #expect(Set(shippedOrder).count == shippedOrder.count)
    #expect(Set(GridMoreMenu.entries.map(\.id)).count == GridMoreMenu.entries.count)
  }

  @Test("Each section carries its decided label and its own contiguous run of the shipped order")
  func eachSectionCarriesItsDecidedLabelAndRun() {
    let decided: [(id: String, title: String, entries: [String])] = [
      (
        "more.section.view", "View",
        // WP29 P2 (IMGMGR-453): Density and the archive prune left this run.
        // IMGMGR-539 (R3-5): Filename plates sits inside Tile overlays now.
        ["more.tileOverlays", "more.picksInGroups", "more.collapseAllBands"]
      ),
      (
        // WP29 P3 (IMGMGR-454): was "more.section.marks" / "Marks"; Clear mark stays (folded,
        // it is the bar's only Clear) and Open in New Window joins it.
        "more.section.actions", "Actions",
        ["more.clearMark", "more.copyForLightroom", "more.openInNewWindow"]
      ),
      ("more.section.shoot", "Shoot", ["more.status"]),
      // WP29 P4 (IMGMGR-455): the Scene group left for the Select bar's Scene ▸.
    ]
    // Closures rather than key paths on the right: Swift has no key path to a tuple element.
    #expect(GridMoreMenu.sections.map(\.id) == decided.map { $0.id })
    #expect(GridMoreMenu.sections.map(\.title) == decided.map { $0.title })
    #expect(GridMoreMenu.sections.map { $0.entries.map(\.id) } == decided.map { $0.entries })
    // A `Section` with no words is grouping WITHOUT labels — the phase's declared deviation, not
    // something that may ship silently. Ids stay unique because they are the `ForEach` identity.
    #expect(GridMoreMenu.sections.allSatisfy { !$0.title.isEmpty })
    #expect(GridMoreMenu.sections.allSatisfy { !$0.entries.isEmpty })
    #expect(Set(GridMoreMenu.sections.map(\.id)).count == GridMoreMenu.sections.count)
  }

  /// The Clear-folds-into-More rule (WP13 P1) is untouched by the grouping: folded, the Clear row
  /// still answers to the bar's identifier, and it does so from INSIDE the Actions section
  /// (the Marks section until WP29 P3, IMGMGR-454).
  @Test("The folded Clear row keeps its identity, inside the Actions section")
  func theFoldedClearRowKeepsItsIdentityInsideTheActionsSection() {
    guard let marks = GridMoreMenu.sections.first(where: { $0.id == "more.section.actions" })
    else {
      Issue.record("there is no Actions section to fold the bar's Clear into")
      return
    }
    let folded = marks.entries.map {
      GridMoreMenu.accessibilityIdentifier(for: $0, foldsClearIntoMore: true)
    }
    #expect(folded.filter { $0 == ActionBarMarkControl.clear.accessibilityIdentifier }.count == 1)
    // Positive control: the Actions section really was enumerated, so the count above is a fact
    // about the fold and not about an empty section.
    #expect(folded.contains("gridMoreMenu.more.copyForLightroom"))
    // And no OTHER section grew a Clear on the way.
    let elsewhere = GridMoreMenu.sections
      .filter { $0.id != "more.section.actions" }
      .flatMap(\.entries)
      .map { GridMoreMenu.accessibilityIdentifier(for: $0, foldsClearIntoMore: true) }
    #expect(!elsewhere.contains(ActionBarMarkControl.clear.accessibilityIdentifier))
    #expect(elsewhere.contains("gridMoreMenu.more.status"))
  }

  /// Organisation only: no identifier moved, so every UI test that resolves a row by identifier
  /// keeps resolving it.
  @Test("No entry's accessibility identifier changed when the sections arrived")
  func noEntryIdentifierChangedWhenTheSectionsArrived() {
    #expect(
      GridMoreMenu.entries.map(\.accessibilityIdentifier) == [
        // WP29 P2 (IMGMGR-453): Density and the archive prune left; the prune keeps its
        // identifier in the tree's View menu. WP29 P3 (IMGMGR-454): reordered, none renamed.
        // IMGMGR-539 (R3-5): Filename plates keeps its identifier inside the Tile overlays
        // submenu (`allEntries`); the submenu row is the new top-level identifier.
        "gridMoreMenu.more.tileOverlays", "gridMoreMenu.more.picksInGroups",
        "gridMoreMenu.more.collapseAllBands",
        "gridMoreMenu.more.clearMark", "gridMoreMenu.more.copyForLightroom",
        "gridMoreMenu.more.openInNewWindow",
        "gridMoreMenu.more.status",
      ])
    #expect(
      GridMoreMenu.entries.map(\.systemImage) == [
        "rectangle.on.rectangle", "checkmark.square", "rectangle.compress.vertical",
        ActionBarMarkControl.clear.systemImage, "doc.on.clipboard", "macwindow.badge.plus",
        "info.circle",
      ])
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
    // WP13 P8 (IMGMGR-214) added the second key this type owns, IMGMGR-261 the third,
    // IMGMGR-362 the fourth and IMGMGR-539 (R3-5) the four Tile overlays keys, fifth to eighth;
    // the inventory is asserted exactly, so a ninth arriving silently is a failure here rather
    // than a surprise later. The literals are spelled out rather than read back off the constants
    // they name — a test that asks a constant to describe itself could not tell a rename from a
    // rewrite, and these strings are what a reader's device already has on disk.
    let owned = [
      GridPreferences.filenamePlatesKey, GridPreferences.autoAdvanceOnMarkKey,
      GridPreferences.picksInGroupsKey, GridPreferences.pruneMirroredArchiveKey,
      GridPreferences.overlayMarksKey, GridPreferences.overlayEditedKey,
      GridPreferences.overlayLightroomRatingKey, GridPreferences.overlaySourceKindKey,
    ]
    #expect(GridPreferences.persistedKeys == owned)
    #expect(GridPreferences.filenamePlatesKey == "grid.filenamePlates")
    #expect(GridPreferences.autoAdvanceOnMarkKey == "loupe.autoAdvanceOnMark")
    #expect(GridPreferences.picksInGroupsKey == "grid.picksInGroups")
    #expect(GridPreferences.pruneMirroredArchiveKey == "grid.pruneMirroredArchive")
    #expect(GridPreferences.overlayMarksKey == "grid.overlay.marks")
    #expect(GridPreferences.overlayEditedKey == "grid.overlay.edited")
    #expect(GridPreferences.overlayLightroomRatingKey == "grid.overlay.lightroomRating")
    #expect(GridPreferences.overlaySourceKindKey == "grid.overlay.sourceKind")
  }

  /// IMGMGR-362 (WP21 P3): the archive prune is OFF until the reader asks for it (owner decision,
  /// design note /link/3396 §6 Q6), and the flip survives — the same guard-typed read and the
  /// same suite-injected `UserDefaults` the three keys before it use, never a second mechanism.
  @Test("The archive prune is OFF by default and persists once flipped")
  func theArchivePruneIsOffByDefaultAndPersists() {
    #expect(GridPreferences.pruneMirroredArchiveDefault == false)

    let defaults = makeEphemeralDefaults()
    let first = GridPreferences(defaults: defaults)
    #expect(first.pruneMirroredArchive == false)
    first.pruneMirroredArchive = true
    #expect(GridPreferences(defaults: defaults).pruneMirroredArchive == true)

    // Guard-typed, like every other key: a value of the wrong TYPE reads as "no preference" and
    // takes the declared default rather than silently becoming a real `false`.
    let poisoned = makeEphemeralDefaults()
    poisoned.set("definitely", forKey: GridPreferences.pruneMirroredArchiveKey)
    #expect(GridPreferences(defaults: poisoned).pruneMirroredArchive == false)
    // Positive control for the line above: this suite CAN observe a stored value here.
    poisoned.set(true, forKey: GridPreferences.pruneMirroredArchiveKey)
    #expect(GridPreferences(defaults: poisoned).pruneMirroredArchive == true)
  }

}

/// A reference box for the spy: `ShootWindowOpener.open` is an escaping `@Sendable` closure, so it
/// cannot capture a local `var` array.
@MainActor
final class OpenedShootWindows {
  var values: [ShootSceneValue] = []
}
