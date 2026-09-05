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
        // WP14 P4 (IMGMGR-277): the three scene-edit actions, APPENDED — the owner's decided set
        // and its order above are untouched, exactly as P11's row left them.
        "more.mergeScene", "more.splitScene", "more.extractScene",
        // IMGMGR-347: the absorb, APPENDED on the same terms.
        "more.absorbScene",
      ])

    let titles = GridMoreMenu.entries.map { $0.title(store) }
    #expect(
      titles == [
        "Select", "Clear mark", "Copy for Lightroom", "Filename plates", "Picks in groups",
        "Density: 200 pt", "Status", "Open in New Window", "Merge into…", "Split here",
        "Extract selected",
        // IMGMGR-347: the absorb row's title IS its reason while it cannot act, and this store
        // has nothing focused at all — a plain "Add to scene…" here would be the inert control
        // the ticket exists to remove.
        "Add to scene — focus a loose photograph",
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

      case "more.mergeScene":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.mergeScene is not an action entry")
          continue
        }
        await loadSceneEditFixture(store, transport)
        #expect(entry.isEnabled(store), "Merge into… is disabled with a focused scene member")
        #expect(store.isSceneMergePickerPresented == false)
        run(store)
        #expect(store.isSceneMergePickerPresented, "Merge into… raised no target sheet")

      case "more.splitScene":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.splitScene is not an action entry")
          continue
        }
        await loadSceneEditFixture(store, transport)
        #expect(entry.isEnabled(store), "Split here is disabled at a splittable member")
        run(store)
        await waitForEdits(transport, count: 1)
        #expect(await transport.recordedStackEdits.count == 1, "Split here sent nothing")

      case "more.extractScene":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.extractScene is not an action entry")
          continue
        }
        await loadSceneEditFixture(store, transport)
        store.selection.enterSelectExplicitly()
        store.selection.toggle(2)
        #expect(entry.isEnabled(store), "Extract selected is disabled with a member selected")
        run(store)
        await waitForEdits(transport, count: 1)
        #expect(await transport.recordedStackEdits.count == 1, "Extract selected sent nothing")

      case "more.absorbScene":
        guard case .action(let run) = entry.surface else {
          Issue.record("more.absorbScene is not an action entry")
          continue
        }
        await loadLooseAbsorbFixture(store, transport)
        #expect(entry.isEnabled(store), "Add to scene… is disabled with a loose photograph focused")
        #expect(store.isSceneAbsorbPickerPresented == false)
        run(store)
        #expect(store.isSceneAbsorbPickerPresented, "Add to scene… raised no target sheet")

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

    let matches = GridMoreMenu.entries.filter {
      $0.accessibilityIdentifier == "gridMoreMenu.more.absorbScene"
    }
    #expect(matches.count == 1, "the More menu carries no absorb row")
    guard let entry = matches.first else { return }

    #expect(entry.isEnabled(store) == false, "the absorb row is live with nothing focused")
    #expect(
      entry.title(store).localizedCaseInsensitiveContains("loose"),
      "the disabled row does not say what is missing: '\(entry.title(store))'")

    await loadLooseAbsorbFixture(store, transport)
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
    await store.toggleSceneExpanded(5)
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

  /// The twelve ids at `4753450`, in the order the owner decided (WP13 kickoff decision 2, epic
  /// IMGMGR-211 comment 2106; P11, WP14 P4 and IMGMGR-347 APPENDED, never reordered). Grouping is a
  /// CONTIGUOUS partition over exactly this sequence, so a reorder, a drop or a duplicate fails
  /// element-wise here.
  private let shippedOrder = [
    "more.select", "more.clearMark", "more.copyForLightroom", "more.filenamePlates",
    "more.picksInGroups", "more.density", "more.status", "more.openInNewWindow",
    "more.mergeScene", "more.splitScene", "more.extractScene", "more.absorbScene",
  ]

  @Test("`entries` is the sections flattened — one inventory, never a second hand-written list")
  func entriesAreDerivedFromTheSections() {
    #expect(GridMoreMenu.entries.map(\.id) == GridMoreMenu.sections.flatMap(\.entries).map(\.id))
    let counted = GridMoreMenu.sections.reduce(0) { $0 + $1.entries.count }
    #expect(GridMoreMenu.entries.count == counted)
    // Positive control for the equalities above: there really are sections and entries to
    // compare, so neither line can pass on two empty arrays.
    #expect(GridMoreMenu.sections.count == 4)
    #expect(GridMoreMenu.entries.count == 12)
  }

  @Test("Grouping changed nothing about the set: the twelve ids, in the shipped order")
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
        "more.section.marks", "Marks",
        ["more.select", "more.clearMark", "more.copyForLightroom"]
      ),
      (
        "more.section.view", "View",
        ["more.filenamePlates", "more.picksInGroups", "more.density"]
      ),
      ("more.section.shoot", "Shoot", ["more.status", "more.openInNewWindow"]),
      (
        "more.section.scene", "Scene",
        ["more.mergeScene", "more.splitScene", "more.extractScene", "more.absorbScene"]
      ),
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
  /// still answers to the bar's identifier, and it does so from INSIDE the Marks section.
  @Test("The folded Clear row keeps its identity, inside the Marks section")
  func theFoldedClearRowKeepsItsIdentityInsideTheMarksSection() {
    guard let marks = GridMoreMenu.sections.first(where: { $0.id == "more.section.marks" }) else {
      Issue.record("there is no Marks section to fold the bar's Clear into")
      return
    }
    let folded = marks.entries.map {
      GridMoreMenu.accessibilityIdentifier(for: $0, foldsClearIntoMore: true)
    }
    #expect(folded.filter { $0 == ActionBarMarkControl.clear.accessibilityIdentifier }.count == 1)
    // Positive control: the Marks section really was enumerated, so the count above is a fact
    // about the fold and not about an empty section.
    #expect(folded.contains("gridSelectCommand"))
    // And no OTHER section grew a Clear on the way.
    let elsewhere = GridMoreMenu.sections
      .filter { $0.id != "more.section.marks" }
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
        "gridSelectCommand", "gridMoreMenu.more.clearMark", "gridMoreMenu.more.copyForLightroom",
        "gridMoreMenu.more.filenamePlates", "gridMoreMenu.more.picksInGroups",
        "gridMoreMenu.more.density", "gridMoreMenu.more.status",
        "gridMoreMenu.more.openInNewWindow", "gridMoreMenu.more.mergeScene",
        "gridMoreMenu.more.splitScene", "gridMoreMenu.more.extractScene",
        "gridMoreMenu.more.absorbScene",
      ])
    #expect(
      GridMoreMenu.entries.map(\.systemImage) == [
        "checkmark.circle", ActionBarMarkControl.clear.systemImage, "doc.on.clipboard",
        "textformat", "checkmark.square", "square.grid.2x2", "info.circle",
        "macwindow.badge.plus", "arrow.triangle.merge", "scissors", "square.on.square.dashed",
        "rectangle.stack.badge.plus",
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
