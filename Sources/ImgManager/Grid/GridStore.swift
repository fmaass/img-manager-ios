import Foundation
import ImgManagerAPI

/// Select mode's own copy, pinned as data beside `PickLockCopy` (its Pick-Lock twin) so a test
/// asserts the exact strings without touching SwiftUI.
///
/// The COUNT is stated at every N, zero included — "0 selected", never an instructional caption
/// that hides it. The empty Select is exactly the state a reader has to be able to see, because
/// it is the state where every selection-consuming control refuses to write (WP13 P1 / the
/// shipped defect IMGMGR-223); the instruction is a second, subordinate line rather than a
/// replacement for the number.
enum SelectCopy {
  static func caption(selectedCount: Int) -> String { "\(selectedCount) selected" }
  static let emptyHint = "Tap photos to choose"
}

/// Grid-relative navigation. `.left`/`.right` move one image in the currently-loaded flat
/// order; `.up`/`.down` move by `columnsPerRow` — a value the VIEW sets from its own measured
/// layout (this store never guesses a column count).
enum GridArrowDirection: Sendable, Equatable { case up, down, left, right }

/// The one screen-owned mutable error surface this store exposes — never a raw transport
/// string (opaque by construction: `GridServiceError` itself carries none, and this property
/// stores that enum verbatim).
typealias GridMutationError = GridServiceError

/// What a refused write was trying to DO — the two mutation kinds the recovery machine serves.
/// `applyConflictAgain` branches on this to resubmit the right operation.
enum ConflictIntent: Sendable, Equatable {
  case setState(MarkStateValue)
  case addTag(String)
}

/// One submitted image id's precondition revision — the "affected batch" a conflict recovery
/// re-reads and diffs against. Deliberately just id+revision (not a full `PriorMarkSnapshot`):
/// a tag conflict has no `state` to speak of, and the diff never needs one either.
struct ConflictBatchEntry: Sendable, Equatable {
  var imageID: Int
  var revisionSubmitted: String
}

/// A conflict recovery's OWN normalized copy of one image's markview at re-read time (diff-gate
/// round 2, B6) — carried in `ConflictRecovery.identified` so `applyConflictAgain` can build its
/// resubmission from THIS, never from `images` (which may no longer contain an id the active
/// filter excluded). Not `Components.Schemas.MarkView` itself only because that type's `tags` is
/// optional and its `state` is the wire payload type — normalized the same way
/// `PriorMarkSnapshot`/`PriorTagSnapshot` already are.
struct FreshMarkSnapshot: Sendable, Equatable {
  var state: MarkStateValue
  var tags: [String]
  var revision: String
}

/// P6 (IMGMGR-116): the adjudicated 409 recovery state — non-modal by construction (plan item
/// 3, "no alerts, no auto-opening popovers, no modality anywhere in this flow"). Nil except
/// while one rejected batch's recovery is live; `handleConflict` creates it, `applyConflictAgain`/
/// `dismissConflictRecovery` end it, `retryConflictRefresh` re-attempts the read from
/// `.readFailed`. The 409 body itself is never decoded (backend does not type it, IMGMGR-177) —
/// every case here is derived purely from a sanctioned re-read (`performAuthoritativeRefresh`,
/// falling back to a per-id `service.detail(imageID:)` for an id the re-read's own filtered query
/// no longer contains) diffed against the revision the REJECTED request's precondition submitted.
enum ConflictRecovery: Sendable, Equatable {
  /// The re-read is in flight; nothing to show yet beyond "something was refused".
  case reading(intent: ConflictIntent, batch: [ConflictBatchEntry])
  /// The re-read succeeded: `changedIDs` is the subset whose re-read revision differs from the
  /// precondition the rejected request submitted (or, if the diff found nothing — "a revision
  /// raced back" — the WHOLE submitted batch, per plan item 3's named fallback). `freshMarkViews`
  /// (B6) is what `applyConflictAgain` resubmits from — never `images` directly.
  case identified(
    intent: ConflictIntent, freshMarkViews: [Int: FreshMarkSnapshot], changedIDs: Set<Int>)
  /// The re-read itself failed (network/unreachable) — "Couldn't refresh" + Retry Refresh; Apply
  /// Again is unavailable from this state (no fresh revision exists yet to resubmit with).
  case readFailed(intent: ConflictIntent, batch: [ConflictBatchEntry])
}

/// P4's orchestrator: owns the loaded page of images, the shoot/filter/tier "query generation",
/// focus, Pick Lock, Select, and Undo, and is the ONE place that turns a pinned interaction into
/// a network call. Every leaf type it composes (`SelectionState`, `PickLockState`, `UndoStack`)
/// stays independently simple and independently tested; this type's own tests prove the
/// CROSS-CUTTING invariants those leaves deliberately do not know about (Pick Lock ⟷ Select
/// mutual exclusion, reset-on-query-generation-change, 409 rollback, undo truth).
@Observable
@MainActor
final class GridStore {
  private let service: GridService

  private(set) var images: [Components.Schemas.ImageSummary] = []
  private(set) var nextCursor: String?
  /// IMGMGR-541 (R3-21): grouped by Mark or Rating, the photographs in the server's null bucket
  /// (no mark / no rating). They NEVER enter `images`: every stream page is cut at the boundary
  /// by `ingestStreamPage`, so no stream gesture, count or heading can reach one. The slice is the
  /// drilled remainder's own, in the server's order, paged only by `remainderCursor`.
  private(set) var remainderImages: [Components.Schemas.ImageSummary] = []
  /// The remainder's OWN continuation, exactly as the server issued it with the page that crossed
  /// into the null bucket (and with every remainder page since). Never derived from a tile.
  private(set) var remainderCursor: String?
  /// The stream has reached the null bucket: it is exhausted (the server orders that bucket LAST
  /// for both keys and both directions), and the remainder row may be drawn.
  private(set) var remainderReached = false
  private(set) var isLoadingPage = false
  private(set) var lastMutationError: GridMutationError?
  private(set) var lastPageLoadError: GridMutationError?

  /// WP14 (IMGMGR-204, IMGMGR-250): photographs a write was SUBMITTED for while they were
  /// genuinely writable, and which had stopped being writable by the time that write — queued
  /// behind something else on the mutation lane — actually ran.
  ///
  /// The mutation lane serialises writes, so a write can wait; `capturePriorTagSnapshots` /
  /// `capturePriorSnapshots` then filter against the LIVE actionable pool, so an authoritative
  /// refresh that lands in that window can prune an id out from under a write already submitted
  /// for it. Nothing downstream could tell: the write simply went out for fewer ids.
  ///
  /// This is NOT the pre-existing "an id that was never loaded is silently skipped" rule (the
  /// loaded-only membership boundary `applyMark`'s own doc comment states). Only ids this store
  /// could have written when the person asked for the write, and then lost before it ran, ever
  /// land here — which is exactly the race, and nothing else.
  private(set) var droppedWriteIDs: Set<Int> = []

  /// The notice's own dismissal — the reader has seen which photographs were not written.
  func dismissDroppedWriteNotice() { droppedWriteIDs = [] }

  /// WP8 P7 (coexistence adjudication 7c): increments on every COMMITTED mark/undo/tag mutation
  /// — never on a rollback/conflict/refusal (each success branch below sets this alongside its
  /// own `lastMutationError = nil`). The ONE signal `RootView` watches (`.onChange`) to invalidate
  /// the queue's own summary cache — GridStore itself carries no reference to `QueueStore` and
  /// no knowledge that a queue even exists (P6 coexistence: "no second mutation lane; queue
  /// reads stay read-only and separate"). `applyConflictAgain`'s resubmission increments this
  /// too, for free — it resubmits through this SAME `applyMark`/`addTag`, hitting the same
  /// success branch, not a separate code path.
  private(set) var mutationCommitCount = 0

  private(set) var query = GridImagesQuery()
  private(set) var rowHeight: GridRowHeight = .step200
  /// IMGMGR-551 (R3-7): Arrange › Layout. Presentation only and NOT persisted, like `rowHeight`.
  private(set) var layoutStyle: GridLayoutStyle = .justified
  /// Set by the view after every justified-packing pass (`JustifiedRowLayout.pack`) — the
  /// packed rows of display ids, in the SAME order the grid renders them. A justified grid's
  /// column count varies per row (unlike a uniform `LazyVGrid`), so Up/Down navigation below
  /// looks up the focused tile's actual row/column position rather than dividing by a single
  /// constant. WP12: typed ids, so a row that contains a scene card is navigable THROUGH rather
  /// than into — arrow keys land on photographs, which are the only focusable things.
  var rows: [[GridDisplayID]] = []

  // MARK: - Scene mode (WP12: stacks as display rows)

  /// Flat browse or Scene browse. Not a filter and not a query field: the two modes call
  /// different endpoints, serve different row vocabularies and mint mutually unusable cursors.
  private(set) var displayMode: GridDisplayMode = .flat

  /// The rows `GET /api/browse/stacks` served, in ITS order. A SEPARATE slice from `images`,
  /// deliberately: `images` stays EMPTY while Scene mode is on, so a collapsed card's
  /// `representative.id` — display-only, and impossible to keep off the wire — has no way into
  /// the array the flat paths read.
  private(set) var sceneRows: [SceneBrowseRow] = []
  /// Scene browse's OWN cursor. Never `nextCursor`: the two endpoints fingerprint their cursors
  /// differently and each refuses the other's with a 400 (`cursor_scope_mismatch`).
  private(set) var sceneNextCursor: String?
  /// WP442 P12 (IMGMGR-540): the ONE scene the reader has entered (pushed). The only writer is
  /// `transitionScene(to:reason:)`; everything that used to read an "expanded" set derives from it.
  /// IMGMGR-541: the ONE entered destination — a scene or the Mark/Rating remainder. The only
  /// writer is `transitionScene(to:reason:)`.
  private(set) var entry: GridEntry?
  var sceneEntry: SceneEntry? {
    guard case .scene(let scene) = entry else { return nil }
    return scene
  }
  var enteredSceneID: Int? { sceneEntry?.stackID }
  /// The remainder key while the reader is inside the drilled remainder.
  var enteredRemainder: GroupByKey? {
    guard case .remainder(let key) = entry else { return nil }
    return key
  }
  var isInRemainder: Bool { enteredRemainder != nil }
  /// The entered destination as the Compact stack's route — a pure projection, never stored.
  var enteredRoute: WorkspaceRoute? {
    switch entry {
    case .scene(let scene): return .scene(scene.stackID)
    case .remainder(let key): return .group(key: key.rawValue, value: GroupRemainder.routeValue)
    case nil: return nil
    }
  }
  /// Computed, never stored: the edit subject, the paging fences and the filmstrip read it, so
  /// none of them can name a scene the display has left.
  var sceneExpanded: Set<Int> { enteredSceneID.map { [$0] } ?? [] }
  /// IMGMGR-542 (R3-22): the open peek bands, in the order they were opened (last = most
  /// recent). Stream state: entering or leaving a scene never touches it; a window rebuild
  /// (`clearSceneWindow`) closes them all.
  private(set) var peekBands: [PeekBand] = []
  var openBandIDs: [Int] { peekBands.map(\.stackID) }
  /// Membership on screen somewhere: the entered scene plus every open band. The filmstrip scope
  /// and the membership paging/landing fences read this; the scene-EDIT subject keeps reading
  /// `sceneExpanded` (no Split/Extract from inside a band).
  var openMembershipIDs: Set<Int> {
    Set(openBandIDs).union(enteredSceneID.map { [$0] } ?? [])
  }
  /// Bumped on every band open and every scene entry; a membership page lands only while the
  /// token it was requested under is still current, so a closed-then-reopened band's OLD page is
  /// dropped.
  @ObservationIgnored private var membershipToken: [Int: Int] = [:]
  /// Bands whose membership read failed; the chevron offers Retry.
  private(set) var bandLoadFailed: Set<Int> = []
  /// Bumped by every band close; `GridView` restores `bandCloseAnchor` when it moves.
  private(set) var bandCloseRevision = 0
  @ObservationIgnored private(set) var bandCloseAnchor: GridDisplayID?
  /// The scope the reader is looking at: the stream, or the entered scene.
  var activeScope: GridScope {
    switch entry {
    case .scene(let scene): return .scene(scene.stackID)
    case .remainder(let key): return .remainder(key)
    case nil: return .stream
    }
  }
  /// Bumped by every real transition; a topology completion navigates only while it still
  /// matches the revision its edit started at.
  @ObservationIgnored private(set) var sceneRevision = 0
  /// Entered scenes whose membership (or stack-row lookup) failed; the screen offers Retry.
  private(set) var sceneLoadFailed: Set<Int> = []
  /// A topology destination that could not be told yet (a candidate read failed).
  private(set) var sceneDestinationRetry: SceneDestinationRetry?
  /// The entered scene's own scroll slot; cleared by every transition, so a scene opens at the top.
  @ObservationIgnored var sceneScrollAnchor: GridDisplayID?
  /// Each opened scene's members, as `GET /api/stacks/{id}/members` served them: capture-ordered,
  /// tombstones included, and UNFILTERED — the card's `matched_count` is the filtered question.
  private(set) var sceneMembers: [Int: [Components.Schemas.ImageSummary]] = [:]
  /// How to ask for the rest of a long scene, per opened scene. Absent = never opened.
  private(set) var sceneMemberCursors: [Int: SceneMemberCursor] = [:]
  /// Single-flight: which scenes have a membership request in flight right now. A second tap on
  /// an opening card, or a second "load more" while one page is still on the wire, is dropped
  /// rather than duplicating the page into the strip.
  private(set) var sceneMembersInFlight: Set<Int> = []
  /// IMGMGR-261: the picks a COLLAPSED scene holds, for DISPLAY only.
  ///
  /// A SEPARATE array from `sceneMembers` on purpose, and the separation is the whole safety
  /// argument. `sceneMembers` is what expansion writes into, and everything in it becomes an
  /// ordinary, markable, selectable, focusable photograph through `actionableImages`. What this
  /// holds must not: these are members of a scene nobody opened, drawn inside the card, and a
  /// gesture must be no more able to reach them than it was before the toggle existed. Putting
  /// them in a different array is what makes that true by construction rather than by a filter
  /// somebody has to remember.
  private(set) var sceneInlinePicks: [Int: [Components.Schemas.ImageSummary]] = [:]
  /// Single-flight per scene, exactly like `sceneMembersInFlight` — several cards appearing at
  /// once must not each start the same read.
  private var sceneInlinePicksInFlight: Set<Int> = []

  /// The grid's row sequence in Scene mode: cards and loose photographs in the server's order,
  /// each opened scene followed by the members loaded for it.
  var sceneDisplayRows: [SceneDisplayRow] {
    SceneRowBuilder.displayRows(rows: sceneRows)
  }

  /// IMGMGR-542: the open bands as the packer takes them — in insertion order, only bands whose
  /// card is still listed and whose membership has loaded (a derived prune: no path can render an
  /// orphan band).
  var peekBandRows: [SceneBand] {
    guard displayMode == .scene else { return [] }
    let listed = Set(
      sceneRows.compactMap { row -> Int? in
        guard case .stack(let stack) = row else { return nil }
        return stack.stackId
      })
    return peekBands.compactMap { band in
      guard listed.contains(band.stackID), let members = sceneMembers[band.stackID],
        !members.isEmpty
      else { return nil }
      return SceneBand(
        stackID: band.stackID, rows: SceneRowBuilder.enteredSceneRows(members: members))
    }
  }

  /// THE definition of what one grid instance renders. `.stream` keeps the Flat/Scene branch the
  /// view used to hold; `.scene(id)` is the entered scene's members.
  func displayRows(for scope: GridScope) -> [SceneDisplayRow] {
    switch scope {
    case .stream:
      switch displayMode {
      case .flat: return images.map(SceneDisplayRow.image)
      case .scene: return SceneRowBuilder.bandedDisplayRows(rows: sceneRows, bands: peekBandRows)
      }
    case .scene(let id):
      return SceneRowBuilder.enteredSceneRows(members: sceneMembers[id] ?? [])
    case .remainder:
      return remainderImages.map(SceneDisplayRow.image)
    }
  }

  /// The scene screen's state for an entered id.
  func sceneScreenState(for stackID: Int) -> SceneScreenState {
    SceneScreenState.resolve(
      hasMembers: !(sceneMembers[stackID] ?? []).isEmpty,
      isInFlight: sceneMembersInFlight.contains(stackID),
      hasFailed: sceneLoadFailed.contains(stackID))
  }

  /// "Scene · N photos" from the card's `member_count`, falling back to the loaded count.
  func sceneTitle(for stackID: Int) -> String {
    let card = sceneRows.lazy.compactMap { row -> Int? in
      guard case .stack(let stack) = row, stack.stackId == stackID else { return nil }
      return stack.memberCount
    }.first
    return SceneScreenTitle.title(memberCount: card ?? sceneMembers[stackID]?.count ?? 0)
  }

  /// Which OPEN scene this photograph belongs to, as its band in display order — `nil` for a
  /// loose photograph, for a member of a scene nobody has open, and for every photograph in flat
  /// browse, where the question does not arise.
  ///
  /// IMGMGR-406: the loupe's filmstrip asks this to scope itself to the scene being culled. It is
  /// a READ of the state the band is already rendered from (`sceneExpanded`/`sceneMembers`), so
  /// the strip and the band can never name different photographs, and it never reaches the
  /// network — a scene whose membership has not been fetched simply answers `nil`.
  func openSceneMembers(containing imageID: Int) -> [Components.Schemas.ImageSummary]? {
    guard displayMode == .scene else { return nil }
    return SceneRowBuilder.openSceneMembers(
      containing: imageID, expanded: openMembershipIDs, members: sceneMembers)
  }

  /// THE list of "photographs on screen" — the single projection every mark, tag, undo, focus,
  /// arrow-navigation and loupe path in this type reads instead of `images` directly.
  ///
  /// In flat mode it IS `images`, so every shipped behaviour is unchanged. In Scene mode it is
  /// the display sequence's photographs: loose rows and the members of EXPANDED scenes, never a
  /// collapsed card's cover. Deriving it once, here, is what makes "a card is not a write target"
  /// and "an expanded member IS one" the same fact rather than two rules a dozen call sites each
  /// have to remember. The loupe's filmstrip walks this list in FLAT browse; in Scene mode
  /// IMGMGR-406 narrows the strip to one open scene's band (`openSceneMembers(containing:)`
  /// above), while every mark, focus and navigation path here keeps reading this projection.
  var actionableImages: [Components.Schemas.ImageSummary] {
    switch displayMode {
    // IMGMGR-541: inside the drilled remainder the photographs on screen are the remainder's.
    case .flat: return isInRemainder ? remainderImages : images
    case .scene: return SceneRowBuilder.actionableImages(displayRows(for: activeScope))
    }
  }

  var focusedImageID: Int?
  /// `T`/the action bar's Tag control opens tag entry for the focused image (browse mode) or
  /// the current selection (Select mode); the actual write happens on submit, via `addTag`.
  var isTagEntryPresented = false
  /// WP13 P4 (IMGMGR-215): the shortcut help sheet, opened from the menu-bar View menu, from
  /// `?` and from ⌘/. It lives here — beside `isTagEntryPresented`, the same shape — because
  /// `AppCommands` is a scene-level `Commands` builder with no view state of its own and
  /// reaches the workspace only through this store's `GridKeyboardActions`; `RootView` hosts
  /// the sheet itself.
  var isShortcutHelpPresented = false

  // MARK: - More menu surfaces (WP13 P5a, IMGMGR-221)

  /// The read-only Status sheet (`StatusSheet`). Beside `isTagEntryPresented` and
  /// `isShortcutHelpPresented`, the same shape, for the same reason: the menu entry that raises
  /// it is declared as data (`GridMoreMenu`) and reaches this screen only through the store.
  var isStatusPresented = false
  /// IMGMGR-545: the Sync sheet, raised from More › Shoot.
  var isSyncPresented = false
  private(set) var statusSnapshot: Components.Schemas.StatusResponse?
  /// The status READ failed — distinct from "not loaded yet", which is `statusSnapshot == nil`
  /// with this false. Nothing on the sheet retries anything but the read itself.
  private(set) var statusReadFailed = false

  /// What the last "Copy for Lightroom" did, in the reader's words — including the scope the
  /// endpoint can actually back ("whole library") and any truncation. Nil = nothing to say.
  private(set) var marksCopyMessage: String?
  /// Single-flight: a second tap while the export is on the wire is refused rather than racing
  /// two writes onto the pasteboard.
  private(set) var isCopyingMarksForLightroom = false

  /// This app's first persisted scalar preferences (`GridPreferences`) — today the filename
  /// plates, P8's auto-advance next. Injected so every test runs in its OWN `UserDefaults`
  /// suite instead of the simulator's shared standard one.
  let preferences: GridPreferences
  private let pasteboard: any MarksPasteboard
  /// IMGMGR-548: Settings › Culling › "Start with Tap to Pick" (`culling.tapToPickDefault`), read
  /// when a shoot opens. A closure, not the preferences object, so the default is a constant
  /// `false` that no test inherits from the simulator's standard suite; `RootView` hands in the
  /// live `SettingsPreferences`.
  private let startsWithTapToPick: @MainActor () -> Bool

  let selection = SelectionState()
  let pickLock = PickLockState()
  let undo = UndoStack()
  /// IMGMGR-382: the loupe's session-only look (`LookModel`). One per store, so it survives
  /// frame-to-frame navigation and closing and reopening the loupe, and ends with the app.
  let looks: LookModel

  // MARK: - Loupe (P5)

  /// Whether the loupe is the active surface at all. Compact always presents it full-screen;
  /// Regular-2/3 present it DOCKED in the content column — see `RootView` for that split.
  ///
  /// The Regular-2/3 "go full-screen" flag that used to sit beside this one is GONE with the
  /// header control that was its only way in (IMGMGR-348, owner device pass 2026-09-02): a mode
  /// nothing can reach is not a mode, and leaving the flag would have left `RootView` branching
  /// on a value that could never change.
  private(set) var isLoupeOpen = false
  /// Flips true once a forward-neighbour fetch at the loaded tail returned zero new images —
  /// i.e., confirmed nothing more to advance to. Reset on every scope change (`reloadFirstPage`)
  /// so a NEW shoot/filter always starts un-exhausted.
  private(set) var loupeExhausted = false

  /// Which loupe SESSION is current — one per `openLoupe`, monotonic, never reused. The
  /// distinction matters because "a loupe is open" and "the loupe that asked for this is still
  /// open" are different questions, and only the second one licenses a completion to move the
  /// frame: closing and reopening on the same image (a tile tap on the frame the grid still has
  /// focused — the ordinary way back in) satisfies the first while the reader has plainly not
  /// asked the new session to advance anywhere. Incremented unconditionally, including on an
  /// `openLoupe` over an already-open loupe, because that is a new act of opening either way.
  private var loupeSession = 0

  func openLoupe(on imageID: Int) {
    loupeSession += 1
    focusedImageID = imageID
    // Pin (`SelectionState.swift`'s own `SelectionResetTrigger.enteredLoupe` doc comment,
    // written ahead of P5 for exactly this call site): entering the loupe resets selection.
    // A latched lock (either verb) is deliberately left UNTOUCHED — `PickLockState.exit()`'s
    // own doc comment pins it "Grid-only, never the loupe" — and structurally a latched tap
    // never reaches here anyway (`tapTile`'s `latchedVerb` branch returns before this switch).
    selection.reset(.enteredLoupe)
    // WP30 P3: a new loupe session never inherits a Compare the previous one left open.
    compareState = nil
    isLoupeOpen = true
  }

  func closeLoupe() {
    compareState = nil
    isLoupeOpen = false
  }

  // MARK: - Triage (WP31 P1, IMGMGR-460)

  /// Whether the Compact Triage cover is up — a flag beside `isShortcutHelpPresented`, the same
  /// shape, because the control that raises it rides the grid's bar while `RootView` hosts the
  /// cover. Triage never touches `isLoupeOpen`: the two covers are separate surfaces, and
  /// `openTriage()` refuses while the loupe is open.
  var isTriagePresented: Bool { triageCover != nil }

  /// IMGMGR-501 review r2: the cover's ITEM — set while Triage is presented, carrying the gate
  /// generation its request was given, so the content names its own presentation.
  private(set) var triageCover: TriagePresentation?

  /// Triage needs a photograph to start on — disabled while the scope is empty.
  var canOpenTriage: Bool { !actionableImages.isEmpty }

  /// WP31 P2 review round 2: the presented surfaces a Handoff route waits on. Triage's cover is
  /// registered HERE, where its presentation is requested, so a route arriving before the
  /// cover's content appears still waits for it (`RootView` settles it from the cover).
  let presentationGate = PresentationDismissalGate()

  /// IMGMGR-501: whether the current width hosts Triage's cover — Compact only. `RootView`
  /// keeps it in step with its `layoutMode` (`applyWidth`); true at first, like that mode's
  /// initial `.compact`. A Triage request at Regular would present no cover, so its gate
  /// registration would never appear and the next Handoff route would wait out the whole
  /// grace for nothing: `openTriage()` refuses there instead.
  var hostsTriageCover = true

  /// The layout → host mapping `RootView.applyWidth` applies, and the one the cover's binding
  /// reads — one answer for both, so the request and the presentation cannot disagree.
  static func triageCoverIsHosted(in mode: LayoutMode) -> Bool { mode == .compact }

  func openTriage() {
    guard canOpenTriage, !isLoupeOpen, hostsTriageCover else { return }
    triageCover = TriagePresentation(generation: presentationGate.requested(.triageCover))
  }

  func closeTriage() {
    triageCover = nil
  }

  /// Dedicated flat previous/next (fold advisory: "don't overload row-relative `moveFocus`") —
  /// the loupe's own notion of "next", over the SAME flat load order the grid's paging already
  /// maintains, never a filmstrip-local page.
  func loupeNext() async {
    guard let current = focusedImageID else { return }
    if case .next(let id) = loadedSuccessor(after: current) {
      focusedImageID = id
      return
    }
    // WP31 P1 (IMGMGR-460): the tail is the shared `successor(after:pagesScenes:)`, asked with
    // `pagesScenes: false` — exactly the loupe's behaviour before the extraction. In flat mode
    // the neighbours fetch moves the loupe's focus itself, under its own session fence; in Scene
    // mode nothing is asked of the network.
    _ = await successor(after: current, pagesScenes: false)
  }

  /// The photograph after `imageID` in the loaded actionable pool, without paging.
  func loadedSuccessor(after imageID: Int) -> LoadedSuccessor {
    let pool = actionableImages
    guard let idx = pool.firstIndex(where: { $0.id == imageID }) else { return .absent }
    return pool.indices.contains(idx + 1) ? .next(pool[idx + 1].id) : .tail
  }

