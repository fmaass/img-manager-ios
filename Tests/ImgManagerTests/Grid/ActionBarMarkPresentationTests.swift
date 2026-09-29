import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-474: the grid bar's Pick/Dislike/Clear say what the mark target already carries —
/// the focused photograph in browse, the selection in Select — while a latch keeps its own,
/// different signal (prominent fill + mode-row caption). Pure half first: the whole matrix of
/// focused pick/dislike/none × latched/unlatched × Select uniform/mixed.
@Suite("Action bar mark presentation (IMGMGR-474: the bar shows the target's mark)")
struct ActionBarMarkPresentationTests {
  private func present(
    _ control: ActionBarMarkControl, _ lock: PickLockState.LockState,
    _ readout: MarkTargetReadout
  ) -> ActionBarMarkPresentation {
    ActionBarMarkPresentation.for(control, lockState: lock, readout: readout)
  }

  /// Unlatched — the case the ticket is about.
  private func present(_ control: ActionBarMarkControl, _ readout: MarkTargetReadout)
    -> ActionBarMarkPresentation
  {
    present(control, .idle, readout)
  }

  @Test("The readout collapses states: none, one, repeated one, and mixed")
  func readoutOfStates() {
    #expect(MarkTargetReadout.of([]) == .noTarget)
    #expect(MarkTargetReadout.of([.pick]) == .uniform(.pick))
    #expect(MarkTargetReadout.of([.dislike, .dislike, .dislike]) == .uniform(.dislike))
    #expect(MarkTargetReadout.of([.none]) == .uniform(.none))
    #expect(MarkTargetReadout.of([.pick, .none, .pick]) == .mixed([.pick, .none]))
    #expect(MarkTargetReadout.of([.pick, .dislike, .none]) == .mixed([.pick, .dislike, .none]))
  }

  @Test("No target: nothing is selected, badged, filled or spoken — the bar is as it was")
  func noTargetIsPlain() {
    for control in ActionBarMarkControl.allCases {
      let p = present(control, .noTarget)
      #expect(!p.isSelected)
      #expect(!p.isProminent)
      #expect(!p.showsMixedBadge)
      #expect(p.systemImage == control.systemImage)
      #expect(p.accessibilityValue == "")
      #expect(p.latch.modeRowCaption == nil)
    }
  }

  @Test("Focused photograph PICKED, unlatched: Pick alone is selected, filled, plain-styled")
  func focusedPickUnlatched() {
    let pick = present(.pick, .uniform(.pick))
    #expect(pick.isSelected)
    #expect(pick.indication == .on)
    #expect(pick.systemImage == "hand.thumbsup.fill")
    #expect(pick.accessibilityValue == "Picked")
    // A state readout, NOT a latch: no prominent fill, no mode-row caption.
    #expect(!pick.isProminent)
    #expect(pick.latch.modeRowCaption == nil)

    let dislike = present(.dislike, .uniform(.pick))
    #expect(!dislike.isSelected)
    #expect(dislike.systemImage == "hand.thumbsdown")
    #expect(dislike.accessibilityValue == "Not disliked")

    let clear = present(.clear, .uniform(.pick))
    #expect(!clear.isSelected)
    #expect(clear.systemImage == "xmark.circle")
    #expect(clear.accessibilityValue == "Marked")
  }

  @Test("Focused photograph DISLIKED, unlatched: Dislike alone is selected")
  func focusedDislikeUnlatched() {
    let dislike = present(.dislike, .uniform(.dislike))
    #expect(dislike.isSelected)
    #expect(dislike.systemImage == "hand.thumbsdown.fill")
    #expect(dislike.accessibilityValue == "Disliked")
    #expect(!dislike.isProminent)
    #expect(!present(.pick, .uniform(.dislike)).isSelected)
    #expect(present(.pick, .uniform(.dislike)).accessibilityValue == "Not picked")
    #expect(!present(.clear, .uniform(.dislike)).isSelected)
  }

  @Test("Focused photograph UNMARKED, unlatched: Clear alone is selected")
  func focusedNoneUnlatched() {
    let clear = present(.clear, .uniform(.none))
    #expect(clear.isSelected)
    #expect(clear.systemImage == "xmark.circle.fill")
    #expect(clear.accessibilityValue == "Unmarked")
    #expect(!clear.isProminent)
    #expect(!present(.pick, .uniform(.none)).isSelected)
    #expect(!present(.dislike, .uniform(.none)).isSelected)
  }

  @Test("LATCHED: only the latched control is lit, prominent and captioned; no readout anywhere")
  func latchedWithholdsTheReadout() {
    let readouts: [MarkTargetReadout] = [
      .noTarget, .uniform(.pick), .uniform(.dislike), .uniform(.none), .mixed([.pick, .none]),
    ]
    for verb in LatchVerb.allCases {
      let lock = PickLockState.LockState.latched(verb)
      for readout in readouts {
        for control in ActionBarMarkControl.allCases {
          let p = present(control, lock, readout)
          let isLatched = control.latchVerb == verb
          #expect(p.isSelected == isLatched, "\(control) under \(verb) lock, \(readout)")
          #expect(p.isProminent == isLatched)
          #expect((p.latch.modeRowCaption != nil) == isLatched)
          #expect(p.indication == .off)
          #expect(!p.showsMixedBadge)
          #expect(p.systemImage == control.systemImage)
          #expect(p.accessibilityValue == "")
        }
      }
    }
  }

  /// The DislikeLockScreenshotUITests pin at the data level: the fixture's focused photograph
  /// can be picked, and Pick must STILL read plain while Dislike is the latched control.
  @Test("Dislike latched over a PICKED focused photograph: Pick stays plain")
  func dislikeLatchedOverAPickedPhotograph() {
    let pick = present(.pick, .latched(.dislike), .uniform(.pick))
    #expect(!pick.isSelected)
    #expect(!pick.isProminent)
  }

  @Test("A latch and a readout of the SAME verb are distinguishable by prominence and caption")
  func latchIsNeverMistakenForAReadout() {
    let readout = present(.pick, .uniform(.pick))
    let latched = present(.pick, .latched(.pick), .uniform(.pick))
    #expect(readout.isSelected && latched.isSelected)
    #expect(!readout.isProminent && latched.isProminent)
    #expect(readout.latch.modeRowCaption == nil)
    #expect(latched.latch.modeRowCaption == "Pick Lock — tap photos to apply Pick")
    #expect(readout != latched)
  }

  @Test("Select, uniform selection: that control is selected, as for one focused photograph")
  func selectUniform() {
    // A uniform selection reads exactly like one focused photograph carrying the mark.
    for state in [MarkStateValue.pick, .dislike, .none] {
      for control in ActionBarMarkControl.allCases {
        let p = present(control, .uniform(state))
        #expect(p.isSelected == (control.state == state))
        #expect(!p.showsMixedBadge)
      }
    }
  }