  /// WP31 P1 (IMGMGR-460), plan decision 1: the photograph after `imageID`, paging at the loaded
  /// tail with the active mode's own pager — extracted from `loupeNext`'s tail so the loupe and
  /// Triage share it. It never moves focus itself (the flat neighbours fetch still advances an
  /// open loupe under its own session fence, as it always has).
  ///
  /// - Flat: the forward-neighbour fetch (Triage's call through `SuccessorResolver.resolveFlat`,
  ///   which first waits out an outstanding grid page). WP12: a FLAT-browse mechanism — it asks
  ///   `/api/images/{id}/neighbours` "what follows this in the current filter's order", a
  ///   question Scene mode's row stream (cards and members, one stored anchor) does not have an
  ///   answer to, and the merge target it feeds (`images`) is deliberately empty there.
  /// - Scene with `pagesScenes: false` (the loupe): bounded by what the grid has loaded — the
  ///   fold's "one paging path" rule kept, the loupe consumes no cursor of its own.
  /// - Scene with `pagesScenes: true` (Triage): Scene's own display-row pager
  ///   (`loadMoreScenesIfNeeded`), through `SuccessorResolver` — never the flat-only
  ///   `loadMoreIfNeeded`, which returns at once in Scene mode.
  func successor(after imageID: Int, pagesScenes: Bool) async -> SuccessorLookup {
    let position = loadedSuccessor(after: imageID)
    if case .next(let id) = position { return .found(id) }
    switch displayMode {
    case .flat:
      // WP31 P1 review (B2): Triage's flat path waits out an outstanding grid page before it
      // trusts a tail answer; the loupe's path below is exactly what it was.
      if pagesScenes {
        return await SuccessorResolver.resolveFlat(after: imageID, in: FlatPager(store: self))
      }
      let generation = loadGeneration
      let fetched = await fetchAndMergeNeighbours(after: imageID)
      guard generation == loadGeneration else { return .unresolved }
      switch loadedSuccessor(after: imageID) {
      case .next(let id): return .found(id)
      case .tail: return fetched == .exhausted ? .exhausted : .unresolved
      case .absent: return .unresolved
      }
    case .scene:
      guard pagesScenes, position == .tail else { return .unresolved }
      return await SuccessorResolver.resolve(after: imageID, in: ScenePager(store: self))
    }
  }

  /// Flat mode's pager as `SuccessorResolver.resolveFlat` reads it — the grid's own page-load
  /// flag and the loupe's forward-neighbour fetch.
  @MainActor
  private final class FlatPager: NeighbourPager {
    let store: GridStore

    init(store: GridStore) {
      self.store = store
    }

    func loadedSuccessor(after imageID: Int) -> LoadedSuccessor {
      store.loadedSuccessor(after: imageID)
    }

    var isPageLoadInFlight: Bool { store.isLoadingPage }
    var pagerGeneration: Int { store.loadGeneration }

    func fetchNeighbours(after imageID: Int) async -> NeighbourAnswer {
      switch await store.fetchAndMergeNeighbours(after: imageID) {
      case .merged: return .merged
      case .exhausted: return .exhausted
      case .failed, .stale: return .failed
      }
    }
  }

  /// Scene mode's pager as `SuccessorResolver` reads it — the store's own state and its own
  /// `loadMoreScenesIfNeeded`, asked with the last display row so the tail check always passes.
  ///
  /// WP31 P2 (IMGMGR-461): also the Scene pager a Handoff continuation pages with
  /// (`ContinuationPager`) — the same four primitives, asked whether a photograph is loaded.
  @MainActor
  private final class ScenePager: SuccessorPager, ContinuationPager {
    let store: GridStore

    init(store: GridStore) {
      self.store = store
    }

    func loadedSuccessor(after imageID: Int) -> LoadedSuccessor {
      store.loadedSuccessor(after: imageID)
    }

    var pagerCursor: String? { store.sceneNextCursor }
    var isPageLoadInFlight: Bool { store.isLoadingPage }
    var pagerGeneration: Int { store.loadGeneration }

    func requestNextPage() async {
      guard let last = store.sceneDisplayRows.last?.id else { return }
      await store.loadMoreScenesIfNeeded(currentRowID: last)
    }

    func holds(_ imageID: Int) -> Bool {
      store.actionableImages.contains { $0.id == imageID }
    }
  }

  // MARK: - Handoff continuation (WP31 P2, IMGMGR-461)

  /// Plan decision 6: brings `imageID` into the loaded actionable pool with the grid's OWN
  /// mode-aware paging — flat browse's cursor pager (`loadMoreIfNeeded`), Scene mode's display-row
  /// pager (`loadMoreScenesIfNeeded`) — bounded by `pageBudget` consumed pages. It never moves
  /// focus and never opens anything; the receiving route opens the loupe only on `.found`.
  func locateForContinuation(
    imageID: Int, pageBudget: Int = ContinuationLocator.defaultPageBudget
  ) async -> ContinuationLookup {
    switch displayMode {
    case .flat:
      return await ContinuationLocator.locate(
        imageID: imageID, in: FlatGridPager(store: self), pageBudget: pageBudget)
    case .scene:
      return await ContinuationLocator.locate(
        imageID: imageID, in: ScenePager(store: self), pageBudget: pageBudget)
    }
  }

  /// Flat browse's grid pager as `ContinuationLocator` reads it: the grid's own cursor paging,
  /// asked with the loaded tail so `loadMoreIfNeeded`'s tail check always passes.
  @MainActor
  private final class FlatGridPager: ContinuationPager {
    let store: GridStore

    init(store: GridStore) {
      self.store = store
    }

    func holds(_ imageID: Int) -> Bool {
      store.actionableImages.contains { $0.id == imageID }
    }

    var pagerCursor: String? { store.nextCursor }
    var isPageLoadInFlight: Bool { store.isLoadingPage }
    var pagerGeneration: Int { store.loadGeneration }

    func requestNextPage() async {
      guard let last = store.images.last?.id else { return }
      await store.loadMoreIfNeeded(currentItemID: last)
    }
  }

  /// Previous is PURELY the retained-prefix local walk (fold-verified premise: GridStore
  /// retains a prefix of every loaded page through the paging frontier) — never a network call,
  /// disabled at index 0.
  func loupePrevious() {
    let pool = actionableImages
    guard let current = focusedImageID,
      let idx = pool.firstIndex(where: { $0.id == current }), idx > 0
    else { return }
    focusedImageID = pool[idx - 1].id
  }

  /// A filmstrip thumbnail tap: the image is already loaded (it is IN `images`, or the
  /// filmstrip could not be rendering it), so this is a direct focus move, never a network call.
  func loupeFocus(on imageID: Int) {
    focusedImageID = imageID
  }

  // MARK: - Compare 2-up (WP30 P3, IMGMGR-458)

  /// The Compare state machine's current value (`CompareSession`, pure). Read through
  /// `compareSession`, which is the only form that answers "is Compare open".
  private var compareState: CompareSession?
  /// The `loadGeneration` Compare opened under. Plan decision 6: ANY generation change while
  /// Compare is open ends it — the scope it was comparing is gone — so a moved generation makes
  /// `compareSession` answer nil and the host shows the loupe again, with nothing to reset.
  private var compareGeneration = 0

  /// The open Compare session, or nil: nil while the loupe is closed, and nil once the
  /// generation has moved since Compare opened.
  var compareSession: CompareSession? {
    guard isLoupeOpen, compareGeneration == loadGeneration else { return nil }
    return compareState
  }

  /// Decision 7's switch: while true, `RootView` publishes no keyboard actions at all.
  var isCompareOpen: Bool { compareSession != nil }

  /// Plan decision 2: Compare's candidates are the loupe's filmstrip scope, and it is offered
  /// only when that scope holds the focused photograph and at least one other.
  var canOpenCompare: Bool {
    guard isLoupeOpen, let focused = focusedImageID else { return false }
    return CompareSession(scope: FilmstripScope.resolve(for: self), focused: focused) != nil
  }

  /// Opens Compare on the focused photograph (left) and the next scope image (right).
  func openCompare() {
    guard isLoupeOpen, let focused = focusedImageID,
      let session = CompareSession(scope: FilmstripScope.resolve(for: self), focused: focused)
    else { return }
    compareGeneration = loadGeneration
    compareState = session
  }

  /// Back: the loupe again, focused on the current left image (decision 5).
  func closeCompare() {
    if let session = compareSession { focusedImageID = session.left }
    compareState = nil
  }

  /// One Compare verb: ONE compound mark (decision 6), then the pane progression its outcome
  /// licenses. The progression is applied only to the session that asked, unchanged while the
  /// write was in flight (the strip, swipe and Pin are disabled for that span; this is the
  /// store-side half of the same rule).
  @discardableResult
  func compareDecide(_ verb: CompareVerb) async -> CompoundMarkResult {
    guard let session = compareSession, let groups = session.markGroups(for: verb) else {
      return .refused
    }
    // IMGMGR-482: the token of the entry THIS verb recorded, as the store built it — never a
    // re-read of the mutable slot afterwards.
    let report = await applyCompoundMarkReporting(groups)
    let result = report.result
    // Equality includes the session's `token` (A1), so a reopened session on the same pair is
    // never mistaken for the one that asked.
    guard var current = compareSession, current == session else { return result }
    current.record(verb, result: result, entryToken: report.entryToken)
    compareState = current
    focusedImageID = current.left
    return result
  }

  /// Compare's Undo: the store's one undo slot, and the pane pair restored only when the whole
  /// entry came back (`UndoOutcome.restoredAll`) AND that entry is the one the session's pending
  /// snapshot is keyed by (IMGMGR-482). Any other outcome is reported with the panes unchanged.
  @discardableResult
  func compareUndo() async -> UndoOutcome {
    guard let asked = compareSession?.token else { return .refused }
    let report = await undoLastMarkReporting()
    guard var current = compareSession, current.token == asked else { return report.outcome }
    current.undoCompleted(report)
    compareState = current
    focusedImageID = current.left
    return report.outcome
  }

  /// A strip tap: the right pane shows `imageID` (never the left image).
  func compareShowOnRight(_ imageID: Int) {
    guard !isMutatingMark, var current = compareSession else { return }
    current.showOnRight(imageID)
    compareState = current
  }

  /// A swipe on the right pane: the right candidate steps, skipping the left image.
  func compareStepRight(forward: Bool) {
    guard !isMutatingMark, var current = compareSession else { return }
    current.stepRight(forward: forward)
    compareState = current
  }

  /// Pin: while on, the left pane never changes.
  func compareSetPinned(_ isPinned: Bool) {
    guard !isMutatingMark, var current = compareSession else { return }
    current.isPinned = isPinned
    compareState = current
  }

  /// The FOCUSED photograph's own mark, or `nil` when nothing is focused (or the focused id is
  /// not in the actionable projection — a scope change can leave focus naming a row this store no
  /// longer holds). Reads `actionableImages`, never `images`: that is the same projection the
  /// loupe and the filmstrip walk, so in Scene mode an opened scene's members answer too, where
  /// `images` is empty by design (IMGMGR-275).
  var focusedMarkState: Components.Schemas.MarkView.StatePayload? {
    guard let id = focusedImageID else { return nil }
    return actionableImages.first(where: { $0.id == id })?.mark.state
  }

  var canLoupeGoPrevious: Bool {
    let pool = actionableImages
    guard let current = focusedImageID, let idx = pool.firstIndex(where: { $0.id == current })
    else { return false }
    return idx > 0
  }

  var canLoupeGoNext: Bool {
    let pool = actionableImages
    guard let current = focusedImageID, let idx = pool.firstIndex(where: { $0.id == current })
    else { return false }
    if idx + 1 < pool.count { return true }
    // Scene mode has no forward prefetch to reach for (see `loupeNext`), so the loaded tail IS
    // the end as far as the loupe is concerned — never an enabled control that would do nothing.
    return displayMode == .flat && !loupeExhausted
  }

  /// The loupe's own small, targeted forward-look — distinct from the grid's own large
  /// cursor-paged `loadMoreIfNeeded`. Merges (never a filmstrip-local page/cursor: fold's
  /// "one paging path" pivot) via `mergeImages`, the SAME dedup point `loadMoreIfNeeded` uses,
  /// so the two sources can never produce a duplicate tile even when their ranges overlap.
  ///
  /// WP31 P1 (IMGMGR-460): it ANSWERS now, so `successor(after:pagesScenes:)` can tell the
  /// server's "nothing follows" from a failure or a stale scope. Every write is what it was;
  /// `@discardableResult` keeps the answer optional for any other caller.
  @discardableResult
  private func fetchAndMergeNeighbours(after imageID: Int) async -> NeighbourFetchOutcome {
    // IMGMGR-541 (§2.3a): grouped by Mark or Rating, `/neighbours` answers from a photograph's
    // CURRENT grouped position — after a pick inside the remainder that is the Picks group, and
    // "what follows" would be a stream photograph. Each scope pages its own retained order with
    // its own issued cursor instead.
    if remainderGroupBy != nil {
      return await pageActiveGroupedScope(advancingLoupeFrom: imageID)
    }
    // Diff-gate round (2026-08-28): the same generation guard every other paging await here
    // carries — a neighbours response that lands after the shoot/filter changed must be
    // discarded whole, or it appends old-scope rows into the new scope and can focus the
    // loupe on an id the new scope does not contain.
    let generation = loadGeneration
    // IMGMGR-269 (codex gate round 1, blocker 1): the loupe session that ASKED, captured before
    // the await — see `loupeSession` for why current open-state is the wrong question.
    let session = loupeSession
    do {
      let page = try await service.neighbours(after: imageID, query: query, limit: 5)
      guard generation == loadGeneration else { return .stale }
      let added = mergeImages(page.items)
      images.append(contentsOf: added)
      if page.items.isEmpty {
        // Exhaustion is the SERVER's word only. `added` emptying through dedup merely means a
        // concurrent merge (the filmstrip's page fetch) got the same rows in first — the next
        // image exists locally, and latching exhausted here would wrongly disable Next.
        loupeExhausted = true
      } else {
        loupeExhausted = false
        // IMGMGR-269: the focus advance is SESSION-scoped, the merge above is not.
        // `applyLoupeMark` checks `isLoupeOpen` before it calls `loupeNext()`, but at the loaded
        // tail that call awaits this fetch — and Close is never disabled by a write, so the reader
        // can leave the loupe while the page is in flight. `closeLoupe()` neither clears
        // `focusedImageID` nor bumps `loadGeneration` (the bumps belong to scope changes, and this
        // is not one), so the generation guard above passes and, unfenced, this line would move
        // GRID focus after the loupe is gone.
        //
        // `session == loupeSession` rather than `isLoupeOpen` alone (codex gate round 1, blocker
        // 1): closing and REOPENING on the same image — a tile tap on the frame the grid still has
        // focused — makes open-state and focus both read true again, and a stale completion would
        // then advance a session that asked for nothing. `isLoupeOpen` is kept beside it so a
        // completion arriving into a closed loupe is refused on its own terms rather than only as
        // a session mismatch. The rows still merge either way: the grid legitimately gains them.
        if isLoupeOpen, session == loupeSession, focusedImageID == imageID,
          let idx = images.firstIndex(where: { $0.id == imageID }),
          images.indices.contains(idx + 1)
        {
          focusedImageID = images[idx + 1].id
        }
      }
      lastPageLoadError = nil
      return page.items.isEmpty ? .exhausted : .merged
    } catch {
      // P6 (premise-gate advisory (a)): the SAME generation guard the success path above
      // already carries — a neighbours call that started in an OLD scope and only FAILS after
      // a scope change must not surface its error in the NEW scope either (the success path
      // discards silently; a failure discarding into a stale write would be the inconsistent
      // half). Reuses the grid's own paging-error surface — a neighbours failure is the same
      // class of "reachability" concern as a failed grid page fetch, not a new error surface.
      guard generation == loadGeneration else { return .stale }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
      return .failed
    }
  }

  /// How one forward-neighbour fetch ended (WP31 P1).
  private enum NeighbourFetchOutcome: Equatable {
    case merged
    case exhausted
    case failed
    case stale
  }

  /// The ONE merge point for every source that can add to `images` after the first page: the
  /// grid's own cursor-paged `loadMoreIfNeeded` AND the loupe's forward-neighbour prefetch both
  /// route through this, so neither can ever reintroduce an id the other already loaded (fold's
  /// "the filmstrip and the grid share exactly one data source" pivot, made an actual
  /// correctness guarantee rather than just true by convention).
  private func mergeImages(_ newItems: [Components.Schemas.ImageSummary])
    -> [Components.Schemas.ImageSummary]
  {
    let existingIDs = Set(images.map(\.id))
    return newItems.filter { !existingIDs.contains($0.id) }
  }

  /// A monotonic counter for a paging request race: a slow first-page fetch that returns AFTER
  /// a second one was already started (shoot changed twice quickly) must not clobber the newer
  /// result with stale data.
  private var loadGeneration = 0

  init(
    service: GridService,
    preferences: GridPreferences = GridPreferences(),
    pasteboard: any MarksPasteboard = SystemMarksPasteboard(),
    startsWithTapToPick: @escaping @MainActor () -> Bool = { false }
  ) {
    self.service = service
    self.preferences = preferences
    self.pasteboard = pasteboard
    self.startsWithTapToPick = startsWithTapToPick
    self.looks = LookModel(fetchCatalogue: { try await service.looks() })
  }

  // MARK: - Loading

  /// `sourceTier` (WP8 P7, Q5): the COMPLETE destination is `(folderID, sourceTier)`, set
  /// atomically in this one call — never `selectShoot` followed by a separate
  /// `applyFilterChange` to set the tier, which would double-reload and briefly publish the
  /// wrong scope. Defaulting to `nil` keeps every pre-P7 caller behavior-preserving: `query.
  /// sourceTier` was never set anywhere in the app before this phase (verified: no call site,
  /// no test, sets it), so an omitted `sourceTier` here reproduces the exact prior behavior
  /// bit-for-bit, not merely "close enough".
  func selectShoot(folderID: Int, sourceTier: GridSourceTier? = nil) async {
    guard query.folderID != folderID || query.sourceTier != sourceTier else {
      // P6: genuine re-entry into the ALREADY-selected shoot (same folder AND same tier) — no
      // scope change, so none of the resets below apply, but the plan requires this to refresh
      // rather than the prior bare no-op (`selectShoot`'s own doc history: "P6 changes this for
      // genuine re-entry"). P7 extends the equality check to `sourceTier` too: a same-folder-
      // different-tier destination (e.g. re-tapping a tree row under a different tier branch
      // than the queue last selected) IS a real scope change, never a mere refresh.
      await authoritativeRefresh()
      return
    }
    leaveScene(.scopeChanged)
    query.folderID = folderID
    query.sourceTier = sourceTier
    pickLock.exit()
    // IMGMGR-548: the reader's "Start with Tap to Pick" latches Pick on the NEW shoot — only on a
    // real shoot change (the guard above returned for a re-select), through the menu's own
    // `forceLatch`, which is a no-op unless idle.
    if startsWithTapToPick() { pickLock.forceLatch(.pick) }
    selection.reset(.shootChange)
    focusedImageID = nil
    undo.clear()
    conflictRecovery = nil
    // The rendered sequence is rebuilt outright — a different shoot, or the flat/scene swap that
    // changes every row id — so an anchor into the old one means nothing. Retired at EVERY site
    // that rebuilds the sequence, `applyFilterChange` included; see its own note for why the
    // exception this line once carried was wrong.
    gridScrollAnchor = nil
    // IMGMGR-557: a new folder opens on its OWN default arrangement — Scene when it has scenes,
    // Flat when not — never on the mode the last folder was left in. Only here: the re-select
    // above is a refresh within the same visit and keeps whatever the reader switched to.
    await reloadFirstPage(choosesFolderDefault: true)
  }

  /// Any effective filter/tier/tree change (Stats-tab facet taps route through this).
  func applyFilterChange(_ mutate: (inout GridImagesQuery) -> Void) async {
    var next = query
    mutate(&next)
    guard next != query else { return }
    leaveScene(.scopeChanged)
    query = next
    selection.reset(.queryGenerationChange)
    focusedImageID = nil
    conflictRecovery = nil
    // WP16 P2 (IMGMGR-298), Codex round-3 blocker — a retraction, stated as one. This site
    // deliberately did NOT retire the anchor, on the argument that a filter narrows the same
    // shoot so a surviving row is still the reader's row. The argument is wrong, and the path
    // that shows it is concrete: scroll deep, apply a filter that matches nothing, clear it
    // again. The anchored photograph is still set while no rows exist to resolve it against, so
    // the moment rows come back the position jumps deep into the repopulated grid instead of
    // landing at the top, which is where every filter change has always left the reader
    // (`reloadFirstPage` below). A filter change rebuilds the result sequence, and the anchor is
    // retired wherever that happens — no exceptions, which is also one less rule to reason about.
    gridScrollAnchor = nil
    await reloadFirstPage()
  }

  /// Enter or leave Scene mode — the Group control's own action.
  ///
  /// A mode switch is a SCOPE change of the strongest kind: a different endpoint, a different row
  /// vocabulary, a different cursor namespace, and no 1:1 mapping between the two row sequences.
  /// So it takes `selectShoot`'s full reset — Pick Lock exited, selection reset, focus cleared,
  /// the undo slot cleared, any live conflict recovery abandoned — and not `applyFilterChange`'s
  /// lighter one, which deliberately leaves Pick Lock and Undo standing because a filter edit
  /// keeps the same photographs addressable. Here they are not: an id selected among loose rows
  /// may be inside a collapsed card after the switch, and an undo entry's priors would name
  /// photographs the new window cannot show. Zero-leak over zero-loss, the same adjudication the
  /// web made for the identical switch.
  ///
  /// It ALSO suspends and restores the sort/group presentation — ADR-0005 decision 6, reachable
  /// for the first time in WP13 P5b (IMGMGR-221 part 2). This doc comment used to say the
  /// opposite ("this client has none of them … there is therefore nothing to suspend"), which was
  /// true only while `GridImagesQuery` declared no `sort`, `direction` or `groupBy`. It declares
  /// all three now, so the excuse is replaced by the implementation rather than updated:
  /// - entering Scene SUSPENDS the current `(sort, direction, group_by)` and clears it from the
  ///   query, because `/api/browse/stacks` accepts none of the three (chronological only,
  ///   ADR-0005 decision 1) — a suspension that left them in the query would be a claim, not a
  ///   fact;
  /// - leaving Scene RESTORES exactly that presentation, and nothing else: a facet edit made
  ///   while Scene was on survives, because it describes WHICH photographs, not how they are
  ///   arranged.
  ///
  /// Every route out of Scene lands here — the Group menu, the View menu's pair, ⌘⇧G, and the
  /// Scene mode row's Exit button — so the restore is a property of the mode switch rather than
  /// of one control remembering to do it.
  func setDisplayMode(_ next: GridDisplayMode) async {
    guard next != displayMode else { return }
    leaveScene(.scopeChanged)
    adoptDisplayMode(next)
    pickLock.exit()
    selection.reset(.shootChange)
    focusedImageID = nil
    undo.clear()
    conflictRecovery = nil
    // The rendered sequence is rebuilt outright — a different shoot, or the flat/scene swap that
    // changes every row id — so an anchor into the old one means nothing. Retired at EVERY site
    // that rebuilds the sequence, `applyFilterChange` included; see its own note for why the
    // exception this line once carried was wrong.
    gridScrollAnchor = nil
    await reloadFirstPage()
  }

  /// The mode switch itself, with the presentation suspended on the way into Scene and restored
  /// on the way out. Shared by `setDisplayMode` and a folder open's default (IMGMGR-557), so the
  /// default Scene is left exactly as a chosen one is.
  private func adoptDisplayMode(_ next: GridDisplayMode) {
    guard next != displayMode else { return }
    switch next {
    case .scene:
      suspendedPresentation = SortGroupPresentation(of: query)
      query = SortGroupPresentation.cleared.applied(to: query)
    case .flat:
      if let suspended = suspendedPresentation {
        query = suspended.applied(to: query)
      }
      suspendedPresentation = nil
    }
    displayMode = next
  }

  // MARK: - Sort and grouping (WP13 P5b, IMGMGR-221 part 2)

  /// What entering Scene mode put away, and what leaving it puts back. Nil whenever Scene is off,
  /// which is what makes "leaving restores EXACTLY that presentation" checkable rather than
  /// merely intended.
  private(set) var suspendedPresentation: SortGroupPresentation?

  /// The sort key currently in force — the server's own default until the reader picks another,
  /// so the menu can draw its checkmark before anything has been chosen.
  var activeSortKey: SortKey {
    presentationInForce.sort.flatMap(SortKey.init(rawValue:)) ?? SortGroupOptions.defaultSortKey
  }

  var activeDirection: SortDirection {
    presentationInForce.direction.flatMap(SortDirection.init(rawValue:))
      ?? SortGroupOptions.defaultDirection
  }

  /// The ONE single-select value the Group menu renders: Scene, a `group_by` dimension, or
  /// neither. Derived, never stored — two stored flags is exactly how the two halves would drift
  /// apart into a state where both look active.
  var activeGrouping: GroupingChoice {
    if displayMode == .scene { return .scene }
    if let key = query.groupBy.flatMap(GroupByKey.init(rawValue:)) { return .key(key) }
    return .none
  }

  /// The presentation in force for the FLAT grid: the query's own while flat, and the SUSPENDED
  /// one while Scene is on.
  ///
  /// Reading the suspension in Scene mode is what makes the Sort control tell the truth there. A
  /// suspended presentation is not a forgotten one — it is exactly what comes back on the way out
  /// and what a sort choice made from Scene mode is a change TO — so the menu's checkmark and the
  /// control's label must name it, not the server defaults the cleared query falls back to.
  private var presentationInForce: SortGroupPresentation {
    if displayMode == .scene, let suspended = suspendedPresentation { return suspended }
    return SortGroupPresentation(of: query)
  }

  /// The Sort menu's key rows. Routed through `applyFlatPresentation`, and from there through
  /// `applyFilterChange`, which resets selection, clears focus and RESTARTS paging under a fenced
  /// generation — the client therefore never replays a cursor across a sort change, which the
  /// server refuses with `400 cursor_scope_mismatch` (live-probed 2026-08-30 against the deployed
  /// v0.12.1: cross-sort, cross-direction and cross-`group_by` replays are all refused, as is
  /// dropping `group_by`).
  func setSortKey(_ key: SortKey) async {
    await applyFlatPresentation { $0.sort = key.rawValue }
  }

  func setSortDirection(_ direction: SortDirection) async {
    await applyFlatPresentation { $0.direction = direction.rawValue }
  }

  /// The Sort menu's direction row in its accelerator form (the View menu's ⌥⌘R). Reverses the
  /// presentation IN FORCE — which, in Scene mode, is the suspended one, not the cleared query's
  /// fallback.
  func toggleSortDirection() async {
    await setSortDirection(activeDirection.reversed)
  }

  /// Every FLAT-presentation choice — a sort key, a direction, a `group_by` dimension — leaves
  /// Scene first and then applies, as ONE awaited sequence with no intermediate state published
  /// to the caller.
  ///
  /// Diff-gate r1 BLOCKER 2: without this, a sort key chosen in Scene mode was enabled but inert.
  /// It mutated the cleared query and moved the label, while Scene reloaded through
  /// `browseStacks` — which ignores `sort`, `direction` and `group_by` by contract (ADR-0005
  /// decision 1, and it stays that way) — and then leaving Scene RESTORED the suspended
  /// presentation and discarded the choice outright. The rule the Group menu already followed is
  /// simply the rule for the whole flat presentation: choosing any of it means asking for the
  /// flat grid. No disabled controls, no dead choices.
  ///
  /// `setDisplayMode(.flat)` restores the suspension first, so the mutation below edits the
  /// presentation the reader was last looking at rather than a cleared one — and when the
  /// restored value already IS the chosen one, `applyFilterChange`'s own `next != query` guard
  /// makes the second step a no-op and the whole thing is a single reload.
  private func applyFlatPresentation(_ mutate: (inout GridImagesQuery) -> Void) async {
    if displayMode == .scene {
      await setDisplayMode(.flat)
    }
    await applyFilterChange(mutate)
  }