  @Test("Select, mixed selection: every carried mark is badged, none selected — never blank")
  func selectMixed() {
    let readout = MarkTargetReadout.mixed([.pick, .none])
    let pick = present(.pick, readout)
    #expect(pick.indication == .partial)
    #expect(pick.showsMixedBadge)
    #expect(!pick.isSelected)
    #expect(pick.systemImage == "hand.thumbsup")
    #expect(pick.accessibilityValue == "Some picked")

    let clear = present(.clear, readout)
    #expect(clear.showsMixedBadge)
    #expect(clear.accessibilityValue == "Some unmarked")

    let dislike = present(.dislike, readout)
    #expect(dislike.indication == .off)
    #expect(!dislike.showsMixedBadge)
    #expect(dislike.accessibilityValue == "Not disliked")

    // Never blank: whatever the mix, at least two controls carry the badge.
    let mixes: [Set<MarkStateValue>] = [
      [.pick, .dislike], [.pick, .none], [.dislike, .none], [.pick, .dislike, .none],
    ]
    for mix in mixes {
      let badged = ActionBarMarkControl.allCases.filter {
        present($0, .mixed(mix)).showsMixedBadge
      }
      #expect(badged.count == mix.count)
      #expect(badged.count >= 2)
    }
    #expect(
      present(.dislike, .mixed([.pick, .dislike, .none])).accessibilityValue == "Some disliked")
  }

  @Test("The latch half is PickButtonPresentation unchanged; Clear never carries a latch")
  func latchHalfIsTheExistingPresentation() {
    let locks: [PickLockState.LockState] = [.idle, .latched(.pick), .latched(.dislike)]
    for lock in locks {
      for verb in LatchVerb.allCases {
        let control = ActionBarMarkControl.control(for: verb)
        #expect(control.latchVerb == verb)
        #expect(
          present(control, lock, .uniform(.pick)).latch
            == PickButtonPresentation.for(lock, control: verb))
      }
      let clear = present(.clear, lock, .uniform(.none)).latch
      #expect(!clear.isProminent && !clear.accessibilitySelected && clear.modeRowCaption == nil)
    }
    #expect(ActionBarMarkControl.clear.latchVerb == nil)
  }
}

/// The store half: the readout is read from the SAME target the bar writes to, live.
@MainActor
@Suite("GridStore mark-target readout (IMGMGR-474)")
struct GridStoreMarkTargetReadoutTests {
  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0"
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  /// Photograph 1 picked, 2 unmarked, 3 disliked.
  private func loadedStore() async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .pick), makeImage(id: 2), makeImage(id: 3, mark: .dislike),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  @Test("Browse: the readout follows the focused photograph, and is empty without one")
  func browseFollowsFocus() async {
    let (store, _) = await loadedStore()
    store.focusedImageID = nil
    #expect(store.markTargetReadout == .noTarget)
    store.focusedImageID = 1
    #expect(store.markTargetReadout == .uniform(.pick))
    store.focusedImageID = 2
    #expect(store.markTargetReadout == .uniform(.none))
    store.focusedImageID = 3
    #expect(store.markTargetReadout == .uniform(.dislike))
    // A focus naming a row this store no longer holds reads as nothing, like `focusedMarkState`.
    store.focusedImageID = 99
    #expect(store.markTargetReadout == .noTarget)
  }

  @Test("A bar Pick lights Pick while the write is STILL in flight, and after it commits")
  func readoutMovesWithTheOptimisticWrite() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 2
    #expect(store.markTargetReadout == .uniform(.none))
    #expect(
      !ActionBarMarkPresentation.for(.pick, lockState: .idle, readout: store.markTargetReadout)
        .isSelected)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 2, revision: "r1")])))
    await transport.holdMarkStateRequests(true)

    async let done: Void = store.applyMarkToTarget(.pick)
    await transport.waitUntilMarkStateStarted()
    // The network has not answered: this is the optimistic frame.
    #expect(store.markTargetReadout == .uniform(.pick))
    #expect(
      ActionBarMarkPresentation.for(.pick, lockState: .idle, readout: store.markTargetReadout)
        .isSelected)
    await transport.releaseMarkState()
    await done

    #expect(store.markTargetReadout == .uniform(.pick))
    #expect(
      !ActionBarMarkPresentation.for(.clear, lockState: .idle, readout: store.markTargetReadout)
        .isSelected)
  }

  @Test("Select: empty reads nothing, one member reads uniform, two marks read mixed")
  func selectReadsTheSelection() async {
    let (store, _) = await loadedStore()
    store.focusedImageID = 2  // must NOT leak into the Select readout
    store.enterSelectExplicitly()
    #expect(store.markTargetReadout == .noTarget)
    store.selection.toggle(1)
    #expect(store.markTargetReadout == .uniform(.pick))
    store.selection.toggle(3)
    #expect(store.markTargetReadout == .mixed([.pick, .dislike]))
    store.selection.toggle(1)
    #expect(store.markTargetReadout == .uniform(.dislike))
  }
}