  /// Scene ⟷ `group_by` as ONE single-select state — the coordinator entry point the Group menu
  /// calls, for every one of its rows (ADR-0005 decision 6; gate round 1 BLOCKING finding).
  ///
  /// `applyFilterChange` alone is not enough and never was: it mutates the flat query and never
  /// touches `displayMode`, and `browseStacks` carries no `group_by` — so choosing "Camera" while
  /// Scene was on would have left `displayMode == .scene` and the chosen menu row would visibly
  /// have done nothing. The three rules, in one place:
  /// - `.scene` → `setDisplayMode(.scene)`, which suspends the presentation on the way in;
  /// - `.key(k)`/`.none` → `applyFlatPresentation`, which leaves Scene first (restoring the
  ///   suspended presentation) and then applies the chosen key as one awaited sequence, and is a
  ///   plain `applyFilterChange` when the reader is already flat. Since diff-gate r1 BLOCKER 2
  ///   that helper is shared with the Sort menu: choosing ANY part of the flat presentation means
  ///   asking for the flat grid, so a group dimension and a sort key behave identically here.
  ///
  /// Exclusivity holds BY CONSTRUCTION rather than by arithmetic: the menu is a single-select
  /// list over `GroupingChoice`, and `GroupingChoice` cannot express "Scene and Camera".
  func selectGrouping(_ choice: GroupingChoice) async {
    switch choice {
    case .scene:
      await setDisplayMode(.scene)
    case .none, .key:
      await applyFlatPresentation { $0.groupBy = choice.groupByKey?.rawValue }
    }
  }

  // MARK: - Grid scroll anchor (WP16 P2)

  /// Where the contact sheet is scrolled to, as the id of its top-most rendered row.
  ///
  /// View state living in the store, deliberately, and only because the view cannot keep it.
  /// Decision 4's Regular-3 collapse (IMGMGR-298) swaps the workspace between the three-column
  /// and two-column `NavigationSplitView` shapes — the only shape change that reclaims the
  /// inspector's width, since a column is reserved by the initializer's arity — and that moves
  /// `GridView` from the `content` slot to the `detail` slot. A different position in the view
  /// tree is a different STRUCTURAL IDENTITY, so SwiftUI tears the subtree down and builds a
  /// fresh one: this store keeps the page, the selection and the focus, but the `ScrollView`'s
  /// own offset belongs to the view and goes with it. A reader deep inside a shoot who hides the
  /// inspector would land back at the top. Parked here, it outlives the rebuild.
  ///
  /// `@ObservationIgnored` on purpose: this is written on every scroll tick, and an observable
  /// write there would invalidate every view reading this store while the reader is dragging
  /// through a contact sheet. Nothing needs to REACT to it — the value only has to survive, and
  /// the rebuilt `ScrollView` reads it once to restore (`GridView.restoreOrRecordScrollAnchor`).
  ///
  /// A PHOTOGRAPH, never the row id `ScrollView` itself reports: the collapse changes the pane
  /// width, which repacks every justified row, so a remembered row id names a row that no longer
  /// exists. `GridScrollAnchor` is the translation in both directions, and owns that argument.
  @ObservationIgnored var gridScrollAnchor: GridDisplayID?

  // MARK: - Stats facets (WP12: the Compact filter surface)

  /// The counts the Stats tab renders. They live HERE, not in the inspector view's own `@State`,
  /// because the thing that has to be provable is the CHAIN — a facet tap changes the filter and
  /// the counts come back in step — and a trigger that only exists inside a SwiftUI `.task(id:)`
  /// modifier cannot be exercised by any test, so deleting it would break the app while every
  /// test stayed green.
  private(set) var facets: Components.Schemas.ImageFacets?

  /// The query the published `facets` describes. `refreshFacets` is a no-op while it already
  /// matches, so the workspace's `.task(id: queryIdentity)` (WP16 P2's `FacetsRefreshInstaller`,
  /// formerly the inspector's own) re-firing right after a tap that already refreshed does not
  /// fetch the same counts a second time.
  private(set) var facetsIdentity: GridImagesQuery?

  /// The refresh currently in flight, recorded SYNCHRONOUSLY — before this method's first
  /// suspension — so a second caller for the SAME query joins it instead of issuing a duplicate
  /// request. This is the reentrancy the MainActor does not prevent: `applyFacetFilter` sets
  /// `query` and then suspends inside `reloadFirstPage`, and the workspace's
  /// `.task(id: queryIdentity)` fires for the NEW identity inside that window. With the identity
  /// only written after the network await, both calls passed the guard below and whichever
  /// response came home last won.
  private var facetsRefresh: (identity: GridImagesQuery, task: Task<Void, Never>)?

  /// Idempotent per query: the workspace's `.task(id:)` calls this on appearance and on every
  /// query-identity change, and the tap handlers below call it after they mutate the filter.
  /// A response that arrives after the query moved on is discarded (same discipline as the
  /// paging generation fence), and a failed fetch leaves the last good counts standing rather
  /// than blanking the tab — absence renders as absence, never as zeros.
  func refreshFacets() async {
    // R3-18 / plan Decision 7 (IMGMGR-550): never a bare `/api/facets` — unscoped, it cancels at
    // 30 s in production (IMGMGR-384) — and never the previous folder's counts under no folder.
    // A held scoped response is dropped by the fetch's own `self.query == requested` fence.
    guard query.folderID != nil else {
      facets = nil
      facetsIdentity = nil
      facetsRefresh = nil
      return
    }
    await refreshDerived(
      isSatisfied: facetsIdentity == query && facets != nil,
      inFlight: { self.facetsRefresh },
      setInFlight: { self.facetsRefresh = $0 },
      fetch: { requested in
        let fetched = try? await self.service.facets(requested)
        guard self.query == requested, let fetched else { return }
        self.facets = fetched
        self.facetsIdentity = requested
      })
  }

  // MARK: - Group headers (WP13 P5b: the ONLY truthful section source)

  /// The last VOUCHED answer and the query identity it describes, together and inseparable.
  ///
  /// Private, and a single value rather than three parallel properties, because the identity is
  /// not metadata about the headers — it is the condition under which they mean anything at all.
  /// Diff-gate r1 BLOCKER 1: while these were three independent stored properties, a failed
  /// `/api/image-groups` fetch left the PREVIOUS scope's headers published (the failure path
  /// simply returns), and the view consumed them unconditionally — so after a grouped folder or
  /// filter switch the old scope's label, count and timezone could render over the new
  /// photographs. Pairing them makes that unrepresentable rather than merely discouraged.
  private var vouchedGroups:
    (
      identity: GridImagesQuery, headers: [GroupKey: Components.Schemas.GroupHeader],
      timezone: String?
    )?

  /// The sections for the CURRENT query, exactly as `GET /api/image-groups` stated them, keyed so
  /// a tile's own `group_key` (nullable — the Unknown bucket) looks one up directly. EMPTY unless
  /// the server has vouched for THIS query: unvouched renders as an unsectioned stream, never as
  /// the previous scope's sections.
  ///
  /// Never a client-side tally. A page holds PART of a group, so a count derived from the loaded
  /// rows would state the PAGE's number under a section's name; the same goes for the Unknown
  /// bucket's label and for the timezone a time-key label was rendered in. All three are the
  /// server's words (`app/api/images.py:1816-1826`: "the ONLY truthful way a client can place a
  /// section header").
  ///
  /// Gated HERE rather than in the view, so the view stays dumb: there is no way to read a header
  /// out of this store without the identity check having already run.
  var groupHeaders: [GroupKey: Components.Schemas.GroupHeader] {
    guard let vouched = vouchedGroups, vouched.identity == query else { return [:] }
    return vouched.headers
  }

  /// The zone the response named for its labels — non-nil for the five time keys only
  /// (live-probed 2026-08-30: `group_by=day` → `Europe/Zurich`; `camera`/`location` → null).
  /// Estate ADR-0007 (/link/2553): a rendered local time names its zone. Identity-gated for the
  /// same reason as `groupHeaders`: a zone from another scope is as wrong as a count from one.
  var groupTimezone: String? {
    guard let vouched = vouchedGroups, vouched.identity == query else { return nil }
    return vouched.timezone
  }

  /// The query the vouched headers describe — the SAME identity discipline `facetsIdentity`
  /// uses. Exposed for the refresh guard and for tests; reading it is never a substitute for
  /// the gate above, which has already applied it.
  var groupHeadersIdentity: GridImagesQuery? { vouchedGroups?.identity }

  private var groupHeadersRefresh: (identity: GridImagesQuery, task: Task<Void, Never>)?

  /// Fetch the sections for the current query, or drop them when nothing is grouped.
  ///
  /// Runs through the SAME single-flight `refreshFacets` does (`refreshDerived`), keyed by the
  /// same query identity — one mechanism, two slots, rather than a second concurrency pattern
  /// beside it.
  ///
  /// A failed fetch publishes NOTHING — it leaves the last vouched answer where it is, and that
  /// answer stops being published the moment the query moves past it (`groupHeaders`' own gate).
  /// So a failure under the CURRENT query keeps the sections the server already vouched for, and
  /// a failure after a scope change renders the new photographs unsectioned rather than under the
  /// old scope's headings. Absence renders as absence, never as an invented or a stale label.
  func refreshGroupHeaders() async {
    guard let key = query.groupBy.flatMap(GroupByKey.init(rawValue:)) else {
      vouchedGroups = nil
      return
    }
    await refreshDerived(
      isSatisfied: groupHeadersIdentity == query,
      inFlight: { self.groupHeadersRefresh },
      setInFlight: { self.groupHeadersRefresh = $0 },
      fetch: { requested in
        let fetched = try? await self.service.imageGroups(requested, groupBy: key)
        guard self.query == requested, let fetched else { return }
        self.vouchedGroups = (
          identity: requested,
          headers: Dictionary(
            (fetched.headers ?? []).map { (GroupKey($0.key), $0) },
            uniquingKeysWith: { first, _ in first }),
          timezone: fetched.timezone
        )
      })
  }

  /// The ONE idempotent-per-query single-flight both derived reads use.
  ///
  /// The reentrancy it defends against is identical for both, and the MainActor does not prevent
  /// it: a mutation sets `query` and then suspends inside `reloadFirstPage`, and a view's
  /// `.task(id: queryIdentity)` fires for the NEW identity inside that window. Recording the
  /// in-flight identity SYNCHRONOUSLY — before the first suspension — is what makes the second
  /// caller join instead of issuing a duplicate request.
  ///
  /// A refresh for a DIFFERENT identity is never joined — it supersedes. The superseded task is
  /// left to finish and discard itself on its own guard rather than being cancelled, so a
  /// response racing home first can still never publish for a query already moved past. The slot
  /// is cleared by TASK, not by identity: a newer refresh for the same identity may already have
  /// claimed it while this one was in flight, and clearing it blindly would let a duplicate
  /// through the join.
  private func refreshDerived(
    isSatisfied: Bool,
    inFlight: () -> (identity: GridImagesQuery, task: Task<Void, Never>)?,
    setInFlight: ((identity: GridImagesQuery, task: Task<Void, Never>)?) -> Void,
    fetch: @escaping @MainActor (GridImagesQuery) async -> Void
  ) async {
    let requested = query
    if isSatisfied { return }
    if let current = inFlight(), current.identity == requested {
      await current.task.value
      return
    }
    let task = Task { @MainActor in await fetch(requested) }
    setInFlight((requested, task))
    await task.value
    if inFlight()?.task == task { setInFlight(nil) }
  }

  /// A Stats facet row's tap, as ONE call: mutate that dimension (one value per dimension — a
  /// second tap on the active value clears it) and bring the counts back in step. The view's
  /// Button does exactly this and nothing else, so a test that calls it exercises the whole
  /// chain the row triggers.
  func applyFacetFilter(_ field: InspectorFacetField, value: String) async {
    await applyFilterChange { field.toggle(value, in: &$0) }
    await refreshFacets()
  }

  /// The Stats tab's "Clear filters" row: the facet fields only — never the shoot scope
  /// (`folderID`/`sourceTier`, set atomically by `selectShoot`) and never `q`.
  func clearFacetFilters() async {
    await applyFilterChange { InspectorFacetFilters.clear(&$0) }
    await refreshFacets()
  }

  /// Foreground/retry: same scope, fresh data.
  func fullReload() async {
    // IMGMGR-541 (§2.5): under Mark/Rating grouping the notice's Retry is a PRESERVING refresh,
    // never a replace: the stream keeps its tiles where they are and an entered remainder stays
    // entered. Then the page that failed is asked for again from the scope's kept cursor.
    if remainderGroupBy != nil, !images.isEmpty || remainderReached {
      guard await authoritativeRefresh() else { return }
      if isInRemainder {
        await loadMoreRemainder()
      } else if nextCursor != nil, let last = images.last {
        await loadMoreIfNeeded(currentItemID: last.id)
      }
      return
    }
    selection.reset(.fullReload)
    focusedImageID = nil
    await reloadFirstPage()
  }

  /// `revalidatesEntry`: a KEEP reload revalidates the entered scene once the rows are in; the
  /// topology coordinator passes false because it resolves its own destination (§2.3a).
  ///
  /// `choosesFolderDefault` (IMGMGR-557): a folder open decides the mode first. "Has scene data"
  /// means the folder's first `/api/browse/stacks` page holds at least one scene row — and that
  /// page IS Scene's first page (the endpoint takes no sort or `group_by`, so the presentation
  /// in force does not change the request), so a folder with scenes costs no second request. A
  /// folder without scenes, or a probe that fails, falls back to Flat and loads the flat page as
  /// any flat reload does; the probe's own failure is not reported, because Flat is a complete
  /// answer and the flat page carries today's error if the server is really down.
  private func reloadFirstPage(
    revalidatesEntry: Bool = true, choosesFolderDefault: Bool = false
  ) async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoadingPage = true
    // P6: only THIS call's own generation may declare loading complete — an older reload whose
    // `defer` fires after a newer refresh/reload already took over must not clear the flag out
    // from under it (plan item 2: "An older request's `defer { isLoadingPage = false }` must
    // not declare loading complete while a newer refresh is active").
    defer { if generation == loadGeneration { isLoadingPage = false } }
    // Any scope change closes the loupe (its focused image is about to be replaced or cleared
    // by the callers below, all of which already null `focusedImageID`) and clears the
    // exhaustion flag a NEW scope has not actually earned yet.
    isLoupeOpen = false
    loupeExhausted = false
    // WP12: the whole Scene window dies with the scope for exactly the reason the flat window
    // does — and so does every expansion, which describes a membership OF a result set that is
    // being replaced. Cleared in BOTH modes: a scope change while flat must not leave a stale
    // scene slice behind for the next entry into Scene mode to find.
    clearSceneWindow()
    if displayMode == .scene {
      // "`images` stays EMPTY in Scene mode" has to be something this code DOES, not something
      // its doc comment says. Nothing below ever assigns `images` in this mode, so without this
      // the flat window simply survives the switch — carrying the previous mode's photographs
      // into the shared actionable projection, which is the one thing that projection exists to
      // prevent. Caught by `sceneRowsAreKindDiscriminated`/`enteringSceneModeIsAFullReset`, which
      // asserted the claim rather than trusting it. Its flat cursor goes with it: a cursor minted
      // by `/api/images` is refused outright by the stacks endpoint.
      images = []
      nextCursor = nil
      clearRemainder()
    }
    var rowsLoaded = false
    var probedScenePage: StackBrowsePageResult?
    if choosesFolderDefault {
      let probe = try? await service.browseStacks(query, cursor: nil, limit: Self.scenePageLimit)
      guard generation == loadGeneration else { return }
      let hasScenes = probe.map(Self.holdsAScene) ?? false
      adoptDisplayMode(hasScenes ? .scene : .flat)
      if hasScenes {
        // The flat window goes for the same reason it goes above when Scene is already on.
        images = []
        nextCursor = nil
        clearRemainder()
        probedScenePage = probe
      }
    }
    do {
      switch displayMode {
      case .flat:
        let page = try await service.images(query, cursor: nil, limit: 100)
        guard generation == loadGeneration else { return }
        // Assigned only on success, deliberately: a failed flat reload keeps the rows the reader
        // was looking at rather than blanking the grid (pre-existing behaviour, unchanged).
        ingestStreamPage(page.items, nextCursor: page.nextCursor, replacing: true)
      case .scene:
        let page: StackBrowsePageResult
        if let probedScenePage {
          page = probedScenePage
        } else {
          page = try await service.browseStacks(query, cursor: nil, limit: Self.scenePageLimit)
          guard generation == loadGeneration else { return }
        }
        sceneRows = page.rows
        sceneNextCursor = page.nextCursor
      }
      rowsLoaded = true
      lastPageLoadError = nil
      // A fresh window makes any earlier "these ids were pruned out from under your write"
      // notice meaningless — it names photographs from a set that no longer stands.
      droppedWriteIDs = []
    } catch {
      guard generation == loadGeneration else { return }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
    }
    // WP13 P5b: sections come from the server or not at all, so the header fetch is part of
    // loading a grouped scope rather than something the view asks for afterwards — and it runs
    // INSIDE this generation fence, so a header set for an abandoned scope is never published.
    // A no-op whenever `group_by` is nil (Scene mode included, which clears the presentation on
    // the way in) and idempotent per query identity, so the common re-entry costs no request.
    guard generation == loadGeneration else { return }
    // WP442 P12: a KEEP reload revalidates the entered scene against the new rows (B5).
    if revalidatesEntry, displayMode == .scene, let entered = enteredSceneID {
      if rowsLoaded {
        await revalidateEnteredScene(generation: generation)
        guard generation == loadGeneration else { return }
      } else {
        sceneLoadFailed.insert(entered)
      }
    }
    // WP14 (IMGMGR-251): and it runs only when the ROWS for this query actually arrived. The
    // catch above deliberately keeps the previous query's photographs on screen; fetching
    // headers anyway would vouch the NEW query's labels, counts and timezone, and the
    // `groupHeaders` identity gate would then publish them — headers and rows each agreeing with
    // the store and disagreeing with each other. Suppressing the publish leaves the last vouched
    // answer where it is, so the stale rows render UNSECTIONED (the gate rejects an identity the
    // query has moved past) rather than under section headers describing a different set of
    // photographs. The next successful reload of this query fetches them for real.
    guard rowsLoaded else { return }
    await refreshGroupHeaders()
  }

  /// `GET /api/browse/stacks` counts DISPLAY ROWS, not photographs ("a page of 100 may stand for
  /// thousands of frames" — the schema's own words), so the flat grid's 100 is if anything
  /// generous here rather than tight. Its declared maximum is 200.
  private static let scenePageLimit = 100

  /// IMGMGR-557: "has scene data" — the page holds at least one scene row, not only photographs.
  private static func holdsAScene(_ page: StackBrowsePageResult) -> Bool {
    page.rows.contains { row in
      if case .stack = row { return true }
      return false
    }
  }

  /// Drops everything that describes a Scene RESULT SET: the served rows, its cursor, which
  /// scenes are open and every membership page loaded for them. Never touches `displayMode` —
  /// the reader is still in Scene mode, the window under them is simply being rebuilt.
  private func clearSceneWindow() {
    sceneRows = []
    sceneNextCursor = nil
    sceneMembers = [:]
    sceneMemberCursors = [:]
    sceneMembersInFlight = []
    sceneInlinePicks = [:]
    sceneInlinePicksInFlight = []
    peekBands = []
    bandLoadFailed = []
  }

  // MARK: - Authoritative refresh (P6: foreground + genuine same-shoot re-entry)

  /// `GET /api/images` per-request cap (verified live against the vendored schema,
  /// `openapi.json`'s `limit` parameter: `maximum: 200`) — the refresh uses the largest page the
  /// server allows, so a 600-image shoot still resolves in 3 round trips rather than 6.
  private static let refreshPageLimit = 200
  /// Bounds the cursor-invalid restart loop (plan item 1: "discard the snapshot, restart from
  /// page one") so a server that keeps refusing every cursor cannot spin this forever.
  private static let refreshCursorRestartLimit = 3

  /// P6's authoritative resync: a generation-fenced, MULTI-PAGE re-read of the CURRENT query
  /// (RootView's foreground hook, and `selectShoot`'s own same-id re-entry branch, are the two
  /// callers). Joins the SAME lane `applyMark`/`undoLastMark`/`addTag` use — but never REFUSES
  /// like they do; a required lifecycle refresh queues behind an in-flight mutation instead of
  /// being dropped (plan item 2). Returns whether it actually published (`false` on a discarded
  /// stale snapshot or a read failure) — `handleConflict`/`retryConflictRefresh` key off this.
  @discardableResult
  func authoritativeRefresh() async -> Bool {
    await acquireLaneQueueing()
    defer { releaseLane() }
    return await performAuthoritativeRefresh()
  }

  /// The core fetch loop, WITHOUT its own lane acquisition — callable by `authoritativeRefresh()`
  /// (which acquires the lane itself) and by the conflict-recovery path (`performRecoveryReread`),
  /// which runs while its OWN caller (either `applyMark`'s live hold, or `retryConflictRefresh`'s
  /// explicit `tryAcquireLane()`) already holds the lane for the whole recovery sequence —
  /// acquiring here too would deadlock (nothing would ever release the lane the outer caller is
  /// waiting to hand back to itself).
  private func performAuthoritativeRefresh() async -> Bool {
    guard query.folderID != nil else { return false }
    // Diff-gate round 2, B1: ADVANCE the generation (mirrors `reloadFirstPage`'s own
    // `loadGeneration += 1`) rather than merely reading the current value — copying it left an
    // OLDER pending `reloadFirstPage`/`loadMoreIfNeeded` sharing the SAME generation number, so
    // its own fence (`generation == loadGeneration`) passed trivially and it could overwrite this
    // refresh's newer, already-published snapshot whenever its response happened to arrive later;
    // its `defer` could also clear `isLoadingPage` while this refresh was still genuinely active.
    // Advancing here makes every such older in-flight load fail its own fence once THIS refresh
    // starts, exactly like any other scope-changing operation already does.
    loadGeneration += 1
    let generation = loadGeneration
    isLoadingPage = true
    defer { if generation == loadGeneration { isLoadingPage = false } }

    switch displayMode {
    case .flat: return await refreshFlatPages(generation: generation)
    case .scene: return await refreshScenePage(generation: generation)
    }
  }

  /// Scene mode's authoritative re-read: page one of the CURRENT scene scope, plus a fresh
  /// membership page for every scene that is currently open, published together.
  ///
  /// It exists so the mark/undo lane behaves identically in both modes rather than degrading:
  /// the 409 recovery machine and the foreground refresh both call `performAuthoritativeRefresh`
  /// and both need it to actually publish server truth for the photographs on screen — which in
  /// Scene mode live in `sceneMembers` and the loose rows, not in `images`. Expansion is
  /// PRESERVED (the reader's open scenes are not a data question), memberships are re-fetched
  /// rather than kept, and a failure anywhere leaves the existing window untouched — a partial
  /// refresh would be a window nobody asked for.
  private func refreshScenePage(generation: Int) async -> Bool {
    // WP442 P12: the entered scene is KEPT and revalidated (B5): absence from page 1 is not
    // evidence it is gone — a stack-row reread is, and only a 404 or an empty membership leaves.
    let entered = enteredSceneID
    let resolving = entered != nil && sceneDestinationRetry?.owner.stackID == entered
    do {
      let page = try await service.browseStacks(query, cursor: nil, limit: Self.scenePageLimit)
      guard generation == loadGeneration else { return false }
      var rows = page.rows
      var refreshedMembers: [Int: [Components.Schemas.ImageSummary]] = [:]
      var refreshedCursors: [Int: SceneMemberCursor] = [:]
      var gone = false
      if let id = entered, !resolving {
        sceneLoadFailed.remove(id)
        if !rows.contains(where: { $0.displayID == .stack(id) }) {
          do {
            let row = try await service.stackRow(stackID: id, query: query)
            guard generation == loadGeneration else { return false }
            rows.insert(
              .stack(row), at: SceneEditPlanner.insertionIndex(for: row.anchorTakenAt, in: rows))
          } catch GridServiceError.notFound {
            guard generation == loadGeneration else { return false }
            gone = true
          } catch {
            guard generation == loadGeneration else { return false }
            if enteredSceneID == id { sceneLoadFailed.insert(id) }
            return false
          }
        }
        if !gone {
          do {
            let members = try await service.stackMembers(
              stackID: id, cursor: nil, limit: Self.sceneMemberPageLimit)
            guard generation == loadGeneration else { return false }
            if members.items.isEmpty && members.nextCursor == nil {
              gone = true
            } else {
              refreshedMembers[id] = members.items
              refreshedCursors[id] =
                members.nextCursor.map(SceneMemberCursor.more) ?? .exhausted
            }
          } catch GridServiceError.notFound {
            guard generation == loadGeneration else { return false }
            gone = true
          }
        }
      }
      guard generation == loadGeneration else { return false }
      // A Back or a different enter made during the awaits wins: the scene entered NOW keeps
      // what it already loaded.
      let now = enteredSceneID
      if let now, now != entered || resolving {
        if let held = sceneMembers[now] { refreshedMembers[now] = held }
        if let held = sceneMemberCursors[now] { refreshedCursors[now] = held }
      }
      let bandOrderBeforeRefresh = displayRows(for: .stream).map(\.id)
      sceneRows = rows
      sceneNextCursor = page.nextCursor
      sceneMembers = refreshedMembers
      sceneMemberCursors = refreshedCursors
      sceneMembersInFlight = sceneMembersInFlight.intersection(now.map { [$0] } ?? [])
      if gone, let id = entered, enteredSceneID == id { leaveScene(.sceneGone) }
      // IMGMGR-542: bands whose card is still listed are re-read (authoritative, like the entered
      // scene); the rest close. Stored anchors are then revalidated against what survives.
      let listed = Set(rows.map(\.displayID))
      peekBands.removeAll { !listed.contains(.stack($0.stackID)) }
      for band in peekBands where sceneMembers[band.stackID] == nil {
        await fetchSceneMembers(stackID: band.stackID, cursor: nil)
        guard generation == loadGeneration else { return false }
      }
      revalidateBandAnchors(previousOrder: bandOrderBeforeRefresh)
      // IMGMGR-261: a refresh re-reads every card, so a cached summary may now be stale.
      sceneInlinePicks = [:]
      sceneInlinePicksInFlight = []
      let actionable = actionableImages
      pruneSelectionOutside(actionable)
      publishRefreshedFocusAndUndo(actionable: actionable)
      if resolving, let retry = sceneDestinationRetry, ownsNavigation(retry.owner) {
        await resolveDestination(retry, dissolved: [], generation: generation)
      }
      return true
    } catch {
      guard generation == loadGeneration else { return false }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
      return false
    }
  }

  /// A Scene refresh REPLACES the window rather than extending it — page one of the scene stream,
  /// plus a FIRST membership page for each surviving open scene — so a photograph the reader
  /// selected deeper in a long scene, or further down the stream, can simply stop being loaded.
  /// Its id leaves the selection with it, for the same reason collapsing a card prunes
  /// (`leaveScene`): the selection is a set of ids, so nothing downstream can tell that
  /// one of them is no longer on screen. `tagTargetImageIDs` would keep advertising it while
  /// `capturePriorTagSnapshots` drops anything outside `actionableImages` — a mixed selection
  /// would then write only its visible part and an all-hidden one would write nothing, in both
  /// cases with no signal to the reader that the rest was skipped.
  ///
  /// Pruning, not preserving the extent: a refresh's whole point is that the window it publishes
  /// is what the server says is there now, and re-fetching every page a reader had scrolled
  /// through to keep a selection alive would make the resync unbounded.
  private func pruneSelectionOutside(_ actionable: [Components.Schemas.ImageSummary]) {
    guard !selection.members.isEmpty else { return }
    let vanished = selection.members.subtracting(actionable.map(\.id))
    guard !vanished.isEmpty else { return }
    selection.removeHidden(Array(vanished))
  }

  private func refreshFlatPages(generation: Int) async -> Bool {
    if remainderGroupBy != nil {
      return await refreshGroupedPreserving(generation: generation)
    }
    var snapshot: [Components.Schemas.ImageSummary] = []
    var cursor: String?
    var restarts = 0
    while true {
      guard generation == loadGeneration else { return false }
      do {
        let page = try await service.images(query, cursor: cursor, limit: Self.refreshPageLimit)
        guard generation == loadGeneration else { return false }
        snapshot.append(contentsOf: page.items)
        guard let next = page.nextCursor else { break }
        cursor = next
      } catch GridServiceError.cursorInvalid {
        guard generation == loadGeneration else { return false }
        restarts += 1
        guard restarts <= Self.refreshCursorRestartLimit else {
          lastPageLoadError = .cursorInvalid
          return false
        }
        // Never mix generations of the snapshot itself either — a partial snapshot built from
        // pages before the invalid cursor is discarded whole, not appended to.
        snapshot = []
        cursor = nil
      } catch {
        guard generation == loadGeneration else { return false }
        lastPageLoadError = (error as? GridServiceError) ?? .unreachable
        return false
      }
    }
    guard generation == loadGeneration else { return false }
    publishAuthoritativeSnapshot(snapshot)
    return true
  }

  /// The one atomic publish point: server truth replaces `images` WHOLESALE (state+tags+revision
  /// — a local optimistic mark is never authority) and invalidates the undo slot (item 2: stale
  /// priors must never be replayed over refreshed state). Loupe focus/presentation is preserved
  /// if the previously-focused id survives the refreshed query; otherwise focus is cleared and
  /// the loupe closed — a deterministic choice, never the prior unconditional clear `fullReload`
  /// still uses for its own (unrelated) manual-retry callers.
  private func publishAuthoritativeSnapshot(_ snapshot: [Components.Schemas.ImageSummary]) {
    images = snapshot
    nextCursor = nil
    publishRefreshedFocusAndUndo(actionable: snapshot)
  }

  /// The half of a publish that is mode-independent: the undo slot is invalidated (item 2: stale
  /// priors must never be replayed over refreshed state) and focus/loupe survive only if the
  /// previously-focused photograph is still among the refreshed ACTIONABLE photographs. Scene
  /// mode's refresh calls it with its own derived list, so "survived" means the same thing in
  /// both modes: still reachable by a gesture, not merely still somewhere in the response.
  private func publishRefreshedFocusAndUndo(actionable: [Components.Schemas.ImageSummary]) {
    let previousFocus = focusedImageID
    lastPageLoadError = nil
    // WP14 (diff-gate round 1, blocker 4): the dropped-write notice names photographs from the
    // window this publish is REPLACING, so it dies with that window — exactly like the undo slot
    // below, and for the same reason. `reloadFirstPage` clears it on a scope change; this is the
    // other way a window is replaced (a same-shoot refresh), and without it a stale notice could
    // outlive the state it describes indefinitely. Both modes' refreshes publish through here.
    droppedWriteIDs = []
    undo.clear()
    let survived = previousFocus.map { id in actionable.contains { $0.id == id } } ?? false
    guard !survived else { return }
    focusedImageID = nil
    if isLoupeOpen { closeLoupe() }
  }

  /// Called by the view when the last loaded row is about to appear. Paging append: per
  /// selection semantics, this never clears and never implicitly selects the newly-appended
  /// rows (`SelectionState.pageAppended()` is a documented no-op called here for exactly that
  /// reason).
  func loadMoreIfNeeded(currentItemID: Int) async {
    // WP12: flat paging only. Scene mode pages DISPLAY ROWS through its own cursor
    // (`loadMoreScenesIfNeeded`); routing an image id through here would consume the flat cursor,
    // which the stacks endpoint refuses outright as a scope mismatch.
    guard displayMode == .flat else { return }
    // IMGMGR-541: inside the remainder, the grid and the loupe page the remainder's own cursor.
    if isInRemainder {
      await loadMoreRemainderIfNeeded(currentItemID: currentItemID)
      return
    }
    guard images.last?.id == currentItemID, let cursor = nextCursor, !isLoadingPage else {
      return
    }
    let generation = loadGeneration
    isLoadingPage = true
    defer { if generation == loadGeneration { isLoadingPage = false } }
    do {
      let page = try await service.images(query, cursor: cursor, limit: 100)
      guard generation == loadGeneration else { return }
      // `mergeImages` (P5): dedups against anything the loupe's own forward-neighbour prefetch
      // already appended, so a grid page whose range overlaps a prior neighbours-merge never
      // produces a duplicate tile.
      ingestStreamPage(page.items, nextCursor: page.nextCursor, replacing: false)
      selection.pageAppended()
      lastPageLoadError = nil
    } catch GridServiceError.cursorInvalid where remainderGroupBy != nil {
      // IMGMGR-541 (§2.5): under Mark/Rating grouping the retained stream is never replaced —
      // a tile marked in place stays where it is — so the dead cursor is recovered by re-paging
      // and appending only what is new.
      guard generation == loadGeneration else { return }
      isLoadingPage = false
      await recoverGroupedCursor(for: .stream)
    } catch GridServiceError.cursorInvalid {
      // Pinned disposition (plan §Phase 4, "v0.9.1-era cursor behavior"): discard the cursor
      // and restart the SAME scope from page one, rather than surfacing a dead-end paging
      // error the person can't do anything about.
      guard generation == loadGeneration else { return }
      await reloadFirstPage()
    } catch {
      guard generation == loadGeneration else { return }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
    }
  }

  // MARK: - Scene paging, expansion, and the cover that follows a mark (WP12)

  /// `GET /api/stacks/{id}/members` page size. A scene can be large — gap clustering is
  /// transitive, so a half-hour burst is one scene — which is exactly why the endpoint pages at
  /// all rather than being "small by construction".
  private static let sceneMemberPageLimit = 100

  /// Scene mode's own paging append, called by the view when the LAST display row appears.
  /// Consumes `sceneNextCursor` and only ever that — the flat cursor is a different namespace.
  func loadMoreScenesIfNeeded(currentRowID: GridDisplayID) async {
    guard displayMode == .scene else { return }
    guard isSceneWindowTail(currentRowID), let cursor = sceneNextCursor, !isLoadingPage
    else { return }
    let generation = loadGeneration
    isLoadingPage = true
    defer { if generation == loadGeneration { isLoadingPage = false } }
    do {
      let page = try await service.browseStacks(
        query, cursor: cursor, limit: Self.scenePageLimit)
      guard generation == loadGeneration else { return }
      // Dedup by display id, the same guarantee `mergeImages` gives the flat grid: a server that
      // repeats a row across a page boundary must never produce two cards for one scene.
      //
      // And an ORDER-PRESERVING merge rather than a blind append (codex gate round 2). The window
      // can hold a row this pager never fetched — `reloadAfterTopologyEdit` splices an edited
      // scene back in by its anchor when the reloaded first page does not carry it — so rows
      // arriving afterwards can belong BEFORE it, and appending them would break the one thing
      // this browse promises. ONE code path, not a special case: with no spliced row present every
      // incoming row is at or after everything loaded, `insertionIndex` answers "the end", and
      // this is exactly the append it has always been.
      var known = Set(sceneRows.map(\.displayID))
      for row in page.rows where !known.contains(row.displayID) {
        sceneRows.insert(
          row,
          at: SceneEditPlanner.insertionIndex(
            for: SceneEditPlanner.streamTime(of: row), in: sceneRows))
        known.insert(row.displayID)
      }
      sceneNextCursor = page.nextCursor
      selection.pageAppended()
      lastPageLoadError = nil
    } catch GridServiceError.cursorInvalid {
      // The same pinned disposition the flat grid uses: discard the cursor, restart the SAME
      // scope from page one, rather than surfacing a dead-end paging error.
      guard generation == loadGeneration else { return }
      await reloadFirstPage()
    } catch {
      guard generation == loadGeneration else { return }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
    }
  }

  /// "Has the caller reached the end of what IT walks?" — the tail test the one scene pager asks
  /// (IMGMGR-267).
  ///
  /// Two surfaces walk the loaded scene window and they walk DIFFERENT sequences: the grid walks
  /// display rows, whose tail can be a collapsed card, while the LOUPE walks the actionable
  /// photographs, whose tail is the last loose photograph or band member — which, in a stream
  /// ending in collapsed cards, is not the last display row at all. Asking only the first
  /// question is what made the loupe unable to extend the pool in Scene mode: its own last frame
  /// was never "the tail", so it never asked for more and the walk simply ended. (The asker was
  /// the filmstrip until IMGMGR-406 moved the trigger onto the focused photograph, which is the
  /// same sequence's tail and exists whether or not a strip is drawn.)
  ///
  /// Both answers name the same window and are served by the SAME function through the SAME
  /// `sceneNextCursor` — this widens what counts as the end, it does not add a second pager.
  /// The grid's own trigger can now fire a page earlier than the very last cell when trailing
  /// cards follow the last photograph; that is a prefetch through the same cursor, dedup'd by
  /// display id and single-flighted by `isLoadingPage`, and it appends exactly the same rows.
  func isSceneWindowTail(_ id: GridDisplayID) -> Bool {
    if sceneDisplayRows.last?.id == id { return true }
    if let lastActionable = actionableImages.last?.id, id == .image(lastActionable) { return true }
    return false
  }

  // MARK: - Mark/Rating remainder (IMGMGR-541, R3-6/R3-21)

  /// The key whose null bucket is the remainder, while the flat grid is grouped by one.
  var remainderGroupBy: GroupByKey? {
    guard displayMode == .flat, let key = activeGrouping.groupByKey, key.hasRemainder else {
      return nil
    }
    return key
  }

  /// The server-vouched size of the remainder, or nil while the headers do not vouch for this
  /// query. Never a tally of `remainderImages` (a page holds PART of the bucket).
  var remainderCount: Int? {
    guard remainderGroupBy != nil else { return nil }
    return groupHeaders[.unknown]?.count
  }

  private func clearRemainder() {
    remainderImages = []
    remainderCursor = nil
    remainderReached = false
  }

  /// THE only writer of stream pages into `images` (§2.2). Cuts the page at the remainder
  /// boundary; the first remainder rows seed the remainder with the cursor the server issued for
  /// that page, and the stream stops paging — every later row is remainder. A page that ends
  /// exactly on the last marked photograph seeds nothing: the stream pages on and the next page,
  /// all remainder, finds the boundary.
  private func ingestStreamPage(
    _ items: [Components.Schemas.ImageSummary], nextCursor next: String?, replacing: Bool
  ) {
    let cut = GroupRemainder.split(items, groupBy: remainderGroupBy)
    if replacing {
      clearRemainder()
      images = cut.stream
    } else {
      images.append(contentsOf: mergeImages(cut.stream))
    }
    guard !cut.remainder.isEmpty, !remainderReached else {
      nextCursor = next
      return
    }
    let known = Set(images.map(\.id))
    remainderImages = cut.remainder.filter { !known.contains($0.id) }
    remainderCursor = next
    remainderReached = true
    nextCursor = nil
  }

  /// Appends a remainder page: null-bucket rows only, never an id the stream or the remainder
  /// already holds (§2.3a: no marked-stream id, no duplicate).
  private func appendRemainder(_ items: [Components.Schemas.ImageSummary]) -> Int {
    let known = Set(images.map(\.id)).union(remainderImages.map(\.id))
    let fresh = items.filter {
      GroupRemainder.isRemainder(groupKey: $0.groupKey, groupBy: remainderGroupBy)
        && !known.contains($0.id)
    }
    remainderImages.append(contentsOf: fresh)
    return fresh.count
  }

  /// The grid's tail paging inside the drilled remainder (the stream's is `loadMoreIfNeeded`).
  func loadMoreRemainderIfNeeded(currentItemID: Int) async {
    guard isInRemainder, remainderImages.last?.id == currentItemID else { return }
    _ = await loadMoreRemainder()
  }

  /// One remainder page from `remainderCursor`, the same grouped query. The cursor advances only
  /// from a page that landed; a failure leaves it, so the continuation is never lost.
  @discardableResult
  private func loadMoreRemainder() async -> NeighbourFetchOutcome {
    guard let cursor = remainderCursor else { return .exhausted }
    guard !isLoadingPage else { return .failed }
    let generation = loadGeneration
    let scope = activeScope
    isLoadingPage = true
    defer { if generation == loadGeneration { isLoadingPage = false } }
    do {
      let page = try await service.images(query, cursor: cursor, limit: 100)
      guard generation == loadGeneration, activeScope == scope else { return .stale }
      _ = appendRemainder(page.items)
      remainderCursor = page.nextCursor
      selection.pageAppended()
      lastPageLoadError = nil
      return .merged
    } catch GridServiceError.cursorInvalid {
      guard generation == loadGeneration, activeScope == scope else { return .stale }
      isLoadingPage = false
      await recoverGroupedCursor(for: .remainder)
      return .merged
    } catch {
      guard generation == loadGeneration else { return .stale }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
      return .failed
    }
  }

  /// The successor fetch under Mark/Rating grouping: the ACTIVE scope's own cursor, never
  /// `/neighbours`. Advances an open loupe exactly as the neighbours merge does.
  private func pageActiveGroupedScope(advancingLoupeFrom imageID: Int) async
    -> NeighbourFetchOutcome
  {
    let session = loupeSession
    let outcome: NeighbourFetchOutcome
    if isInRemainder {
      outcome = await loadMoreRemainder()
    } else {
      guard let cursor = nextCursor else {
        loupeExhausted = true
        return .exhausted
      }
      guard !isLoadingPage else { return .failed }
      let generation = loadGeneration
      isLoadingPage = true
      defer { if generation == loadGeneration { isLoadingPage = false } }
      do {
        let page = try await service.images(query, cursor: cursor, limit: 100)
        guard generation == loadGeneration else { return .stale }
        ingestStreamPage(page.items, nextCursor: page.nextCursor, replacing: false)
        selection.pageAppended()
        lastPageLoadError = nil
        outcome = .merged
      } catch GridServiceError.cursorInvalid {
        guard generation == loadGeneration else { return .stale }
        isLoadingPage = false
        await recoverGroupedCursor(for: .stream)
        outcome = .merged
      } catch {
        guard generation == loadGeneration else { return .stale }
        lastPageLoadError = (error as? GridServiceError) ?? .unreachable
        return .failed
      }
    }
    guard outcome == .merged || outcome == .exhausted else { return outcome }
    let pool = actionableImages
    if let idx = pool.firstIndex(where: { $0.id == imageID }), pool.indices.contains(idx + 1) {
      loupeExhausted = false
      if isLoupeOpen, session == loupeSession, focusedImageID == imageID {
        focusedImageID = pool[idx + 1].id
      }
      return .merged
    }
    if (isInRemainder ? remainderCursor : nextCursor) == nil {
      loupeExhausted = true
      return .exhausted
    }
    return .merged
  }

  enum GroupedScope: Equatable, Sendable {
    case stream
    case remainder
  }

  /// Cursor-invalid recovery under Mark/Rating grouping (§2.5): re-page the grouped query from
  /// page one and APPEND only ids neither slice holds, after the retained tail, in server order.
  /// Nothing retained moves — a tile marked in place stays at its index — and the fresh cursor
  /// replaces the dead one at the first page that brought something new (or at the end).
  private func recoverGroupedCursor(for scope: GroupedScope) async {
    guard let groupBy = remainderGroupBy else { return }
    let generation = loadGeneration
    var cursor: String?
    for _ in 0..<Self.groupedRecoveryPageCap {
      let page: GridImagesPage
      do {
        page = try await service.images(query, cursor: cursor, limit: 100)
      } catch {
        guard generation == loadGeneration else { return }
        lastPageLoadError = (error as? GridServiceError) ?? .unreachable
        return
      }
      guard generation == loadGeneration else { return }
      let known = Set(images.map(\.id)).union(remainderImages.map(\.id))
      let cut = GroupRemainder.split(page.items, groupBy: groupBy)
      let freshStream = cut.stream.filter { !known.contains($0.id) }
      let freshRemainder = cut.remainder.filter { !known.contains($0.id) }
      switch scope {
      case .stream:
        images.append(contentsOf: freshStream)
        if !cut.remainder.isEmpty {
          if !remainderReached {
            remainderImages = freshRemainder
            remainderCursor = page.nextCursor
            remainderReached = true
          }
          nextCursor = nil
          lastPageLoadError = nil
          return
        }
        if !freshStream.isEmpty || page.nextCursor == nil {
          nextCursor = page.nextCursor
          lastPageLoadError = nil
          return
        }
      case .remainder:
        if !freshRemainder.isEmpty || page.nextCursor == nil {
          remainderImages.append(contentsOf: freshRemainder)
          remainderCursor = page.nextCursor
          lastPageLoadError = nil
          return
        }
      }
      guard let next = page.nextCursor else { return }
      cursor = next
    }
    lastPageLoadError = .cursorInvalid
  }

  /// Bounds a recovery re-page: 50 pages of 100 is far past any shoot the grid pages by hand.
  private static let groupedRecoveryPageCap = 50

  /// The foreground / notice-Retry / 409 refresh under Mark/Rating grouping (§2.5): membership
  /// and order are PRESERVED. It re-reads the stream up to the boundary (never past it) and
  /// patches each retained photograph's fields in place — marks, revisions, ratings — keeping the
  /// `group_key` it was placed under. No id is added, none dropped, nothing reordered; the headers
  /// stay the ones vouched for this query, so counts and tiles keep agreeing until a reconcile.
  private func refreshGroupedPreserving(generation: Int) async -> Bool {
    guard let groupBy = remainderGroupBy else { return false }
    var fresh: [Int: Components.Schemas.ImageSummary] = [:]
    var cursor: String?
    for _ in 0..<Self.groupedRecoveryPageCap {
      guard generation == loadGeneration else { return false }
      let page: GridImagesPage
      do {
        page = try await service.images(query, cursor: cursor, limit: Self.refreshPageLimit)
      } catch {
        guard generation == loadGeneration else { return false }
        lastPageLoadError = (error as? GridServiceError) ?? .unreachable
        return false
      }
      guard generation == loadGeneration else { return false }
      for item in page.items { fresh[item.id] = item }
      let reachedBoundary = page.items.contains {
        GroupRemainder.isRemainder(groupKey: $0.groupKey, groupBy: groupBy)
      }
      guard !reachedBoundary, let next = page.nextCursor else { break }
      cursor = next
    }
    func patched(_ old: Components.Schemas.ImageSummary) -> Components.Schemas.ImageSummary {
      guard var item = fresh[old.id] else { return old }
      item.groupKey = old.groupKey
      return item
    }
    images = images.map(patched)
    remainderImages = remainderImages.map(patched)
    publishRefreshedFocusAndUndo(actionable: actionableImages)
    return true
  }

  // MARK: - Scene entry (WP442 P12, IMGMGR-540): one truth, one transition

  /// THE only writer of `sceneEntry`. Runs synchronously, before any await, in this order; a
  /// `.retarget` (topology result) skips the selection/focus/loupe reset because the coordinator
  /// restores focus by rule right afterwards. It KEEPS the latch, undo, the query, the STREAM
  /// scroll anchor and the members cache.
  private func transitionScene(to next: GridEntry?, reason: SceneTransitionReason) {
    guard next != entry else { return }
    if reason != .retarget {
      selection.reset(.sceneTransition)
      focusedImageID = nil
      if isLoupeOpen { closeLoupe() }
    }
    conflictRecovery = nil
    dragSession = DragPaintSession()
    dismissGridPresentations()
    rows = []
    sceneScrollAnchor = nil
    sceneDestinationRetry = nil
    entry = next
    sceneRevision &+= 1
  }

  /// The store-bound presentations belong to the scope being left.
  private func dismissGridPresentations() {
    isTagEntryPresented = false
    isStatusPresented = false
    isSyncPresented = false
    isSceneMergePickerPresented = false
    isSceneAbsorbPickerPresented = false
    sceneEditError = nil
    sceneEditErrorKind = nil
    pendingSceneEdit = nil
  }

  /// A card tap: push the scene. Refused outside Scene mode and for a card that is not listed.
  func enterScene(_ stackID: Int) async {
    guard displayMode == .scene else { return }
    guard sceneRows.contains(where: { $0.displayID == .stack(stackID) }) else { return }
    transitionScene(to: .scene(SceneEntry(stackID: stackID)), reason: .userOpen)
    // A second enter while this scene's page is still on the wire joins that request rather
    // than asking again; only an enter with nothing in flight starts a new opening.
    if !sceneMembersInFlight.contains(stackID) { membershipToken[stackID, default: 0] &+= 1 }
    guard sceneMembers[stackID] == nil else { return }
    await fetchSceneMembers(stackID: stackID, cursor: nil)
  }

  /// Back (or any rule that leaves): the stream again. Leaves a scene or the remainder alike.
  ///
  /// IMGMGR-541 (§2.4 T1): Back out of the Mark remainder after a mark landed inside it is the
  /// R3-21 "return": the groups are reconciled from the server, so the row's count shrinks and
  /// the newly marked photograph lands in its section. Without a mark inside, Back costs nothing.
  func leaveScene(_ reason: SceneTransitionReason = .userBack) {
    let left = enteredRemainder
    let marked = remainderMarkedDuringVisit
    transitionScene(to: nil, reason: reason)
    remainderMarkedDuringVisit = false
    if reason == .userBack, left == .mark, marked {
      pendingReconcile = Task { await self.reconcileGrouping() }
    }
  }

  /// The general name for `leaveScene`: the entry may be a scene or the remainder.
  func leaveEntry(_ reason: SceneTransitionReason = .userBack) {
    leaveScene(reason)
  }

  /// The remainder row's tap (R3-21): entered like a scene. Refused before the stream reached the
  /// null bucket and while the headers do not vouch for a non-zero remainder.
  func enterRemainder() {
    guard let key = remainderGroupBy, remainderReached, let count = remainderCount, count > 0
    else { return }
    remainderEntryCount = count
    remainderMarkedDuringVisit = false
    transitionScene(to: .remainder(key), reason: .userOpen)
  }

  /// The count the remainder screen's title states, frozen at entry (ruling Q5).
  private(set) var remainderEntryCount = 0
  /// A mark landed inside the remainder during this visit (§2.4 T1).
  @ObservationIgnored private var remainderMarkedDuringVisit = false
  /// The reconcile a Back started, exposed so a test (and nothing else) can await it.
  @ObservationIgnored private(set) var pendingReconcile: Task<Void, Never>?

  /// The Mark/Rating reconcile (§2.4): headers dropped (the row hides rather than states a stale
  /// count), in-flight mark writes allowed to land (the lane), then the stream re-read to the
  /// boundary and the headers refetched. Membership and counts become the server's again.
  func reconcileGrouping() async {
    await acquireLaneQueueing()
    defer { releaseLane() }
    vouchedGroups = nil
    await reloadFirstPage(revalidatesEntry: false)
    await refreshGroupHeaders()
  }

  /// A folder row tap from any shell: always lands on the folder's stream, even for the same
  /// folder.
  func openShoot(folderID: Int, sourceTier: GridSourceTier? = nil) async {
    leaveScene(.shootOpened)
    // IMGMGR-541 (§2.4 T2): re-opening the SAME folder under Mark/Rating grouping is a "return":
    // it reconciles, where an ordinary same-folder refresh preserves membership (§2.5).
    if remainderGroupBy != nil, query.folderID == folderID, query.sourceTier == sourceTier {
      await reconcileGrouping()
      return
    }
    await selectShoot(folderID: folderID, sourceTier: sourceTier)
  }

  /// The ONE store entry for card focus: a card holding real focus means no photograph does.
  func cardDidTakeFocus(_ stackID: Int) {
    focusedImageID = nil
  }

  /// W1: packed rows from one grid instance; refused unless that instance is the active one.
  func publishRows(_ packed: [[GridDisplayID]], from scope: GridScope) {
    guard scope == activeScope else { return }
    rows = packed
  }

  /// W2: one scroll slot per scope. The stream slot is written only by a `.stream` instance; a
  /// scene slot write is dropped unless that scene is the entered one.
  func scrollAnchor(for scope: GridScope) -> GridDisplayID? {
    switch scope {
    case .stream: return gridScrollAnchor
    case .scene, .remainder: return sceneScrollAnchor
    }
  }

  func recordScrollAnchor(_ id: GridDisplayID, for scope: GridScope) {
    switch scope {
    case .stream:
      gridScrollAnchor = id
    case .scene(let stackID):
      guard enteredSceneID == stackID else { return }
      sceneScrollAnchor = id
    case .remainder(let key):
      guard enteredRemainder == key else { return }
      sceneScrollAnchor = id
    }
  }

  /// The scene screen's Retry: re-run a pending destination resolution, or revalidate.
  func retryEnteredScene() async {
    guard let id = enteredSceneID else { return }
    let generation = loadGeneration
    if let retry = sceneDestinationRetry, ownsNavigation(retry.owner) {
      sceneLoadFailed.remove(id)
      await resolveDestination(retry, dissolved: [], generation: generation)
      return
    }
    await revalidateEnteredScene(generation: generation)
  }

  /// B5: keep the entered scene on a reload unless the server says it is gone. Page 1 holding
  /// the card refetches its members; a card beyond page 1 is looked up and spliced back.
  private func revalidateEnteredScene(generation: Int) async {
    guard let id = enteredSceneID else { return }
    if let retry = sceneDestinationRetry, retry.owner.stackID == id {
      guard ownsNavigation(retry.owner) else { return }
      await resolveDestination(retry, dissolved: [], generation: generation)
      return
    }
    sceneLoadFailed.remove(id)
    if !sceneRows.contains(where: { $0.displayID == .stack(id) }) {
      do {
        let row = try await service.stackRow(stackID: id, query: query)
        guard generation == loadGeneration, enteredSceneID == id else { return }
        if !sceneRows.contains(where: { $0.displayID == .stack(id) }) {
          sceneRows.insert(
            .stack(row),
            at: SceneEditPlanner.insertionIndex(for: row.anchorTakenAt, in: sceneRows))
        }
      } catch GridServiceError.notFound {
        guard generation == loadGeneration, enteredSceneID == id else { return }
        leaveScene(.sceneGone)
        return
      } catch {
        guard generation == loadGeneration, enteredSceneID == id else { return }
        sceneLoadFailed.insert(id)
        return
      }
    }
    await fetchSceneMembers(stackID: id, cursor: nil)
  }

  /// Appear-driven membership paging: called when a member tile appears, it asks the ONE question
  /// the view cannot answer — "is this the last member currently loaded for some opened scene?" —
  /// and pages that scene if so.
  ///
  /// Deliberately not the brief's "more members" affordance. An explicit button would have to be
  /// a cell in the justified row (it has no aspect ratio and no pixels), i.e. a THIRD cell kind
  /// whose only job is to be tapped — a new gesture target in the one place this lane is trying
  /// to keep gesture targets to a minimum. Appearing at the tail is the same trigger the grid's
  /// own paging already uses, adds no tappable surface, and cannot be aimed at the wrong scene.
  /// Recorded as a deviation in the phase ledger.
  func loadMoreSceneMembersIfNeeded(afterMemberID imageID: Int) async {
    guard displayMode == .scene else { return }
    guard let stackID = sceneMembers.first(where: { $0.value.last?.id == imageID })?.key else {
      return
    }
    await loadMoreSceneMembers(stackID: stackID)
  }

  /// The rest of a long scene's membership. Appends in place; the card never moves.
  func loadMoreSceneMembers(stackID: Int) async {
    guard displayMode == .scene, openMembershipIDs.contains(stackID) else { return }
    guard case .more(let cursor) = sceneMemberCursors[stackID] else { return }
    await fetchSceneMembers(stackID: stackID, cursor: cursor)
  }

  /// One membership page, single-flighted per scene and generation-fenced like every other read
  /// here. `cursor == nil` is the first page (replaces), a cursor appends.
  private func fetchSceneMembers(stackID: Int, cursor: String?) async {
    // IMGMGR-542: single-flight per (scene, token) — a request from an EARLIER opening must not
    // block the reopened band's own request, or the band would wait on a page that is dropped.
    let token = membershipToken[stackID, default: 0]
    guard !(sceneMembersInFlight.contains(stackID) && inFlightToken[stackID] == token) else {
      return
    }
    sceneMembersInFlight.insert(stackID)
    inFlightToken[stackID] = token
    defer {
      if inFlightToken[stackID] == token {
        sceneMembersInFlight.remove(stackID)
        inFlightToken[stackID] = nil
      }
    }
    sceneLoadFailed.remove(stackID)
    bandLoadFailed.remove(stackID)
    let generation = loadGeneration
    do {
      let page = try await service.stackMembers(
        stackID: stackID, cursor: cursor, limit: Self.sceneMemberPageLimit)
      // The window may have been replaced while the membership was on the wire — its rows belong
      // to a result set the reader has left, exactly as a late grid page would.
      guard generation == loadGeneration else { return }
      // And the reader may have closed the scene (or its band) in the meantime, or closed and
      // reopened it: splicing members nobody asked for — or an old opening's page — is refused.
      guard openMembershipIDs.contains(stackID), membershipToken[stackID, default: 0] == token
      else { return }
      if cursor == nil, page.items.isEmpty, page.nextCursor == nil {
        // An empty membership is never shown: the scene is gone (B5).
        sceneGone(stackID)
        return
      }
      if cursor == nil {
        sceneMembers[stackID] = page.items
      } else {
        let held = sceneMembers[stackID] ?? []
        let known = Set(held.map(\.id))
        sceneMembers[stackID] = held + page.items.filter { !known.contains($0.id) }
      }
      sceneMemberCursors[stackID] = page.nextCursor.map(SceneMemberCursor.more) ?? .exhausted
      lastPageLoadError = nil
    } catch GridServiceError.notFound {
      guard generation == loadGeneration, openMembershipIDs.contains(stackID),
        membershipToken[stackID, default: 0] == token
      else { return }
      sceneGone(stackID)
    } catch {
      guard generation == loadGeneration, membershipToken[stackID, default: 0] == token else {
        return
      }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
      if enteredSceneID == stackID { sceneLoadFailed.insert(stackID) }
      if openBandIDs.contains(stackID) { bandLoadFailed.insert(stackID) }
    }
  }

  @ObservationIgnored private var inFlightToken: [Int: Int] = [:]

  /// A scene whose membership came back empty or 404: the entered scene is left (B5); a band of
  /// it closes, and nothing else moves.
  private func sceneGone(_ stackID: Int) {
    if openBandIDs.contains(stackID) { closeBands([stackID]) }
    if enteredSceneID == stackID { leaveScene(.sceneGone) }
  }

  // MARK: - Peek bands (IMGMGR-542, R3-22)

  /// The card's chevron: open this scene's band under its card's row, or close it. Refused outside
  /// Scene mode, outside the stream and for a card that is not listed. Never enters the scene and
  /// never names a route.
  func togglePeekBand(_ stackID: Int) async {
    guard displayMode == .scene, activeScope == .stream else { return }
    guard sceneRows.contains(where: { $0.displayID == .stack(stackID) }) else { return }
    if openBandIDs.contains(stackID) {
      closeBands([stackID])
      return
    }
    peekBands.append(PeekBand(stackID: stackID, anchorAtOpen: scrollAnchor(for: .stream)))
    membershipToken[stackID, default: 0] &+= 1
    bandLoadFailed.remove(stackID)
    guard sceneMembers[stackID] == nil else { return }
    await fetchSceneMembers(stackID: stackID, cursor: nil)
  }

  /// Esc: close the most recently opened band. A no-op with none open.
  func closeMostRecentBand() {
    guard let last = peekBands.last else { return }
    closeBands([last.stackID])
  }

  /// No page and no membership read in flight, and every open band fully loaded — the state the
  /// scroll measurement waits for before it times anything.
  var bandsSettled: Bool {
    !isLoadingPage && sceneMembersInFlight.isEmpty
      && peekBands.allSatisfy { sceneMemberCursors[$0.stackID] == .exhausted }
  }

  /// More › Collapse all.
  func collapseAllBands() {
    closeBands(openBandIDs)
  }

  /// Whether Esc closes a band right now. Only on the bare Scene stream: never in Flat, never
  /// inside an entered scene or the remainder, never with the loupe open, and never while a sheet
  /// or popover is up over the grid — Esc is that presentation's own key there.
  var canCloseBand: Bool {
    !peekBands.isEmpty && displayMode == .scene && activeScope == .stream && !isLoupeOpen
      && !hasGridPresentation
  }

  /// A sheet or popover raised over the grid. The store-held flags plus the chrome popovers that
  /// keep their own `isPresented` and report it through `notePopover(_:isPresented:)`.
  var hasGridPresentation: Bool {
    isTagEntryPresented || isShortcutHelpPresented || isStatusPresented || isSyncPresented
      || isTriagePresented
      || isSceneMergePickerPresented || isSceneAbsorbPickerPresented || sceneEditError != nil
      || !openGridPopovers.isEmpty
  }

  /// The grid chrome's own popovers (Arrange, Filters) that are up right now.
  private(set) var openGridPopovers: Set<String> = []

  func notePopover(_ id: String, isPresented: Bool) {
    if isPresented { openGridPopovers.insert(id) } else { openGridPopovers.remove(id) }
  }

  private func closeBands(_ ids: [Int]) {
    let closing = peekBands.filter { ids.contains($0.stackID) }
    guard !closing.isEmpty else { return }
    let closedMembers = Set(
      closing.flatMap { band in (sceneMembers[band.stackID] ?? []).map(\.id) })
    let before = displayRows(for: .stream).map(\.id)
    let current = scrollAnchor(for: .stream)
    peekBands.removeAll { ids.contains($0.stackID) }
    for id in ids { bandLoadFailed.remove(id) }
    let surviving = Set(displayRows(for: .stream).map(\.id))
    let restore = GridScrollAnchor.anchorAfterClosing(
      current: current, closing: closing,
      members: Dictionary(
        closing.map { ($0.stackID, (sceneMembers[$0.stackID] ?? []).map(\.id)) },
        uniquingKeysWith: { a, _ in a }),
      surviving: surviving, streamOrder: before)
    if let focused = focusedImageID, closedMembers.contains(focused) { focusedImageID = nil }
    selection.removeHidden(Array(closedMembers))
    bandCloseAnchor = restore
    if let restore { recordScrollAnchor(restore, for: .stream) }
    revalidateBandAnchors()
    bandCloseRevision &+= 1
  }

  /// Every stored anchor that no longer names a rendered row is reset, with the same
  /// surviving-ID validation the close uses: a band's open-time anchor → nil; the stream anchor →
  /// its band's card only if that card survives, else the nearest surviving predecessor, else
  /// left for the next visibility report to replace.
  func revalidateBandAnchors(previousOrder: [GridDisplayID]? = nil) {
    let rows = displayRows(for: .stream).map(\.id)
    let surviving = Set(rows)
    for i in peekBands.indices {
      if let anchor = peekBands[i].anchorAtOpen, !surviving.contains(anchor) {
        peekBands[i].anchorAtOpen = nil
      }
    }
    let listed = Set(sceneRows.map(\.displayID))
    peekBands.removeAll { !listed.contains(.stack($0.stackID)) }
    guard let anchor = scrollAnchor(for: .stream), !surviving.contains(anchor) else { return }
    let owner: GridDisplayID? = {
      guard case .image(let id) = anchor else { return nil }
      return sceneMembers.first { $0.value.contains { $0.id == id } }.map { .stack($0.key) }
    }()
    if let replacement = GridScrollAnchor.firstSurviving(
      [owner], surviving: surviving, predecessorOf: anchor,
      streamOrder: previousOrder ?? rows)
    {
      recordScrollAnchor(replacement, for: .stream)
    } else {
      gridScrollAnchor = nil
    }
  }

  /// IMGMGR-261: the picks inside a COLLAPSED scene, read once per card, for DISPLAY ONLY.
  ///
  /// A bespoke read rather than a reuse of `fetchSceneMembers`, and deliberately so: that method
  /// writes `sceneMembers`, which is the array that makes photographs actionable. This one writes
  /// a different array, follows NO cursor (the first membership page and nothing beyond it — a
  /// card is a summary, and a summary does not page), and stores only the picks. So the worst a
  /// bug here can do is draw the wrong thumbnails on a card; it cannot put a photograph nobody
  /// opened into the reach of a mark.
  ///
  /// Nothing is read at all while the preference is off — the toggle gates the REQUEST, not just
  /// the rendering, so OFF costs exactly what it cost before this story existed.
  ///
  /// A failed read is a non-event and deliberately not retried: the card simply keeps the badges
  /// it already has, which is the state it had before the switch existed. Nothing here writes
  /// `lastPageLoadError` either — a decoration that could not be fetched is not a reason to tell
  /// the reader the grid is broken.
  func loadInlinePicksIfNeeded(stackID: Int) async {
    guard displayMode == .scene, preferences.picksInGroups else { return }
    // An OPEN scene draws its members for real; the card's summary is not the question there.
    guard !sceneExpanded.contains(stackID) else { return }
    guard sceneInlinePicks[stackID] == nil, !sceneInlinePicksInFlight.contains(stackID) else {
      return
    }
    sceneInlinePicksInFlight.insert(stackID)
    defer { sceneInlinePicksInFlight.remove(stackID) }
    let generation = loadGeneration
    guard
      let page = try? await service.stackMembers(
        stackID: stackID, cursor: nil, limit: Self.sceneMemberPageLimit)
    else { return }
    // The window may have been replaced, or the reader may have opened the scene, while this was
    // on the wire — the same two fences the membership read itself carries.
    guard generation == loadGeneration, !sceneExpanded.contains(stackID) else { return }
    sceneInlinePicks[stackID] = page.items.filter { $0.mark.state == .pick }
  }

  /// Which OPENED scenes hold any of these photographs — the question a finished write asks so it
  /// can re-read exactly the cards whose badges or cover it may have changed.
  private func scenesHolding(_ imageIDs: [Int]) -> [Int] {
    let wanted = Set(imageIDs)
    return sceneMembers.compactMap { stackID, members in
      members.contains { wanted.contains($0.id) } ? stackID : nil
    }.sorted()
  }

  /// "The cover follows the pick" — after a mark, an undo or a tag write touching a scene's
  /// member, re-read that scene's row and merge it IN PLACE.
  ///
  /// ONE request per DISTINCT touched scene, and only the five fields a write can change:
  /// `member_count`, `has_pick`, `picked_count`, `matched_count` and `representative`. The cover
  /// is the SERVER's election, never re-derived here (IMGMGR-241): the derivation's first clause
  /// is "an explicit cover override wins while it is still picked", and no field on this payload
  /// says whether a scene HAS one — a client that guessed would disagree with the server on
  /// exactly the scenes someone had curated. Everything else about the
  /// row is left exactly as it was — its POSITION in the stream (the stored anchor never moves
  /// for a mark), its expansion, the selection, and the page cursor. A reload would be the easy
  /// way to get a fresh cover and would cost the reader their scroll position, their open scenes
  /// and their selection on every press of P.
  ///
  /// A row whose `matched_count` has fallen to zero is still merged and still rendered: a mutated
  /// row stays in the window until an explicit reload, and the badge simply tells the truth
  /// about it. A refresh that fails is a non-event — the card keeps the numbers it has.
  private func refreshScenesFor(_ imageIDs: [Int]) async {
    guard displayMode == .scene else { return }
    let touched = scenesHolding(imageIDs)
    guard !touched.isEmpty else { return }
    // IMGMGR-261: the card summary describes exactly the state this write just changed, so it
    // stops being an answer the moment the write lands. Dropped rather than patched locally —
    // the strip is a capped read of the server's own membership, and re-reading it when the card
    // is next drawn is both cheaper to reason about and correct for the case a local patch gets
    // wrong (a batch that picks one member and un-picks another leaves `picked_count` unmoved
    // while changing every thumbnail). Done BEFORE the row re-read below and independently of
    // it, so a failed re-read still cannot leave a stale summary standing.
    for stackID in touched { sceneInlinePicks[stackID] = nil }
    let generation = loadGeneration
    for stackID in touched {
      guard let fresh = try? await service.stackRow(stackID: stackID, query: query) else {
        continue
      }
      guard generation == loadGeneration else { return }
      for index in sceneRows.indices {
        guard case .stack(var row) = sceneRows[index], row.stackId == stackID else { continue }
        row.memberCount = fresh.memberCount
        row.hasPick = fresh.hasPick
        row.pickedCount = fresh.pickedCount
        row.matchedCount = fresh.matchedCount
        row.representative = fresh.representative
        sceneRows[index] = .stack(row)
      }
    }
  }

  // MARK: - Scene editing (WP14 P4, IMGMGR-277)

  /// Why the last scene edit did not happen, or nil. Rendered as an ALERT beside the account
  /// sheet's own (`AccountSheetView`'s `.alert(presenting:)` is the app's one typed-decision
  /// idiom) — never as a banner: the connectivity/stale-cache banner surface is somebody else's
  /// and a refusal that changed nothing is a question, not a status line.
  private(set) var sceneEditError: SceneEditFailure?

  /// One edit at a time. A second activation while the first is on the wire is a mistake, not a
  /// queue — the same answer the web gives (`stackEditBusy`), and the reason it is not the mark
  /// lane is that a topology edit is not a mark: it takes no preconditions, writes no revision and
  /// never enters the undo slot (there is no un-split endpoint, so the slot would promise a
  /// rollback nothing can perform).
  private(set) var isSceneEditInFlight = false

  /// THE FROZEN PAYLOAD. Set only when a 503 refused an edit before it started, and replayed
  /// VERBATIM — the stack id and the image ids as they were at the FIRST attempt, never
  /// recomputed. A retry that re-read the selection or the focus would run a DIFFERENT edit than
  /// the one the reader asked for, which is exactly what a reader does while they wait for a busy
  /// folder.
  ///
  /// READABLE, deliberately: the alert captures this value when it is BUILT and carries it in its
  /// retry action, because SwiftUI runs the dismissal binding's setter before that action — see
  /// `SceneEditAlert`.
  private(set) var pendingSceneEdit: SceneEditRequest?

  /// WHICH edit the standing refusal belongs to. Kept beside the failure rather than read off
  /// `pendingSceneEdit`, because that payload is dropped for every refusal except the busy one —
  /// so a conflict, which is exactly the case whose wording depends on the edit, would have no
  /// kind left to key on (codex gate, blocker).
  private(set) var sceneEditErrorKind: SceneEditKind?

  /// The merge-target sheet. A plain `var` like `isTagEntryPresented`/`isStatusPresented`, for the
  /// same reason: the menu entry that raises it is declared as data and reaches this screen only
  /// through the store.
  var isSceneMergePickerPresented = false

  /// The absorb's own target sheet (IMGMGR-347). A second flag rather than a mode on the first,
  /// because the two are raised from rows with different subjects and SwiftUI presents a sheet
  /// off a boolean binding: one flag with a mode beside it can be set inconsistently, two cannot.
  var isSceneAbsorbPickerPresented = false

  /// The subject of every scene-edit action, derived once (plan Decision 2).
  var sceneEditSubject: SceneEditSubject? {
    guard displayMode == .scene else { return nil }
    return SceneEditPlanner.subject(
      expanded: sceneExpanded, members: sceneMembers, focusedImageID: focusedImageID)
  }

  /// The scenes "Merge into…" offers: the same folder's OTHER loaded scenes, in capture order.
  var sceneMergeTargets: [SceneMergeTarget] {
    guard let subject = sceneEditSubject else { return [] }
    return SceneEditPlanner.mergeTargets(rows: sceneRows, subjectStackID: subject.stackID)
  }

  /// The extraction set: the selection intersected with the SUBJECT scene's loaded membership, in
  /// membership order. Membership SELECTION — never a client-side topology mutation.
  var sceneExtractionSelection: [Int] {
    guard let subject = sceneEditSubject else { return [] }
    return SceneEditPlanner.selectedMembers(
      of: subject.stackID, members: sceneMembers, selected: selection.members)
  }

  var canMergeFocusedScene: Bool { !sceneMergeTargets.isEmpty && !isSceneEditInFlight }

  // MARK: - Absorbing a loose photograph (IMGMGR-347, the client half of IMGMGR-289)

  /// The absorb's subject: the focused photograph when the stream is serving it LOOSE. Nil for
  /// every state the other three rows are offered in, and they are nil for this one — the two
  /// subjects are mutually exclusive by construction, since a scene member is never an `.image`
  /// row of the stream.
  var sceneAbsorbSubject: SceneAbsorbSubject? {
    guard displayMode == .scene else { return nil }
    return SceneEditPlanner.absorbSubject(rows: sceneRows, focusedImageID: focusedImageID)
  }

  /// The scenes the focused loose photograph may join: its own folder's loaded scenes.
  var sceneAbsorbTargets: [SceneMergeTarget] {
    guard let subject = sceneAbsorbSubject else { return [] }
    return SceneEditPlanner.absorbTargets(rows: sceneRows, folderID: subject.folderID)
  }

  /// Why the absorb cannot run, or nil when it can — the ONE derivation the row's enablement and
  /// the row's words both read (P11's single-predicate discipline), so a row that says "focus a
  /// loose photograph" while being tappable is not a state this store can be in.
  var sceneAbsorbUnavailability: SceneAbsorbUnavailability? {
    guard sceneAbsorbSubject != nil else { return .noLoosePhotographFocused }
    guard !sceneAbsorbTargets.isEmpty else { return .noSceneInTheSameFolderLoaded }
    guard !isSceneEditInFlight else { return .anotherEditIsRunning }
    return nil
  }

  var canAbsorbFocusedPhoto: Bool { sceneAbsorbUnavailability == nil }

  func presentSceneAbsorbPicker() {
    guard canAbsorbFocusedPhoto else { return }
    isSceneAbsorbPickerPresented = true
  }

  /// Put the focused loose photograph into the scene the reader picked.
  ///
  /// EXACTLY the focused photograph, never the selection: the selection is a membership concept
  /// this lane does not touch (ADR-0005 / ADR-0008 leave it alone), and the row's enablement is
  /// derived from the focus alone — so sending anything else would mean the control's subject and
  /// the request's subject were two different things. Absorbing several at once is the server's
  /// capability (`image_ids` is a list) and stays available for a later ticket to arm.
  ///
  /// The target is re-derived through the SAME list the sheet was built from, so a scene that has
  /// left the window while the sheet stood open is a no-op rather than a request — the merge
  /// picker's own rule.
  func absorbFocusedPhoto(into targetStackID: Int) async {
    guard let subject = sceneAbsorbSubject,
      sceneAbsorbTargets.contains(where: { $0.stackID == targetStackID })
    else { return }
    isSceneAbsorbPickerPresented = false
    await runSceneEdit(
      .absorb(
        stackID: targetStackID, imageIDs: [subject.imageID], focusedImageID: subject.imageID))
  }

  /// A split BEFORE the first member would leave a memberless half, which the server refuses as
  /// `empty_split_side`. The first member is on the first membership page by construction, so this
  /// is knowable here and the control is disabled rather than offered as a guaranteed refusal.
  var canSplitFocusedScene: Bool {
    guard let subject = sceneEditSubject, !isSceneEditInFlight else { return false }
    guard let first = sceneMembers[subject.stackID]?.first else { return false }
    return first.id != subject.focusedImageID
  }

  var canExtractSelectionFromScene: Bool {
    guard let subject = sceneEditSubject, !isSceneEditInFlight else { return false }
    let complete = sceneMemberCursors[subject.stackID] == .exhausted
    return SceneEditPlanner.extractionIsOffered(
      chosen: sceneExtractionSelection.count,
      loaded: sceneMembers[subject.stackID]?.count ?? 0, membershipComplete: complete)
  }

  func presentSceneMergePicker() {
    guard canMergeFocusedScene else { return }
    isSceneMergePickerPresented = true
  }

  /// Join the subject scene with one the reader picked in the sheet. The target is re-derived
  /// through the SAME list the sheet was built from — never a second check, and a target that has
  /// left the window while the sheet stood open is a no-op rather than a request.
  func mergeFocusedScene(into targetStackID: Int) async {
    guard let subject = sceneEditSubject,
      sceneMergeTargets.contains(where: { $0.stackID == targetStackID })
    else { return }
    isSceneMergePickerPresented = false
    await runSceneEdit(
      .merge(
        stackIDs: [subject.stackID, targetStackID], focusedImageID: subject.focusedImageID))
  }

  /// Cut the subject scene BEFORE the focused member.
  func splitFocusedScene() async {
    guard let subject = sceneEditSubject, canSplitFocusedScene else { return }
    await runSceneEdit(.split(stackID: subject.stackID, atImageID: subject.focusedImageID))
  }

  /// Take the subject scene's SELECTED members into a scene of their own.
  func extractSelectionFromFocusedScene() async {
    guard let subject = sceneEditSubject, canExtractSelectionFromScene else { return }
    await runSceneEdit(
      .extract(
        stackID: subject.stackID, imageIDs: sceneExtractionSelection,
        focusedImageID: subject.focusedImageID))
  }

  /// Run the edit the busy answer refused, exactly as it was asked the first time — over the
  /// payload the CALLER captured, never over what this store happens to hold when it runs.
  ///
  /// That is the whole difference between a retry that works and one that silently does nothing:
  /// the only caller is the alert's Retry button, and SwiftUI runs the alert's dismissal — which
  /// clears `pendingSceneEdit` — BEFORE the button's action. A no-argument version of this method
  /// read that cleared value and sent nothing (codex gate, blocker 1; RED-proven).
  func replaySceneEdit(_ request: SceneEditRequest) async {
    sceneEditError = nil
    sceneEditErrorKind = nil
    pendingSceneEdit = nil
    await runSceneEdit(request)
  }

  func dismissSceneEditError() {
    sceneEditError = nil
    sceneEditErrorKind = nil
    pendingSceneEdit = nil
  }

  /// One scene edit: the call, the coordinator its confirmation asks for, and the typed refusal
  /// otherwise. Nothing local changes on a refusal — every one of them means ZERO writes server-
  /// side, so the window the reader is looking at is still the truth.
  private func runSceneEdit(_ request: SceneEditRequest) async {
    guard !isSceneEditInFlight else { return }
    // WP442 P12 (§2.3a): who may navigate when this edit completes — captured BEFORE the POST.
    let owner = SceneEditOwner(stackID: enteredSceneID, revision: sceneRevision)
    isSceneEditInFlight = true
    defer { isSceneEditInFlight = false }
    do {
      let result = try await performSceneEdit(request)
      sceneEditError = nil
      sceneEditErrorKind = nil
      pendingSceneEdit = nil
      await reloadAfterTopologyEdit(result, request: request, owner: owner)
    } catch let error as StackEditError {
      // Whatever the refusal is, it belongs to THIS edit — set once, beside the failure, rather
      // than in each branch below.
      sceneEditErrorKind = request.kind
      switch error {
      case .busy(let seconds):
        // The ONLY branch that keeps the payload: "ask again, unchanged" is what a busy folder
        // means, and the retry must ask the same question.
        pendingSceneEdit = request
        sceneEditError = .busy(retryAfterSeconds: seconds)
      case .conflict(let reason):
        pendingSceneEdit = nil
        sceneEditError = .conflict(reason)
      case .refused:
        pendingSceneEdit = nil
        sceneEditError = .refused
      case .vanished:
        pendingSceneEdit = nil
        sceneEditError = .vanished
      case .unreachable:
        pendingSceneEdit = nil
        sceneEditError = .unreachable
      }
    } catch {
      sceneEditErrorKind = request.kind
      pendingSceneEdit = nil
      sceneEditError = .unreachable
    }
  }

  private func performSceneEdit(_ request: SceneEditRequest) async throws
    -> Components.Schemas.StackEditResult
  {
    switch request {
    case .merge(let stackIDs, _):
      return try await service.mergeStacks(stackIDs: stackIDs)
    case .split(let stackID, let atImageID):
      return try await service.splitStack(stackID: stackID, atImageID: atImageID)
    case .extract(let stackID, let imageIDs, _):
      return try await service.extractFromStack(stackID: stackID, imageIDs: imageIDs)
    case .absorb(let stackID, let imageIDs, _):
      return try await service.absorbIntoStack(stackID: stackID, imageIDs: imageIDs)
    }
  }

  /// How many membership pages a completion will walk before it stops. A bound, not an expected
  /// size: a scene is transitive gap clustering, so it can be long, but a server that kept handing
  /// back cursors must not be able to spin this forever.
  private static let sceneMemberCompletionPageCap = 20

  /// THE TOPOLOGY COORDINATOR (plan §Phase 4).
  ///
  /// A topology edit changes which rows EXIST and where they sit — the anchors are recomputed
  /// server-side — so a local patch is not available to the client at any price and a reload is
  /// the honest answer. What the reload costs is the reader's place, and the four steps here are
  /// what buy it back:
  ///
  /// 1. **Reload** page one of the scene stream (`reloadFirstPage`, which drops the whole scene
  ///    window including every expansion).
  /// 2. **Reopen** the RESULT stacks and everything that was open and did not dissolve — only
  ///    those the reloaded page actually contains, since a scene the edit removed from the stream
  ///    has no card to sit under any more.
  /// 3. **Complete** the membership of the EDITED scenes past page one. Opening a scene is a
  ///    tap's contract — one page, the rest on demand — which is right for looking at a scene and
  ///    wrong for the one just reorganised: a merge is precisely the gesture after which "how many
  ///    photographs are in here now" is the question being asked. Only the edited scenes, never
  ///    every reopened one (IMGMGR-254's own reasoning on the web).
  /// 4. **Restore focus** by rule (`SceneEditPlanner.restoredFocus`), and prune from the selection
  ///    anything the new window cannot show — the same invariant `refreshScenePage` keeps.
  private func reloadAfterTopologyEdit(
    _ result: Components.Schemas.StackEditResult, request: SceneEditRequest,
    owner: SceneEditOwner
  ) async {
    // IMGMGR-542: the reload rebuilds the window, which closes every band; the bands whose card
    // survives the edit are reopened below and their stored anchors revalidated.
    let bandsBeforeEdit = peekBands
    let streamOrderBeforeEdit = displayRows(for: .stream).map(\.id)
    // Step 1: the KEEP reload; the destination is resolved below, not by revalidation.
    await reloadFirstPage(revalidatesEntry: false)
    let generation = loadGeneration
    // Step 2: every result stack is in the window (data, regardless of who navigates).
    var present = Set(
      sceneRows.compactMap { row -> Int? in
        guard case .stack(let stack) = row else { return nil }
        return stack.stackId
      })
    // ENSURE, unconditionally (codex gate, blocker 2; RED-proven). The reload rebuilds the window
    // from page ONE, and the scene the reader just edited is wherever they had scrolled to — so a
    // result stack can be perfectly real and simply not in the reloaded page. Reopening only what
    // that page happens to contain loses it entirely: not open, not completed, no focus, and the
    // selection pruned out from under the reader. One `GET /api/stacks/{id}` per missing result
    // puts the row back where its own anchor says it belongs, which is what the rest of this
    // method then treats exactly like any other row.
    for stackID in result.stackIds where !present.contains(stackID) {
      guard let row = try? await service.stackRow(stackID: stackID, query: query) else { continue }
      guard generation == loadGeneration else { return }
      sceneRows.insert(
        .stack(row), at: SceneEditPlanner.insertionIndex(for: row.anchorTakenAt, in: sceneRows))
      present.insert(stackID)
    }
    guard generation == loadGeneration else { return }
    reinstateBands(bandsBeforeEdit)
    // Step 3: navigation belongs to the scene the edit started in, at its revision.
    if ownsNavigation(owner) {
      let pending = SceneDestinationRetry(
        owner: owner, candidates: result.stackIds, anchorImageID: request.anchorImageID)
      await resolveDestination(pending, dissolved: result.dissolvedStackIds, generation: generation)
    } else {
      await restoreEnteredScene(dissolved: result.dissolvedStackIds, generation: generation)
    }
    guard generation == loadGeneration else { return }
    await rereadBandMembers(generation: generation)
    guard generation == loadGeneration else { return }
    revalidateBandAnchors(previousOrder: streamOrderBeforeEdit)
  }

  /// IMGMGR-542: after a topology edit, the bands that were open before it whose card is still
  /// listed — in their opening order — and nothing else. A band whose card the edit dissolved
  /// stays closed.
  private func reinstateBands(_ before: [PeekBand]) {
    let listed = Set(sceneRows.map(\.displayID))
    peekBands = before.filter { listed.contains(.stack($0.stackID)) }
    for band in peekBands { membershipToken[band.stackID, default: 0] &+= 1 }
  }

  /// Re-reads the first membership page of every open band the window rebuild emptied.
  private func rereadBandMembers(generation: Int) async {
    for band in peekBands where sceneMembers[band.stackID] == nil {
      await fetchSceneMembers(stackID: band.stackID, cursor: nil)
      guard generation == loadGeneration else { return }
    }
  }

  /// §2.3a: ownership is re-checked after EVERY await of the coordinator.
  private func ownsNavigation(_ owner: SceneEditOwner) -> Bool {
    owner.stackID != nil && enteredSceneID == owner.stackID && sceneRevision == owner.revision
  }

  /// Steps 4, 4b and 5: load the candidates (to the completion cap, never through the members
  /// cache), choose the destination, then commit synchronously after the last ownership check.
  private func resolveDestination(
    _ pending: SceneDestinationRetry, dissolved: [Int], generation: Int
  ) async {
    let candidates = pending.candidates
    var loaded: [Int: CandidateMembers] = [:]
    var failed: Set<Int> = []
    var holder: Int?
    for stackID in candidates {
      let read = await loadCandidateMembers(stackID: stackID)
      guard generation == loadGeneration else { return }
      guard ownsNavigation(pending.owner) else {
        await restoreEnteredScene(dissolved: dissolved, generation: generation)
        return
      }
      guard let read else {
        failed.insert(stackID)
        continue
      }
      loaded[stackID] = read
      if read.items.contains(where: { $0.id == pending.anchorImageID }) {
        holder = stackID
        break
      }
    }
    let target: Int?
    if let holder {
      target = holder
    } else if candidates.count <= 1 {
      target = candidates.first
    } else if failed.isEmpty {
      target = candidates[0]
    } else {
      // Step 4b, UNRESOLVED: the anchor may sit in a part that was not read. No retarget and no
      // install — the entered scene shows `.failed` with Retry, never another part's members.
      sceneDestinationRetry = pending
      if let entered = pending.owner.stackID { sceneLoadFailed.insert(entered) }
      pruneSelectionOutside(actionableImages)
      return
    }
    // Step 5: commit. Every owned commit drops the retry record first (r6).
    sceneDestinationRetry = nil
    // B5: an empty membership is never shown. A destination whose read came back empty and
    // exhausted is gone, exactly as on a first entry — never an entered screen stuck on Loading.
    let targetRead = target.flatMap { loaded[$0] }
    let readEmpty = targetRead?.items.isEmpty == true && targetRead?.cursor == .exhausted
    guard let target, !readEmpty else {
      leaveScene(.sceneGone)
      pruneSelectionOutside(actionableImages)
      return
    }
    transitionScene(to: .scene(SceneEntry(stackID: target)), reason: .retarget)
    if let read = loaded[target] {
      sceneMembers[target] = read.items
      sceneMemberCursors[target] = read.cursor
      sceneLoadFailed.remove(target)
    } else {
      sceneLoadFailed.insert(target)
    }
    let actionable = actionableImages
    pruneSelectionOutside(actionable)
    focusedImageID = SceneEditPlanner.restoredFocus(
      anchorImageID: pending.anchorImageID, actionable: actionable,
      resultStackIDs: candidates, members: sceneMembers)
    if focusedImageID == nil, isLoupeOpen { closeLoupe() }
  }

  /// Step 6, not owned: restore what is entered NOW (the reload dropped its members), or leave
  /// it on server evidence that it dissolved. Never navigates otherwise.
  private func restoreEnteredScene(dissolved: [Int], generation: Int) async {
    if let now = enteredSceneID {
      if dissolved.contains(now) {
        leaveScene(.sceneGone)
      } else if sceneMembers[now] == nil, !sceneMembersInFlight.contains(now) {
        await revalidateEnteredScene(generation: generation)
      }
    }
    let actionable = actionableImages
    pruneSelectionOutside(actionable)
    if let focused = focusedImageID, !actionable.contains(where: { $0.id == focused }) {
      focusedImageID = nil
      if isLoupeOpen { closeLoupe() }
    }
  }

  /// A candidate's membership, walked to the completion cap. It NEVER writes `sceneMembers`,
  /// `sceneMemberCursors` or `sceneMembersInFlight`, so it cannot race the single-flight pager.
  private func loadCandidateMembers(stackID: Int) async -> CandidateMembers? {
    var items: [Components.Schemas.ImageSummary] = []
    var cursor: String?
    var pages = 0
    repeat {
      let page: StackMemberPageResult
      do {
        page = try await service.stackMembers(
          stackID: stackID, cursor: cursor, limit: Self.sceneMemberPageLimit)
      } catch {
        return nil
      }
      let known = Set(items.map(\.id))
      items += page.items.filter { !known.contains($0.id) }
      cursor = page.nextCursor
      pages += 1
    } while cursor != nil && pages <= Self.sceneMemberCompletionPageCap
    return CandidateMembers(
      items: items, cursor: cursor.map(SceneMemberCursor.more) ?? .exhausted)
  }

  // MARK: - Focus / arrow navigation

  /// WP12: navigation moves between PHOTOGRAPHS. A scene card occupies a cell in a packed row
  /// like anything else, but focus is an image concept — the mark bar, the loupe and every
  /// shortcut act on `focusedImageID` — so a card is navigated PAST rather than into, and these
  /// three helpers are what "past" means. In flat mode every cell is `.image`, so each of them
  /// degenerates to the arithmetic this method used before and behaviour is unchanged.
  private func firstImageID(in row: [GridDisplayID], from start: Int, step: Int) -> Int? {
    var index = start
    while row.indices.contains(index) {
      if let id = row[index].imageID { return id }
      index += step
    }
    return nil
  }

  /// The photograph nearest to `column` in `row`, searching outward — so Up/Down from a tile
  /// above a card lands on the closest real photograph rather than doing nothing.
  private func nearestImageID(in row: [GridDisplayID], toward column: Int) -> Int? {
    guard !row.isEmpty else { return nil }
    let clamped = min(max(column, 0), row.count - 1)
    for offset in 0..<row.count {
      if let id = row[safe: clamped - offset]?.imageID { return id }
      if let id = row[safe: clamped + offset]?.imageID { return id }
    }
    return nil
  }

  func moveFocus(_ direction: GridArrowDirection) {
    let pool = actionableImages
    guard !pool.isEmpty else { return }
    guard let current = focusedImageID else {
      focusedImageID = pool.first?.id
      return
    }
    // Fall back to flat left/right-only stepping if the view hasn't published packed rows yet
    // (e.g. before the first layout pass) — still correct, just without row-relative up/down.
    guard !rows.isEmpty,
      let rowIndex = rows.firstIndex(where: { $0.contains(.image(current)) }),
      let colIndex = rows[rowIndex].firstIndex(of: .image(current))
    else {
      guard let idx = pool.firstIndex(where: { $0.id == current }) else { return }
      let delta = (direction == .left) ? -1 : (direction == .right ? 1 : 0)
      let target = idx + delta
      guard delta != 0, pool.indices.contains(target) else { return }
      focusedImageID = pool[target].id
      return
    }
    switch direction {
    case .left:
      if let target = firstImageID(in: rows[rowIndex], from: colIndex - 1, step: -1) {
        focusedImageID = target
      } else if rowIndex > 0,
        let target = firstImageID(
          in: rows[rowIndex - 1], from: rows[rowIndex - 1].count - 1, step: -1)
      {
        focusedImageID = target
      }
    case .right:
      if let target = firstImageID(in: rows[rowIndex], from: colIndex + 1, step: 1) {
        focusedImageID = target
      } else if rowIndex + 1 < rows.count,
        let target = firstImageID(in: rows[rowIndex + 1], from: 0, step: 1)
      {
        focusedImageID = target
      }
    case .up:
      guard rowIndex > 0 else { return }
      if let target = nearestImageID(in: rows[rowIndex - 1], toward: colIndex) {
        focusedImageID = target
      }
    case .down:
      guard rowIndex + 1 < rows.count else { return }
      if let target = nearestImageID(in: rows[rowIndex + 1], toward: colIndex) {
        focusedImageID = target
      }
    }
  }

  /// Shift+advance's "advance": the next image in flat load order — distinct from the arrow
  /// keys' grid-relative `.right`, which a caller could reasonably also equate to "next", but
  /// this stays a separate named step so a culling advance never silently depends on
  /// `columnsPerRow` being set correctly by the view.
  private func advanceToNext() {
    let pool = actionableImages
    guard !pool.isEmpty else { return }
    guard let current = focusedImageID, let idx = pool.firstIndex(where: { $0.id == current })
    else {
      focusedImageID = pool.first?.id
      return
    }
    guard pool.indices.contains(idx + 1) else { return }
    focusedImageID = pool[idx + 1].id
  }

  // MARK: - Tile interaction (tap / long-press)

  /// A tap on a CELL. WP12: the parameter is a display id, so the one place a card's tap is
  /// interpreted is here, and it is interpreted as "open me" and nothing else — never a mark,
  /// never a selection entry, whatever mode the grid is in. A latched lock does not change
  /// that, either verb: there is no image id in a `.stack` to apply a mark to.
  func tapCell(_ id: GridDisplayID) async {
    switch id {
    case .image(let imageID):
      await tapTile(imageID)
    case .stack(let stackID):
      // ADR-0005: a card is never a mark target; a tap pushes its scene in every mode.
      await enterScene(stackID)
    }
  }

  /// A long-press on a CELL. On a photograph it enters Select with that photograph selected; on a
  /// scene card it does NOTHING — the card is not selectable, so there is no Select entry it
  /// could make. Written as an explicit, doc-commented no-op rather than an absent branch,
  /// because "a gesture that silently does nothing" is a thing a reader has to be able to find in
  /// the code: the card's own accessibility hint says the same in the UI.
  func longPressCell(_ id: GridDisplayID) {
    guard case .image(let imageID) = id else { return }
    longPressTile(imageID)
  }

  func tapTile(_ imageID: Int) async {
    // The LATCHED VERB decides the mark — one branch for both locks, never a `.pick` literal a
    // Dislike Lock would have to be a second copy of.
    if let verb = pickLock.latchedVerb {
      await applyMark(verb.markState, to: [imageID])
      return
    }
    switch selection.mode {
    case .select:
      selection.toggle(imageID)
    case .browse:
      // P5: a tap on the ALREADY-focused tile is the "second tap" that opens the loupe (spec
      // "3220 §2.2"); a tap on a DIFFERENT tile just moves focus, same as before — so opening
      // still needs two separate taps, never a system double-tap gesture.
      if focusedImageID == imageID {
        openLoupe(on: imageID)
      } else {
        focusedImageID = imageID
      }
    }
  }

  func longPressTile(_ imageID: Int) {
    // Pin (e): entering Select while latched unlatches first; the transition itself never
    // applies a mark.
    if pickLock.latchedVerb != nil {
      pickLock.unlatch()
    }
    selection.enterSelectViaLongPress(imageID: imageID)
  }

  /// One drag session, OWNED by the store (not the view) so `PrimaryPointerDragGesture`'s
  /// SwiftUI closures never need `inout` access across an escaping `Task` boundary. The view
  /// calls `beginPointerDrag()` on gesture start (and on end, for the next gesture to start
  /// clean) and `pointerDragCrossed(_:)` for every point the recognizer reports.
  private var dragSession = DragPaintSession()

  func beginPointerDrag() {
    dragSession = DragPaintSession()
  }

  /// iPad pointer drag over the grid (diff-gate round 2, blocker 3): one call per tile the
  /// pointer crosses, wired to a real `PrimaryPointerDragGesture` in `GridView`. "Once per
  /// crossed tile per drag" is enforced by `dragSession`, reset at the start of each gesture.
  /// WP12: the drag lane takes a DISPLAY id. A drag that crosses a scene card is recorded as
  /// crossed (so the dedup session is honest about the path the pointer took) and then produces
  /// nothing — a `.stack` has no image id, so neither the latched branch nor the Select branch
  /// below has anything to name. That is the actionability boundary holding for the one gesture
  /// that cannot be stopped at its own site: a pointer drag does not choose which cells it
  /// crosses.
  func pointerDragCrossed(_ id: GridDisplayID) async {
    guard dragSession.crossedTile(id) else { return }
    guard let imageID = id.imageID else { return }
    if let verb = pickLock.latchedVerb {
      await enqueueLatchedCrossing(imageID, verb: verb)
    } else if selection.mode == .select {
      selection.addFromDrag(imageID)
    }
  }

  /// WP14 (IMGMGR-250): a crossing the person's pointer actually made, waiting for the mutation
  /// lane. `verb` and `scope` travel WITH the id — the verb because one write carries one mark,
  /// the scope because a crossing describes a photograph in the query it was made in, and a
  /// query the reader has since left is not one to write into. The fence is the QUERY, not
  /// `loadGeneration`: an authoritative refresh advances the generation while staying in the
  /// same scope, and a lifecycle re-read is no reason to throw away a gesture.
  private struct PendingCrossing {
    var imageID: Int
    var verb: LatchVerb
    var scope: GridImagesQuery
  }

  private var pendingLatchedCrossings: [PendingCrossing] = []
  private var isDrainingLatchedCrossings = false

  /// The latched drag's own write path.
  ///
  /// It used to be a bare `applyMark`, whose `tryAcquireLane()` REFUSES while the lane is busy —
  /// so every tile crossed while the previous crossing's network write was in flight produced
  /// nothing at all: no optimistic apply, no error, no retry. A drag is not a re-tappable button
  /// (the whole point of a lock is that the pointer keeps moving), and over the VPN the crossing
  /// cadence beats the round trip as a matter of course, so "refuse" meant "drop most of the
  /// gesture".
  ///
  /// Crossings are QUEUED and COALESCED instead: while one write is in flight the crossings
  /// behind it accumulate, and the drain sends the whole leading run of same-verb ids as ONE
  /// `setMarkState` — fewer round trips than the per-tile writes it replaces, and not one
  /// crossing lost. The drain holds the lane across its own `capturePriorSnapshots`, so it can
  /// see which of the ids it queued survived the wait and report the rest
  /// (`recordDroppedWrites`): the queueing path's own pruning hazard (IMGMGR-204) is closed here
  /// rather than inherited.
  private func enqueueLatchedCrossing(_ imageID: Int, verb: LatchVerb) async {
    // Never loaded, never writable: the documented loaded-only membership boundary, unchanged
    // and deliberately NOT reported — a scene card's cover id reaching this far must stay the
    // silent no-op `aCoverIdCannotBeMarkedEvenIfNamed` asserts it is.
    guard !writableIDs(among: [imageID]).isEmpty else { return }
    pendingLatchedCrossings.append(PendingCrossing(imageID: imageID, verb: verb, scope: query))
    await drainLatchedCrossings()
  }

  /// One drain at a time: a crossing that arrives while the drain is mid-write simply lands in
  /// the queue the running drain picks up on its next turn. Reentrancy here would be the very
  /// concurrent-mutation race the lane exists to prevent.
  ///
  /// EVERY decision is made AFTER the lane is acquired, and that ordering is the whole design
  /// (diff-gate round 1, blockers 1 and 2). The lane WAIT is precisely the window in which the
  /// drag keeps producing crossings, and it is also a window in which the query can change:
  ///
  /// - Forming the batch before the wait made the crossing that started the drain wait ALONE
  ///   while the rest of the drag piled up behind it, so the release produced two writes rather
  ///   than one — and the second overwrote the single undo slot, leaving the first tile the
  ///   reader painted marked but un-undoable. Read the queue after the wait and the whole run
  ///   coalesces into the one write it should always have been.
  /// - Filtering by scope before the wait let a query change land inside it, so priors were
  ///   captured in the NEW scope for ids latched in the OLD one — a write into a scope the reader
  ///   never painted, or an id legitimately absent from it mislabelled as a dropped write.
  private func drainLatchedCrossings() async {
    guard !isDrainingLatchedCrossings else { return }
    isDrainingLatchedCrossings = true
    defer { isDrainingLatchedCrossings = false }
    while !pendingLatchedCrossings.isEmpty {
      await acquireLaneQueueing()
      // A crossing made in a scope the reader has since left is discarded — not written, and not
      // reported either, the same posture `performMark`'s own stale-generation escape takes.
      pendingLatchedCrossings.removeAll { $0.scope != query }
      guard let verb = pendingLatchedCrossings.first?.verb else {
        // The wait outlived every crossing it was holding the lane for.
        releaseLane()
        continue
      }
      let batch = pendingLatchedCrossings.prefix(while: { $0.verb == verb }).map(\.imageID)
      pendingLatchedCrossings.removeFirst(batch.count)
      let priors = capturePriorSnapshots(for: batch)
      recordDroppedWrites(submitted: Set(batch), written: Set(priors.map(\.imageID)))
      _ = await performMark(verb.markState, priors: priors)
      releaseLane()
    }
  }

  // MARK: - Pick Lock / Dislike Lock (WP13 P2, IMGMGR-222)

  /// The ONE entry point both latch-capable bar buttons call — `GridView.latchButton(_:)` passes
  /// the verb, so the view holds no rule of its own about what a press means, and Dislike is a
  /// latch-capable control on exactly the terms Pick is (owner decision 4, 2026-08-30). That
  /// single funnel is what makes "the two locks are mutually exclusive" a fact about
  /// `PickLockState` rather than a rule this coordinator has to police.
  func activateLatchButton(_ verb: LatchVerb) async {
    // Lock ENTRY stays disabled while Select is active (pin e) — but the button itself is no
    // longer disabled with it: in Select mode a mark control is an ordinary bulk mark on the
    // selection, and the latch machine is never consulted, so a double-tap there cannot latch.
    // The two used to be one modifier on the control; they are two different rules and are now
    // written as two.
    guard selection.mode != .select else {
      await applyMarkToTarget(verb.markState)
      return
    }
    switch pickLock.activate(verb: verb) {
    case .applyMark:
      await applyMarkToTarget(verb.markState)
    case .latch, .unlatch:
      break
    }
  }

  /// The amendment's discoverable "Lock Pick" / "Lock Dislike" long-press menu command — gate's
  /// unasked issue. Same mutual-exclusion guard as the button's own path (pin e);
  /// `PickLockState.forceLatch(_:)` is itself a no-op if a lock of EITHER verb is already on, so
  /// this is safe to invoke unconditionally and cannot produce two simultaneous locks.
  func lockFromMenu(_ verb: LatchVerb) {
    guard selection.mode != .select else { return }
    pickLock.forceLatch(verb)
  }

  // MARK: - Select mode

  func enterSelectExplicitly() {
    if pickLock.latchedVerb != nil { pickLock.unlatch() }
    selection.enterSelectExplicitly()
  }

  func done() {
    pickLock.exit()
    selection.reset(.doneOrEsc)
  }

  // MARK: - Shortcuts (P4: arrows, P, X, Shift+advance, T, Z; P5 adds Space/Enter and U)

  func handlePickShortcut(shiftHeld: Bool) async {
    await handleMarkShortcut(.pick, shiftHeld: shiftHeld)
  }

  func handleDislikeShortcut(shiftHeld: Bool) async {
    await handleMarkShortcut(.dislike, shiftHeld: shiftHeld)
  }

  /// U — active in the grid AND the loupe (same scene-level dispatch either way; `AppCommands`
  /// does not know or care which screen is currently on top). Shift+U also advances, mirroring
  /// P/X (`ShortcutCatalog`'s own doc comment: "Shift held on P/X/U means 'mark and advance'").
  func handleClearShortcut(shiftHeld: Bool) async {
    await handleMarkShortcut(.none, shiftHeld: shiftHeld)
  }

  /// The one body `P`/`X`/`U` share. There are two lanes, and which one a press takes is decided
  /// by the SURFACE, never by the key:
  ///
  /// - `Shift` held is the GRID's own deliberate mark-and-advance, byte-identical to what
  ///   shipped: the same empty-target guard, the same `applyMarkToTarget`, the same
  ///   `advanceToNext()`. It is never composed with the loupe cadence — a Shift press moves
  ///   exactly one frame whatever the toggle says (the phase's Do-NOT list, pinned by
  ///   `shiftAdvanceInTheLoupeIsUnchangedByTheCadence`).
  /// - A BARE press while the loupe is open IS "marking in the loupe" — IMGMGR-214's own AC — so
  ///   it rides the same seam the loupe mark bar's buttons ride, cadence and commit-fence and
  ///   all, rather than being the one way to mark in the loupe that never advances (diff-gate r1,
  ///   blocker 2). The write target is identical either way: entering the loupe resets selection
  ///   to browse (`openLoupe` -> `selection.reset(.enteredLoupe)`), so `markTargetImageIDs` there
  ///   IS `[focusedImageID]`, which is exactly what `applyLoupeMark` writes.
  /// - A bare press in the GRID is unchanged and reads no loupe preference
  ///   (`theGridMarkPathNeverAutoAdvances`).
  private func handleMarkShortcut(_ state: MarkStateValue, shiftHeld: Bool) async {
    if shiftHeld {
      guard !markTargetImageIDs.isEmpty else { return }
      await applyMarkToTarget(state)
      advanceToNext()
      return
    }
    if isLoupeOpen {
      await applyLoupeMark(state)
      return
    }
    guard !markTargetImageIDs.isEmpty else { return }
    await applyMarkToTarget(state)
  }

  /// Space/Enter — opens the loupe on the focused image. Deliberately unconditional on
  /// Pick-Lock/Select state (unlike the tap path, which a latched tap or a Select-mode tap can
  /// never reach at all): the keyboard fast path stays a simple, uniform "open what's focused",
  /// same posture `PickLockState.activateFromKeyboard()` already documents for `P`.
  func handleOpenShortcut() {
    guard let id = focusedImageID else { return }
    openLoupe(on: id)
  }

  func handleUndoShortcut() async {
    await undoLastMark()
  }

  func handleTagShortcut() {
    guard !tagTargetImageIDs.isEmpty else { return }
    isTagEntryPresented = true
  }

  /// WP13 P4 (IMGMGR-215): raise the shortcut help sheet. ONE method rather than call sites
  /// setting the flag. Since IMGMGR-464 (WP32 P2, owner ruling 2026-10-02) its only caller is
  /// `GridKeyboardActions.showShortcutHelp`, which the View menu's "Keyboard Shortcuts" row (⌘/)
  /// and that row's silent `?` twin dispatch into; Compact's options-row button is gone.
  func showShortcutHelp() {
    isShortcutHelpPresented = true
  }

  // MARK: - More menu actions (WP13 P5a, IMGMGR-221)

  /// Raise the read-only Status sheet and start its read. The flag flips SYNCHRONOUSLY so the
  /// menu entry is never a no-op even when the network is gone — the sheet comes up and says
  /// what it knows.
  func presentStatus() {
    isStatusPresented = true
    statusReadFailed = false
    Task { await loadStatus() }
  }

  /// IMGMGR-545: raise the Sync sheet. The sheet reads and writes through `syncService`.
  func presentSync() {
    isSyncPresented = true
  }

  /// The sync routes over this store's own client.
  var syncService: SyncService { service.syncService }

  /// `GET /api/status`, through the SAME generated client every other call uses. Read-only by
  /// construction: this store exposes no maintenance mutation at all, and `POST /api/reindex`
  /// is wired nowhere in this app.
  func loadStatus() async {
    do {
      statusSnapshot = try await service.statusService.status()
      statusReadFailed = false
    } catch {
      statusSnapshot = nil
      statusReadFailed = true
    }
  }

  /// Copy for Lightroom: the marked set's filename STEMS onto the local pasteboard, plus a
  /// confirmation that states the scope. `GET /api/marks/export` answers for the WHOLE marked
  /// set, never the browse scope, and can be truncated — `MarksExportCopy` is where that
  /// fidelity is expressed, and it is the only place the message text is built.
  ///
  /// Nothing is written when the export is empty: an empty pasteboard would silently destroy
  /// whatever the reader had copied before, in exchange for nothing.
  func copyMarkedFilenamesForLightroom() async {
    guard !isCopyingMarksForLightroom else { return }
    isCopyingMarksForLightroom = true
    defer { isCopyingMarksForLightroom = false }
    do {
      let export = try await service.marksExport()
      if export.count > 0 {
        pasteboard.write(MarksExportCopy.pasteboardPayload(export))
      }
      marksCopyMessage = MarksExportCopy.confirmation(export)
    } catch {
      marksCopyMessage = "Couldn't reach the library to copy the marked filenames."
    }
  }

  func dismissMarksCopyMessage() {
    marksCopyMessage = nil
  }

  /// A tag targets exactly what a mark targets: ONE rule, expressed once. The shipped defect
  /// (IMGMGR-223) was precisely a second copy of the rule drifting from the first — this
  /// property used to fall back to the focused photograph on an EMPTY Select, so an explicit
  /// Select with nothing chosen tagged whatever happened to be focused, while `GridView` read
  /// the same property as non-empty and left the Tag control enabled.
  var tagTargetImageIDs: [Int] { markTargetImageIDs }

  // MARK: - Mark targets (WP13 P1)

  /// THE images a grid mark control writes to right now. Pick, Dislike, Clear and Tag all read
  /// this ONE property, so a control can never write to something other than what the screen
  /// says is targeted.
  ///
  /// The MODE decides, not the emptiness. In Select mode the selection IS the target and there
  /// is no fallback to the focused photograph — not even when the selection is empty:
  /// `enterSelectExplicitly()` starts with an EMPTY membership, so a `!members.isEmpty` fallback
  /// marks a photograph the reader never selected while the mode row reads "0 selected". A
  /// Select mode that refuses is better than one that writes to something else.
  ///
  /// ORDERED by `actionableImages` position, never `Array(selection.members)`: `members` is a
  /// `Set` whose iteration order is unspecified, and this order reaches the wire, the undo
  /// entry's prior list and the conflict-recovery batch.
  ///
  /// The `actionableImages` filter IS the actionable-only write boundary, and it is the same
  /// pool `capturePriorSnapshots` resolves against — so the control's target and the store's
  /// preconditions cannot disagree.
  var markTargetImageIDs: [Int] {
    switch selection.mode {
    case .select:
      return actionableImages.map(\.id).filter { selection.members.contains($0) }
    case .browse:
      return focusedImageID.map { [$0] } ?? []
    }
  }

  /// How many photographs the next mark would write to — the ACTIONABLE membership, not
  /// `selection.members.count`, so the number the Select row states is exactly the number the
  /// next Pick acts on even when a member has stopped being visible.
  var selectedCount: Int { markTargetImageIDs.count }

  /// Every purely selection-consuming control (Clear, Tag) disables together, derived from the
  /// one target property — never from `selection.members`, which is what would let the enabled
  /// state and the write target disagree. Pick and Dislike are NOT among them: each owns a lock
  /// entry that is meaningful with nothing focused, so they follow `isLatchControlDisabled`.
  var isMarkActionUnavailable: Bool { markTargetImageIDs.isEmpty }

  /// Pick and Dislike are the two controls that are not purely writes: in BROWSE each also owns
  /// its own lock entry (the double-tap and its "Lock Pick"/"Lock Dislike" chrome twin), which is
  /// meaningful with nothing focused — a latched tap acts on the tile it lands on. So they are
  /// disabled only where they would be a pure no-op write: Select mode with an empty selection.
  /// Lock ENTRY stays disabled through Select (pin e) in `activateLatchButton`'s own guard, which
  /// is why the two conditions are no longer the single modifier they used to share.
  ///
  /// WP13 P2: Dislike moved off `isMarkActionUnavailable` onto this rule for exactly the reason
  /// Pick already was — under the old rule a browse-mode Dislike with nothing focused was
  /// disabled, so its double-tap could never reach the latch machine at all.
  var isLatchControlDisabled: Bool { selection.mode == .select && markTargetImageIDs.isEmpty }

  /// The ONE entry point the grid's mark controls and the `P`/`X`/`U` shortcuts share: the
  /// control names the STATE, the store derives the TARGETS. No control builds an id list of its
  /// own — every `applyMark` call site passing a single focused id is exactly how Select mode
  /// shipped as a tagging-only mode.
  ///
  /// An empty target writes nothing: `applyMark` refuses an empty precondition set on its own
  /// (`capturePriorSnapshots` returns nothing to submit), so the refusal is one rule in one
  /// place rather than a guard each control has to remember.
  func applyMarkToTarget(_ state: MarkStateValue) async {
    await applyMark(state, to: markTargetImageIDs)
  }

  /// WP13 P8 (IMGMGR-214): the loupe mark bar's ONE entry point — its Pick, Dislike and Clear
  /// all come through here, and the advance-on-mark cadence hangs off `applyMark`'s COMMITTED
  /// answer rather than off the button press, so a refused, rolled-back or conflicted write
  /// never moves the frame. It lives on the store, not in the view, because the cadence is a
  /// rule about mutations rather than about a button — `GridStoreTests` drives it directly.
  ///
  /// The GRID's own mark path (`applyMarkToTarget`, `handlePickShortcut` and its siblings)
  /// never calls this: `Shift`+P/X/U is the grid's own deliberate mark-and-advance, and this
  /// phase leaves it exactly as it was.
  ///
  /// The advance is `loupeNext()`, the loupe's own flat-order step — at the true end of the
  /// pool that fetches forward neighbours and, finding none, latches `loupeExhausted` and
  /// leaves the frame where it is. The loupe is NEVER closed by an advance.
  @discardableResult
  func applyLoupeMark(_ state: MarkStateValue) async -> Bool {
    guard let markedID = focusedImageID else { return false }
    // The SECOND site of the same class as the neighbours-completion fence below (codex gate
    // round 1, blocker 1, enumerated rather than fixed one instance at a time): this guard also
    // spans an await, and a close-then-reopen on the same image satisfies both of its original
    // conditions. Those are the only two awaits in the loupe's advance path — `loupeNext`'s
    // local branch and `loupePrevious` are synchronous, so nothing else can complete into a
    // session that did not ask.
    let session = loupeSession
    let committed = await applyMark(state, to: [markedID])
    guard committed, preferences.autoAdvanceOnMark else { return committed }
    // Diff-gate r1, blocker 1: the advance is fenced to the frame this call actually MARKED and
    // to the loupe still being the surface. The mark bar's own controls disable while a write is
    // in flight, but Close and the prev/next chrome do not — so between the await starting and
    // returning, the reader can have closed the loupe (an advance would then move GRID focus) or
    // stepped to another frame (an advance would skip past the one they deliberately chose).
    // Neither is a cadence. The mutation itself always stands; only the advance is withheld.
    guard isLoupeOpen, session == loupeSession, focusedImageID == markedID else { return committed }
    await loupeNext()
    return committed
  }

  /// Any effective tier change resets selection (pin: "any effective filter/tier/tree change").
  func setRowHeight(_ newValue: GridRowHeight) {
    guard rowHeight != newValue else { return }
    rowHeight = newValue
    selection.reset(.queryGenerationChange)
  }

  /// IMGMGR-551 (R3-7): the grid's layout. Unlike a thumbnail-size step this resets nothing: the
  /// same photographs in the same order are only drawn differently, so the selection, the focus and
  /// the query stay as they are and nothing is fetched.
  func setLayoutStyle(_ newValue: GridLayoutStyle) {
    guard layoutStyle != newValue else { return }
    layoutStyle = newValue
  }

  // MARK: - Mark mutation (revision-precondition path; optimistic; 409-rollback)

  /// P5 BINDING (premise-gate fold addendum): `applyMark`/`undoLastMark` each snapshot `images`
  /// synchronously, then await the network before reconciling or rolling back — a second call
  /// that starts before the first's await returns would otherwise snapshot the first's still-
  /// uncommitted optimistic state, and out-of-order responses could make a rollback/undo
  /// describe a state that never actually committed. This flag makes a concurrent second call a
  /// REFUSED no-op (no snapshot is ever taken while `true`) — the sanctioned alternative to a
  /// serialization queue the addendum names ("serialize... or disable mark chrome while one is
  /// in flight"). The view also disables the mark bar's controls while this is true, same
  /// "the guard is the source of truth independent of the view" posture `activateLatchButton`'s
  /// own `selection.mode != .select` guard already uses.
  ///
  /// P6: the SAME flag is now the "one ordered mark/refresh lane" (plan item 2) --
  /// `undoLastMark` still REFUSES via `tryAcquireLane()` (unchanged posture), while
  /// `authoritativeRefresh()` and `addTag` (diff-gate round 2, B5: a submitted tag must never be
  /// silently dropped by a busy lane -- its entry sheet is already dismissed by the time the
  /// write runs) QUEUE via `acquireLaneQueueing()` instead of refusing. IMGMGR-586: `applyMark`
  /// queues too now — a re-tappable button did not make a dropped tap visible, and picks were
  /// lost that way — except on a photograph whose own write is pending (`pendingMarkIDs`).
  private(set) var isMutatingMark = false

  /// FIFO of calls waiting for a busy lane -- see `acquireLaneQueueing()`/`releaseLane()`.
  private var laneWaiters: [CheckedContinuation<Void, Never>] = []

  /// How many calls are queued BEHIND the lane's current holder.
  ///
  /// Exposed for the same reason `isMutatingMark` and `groupHeadersIdentity` are — a test has to
  /// be able to see it. "This call has genuinely reached the lane and suspended" is the milestone
  /// every queueing-interleaving test needs to gate on: without it a test can only guess with
  /// `Task.yield()`, and for the latched-drag queue a guess that lands wrong does not merely
  /// weaken the assertion, it HANGS — an unscheduled first crossing makes the next awaited
  /// crossing the drain owner, which then blocks on the very lane the test has not released yet.
  /// A pure read of the FIFO above; nothing acts on it.
  var laneWaiterCount: Int { laneWaiters.count }

  /// IMGMGR-586: photographs an `applyMark` call is writing or waiting to write. A tap on one of
  /// these is refused (the IMGMGR-475 rule: an accidental double tap must not flip a pick back);
  /// a tap on any other photograph queues.
  private var pendingMarkIDs: Set<Int> = []

  /// The REFUSING acquisition `undoLastMark` uses: `false` (no-op for the caller) if
  /// the lane is already held by anything (another mutation OR a refresh/tag-write in progress).
  private func tryAcquireLane() -> Bool {
    guard !isMutatingMark else { return false }
    isMutatingMark = true
    return true
  }

  /// The QUEUEING acquisition `authoritativeRefresh()` and `addTag` use: waits for the lane
  /// instead of refusing. A waiter that is resumed by `releaseLane()` is already holding the lane
  /// at that point -- the handoff never sets `isMutatingMark` false in between, so nothing else
  /// can slip in ahead of a queued caller once the current holder releases.
  private func acquireLaneQueueing() async {
    guard isMutatingMark else {
      isMutatingMark = true
      return
    }
    await withCheckedContinuation { continuation in
      laneWaiters.append(continuation)
    }
  }

  /// Releases the lane -- handing it DIRECTLY to the oldest queued waiter if one exists (the
  /// waiter proceeds already holding it), otherwise actually freeing it.
  private func releaseLane() {
    guard laneWaiters.isEmpty else {
      laneWaiters.removeFirst().resume()
      return
    }
    isMutatingMark = false
  }

  // MARK: - Refused-write recovery (P6, IMGMGR-116: the adjudicated 409 state machine)

  /// Nil except while one rejected batch's recovery is live. See `ConflictRecovery`'s own doc
  /// comment for the state machine; `handleConflict` is the only place this is set to `.reading`.
  private(set) var conflictRecovery: ConflictRecovery?

  /// The compact tile-local surface's membership query -- the grid, the focused-image/mark-bar
  /// area, and the loupe filmstrip all key off this SAME set (plan item 3.3: "tile-local in the
  /// grid; beside the focused image/mark bar and on its filmstrip thumbnail in the loupe").
  var changedElsewhereImageIDs: Set<Int> {
    guard case .identified(_, _, let changedIDs) = conflictRecovery else { return [] }
    return changedIDs
  }

  /// Entered from `applyMark`/`addTag`'s `.conflict` catch (both still HOLD the lane, their own
  /// `defer { releaseLane() }` not yet run) and from `undoLastMark`'s per-group catch (diff-gate
  /// round 2, B4: undo's own stale-precondition refusals now route through this SAME machine
  /// rather than a bare rollback) -- so the re-read here goes through the lane-less
  /// `performAuthoritativeRefresh()` core, never `authoritativeRefresh()` itself (which would try
  /// to re-acquire the very lane this call is still inside of and deadlock).
  private func handleConflict(intent: ConflictIntent, batch: [ConflictBatchEntry]) async {
    // Item 2: "Clear/invalidate the undo slot ... on refusal recovery" -- unconditionally,
    // before the re-read even starts, since an existing undo entry's priors are already suspect
    // the instant a write anywhere in this batch was refused for being stale. Also correctly
    // abandons an interrupted multi-group undo's OWN slot (B4 scope decision, phase ledger).
    undo.clear()
    await performRecoveryReread(intent: intent, batch: batch)
  }

  /// `Retry Refresh` (plan item 6) from `.readFailed` -- a fresh top-level entry point (the
  /// original mutation call has long since returned), so THIS acquires the lane itself, refusing
  /// like any other user-initiated mutation action if something else is in flight.
  func retryConflictRefresh() async {
    guard case .readFailed(let intent, let batch) = conflictRecovery else { return }
    guard tryAcquireLane() else { return }
    defer { releaseLane() }
    await performRecoveryReread(intent: intent, batch: batch)
  }

  /// The shared re-read + diff, run by both `handleConflict` (lane already held by the caller)
  /// and `retryConflictRefresh` (lane held by ITS OWN acquisition just above). Builds
  /// `freshMarkViews` (B6) from the refreshed `images` where present, falling back to a per-id
  /// `service.detail(imageID:)` (a sanctioned, existing read) for an id the active filter no
  /// longer shows -- Apply Again must work for that id too, not silently skip it.
  private func performRecoveryReread(intent: ConflictIntent, batch: [ConflictBatchEntry]) async {
    conflictRecovery = .reading(intent: intent, batch: batch)
    let refreshed = await performAuthoritativeRefresh()
    guard refreshed else {
      // `performAuthoritativeRefresh` itself discards on a racing scope change (B1) by returning
      // false without publishing -- in that case the scope change already cleared
      // `conflictRecovery` to nil directly (`selectShoot`/`applyFilterChange`), so this check
      // leaves that nil alone rather than overwriting it with a stale `.readFailed`. A GENUINE
      // read failure (no scope change) leaves `conflictRecovery` untouched at `.reading`, so the
      // check passes and `.readFailed` is set correctly.
      guard case .reading = conflictRecovery else { return }
      conflictRecovery = .readFailed(intent: intent, batch: batch)
      return
    }
    // The generation THIS successful refresh just published under (B1) -- used below to detect
    // a scope change racing the per-id detail fetches that can follow.
    let generation = loadGeneration
    // The shared projection, not `images`: in Scene mode the refreshed photographs live in the
    // loose rows and the opened scenes' member strips, and a recovery that read `images` here
    // would find nothing and fall through to a per-id `detail()` fetch for every id in the batch.
    let freshMarkByID = Dictionary(
      uniqueKeysWithValues: actionableImages.map { ($0.id, $0.mark) })
    var freshMarkViews: [Int: FreshMarkSnapshot] = [:]
    var changed = Set<Int>()
    // Diff-gate round 3, B6: a FAILED per-id detail() read must never produce a silent PARTIAL
    // `.identified` -- that let Apply Again clear the recovery and either issue NO write at all
    // (a singleton batch, since `freshMarkViews` would have nothing to resubmit) or a silent
    // partial retry (a mixed batch, quietly dropping just the failed id). Any such failure aborts
    // the WHOLE attempt to `.readFailed` instead, retryable via Retry Refresh, exactly like a
    // failure of the list re-read itself above.
    var requiredReadFailed = false
    for entry in batch {
      if let mark = freshMarkByID[entry.imageID] {
        freshMarkViews[entry.imageID] = FreshMarkSnapshot(
          state: MarkStateValue(mark.state), tags: mark.tags ?? [], revision: mark.revision)
        if mark.revision != entry.revisionSubmitted { changed.insert(entry.imageID) }
      } else {
        do {
          let detail = try await service.detail(imageID: entry.imageID)
          guard generation == loadGeneration else { return }
          freshMarkViews[entry.imageID] = FreshMarkSnapshot(
            state: MarkStateValue(detail.mark.state), tags: detail.mark.tags ?? [],
            revision: detail.mark.revision)
          if detail.mark.revision != entry.revisionSubmitted { changed.insert(entry.imageID) }
        } catch {
          requiredReadFailed = true
          break
        }
      }
    }
    guard generation == loadGeneration else { return }  // a scope change raced the detail fetches
    guard !requiredReadFailed else {
      conflictRecovery = .readFailed(intent: intent, batch: batch)
      return
    }
    // Item 3.3's named fallback: "If the diff finds no differing image -- e.g. a revision raced
    // back -- fall back to marking the whole batch" rather than silently showing nothing refused.
    if changed.isEmpty { changed = Set(batch.map(\.imageID)) }
    conflictRecovery = .identified(
      intent: intent, freshMarkViews: freshMarkViews, changedIDs: changed)
  }

  /// `Apply Again` (plan item 5): resubmits the REJECTED intent using the recovery's OWN
  /// `freshMarkViews` (B6) -- never `images` directly, so an id the active filter excludes still
  /// resubmits correctly. Never called automatically (item 5: "Never auto-reapply") -- only this
  /// explicit call site exists, wired to the banner's button.
  func applyConflictAgain() async {
    guard case .identified(let intent, let freshMarkViews, _) = conflictRecovery else { return }
    conflictRecovery = nil
    switch intent {
    case .setState(let state):
      let priors = freshMarkViews.map { id, fresh in
        PriorMarkSnapshot(imageID: id, state: fresh.state, revisionBefore: fresh.revision)
      }
      guard !priors.isEmpty else { return }
      await applyMark(state, to: priors.map(\.imageID), explicitPriors: priors)
    case .addTag(let tag):
      let priors = freshMarkViews.map { id, fresh in
        PriorTagSnapshot(imageID: id, tags: fresh.tags, revisionBefore: fresh.revision)
      }
      guard !priors.isEmpty else { return }
      await addTag(tag, to: priors.map(\.imageID), explicitPriors: priors)
    }
  }

  /// `Keep Server Version` (plan item 5): dismisses the recovery surface with no further write --
  /// `images` already carries server truth from the re-read, so there is nothing left to do.
  func dismissConflictRecovery() {
    conflictRecovery = nil
  }

  /// Applies `state` to every id in `imageIDs`. Preconditions are normally derived from
  /// `actionableImages`, via `capturePriorSnapshots` — the projection of "photographs a gesture
  /// may act on", NOT the raw `images` array this comment used to name: an id outside that pool
  /// (a collapsed scene's member, a cover, an id the current window no longer holds) is silently
  /// skipped, and THAT is the actionable-only write boundary, enforced here rather than trusted
  /// to every caller — `explicitPriors` overrides this for
  /// exactly one caller (`applyConflictAgain`, diff-gate round 2 B6): a conflict-recovery retry
  /// must resubmit for every originally-rejected id INCLUDING one the active filter no longer
  /// shows, using the FRESH markview the recovery's own re-read already captured for it.
  ///
  /// WP13 P8 (IMGMGR-214): it ANSWERS now, because `await mark; then advance` cannot otherwise
  /// tell a commit from a rollback — every failure is handled internally here, so a caller that
  /// hung an advance off the button press would advance past a refused write. `true` is returned
  /// only from the branch that commits (the one that increments `mutationCommitCount`) AND is
  /// still in the scope it started in; the refused-lane guard, the empty-priors guard, the
  /// `catch`, and either stale-generation escape all answer `false`. A stale generation means a
  /// shoot/filter reload landed while the network call was in flight: the write may well have
  /// committed server-side (which is why `mutationCommitCount` still rises), but the frame the
  /// person was judging is gone, so it is never an advance-eligible answer.
  /// `@discardableResult` keeps every existing call site compiling unchanged.
  @discardableResult
  func applyMark(
    _ state: MarkStateValue, to imageIDs: [Int], explicitPriors: [PriorMarkSnapshot]? = nil
  ) async -> Bool {
    // IMGMGR-586: QUEUES behind a busy lane, as `addTag` does. Refusing dropped every tap made
    // while another mark write was out, with no signal, which over the VPN is most rapid taps.
    // The priors are still captured only once the lane is held, so a queued tap snapshots the
    // committed (or rolled-back) result of the write ahead of it, never its optimistic state —
    // the P5 binding holds by ordering rather than by refusal. Taps land in tap order.
    // The one refusal left: a photograph whose own write is still out (see `pendingMarkIDs`).
    let submitted = explicitPriors.map { Set($0.map(\.imageID)) } ?? writableIDs(among: imageIDs)
    guard submitted.isDisjoint(with: pendingMarkIDs) else { return false }
    pendingMarkIDs.formUnion(submitted)
    defer { pendingMarkIDs.subtract(submitted) }
    await acquireLaneQueueing()
    defer { releaseLane() }
    let priors = explicitPriors ?? capturePriorSnapshots(for: imageIDs)
    recordDroppedWrites(submitted: submitted, written: Set(priors.map(\.imageID)))
    return await performMark(state, priors: priors)
  }

  /// The mutation itself, WITHOUT its own lane acquisition — the same wrapper/core split
  /// `authoritativeRefresh()`/`performAuthoritativeRefresh()` already uses, and for the same
  /// reason: the latched-drag drain (IMGMGR-250) has to hold the lane across its OWN capture of
  /// the priors, so that "which ids did this write actually cover" is answerable before the
  /// write goes out. Every caller holds the lane for the whole call.
  private func performMark(_ state: MarkStateValue, priors: [PriorMarkSnapshot]) async -> Bool {
    await writeMark(state, priors: priors, recordsUndo: true) == .committed
  }

  /// How one `writeMark` ended — the distinctions `applyCompoundMark` needs and `performMark`'s
  /// `Bool` folds away (only `.committed` is `true` there).
  private enum MarkWriteOutcome: Equatable {
    case committed
    case failed
    case conflict
    case scopeChanged
    case nothingToWrite
  }

  /// IMGMGR-586: photographs whose mark write failed and has not been saved since, keyed by id.
  /// A pick is a server write only, so a failure that merely rolled the tile back lost the pick
  /// with no signal (owner report: picks made on one device never reached the other).
  /// `UnsavedMarksBanner` states the count and offers Retry. One entry per photograph — the
  /// latest failed state replaces an earlier one, and any later saved write to it removes it —
  /// so a Retry can never resend a state the reader has since overridden. A scope change does
  /// not clear it: the photographs are still unsaved wherever the reader went.
  private(set) var unsavedMarks: [Int: UnsavedMark] = [:]

  /// Re-sends every unsaved mark, one write per state, against the revision the failed write was
  /// made against — the grid need not still show the photograph, and a photograph another device
  /// changed meanwhile answers 409 and goes to the conflict banner instead of being overwritten
  /// unseen. Queued on the lane like a tap; the record is read once the lane is held, so a second
  /// Retry queued behind the first finds nothing left to send. A 409 stops the run, since the
  /// conflict machine holds one batch at a time.
  func retryUnsavedMarks() async {
    guard !unsavedMarks.isEmpty else { return }
    await acquireLaneQueueing()
    defer { releaseLane() }
    let pending = unsavedMarks.values
    // Pending exactly as a tap's photographs are: Retry shows each one in its retried state, so a
    // repeat tap during the write asks for the opposite and, queued, would undo the Retry once it
    // landed. Claimed only once the lane is held (no other mark write is then out), and never an
    // id a tap queued behind this Retry already holds — that tap releases its own.
    let claimed = Set(pending.map(\.prior.imageID)).subtracting(pendingMarkIDs)
    pendingMarkIDs.formUnion(claimed)
    defer { pendingMarkIDs.subtract(claimed) }
    for state: MarkStateValue in [.pick, .dislike, .none] {
      let group = pending.filter { $0.state == state }.map(\.prior)
      let priors = group.sorted { $0.imageID < $1.imageID }
      guard !priors.isEmpty else { continue }
      if await writeMark(state, priors: priors, recordsUndo: true) == .conflict { return }
    }
  }

  func dismissUnsavedMarks() { unsavedMarks = [:] }

  private func recordUnsaved(_ state: MarkStateValue, priors: [PriorMarkSnapshot]) {
    for prior in priors { unsavedMarks[prior.imageID] = UnsavedMark(state: state, prior: prior) }
  }

  private func forgetUnsaved(_ priors: [PriorMarkSnapshot]) {
    for prior in priors { unsavedMarks[prior.imageID] = nil }
  }

  /// `performMark`'s body. WP30 P3 (IMGMGR-458, plan decision 6): `recordsUndo` lets a compound
  /// verb write its groups here and record ONE entry itself; every existing caller goes through
  /// `performMark`, which passes `true`, so their behaviour is unchanged.
  private func writeMark(
    _ state: MarkStateValue, priors: [PriorMarkSnapshot], recordsUndo: Bool
  ) async -> MarkWriteOutcome {
    guard !priors.isEmpty else { return .nothingToWrite }
    // Diff-gate round 2, B2: the generation THIS mutation's priors were captured under. A
    // shoot/filter reload racing the network await already replaced `images` with fresh server
    // truth by the time this returns — completing (either branch) against a moved generation
    // would either stomp that fresh truth with a rollback/reconcile keyed by now-meaningless ids,
    // or record undo/recovery state that describes a scope the person has already left.
    let generation = loadGeneration
    optimisticallyApply(state, priors: priors)
    let preconditions = priors.map {
      Components.Schemas.MarkPrecondition(imageId: $0.imageID, revision: $0.revisionBefore)
    }
    do {
      let applied = try await service.setMarkState(
        imageIDs: priors.map(\.imageID), state: state, preconditions: preconditions)
      // Diff-gate round-3 closure, B2: the commit signal fires for every SERVER-COMMITTED
      // mutation regardless of a racing generation change — a stale-generation discard below
      // only withholds LOCAL UI state (revisions/undo/selection) for a scope already left, never
      // the fact that the write landed, so the queue's post-mutation re-read is never silently
      // skipped just because a scope change happened to race the network await.
      mutationCommitCount += 1
      // IMGMGR-586: saved is saved, whichever scope the reader is in by now.
      forgetUnsaved(priors)
      guard generation == loadGeneration else { return .scopeChanged }
      reconcileRevisions(applied.revisions ?? [])
      if recordsUndo { undo.record(UndoEntry(appliedState: state, priorStates: priors)) }
      if priors.count > 1 { selection.bulkActionSucceeded() }
      lastMutationError = nil
      // WP12: the cover follows the pick. Still inside this call's own lane hold, so it is
      // serialised against other mutations by construction rather than by a second lock.
      await refreshScenesFor(priors.map(\.imageID))
      return .committed
    } catch {
      let mutationError = (error as? GridServiceError) ?? .unreachable
      // IMGMGR-586: recorded BEFORE the stale-generation escape — a write that failed while the
      // reader changed scope is just as unsaved. A 409 is the conflict banner's instead.
      if mutationError == .conflict {
        forgetUnsaved(priors)
      } else {
        recordUnsaved(state, priors: priors)
      }
      guard generation == loadGeneration else { return .scopeChanged }
      rollback(priors)
      lastMutationError = mutationError
      // P6 item 3: the whole recovery sequence (re-read + diff) runs HERE, still inside the
      // CALLER's lane hold (its `defer { releaseLane() }` has not fired yet — this core never
      // acquires or releases the lane itself) — see `handleConflict`'s own doc comment for why
      // it must never go through `authoritativeRefresh()`'s own lane acquisition.
      if mutationError == .conflict {
        let batch = priors.map {
          ConflictBatchEntry(imageID: $0.imageID, revisionSubmitted: $0.revisionBefore)
        }
        await handleConflict(intent: .setState(state), batch: batch)
        return .conflict
      }
      return .failed
    }
  }

  /// WP30 P3 (IMGMGR-458), plan decision 6: a Compare verb as ONE store-level mutation. The lane
  /// is acquired once and held across every group; the priors of every id are captured once,
  /// before any write; the groups are written in order through `writeMark` with undo recording
  /// suppressed, and exactly ONE `UndoEntry` is recorded, covering the groups that committed.
  ///
  /// Server atomicity is not promised, and nothing is compensated: when a later group fails
  /// after an earlier one landed, the entry is truthful about what landed (Undo reverts exactly
  /// that) and the answer is `.partial`. A conflict runs the existing `handleConflict` machine,
  /// which clears the slot; a generation change is the existing escape.
  ///
  /// Fenced verb-wide (fold round 1, B1): the generation is captured ONCE, here, and re-checked
  /// after every awaited group — `writeMark`'s own fence only covers its request, not the scene
  /// refresh it awaits before answering `.committed` — so no later group is written under a
  /// generation the verb never saw and no entry is recorded for a scope already left.
  func applyCompoundMark(_ groups: [CompoundMarkGroup]) async -> CompoundMarkResult {
    await applyCompoundMarkReporting(groups).result
  }

  /// `applyCompoundMark`, also naming the undo entry it recorded (IMGMGR-482): Compare keys its
  /// one pending pane snapshot by this token.
  func applyCompoundMarkReporting(_ groups: [CompoundMarkGroup]) async -> CompoundMarkReport {
    var recorded: UUID?
    let result = await performCompoundMark(groups, recordedEntry: &recorded)
    return CompoundMarkReport(result: result, entryToken: recorded)
  }

  /// `applyCompoundMarkReporting`'s body; `recordedEntry` is set to the token of the entry it
  /// records, at the line that records it.
  private func performCompoundMark(
    _ groups: [CompoundMarkGroup], recordedEntry: inout UUID?
  ) async -> CompoundMarkResult {
    guard tryAcquireLane() else { return .refused }
    defer { releaseLane() }
    // IMGMGR-586: its photographs are being written, so a tap on one is refused like a repeat
    // tap (`pendingMarkIDs`); a tap on any other photograph queues behind the whole verb.
    let verbIDs = Set(groups.flatMap(\.imageIDs))
    pendingMarkIDs.formUnion(verbIDs)
    defer { pendingMarkIDs.subtract(verbIDs) }
    let generation = loadGeneration
    var planned: [(state: MarkStateValue, priors: [PriorMarkSnapshot])] = []
    for group in groups {
      let priors = capturePriorSnapshots(for: group.imageIDs)
      if !priors.isEmpty { planned.append((group.state, priors)) }
    }
    guard let firstState = planned.first?.state else { return .refused }
    var committed: [PriorMarkSnapshot] = []
    var committedState: MarkStateValue?
    for (state, priors) in planned {
      switch await writeMark(state, priors: priors, recordsUndo: false) {
      case .committed:
        // `.conflict` is answered before this check on purpose: its re-read moves the
        // generation itself. `.failed` never awaits past `writeMark`'s own fence.
        guard generation == loadGeneration else { return .scopeChanged }
        committed += priors
        if committedState == nil { committedState = state }
      case .failed:
        guard let committedState else { return .failed }
        let entry = UndoEntry(appliedState: committedState, priorStates: committed)
        undo.record(entry)
        recordedEntry = entry.token
        return .partial
      case .conflict:
        return .conflict
      case .scopeChanged:
        return .scopeChanged
      case .nothingToWrite:
        continue
      }
    }
    let entry = UndoEntry(appliedState: committedState ?? firstState, priorStates: committed)
    undo.record(entry)
    recordedEntry = entry.token
    return .committed
  }

  /// Restores each image's TRUTHFUL prior state — grouped by target state, since one
  /// `setMarkState` call applies a single state to a batch. Undo is a mutation like any other:
  /// it re-derives its own precondition from the CURRENTLY loaded revision (never the stale
  /// `revisionBefore` the original entry recorded), and rolls back to what the original
  /// mutation actually left in place if a given group's undo write is refused.
  ///
  /// Atomic from the SLOT's perspective (diff-gate round 2, blocker 6): the slot is NOT
  /// consumed up front, and groups are processed in a deterministic order, stopping at the
  /// FIRST failure rather than silently continuing past it. If every group commits, the slot
  /// is cleared only then. If any group fails, that group's own optimistic apply is rolled
  /// back (so nothing is left half-applied for THAT group), and the slot is REWRITTEN to
  /// contain exactly the groups that never successfully committed — never lost, never
  /// re-attempted for a group that already succeeded — so a subsequent `Z` retries precisely
  /// the unfinished remainder. `lastMutationError` surfaces the partial failure either way.
  ///
  /// Truthful remainder, id by id (diff-gate round 3, blocker 1): a group can be PARTIALLY
  /// loaded — some of its snapshot ids currently in `images`, some not (a filter change or a
  /// reload can unload members without invalidating the undo slot; `selectShoot`, the one
  /// change that genuinely invalidates targets, already calls `undo.clear()` explicitly on scope
  /// change). Only ids that were actually SUBMITTED — i.e. loaded and included in the write —
  /// ever leave `remaining`. An id with nothing currently loaded to restore is not settled: it
  /// is not attempted (there is no currently-loaded revision to build a precondition from), but
  /// it is never silently dropped either — it stays in `remaining` exactly as recorded, so a
  /// later `Z` (after the id reloads back into view) attempts it for real. A group with zero
  /// loaded members this pass simply carries all of its ids forward untouched.
  /// Diff-gate round 2, B4: a group's stale-precondition refusal now routes through the SAME
  /// `handleConflict` machine `applyMark`/`addTag` use (re-read, diff, Apply Again) instead of a
  /// bare rollback — the rejected intent IS this group's restore (`targetState` applied to
  /// `priors`). `handleConflict` clears the undo slot unconditionally, which means a conflict on
  /// one group of a multi-group undo abandons the ORIGINAL entry entirely: an unreached sibling
  /// group (the loop already stopped at the first failure, per the doc above) loses its own
  /// retry-via-`Z` along with it — a documented scope decision (phase ledger), not an oversight;
  /// recovering it would need preserving two independent retry mechanisms over the same slot.
  ///
  /// WP30 P3 (IMGMGR-458), plan decision 6: it ANSWERS now (`UndoOutcome`), fenced to the entry
  /// and the generation captured here. The writes are exactly what they were; only the answer is
  /// new, and `@discardableResult` keeps every existing caller compiling unchanged.
  @discardableResult
  func undoLastMark() async -> UndoOutcome {
    await undoLastMarkReporting().outcome
  }

  /// `undoLastMark`, also naming the entry it acted on (IMGMGR-482): the token of the entry it
  /// read from the slot, which is what Compare keys its one pending pane snapshot by.
  func undoLastMarkReporting() async -> UndoReport {
    guard tryAcquireLane() else { return UndoReport(outcome: .refused, entryToken: nil) }
    guard let entry = undo.entry else {
      releaseLane()
      return UndoReport(outcome: .nothingToUndo, entryToken: nil)
    }
    defer { releaseLane() }
    return UndoReport(outcome: await restoreUndoEntry(entry), entryToken: entry.token)
  }

  /// `undoLastMarkReporting`'s body, run with the lane held and `entry` read from the slot.
  private func restoreUndoEntry(_ entry: UndoEntry) async -> UndoOutcome {
    // Fold round 1, B2: ONE generation for the whole call, checked before each group is written
    // and after every await (the request AND the scene refresh), so a later group never writes
    // under a generation this undo never saw and the slot is never touched for a left scope.
    let callGeneration = loadGeneration
    let groups = Dictionary(grouping: entry.priorStates, by: { $0.state })
      .sorted { $0.key.rawValue < $1.key.rawValue }

    var remaining = entry.priorStates
    var encounteredFailure = false

    for (targetState, snapshots) in groups {
      guard !encounteredFailure else { break }
      guard callGeneration == loadGeneration else { return .scopeChanged }
      let ids = snapshots.map(\.imageID)
      let priors = capturePriorSnapshots(for: ids)
      let loadedIDs = Set(priors.map(\.imageID))
      guard !priors.isEmpty else {
        // Nothing currently loaded for this group — NOT settled. Leave every id in `remaining`
        // untouched (never remove) so a retry after a reload can still act on them for real.
        continue
      }
      // Diff-gate round 2, B2: fence THIS group's completion against a scope change racing the
      // network await, same reasoning as `applyMark`'s own `generation` capture — now the call's.
      let generation = callGeneration
      optimisticallyApply(targetState, priors: priors)
      let preconditions = priors.map {
        Components.Schemas.MarkPrecondition(imageId: $0.imageID, revision: $0.revisionBefore)
      }
      do {
        let applied = try await service.setMarkState(
          imageIDs: priors.map(\.imageID), state: targetState, preconditions: preconditions)
        // Diff-gate round-3 closure, B2: same posture as `applyMark` — the write landed
        // server-side regardless of a racing generation change, so the commit signal fires
        // before the generation guard withholds the rest (local reconciliation only).
        mutationCommitCount += 1
        guard generation == loadGeneration else { return .scopeChanged }
        reconcileRevisions(applied.revisions ?? [])
        // Only the ids actually submitted (the loaded subset) come out of the remainder — an
        // unloaded sibling in the same group was never attempted and stays pending.
        remaining.removeAll { loadedIDs.contains($0.imageID) }
        lastMutationError = nil
        await refreshScenesFor(priors.map(\.imageID))
        guard generation == loadGeneration else { return .scopeChanged }
      } catch {
        guard generation == loadGeneration else { return .scopeChanged }
        rollback(priors)
        let mutationError = (error as? GridServiceError) ?? .unreachable
        lastMutationError = mutationError
        if mutationError == .conflict {
          let batch = priors.map {
            ConflictBatchEntry(imageID: $0.imageID, revisionSubmitted: $0.revisionBefore)
          }
          await handleConflict(intent: .setState(targetState), batch: batch)
          return .conflict  // the slot is now owned by conflictRecovery, not the tracking below
        }
        encounteredFailure = true
      }
    }

    guard callGeneration == loadGeneration else { return .scopeChanged }
    if remaining.isEmpty {
      undo.clear()
    } else {
      // The remainder is the same entry, so it keeps the token Compare's snapshot is keyed by.
      undo.record(
        UndoEntry(appliedState: entry.appliedState, priorStates: remaining, token: entry.token))
    }
    return remaining.isEmpty ? .restoredAll : .partial
  }

  // MARK: - Proxy pixels

  /// Keyed by the LOCAL identity (token + reported dimensions, R3-15), so a row adopted to a new
  /// grid edge never reads the old file's bytes back from here.
  private var proxyCache: [ProxyLocalIdentity: Data] = [:]

  /// The `ProxyAvailability` `GridTierResolver.plan` wants for one image's tier, derived from
  /// the loaded `ProxyState` — never probes the network to answer this.
  func availability(for image: Components.Schemas.ImageSummary, tier: ProxyTier)
    -> ProxyAvailability
  {
    guard let state = image.proxies.additionalProperties[tier.rawValue] else { return .missing }
    switch state.verdict {
    case .pending: return .pending
    case .permanentFail: return .permanentFail
    case .ok:
      guard let width = state.width, let height = state.height else { return .missing }
      return .ok(width: width, height: height)
    }
  }

  /// Fetches (and caches, per-launch, in memory) the proxy bytes for one image/tier. Returns
  /// `nil` on 404/unreachable — the caller renders a failure placeholder, never retries in a
  /// loop.
  func proxyData(imageID: Int, tier: ProxyTier, identityToken: String?) async -> Data? {
    await proxyData(
      identity: ProxyLocalIdentity(imageID: imageID, tier: tier, token: identityToken))
  }

  /// `proxyData` for a caller that knows the proxy's reported dimensions (the grid tile and the
  /// scene card): a dimension change is a cache miss even when the token is unchanged or nil.
  ///
  /// The HTTP layer needs no second guard (round-3 advisory 1). The live session is
  /// `URLSession.shared` with its default cache, and a versioned proxy is answered `immutable`
  /// for a year, so an unchanged `?v=` URL WOULD be served from that cache. It never names new
  /// pixels: the backend derives `v` from `(source_hash, render_profile)`
  /// (`availability.identity_token`), and the grid edge is in that profile's fingerprint
  /// (`profile.RenderProfile.fingerprint`, `grid=<edge>`), so an
  /// adopted row reports a new `v` — a new URL — together with its new dimensions. A nil token
  /// sends no `v`, which the backend answers `no-cache`, so URLSession revalidates against the
  /// file's own ETag.
  func proxyData(identity: ProxyLocalIdentity) async -> Data? {
    if let cached = proxyCache[identity] { return cached }
    return await requestProxy(identity: identity)
  }

  /// The unlooked proxy request itself, cache or no cache — `proxyData`'s miss path, and the
  /// looked fallback's enqueue (IMGMGR-382).
  private func requestProxy(identity: ProxyLocalIdentity) async -> Data? {
    do {
      let result = try await service.proxy(
        imageID: identity.imageID, tier: identity.tier, v: identity.token)
      switch result {
      case .ok(let data):
        proxyCache[identity] = data
        return data
      case .notModified:
        return proxyCache[identity]
      case .notFound:
        return nil
      }
    } catch {
      return nil
    }
  }

  // MARK: - Looked proxy pixels (IMGMGR-382)

  /// The unlooked request a looked FALLBACK issued while showing cached unlooked bytes — held
  /// only so a test can await it. Nothing reads its result: the request is made because it is
  /// the one that makes the server enqueue a proxy it does not have.
  @ObservationIgnored private(set) var fallbackProxyRequest: Task<Void, Never>?

  /// The loupe's main image: the `.preview` proxy, through the active look when there is one,
  /// decoded by `decode` (the view's image type; a test's own).
  ///
  /// No look: exactly `proxyData(.preview)`, the path the loupe always took. A look: the looked
  /// proxy at the SAME tier, asked fresh every time — the server sends it `no-store`, so it is
  /// never cached here. If that render fails for any reason (404, a coded 422, transport, or a
  /// 200 whose bytes do not decode) the unlooked proxy is shown instead, the look stays selected,
  /// and the failure is recorded on `looks` so the Looks control can say so. A look never leaves
  /// the loupe blank.
  func loupePreview<Image>(
    imageID: Int, identityToken: String?, decode: (Data) -> Image?
  ) async -> LoupePreview<Image> {
    guard let lookID = looks.activeLookID else {
      let data = await proxyData(imageID: imageID, tier: .preview, identityToken: identityToken)
      return LoupePreview(image: data.flatMap(decode), rendering: .unlooked)
    }
    if let looked = await lookedProxyData(imageID: imageID, tier: .preview, lookID: lookID),
      let image = decode(looked)
    {
      looks.recordRender(imageID: imageID, lookID: lookID, available: true)
      return LoupePreview(image: image, rendering: .looked(lookID: lookID))
    }
    // A load the loupe cancelled (it moved to another frame or look) proves nothing about this
    // photograph, so only a load that ran to its answer is recorded as unavailable.
    if !Task.isCancelled {
      looks.recordRender(imageID: imageID, lookID: lookID, available: false)
    }
    let data = await fallbackProxyData(imageID: imageID, identityToken: identityToken)
    return LoupePreview(image: data.flatMap(decode), rendering: .fallback(lookID: lookID))
  }

  /// One looked render, always a fresh request.
  private func lookedProxyData(imageID: Int, tier: ProxyTier, lookID: String) async -> Data? {
    do {
      switch try await service.lookedProxy(imageID: imageID, tier: tier, lookID: lookID) {
      case .ok(let data):
        return data
      case .notFound, .refused:
        return nil
      }
    } catch {
      return nil
    }
  }

  /// The looked fallback's unlooked bytes. The unlooked request ALWAYS reaches the server — a
  /// looked 404 queues nothing, and the unlooked request is what does — but bytes already cached
  /// are shown at once rather than after that round trip.
  private func fallbackProxyData(imageID: Int, identityToken: String?) async -> Data? {
    let identity = ProxyLocalIdentity(imageID: imageID, tier: .preview, token: identityToken)
    guard let cached = proxyCache[identity] else {
      return await requestProxy(identity: identity)
    }
    fallbackProxyRequest = Task { [weak self] in
      _ = await self?.requestProxy(identity: identity)
    }
    return cached
  }

  // MARK: - Tags (T)

  /// P6: joins the SAME mutation lane state/undo already use — QUEUEING (diff-gate round 2, B5),
  /// never refusing: the entry sheet that submits a tag is already dismissed by the time this
  /// runs, unlike Pick/Dislike's always-visible, always-re-tappable button, so a busy lane must
  /// never silently drop a submitted tag. `explicitPriors` overrides the normal `images`-derived
  /// precondition capture for `applyConflictAgain` (B6), same posture as `applyMark`'s own param.
  /// A 409 here now routes through the SAME recovery machine as state mutations (B5).
  func addTag(
    _ tag: String, to imageIDs: [Int], explicitPriors: [PriorTagSnapshot]? = nil
  ) async {
    // WP14 (IMGMGR-204): the submission-time answer to "which of these can this store write",
    // taken SYNCHRONOUSLY — before the first suspension point, so nothing can prune between the
    // person pressing Add and this line. `explicitPriors` (conflict recovery's resubmission)
    // names its own id set outright and is never filtered against the pool, so its
    // submission-time set is simply that set.
    let submitted = explicitPriors.map { Set($0.map(\.imageID)) } ?? writableIDs(among: imageIDs)
    await acquireLaneQueueing()
    let priors = explicitPriors ?? capturePriorTagSnapshots(for: imageIDs)
    // Whatever the wait cost the reader is stated, never swallowed — including the all-dropped
    // case the `isEmpty` guard below used to return from in complete silence.
    recordDroppedWrites(submitted: submitted, written: Set(priors.map(\.imageID)))
    guard !priors.isEmpty else {
      releaseLane()
      return
    }
    defer { releaseLane() }
    let generation = loadGeneration  // B2: fence completion against a racing scope reload
    optimisticallyAddTag(tag, to: priors.map(\.imageID))
    let preconditions = priors.map {
      Components.Schemas.MarkPrecondition(imageId: $0.imageID, revision: $0.revisionBefore)
    }
    do {
      let applied = try await service.editMarkTags(
        imageIDs: priors.map(\.imageID), operation: .add, tag: tag, preconditions: preconditions)
      // Diff-gate round-3 closure, B2: same posture as `applyMark`/`undoLastMark` — the write
      // landed server-side regardless of a racing generation change.
      mutationCommitCount += 1
      guard generation == loadGeneration else { return }
      reconcileRevisions(applied.revisions ?? [])
      lastMutationError = nil
      await refreshScenesFor(priors.map(\.imageID))
    } catch {
      guard generation == loadGeneration else { return }
      rollbackTag(tag, priors: priors)
      let mutationError = (error as? GridServiceError) ?? .unreachable
      lastMutationError = mutationError
      if mutationError == .conflict {
        let batch = priors.map {
          ConflictBatchEntry(imageID: $0.imageID, revisionSubmitted: $0.revisionBefore)
        }
        await handleConflict(intent: .addTag(tag), batch: batch)
      }
    }
  }

  // MARK: - Private snapshot / apply / rollback helpers

  /// The WRITE half of the shared actionable projection: apply `transform` to every photograph on
  /// screen whose id is in `ids`, wherever that photograph actually lives.
  ///
  /// `actionableImages` answers "which photographs may a gesture act on"; a mark also has to write
  /// the answer back, and in Scene mode the photographs are stored in two places — loose rows and
  /// the member strips of opened scenes — neither of which is `images`. Routing every optimistic
  /// apply, rollback and revision reconcile through this ONE function is what keeps the read and
  /// the write looking at the same set: a photograph reachable by a gesture is by construction
  /// also reachable by the write that gesture triggers.
  ///
  /// A collapsed card's `representative` is deliberately NOT written here even when the mark
  /// landed on the photograph it happens to show — the card carries no mark badge (it is not a
  /// write target), and its aggregate fields come back from the server's own re-read
  /// (`refreshScenesFor`) rather than being guessed at locally.
  private func mutateActionable(
    _ ids: Set<Int>, _ transform: (inout Components.Schemas.ImageSummary) -> Void
  ) {
    switch displayMode {
    case .flat:
      for i in images.indices where ids.contains(images[i].id) {
        transform(&images[i])
      }
      // IMGMGR-541: the remainder's photographs are patched IN PLACE too — a mark never moves a
      // tile out of the slice it was made on (R3-21).
      for i in remainderImages.indices where ids.contains(remainderImages[i].id) {
        transform(&remainderImages[i])
        if isInRemainder { remainderMarkedDuringVisit = true }
      }
    case .scene:
      for i in sceneRows.indices {
        guard case .image(var image) = sceneRows[i], ids.contains(image.id) else { continue }
        transform(&image)
        sceneRows[i] = .image(image)
      }
      // Iterate a snapshot, write into the live dictionary — the two are deliberately separate so
      // the loop's subject cannot change under it.
      for (stackID, members) in sceneMembers.map({ ($0.key, $0.value) }) {
        var updated = members
        var changed = false
        for i in updated.indices where ids.contains(updated[i].id) {
          transform(&updated[i])
          changed = true
        }
        if changed { sceneMembers[stackID] = updated }
      }
    }
  }

  private func capturePriorSnapshots(for imageIDs: [Int]) -> [PriorMarkSnapshot] {
    let pool = actionableImages
    return imageIDs.compactMap { id in
      guard let img = pool.first(where: { $0.id == id }) else { return nil }
      return PriorMarkSnapshot(
        imageID: id, state: MarkStateValue(img.mark.state), revisionBefore: img.mark.revision)
    }
  }

  /// Which of `imageIDs` this store could write RIGHT NOW — the same actionable pool
  /// `capturePriorSnapshots`/`capturePriorTagSnapshots` filter against, asked as a question
  /// instead of applied as a side effect. Called at SUBMISSION time so a queued write can
  /// afterwards tell "was never writable" (the documented loaded-only rule) apart from "was
  /// writable when you asked, and was pruned while your write waited" (the race).
  private func writableIDs(among imageIDs: [Int]) -> Set<Int> {
    let pool = Set(actionableImages.map(\.id))
    return Set(imageIDs).intersection(pool)
  }

  /// Records the difference between what a write was submitted for and what it actually wrote.
  /// Additive: a second dropped batch does not erase the first, and only the reader
  /// (`dismissDroppedWriteNotice`) or a fresh window (`reloadFirstPage`) clears the notice.
  private func recordDroppedWrites(submitted: Set<Int>, written: Set<Int>) {
    let dropped = submitted.subtracting(written)
    guard !dropped.isEmpty else { return }
    droppedWriteIDs.formUnion(dropped)
  }

  private func optimisticallyApply(_ state: MarkStateValue, priors: [PriorMarkSnapshot]) {
    mutateActionable(Set(priors.map(\.imageID))) { $0.mark.state = state.payload }
    applyPickCountDeltas(
      SceneRowBuilder.pickCountDeltas(
        priors.map {
          SceneRowBuilder.PickTransition(
            imageID: $0.imageID, wasPicked: $0.state == .pick, isPicked: state == .pick)
        },
        members: sceneMembers))
  }

  private func rollback(_ priors: [PriorMarkSnapshot]) {
    // The badge unwinds from what is on screen RIGHT NOW back to each prior — read before the
    // states are restored, or the transition would describe itself.
    let current = Dictionary(
      actionableImages.map { ($0.id, MarkStateValue($0.mark.state)) },
      uniquingKeysWith: { first, _ in first })
    applyPickCountDeltas(
      SceneRowBuilder.pickCountDeltas(
        priors.map {
          SceneRowBuilder.PickTransition(
            imageID: $0.imageID, wasPicked: current[$0.imageID] == .pick,
            isPicked: $0.state == .pick)
        },
        members: sceneMembers))
    let byID = Dictionary(uniqueKeysWithValues: priors.map { ($0.imageID, $0.state) })
    mutateActionable(Set(byID.keys)) { image in
      if let prior = byID[image.id] { image.mark.state = prior.payload }
    }
  }

  /// The ✓N badge's OPTIMISTIC half (IMGMGR-241), mirroring the web's own
  /// (`frontend/src/lib/library.ts`): the count moves with the press rather than with the
  /// round-trip, so a reader picking through a burst sees the scene's number answer them.
  ///
  /// It is arithmetic on a count, never a re-derivation of the scene: `has_pick` follows the
  /// count because "some member is picked" and "the count is above zero" are the same statement,
  /// and the COVER is deliberately left alone — `refreshScenesFor` re-reads the server's own
  /// election a moment later, and guessing at it here would be wrong for any curated scene.
  private func applyPickCountDeltas(_ deltas: [Int: Int]) {
    guard !deltas.isEmpty else { return }
    for index in sceneRows.indices {
      guard case .stack(var row) = sceneRows[index], let delta = deltas[row.stackId], delta != 0
      else { continue }
      row.pickedCount = SceneRowBuilder.clampedCount(row.pickedCount, delta: delta)
      row.hasPick = row.pickedCount > 0
      sceneRows[index] = .stack(row)
    }
  }

  private func reconcileRevisions(_ revisions: [Components.Schemas.MarkRevision]) {
    let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.imageId, $0.revision) })
    mutateActionable(Set(byID.keys)) { image in
      if let revision = byID[image.id] { image.mark.revision = revision }
    }
  }

  /// Not `private` (diff-gate round 2, B5/B6): `addTag`'s `explicitPriors` parameter and
  /// `applyConflictAgain`'s resubmission both need this type at internal visibility, matching
  /// `PriorMarkSnapshot`'s own (non-private) access level.
  struct PriorTagSnapshot: Sendable, Equatable {
    var imageID: Int
    var tags: [String]
    var revisionBefore: String
  }

  private func capturePriorTagSnapshots(for imageIDs: [Int]) -> [PriorTagSnapshot] {
    let pool = actionableImages
    return imageIDs.compactMap { id in
      guard let img = pool.first(where: { $0.id == id }) else { return nil }
      return PriorTagSnapshot(
        imageID: id, tags: img.mark.tags ?? [], revisionBefore: img.mark.revision)
    }
  }

  private func optimisticallyAddTag(_ tag: String, to imageIDs: [Int]) {
    mutateActionable(Set(imageIDs)) { image in
      var tags = image.mark.tags ?? []
      if !tags.contains(tag) { tags.append(tag) }
      image.mark.tags = tags
    }
  }

  private func rollbackTag(_ tag: String, priors: [PriorTagSnapshot]) {
    let byID = Dictionary(uniqueKeysWithValues: priors.map { ($0.imageID, $0.tags) })
    mutateActionable(Set(byID.keys)) { image in
      if let priorTags = byID[image.id] { image.mark.tags = priorTags }
    }
  }
}

extension MarkStateValue {
  init(_ payload: Components.Schemas.MarkView.StatePayload?) {
    // `payload` is `StatePayload?`, and `StatePayload` itself has a case literally named
    // `none` — a bare `case .none` here would match ONLY `Optional.none` (nil), silently
    // leaving `.some(.none)` (the wire value "none", not absent) unhandled. Both collapse to
    // this type's own `.none` on purpose (ADR-0001: the tri-state model does not change).
    switch payload {
    case .some(.pick): self = .pick
    case .some(.dislike): self = .dislike
    case .some(.none), .none: self = .none
    }
  }

  var payload: Components.Schemas.MarkView.StatePayload {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    case .none: return .none
    }
  }
}

/// What the loupe's main image was rendered as (IMGMGR-382).
enum LoupeRendering: Equatable, Sendable {
  case unlooked
  /// Through this look.
  case looked(lookID: String)
  /// This look was chosen, but the photograph is shown unlooked: the looked render failed.
  case fallback(lookID: String)
}

/// `GridStore.loupePreview`'s answer: the decoded image (nil when even the unlooked proxy is
/// unavailable) and what it was rendered as.
struct LoupePreview<Image> {
  let image: Image?
  let rendering: LoupeRendering
}
