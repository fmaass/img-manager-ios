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
  private(set) var isLoadingPage = false
  private(set) var lastMutationError: GridMutationError?
  private(set) var lastPageLoadError: GridMutationError?

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
  /// Which scenes the reader has opened.
  private(set) var sceneExpanded: Set<Int> = []
  /// Each opened scene's members, as `GET /api/stacks/{id}/members` served them: capture-ordered,
  /// tombstones included, and UNFILTERED — the card's `matched_count` is the filtered question.
  private(set) var sceneMembers: [Int: [Components.Schemas.ImageSummary]] = [:]
  /// How to ask for the rest of a long scene, per opened scene. Absent = never opened.
  private(set) var sceneMemberCursors: [Int: SceneMemberCursor] = [:]
  /// Single-flight: which scenes have a membership request in flight right now. A second tap on
  /// an opening card, or a second "load more" while one page is still on the wire, is dropped
  /// rather than duplicating the page into the strip.
  private(set) var sceneMembersInFlight: Set<Int> = []

  /// The grid's row sequence in Scene mode: cards and loose photographs in the server's order,
  /// each opened scene followed by the members loaded for it.
  var sceneDisplayRows: [SceneDisplayRow] {
    SceneRowBuilder.displayRows(
      rows: sceneRows, expanded: sceneExpanded, members: sceneMembers)
  }

  /// THE list of "photographs on screen" — the single projection every mark, tag, undo, focus,
  /// arrow-navigation and loupe path in this type reads instead of `images` directly.
  ///
  /// In flat mode it IS `images`, so every shipped behaviour is unchanged. In Scene mode it is
  /// the display sequence's photographs: loose rows and the members of EXPANDED scenes, never a
  /// collapsed card's cover. Deriving it once, here, is what makes "a card is not a write target"
  /// and "an expanded member IS one" the same fact rather than two rules a dozen call sites each
  /// have to remember — including the loupe's filmstrip, which walks this same list.
  var actionableImages: [Components.Schemas.ImageSummary] {
    switch displayMode {
    case .flat: return images
    case .scene: return SceneRowBuilder.actionableImages(sceneDisplayRows)
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

  let selection = SelectionState()
  let pickLock = PickLockState()
  let undo = UndoStack()

  // MARK: - Loupe (P5)

  /// Whether the loupe is the active surface at all. Compact always presents it full-screen;
  /// Regular-2/3 present it DOCKED in the content column by default (`isLoupeFullScreen ==
  /// false`) — see `RootView` for the presentation split, which is the one place this flag and
  /// `isLoupeFullScreen` are read together.
  private(set) var isLoupeOpen = false
  /// Regular-2/3 ONLY: the explicit "go full-screen" toggle (spec: "A full-screen loupe stays
  /// available as an explicit toggle"). Meaningless on Compact, which is always full-screen
  /// regardless of this flag's value.
  private(set) var isLoupeFullScreen = false
  /// Flips true once a forward-neighbour fetch at the loaded tail returned zero new images —
  /// i.e., confirmed nothing more to advance to. Reset on every scope change (`reloadFirstPage`)
  /// so a NEW shoot/filter always starts un-exhausted.
  private(set) var loupeExhausted = false

  func openLoupe(on imageID: Int) {
    focusedImageID = imageID
    // Pin (`SelectionState.swift`'s own `SelectionResetTrigger.enteredLoupe` doc comment,
    // written ahead of P5 for exactly this call site): entering the loupe resets selection.
    // A latched lock (either verb) is deliberately left UNTOUCHED — `PickLockState.exit()`'s
    // own doc comment pins it "Grid-only, never the loupe" — and structurally a latched tap
    // never reaches here anyway (`tapTile`'s `latchedVerb` branch returns before this switch).
    selection.reset(.enteredLoupe)
    isLoupeOpen = true
  }

  func closeLoupe() {
    isLoupeOpen = false
    isLoupeFullScreen = false
  }

  /// Regular-2/3 only; the view disables/hides this control on Compact (always full-screen
  /// there), but the guard lives here too so a programmatic call is never a no-op silently
  /// depending on the caller remembering the layout rule.
  func toggleLoupeFullScreen() {
    isLoupeFullScreen.toggle()
  }

  /// Dedicated flat previous/next (fold advisory: "don't overload row-relative `moveFocus`") —
  /// the loupe's own notion of "next", over the SAME flat load order the grid's paging already
  /// maintains, never a filmstrip-local page.
  func loupeNext() async {
    guard let current = focusedImageID else { return }
    let pool = actionableImages
    if let idx = pool.firstIndex(where: { $0.id == current }), pool.indices.contains(idx + 1) {
      focusedImageID = pool[idx + 1].id
      return
    }
    // WP12: the forward-neighbour prefetch is a FLAT-browse mechanism — it asks
    // `/api/images/{id}/neighbours` "what follows this in the current filter's order", a question
    // Scene mode's row stream (cards and members, one stored anchor) does not have an answer to,
    // and the merge target it feeds (`images`) is deliberately empty here. Scene mode's loupe is
    // therefore bounded by what the grid has loaded, which is also the fold's "one paging path"
    // rule kept: the grid owns Scene paging, the loupe consumes no cursor of its own.
    guard displayMode == .flat else { return }
    await fetchAndMergeNeighbours(after: current)
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
  private func fetchAndMergeNeighbours(after imageID: Int) async {
    // Diff-gate round (2026-08-28): the same generation guard every other paging await here
    // carries — a neighbours response that lands after the shoot/filter changed must be
    // discarded whole, or it appends old-scope rows into the new scope and can focus the
    // loupe on an id the new scope does not contain.
    let generation = loadGeneration
    do {
      let page = try await service.neighbours(after: imageID, query: query, limit: 5)
      guard generation == loadGeneration else { return }
      let added = mergeImages(page.items)
      images.append(contentsOf: added)
      if page.items.isEmpty {
        // Exhaustion is the SERVER's word only. `added` emptying through dedup merely means a
        // concurrent merge (the filmstrip's page fetch) got the same rows in first — the next
        // image exists locally, and latching exhausted here would wrongly disable Next.
        loupeExhausted = true
      } else {
        loupeExhausted = false
        if focusedImageID == imageID,
          let idx = images.firstIndex(where: { $0.id == imageID }),
          images.indices.contains(idx + 1)
        {
          focusedImageID = images[idx + 1].id
        }
      }
      lastPageLoadError = nil
    } catch {
      // P6 (premise-gate advisory (a)): the SAME generation guard the success path above
      // already carries — a neighbours call that started in an OLD scope and only FAILS after
      // a scope change must not surface its error in the NEW scope either (the success path
      // discards silently; a failure discarding into a stale write would be the inconsistent
      // half). Reuses the grid's own paging-error surface — a neighbours failure is the same
      // class of "reachability" concern as a failed grid page fetch, not a new error surface.
      guard generation == loadGeneration else { return }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
    }
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
    pasteboard: any MarksPasteboard = SystemMarksPasteboard()
  ) {
    self.service = service
    self.preferences = preferences
    self.pasteboard = pasteboard
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
    query.folderID = folderID
    query.sourceTier = sourceTier
    pickLock.exit()
    selection.reset(.shootChange)
    focusedImageID = nil
    undo.clear()
    conflictRecovery = nil
    await reloadFirstPage()
  }

  /// Any effective filter/tier/tree change (Stats-tab facet taps route through this).
  func applyFilterChange(_ mutate: (inout GridImagesQuery) -> Void) async {
    var next = query
    mutate(&next)
    guard next != query else { return }
    query = next
    selection.reset(.queryGenerationChange)
    focusedImageID = nil
    conflictRecovery = nil
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
    pickLock.exit()
    selection.reset(.shootChange)
    focusedImageID = nil
    undo.clear()
    conflictRecovery = nil
    await reloadFirstPage()
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

  // MARK: - Stats facets (WP12: the Compact filter surface)

  /// The counts the Stats tab renders. They live HERE, not in the inspector view's own `@State`,
  /// because the thing that has to be provable is the CHAIN — a facet tap changes the filter and
  /// the counts come back in step — and a trigger that only exists inside a SwiftUI `.task(id:)`
  /// modifier cannot be exercised by any test, so deleting it would break the app while every
  /// test stayed green.
  private(set) var facets: Components.Schemas.ImageFacets?

  /// The query the published `facets` describes. `refreshFacets` is a no-op while it already
  /// matches, so the inspector's `.task(id: queryIdentity)` re-firing right after a tap that
  /// already refreshed does not fetch the same counts a second time.
  private(set) var facetsIdentity: GridImagesQuery?

  /// The refresh currently in flight, recorded SYNCHRONOUSLY — before this method's first
  /// suspension — so a second caller for the SAME query joins it instead of issuing a duplicate
  /// request. This is the reentrancy the MainActor does not prevent: `applyFacetFilter` sets
  /// `query` and then suspends inside `reloadFirstPage`, and the inspector's
  /// `.task(id: queryIdentity)` fires for the NEW identity inside that window. With the identity
  /// only written after the network await, both calls passed the guard below and whichever
  /// response came home last won.
  private var facetsRefresh: (identity: GridImagesQuery, task: Task<Void, Never>)?

  /// Idempotent per query: the inspector's `.task(id:)` calls this on appearance and on every
  /// query-identity change, and the tap handlers below call it after they mutate the filter.
  /// A response that arrives after the query moved on is discarded (same discipline as the
  /// paging generation fence), and a failed fetch leaves the last good counts standing rather
  /// than blanking the tab — absence renders as absence, never as zeros.
  func refreshFacets() async {
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
    selection.reset(.fullReload)
    focusedImageID = nil
    await reloadFirstPage()
  }

  private func reloadFirstPage() async {
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
    isLoupeFullScreen = false
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
    }
    do {
      switch displayMode {
      case .flat:
        let page = try await service.images(query, cursor: nil, limit: 100)
        guard generation == loadGeneration else { return }
        // Assigned only on success, deliberately: a failed flat reload keeps the rows the reader
        // was looking at rather than blanking the grid (pre-existing behaviour, unchanged).
        images = page.items
        nextCursor = page.nextCursor
      case .scene:
        let page = try await service.browseStacks(query, cursor: nil, limit: Self.scenePageLimit)
        guard generation == loadGeneration else { return }
        sceneRows = page.rows
        sceneNextCursor = page.nextCursor
      }
      lastPageLoadError = nil
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
    await refreshGroupHeaders()
  }

  /// `GET /api/browse/stacks` counts DISPLAY ROWS, not photographs ("a page of 100 may stand for
  /// thousands of frames" — the schema's own words), so the flat grid's 100 is if anything
  /// generous here rather than tight. Its declared maximum is 200.
  private static let scenePageLimit = 100

  /// Drops everything that describes a Scene RESULT SET: the served rows, its cursor, which
  /// scenes are open and every membership page loaded for them. Never touches `displayMode` —
  /// the reader is still in Scene mode, the window under them is simply being rebuilt.
  private func clearSceneWindow() {
    sceneRows = []
    sceneNextCursor = nil
    sceneExpanded = []
    sceneMembers = [:]
    sceneMemberCursors = [:]
    sceneMembersInFlight = []
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
    let openScenes = sceneExpanded
    do {
      let page = try await service.browseStacks(query, cursor: nil, limit: Self.scenePageLimit)
      guard generation == loadGeneration else { return false }
      var refreshedMembers: [Int: [Components.Schemas.ImageSummary]] = [:]
      var refreshedCursors: [Int: SceneMemberCursor] = [:]
      // Only scenes the refreshed page still contains: one the reader had open that a filter or
      // a split has removed from the stream has no card to sit under any more.
      let survivingScenes = Set(
        page.rows.compactMap { row -> Int? in
          guard case .stack(let stack) = row else { return nil }
          return openScenes.contains(stack.stackId) ? stack.stackId : nil
        })
      for stackID in survivingScenes.sorted() {
        let members = try await service.stackMembers(
          stackID: stackID, cursor: nil, limit: Self.sceneMemberPageLimit)
        guard generation == loadGeneration else { return false }
        refreshedMembers[stackID] = members.items
        refreshedCursors[stackID] = members.nextCursor.map(SceneMemberCursor.more) ?? .exhausted
      }
      guard generation == loadGeneration else { return false }
      sceneRows = page.rows
      sceneNextCursor = page.nextCursor
      sceneExpanded = survivingScenes
      sceneMembers = refreshedMembers
      sceneMemberCursors = refreshedCursors
      sceneMembersInFlight = []
      let actionable = actionableImages
      pruneSelectionOutside(actionable)
      publishRefreshedFocusAndUndo(actionable: actionable)
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
  /// (`toggleSceneExpanded`): the selection is a set of ids, so nothing downstream can tell that
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
      images.append(contentsOf: mergeImages(page.items))
      nextCursor = page.nextCursor
      selection.pageAppended()
      lastPageLoadError = nil
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
    guard sceneDisplayRows.last?.id == currentRowID, let cursor = sceneNextCursor, !isLoadingPage
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
      let known = Set(sceneRows.map(\.displayID))
      sceneRows.append(contentsOf: page.rows.filter { !known.contains($0.displayID) })
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

  /// Open or close ONE scene — the only thing a collapsed card can do.
  ///
  /// Opening fetches its MEMBERSHIP: every member including tombstones, in capture order,
  /// deliberately unfiltered, because that is the authoritative answer to "what is in this
  /// scene". Members already in hand are not re-fetched — closing and reopening is a display
  /// change, not a reason to ask the server again.
  ///
  /// Closing PRUNES that scene's members from the selection. Not defensiveness: select a member
  /// while the scene is open, close the scene, then press Pick — the mark path reads the
  /// selection, and without this the write would land on photographs now hidden inside a
  /// collapsed card, which is the exact thing the actionability boundary exists to prevent. The
  /// ids come out at the moment they stop being visible.
  func toggleSceneExpanded(_ stackID: Int) async {
    guard displayMode == .scene else { return }
    if sceneExpanded.contains(stackID) {
      sceneExpanded.remove(stackID)
      let hidden = sceneMembers[stackID] ?? []
      if !hidden.isEmpty && !selection.members.isEmpty {
        selection.removeHidden(hidden.map(\.id))
      }
      // Focus cannot stay on a photograph nobody can see any more.
      if let focused = focusedImageID, hidden.contains(where: { $0.id == focused }) {
        focusedImageID = nil
        if isLoupeOpen { closeLoupe() }
      }
      return
    }
    sceneExpanded.insert(stackID)
    guard sceneMembers[stackID] == nil else { return }
    await fetchSceneMembers(stackID: stackID, cursor: nil)
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
    guard displayMode == .scene, sceneExpanded.contains(stackID) else { return }
    guard case .more(let cursor) = sceneMemberCursors[stackID] else { return }
    await fetchSceneMembers(stackID: stackID, cursor: cursor)
  }

  /// One membership page, single-flighted per scene and generation-fenced like every other read
  /// here. `cursor == nil` is the first page (replaces), a cursor appends.
  private func fetchSceneMembers(stackID: Int, cursor: String?) async {
    guard !sceneMembersInFlight.contains(stackID) else { return }
    sceneMembersInFlight.insert(stackID)
    defer { sceneMembersInFlight.remove(stackID) }
    let generation = loadGeneration
    do {
      let page = try await service.stackMembers(
        stackID: stackID, cursor: cursor, limit: Self.sceneMemberPageLimit)
      // The window may have been replaced while the membership was on the wire — its rows belong
      // to a result set the reader has left, exactly as a late grid page would.
      guard generation == loadGeneration else { return }
      // And the reader may have closed the scene in the meantime: splicing members under a card
      // that is no longer open would put photographs on screen nobody asked to see.
      guard sceneExpanded.contains(stackID) else { return }
      if cursor == nil {
        sceneMembers[stackID] = page.items
      } else {
        let held = sceneMembers[stackID] ?? []
        let known = Set(held.map(\.id))
        sceneMembers[stackID] = held + page.items.filter { !known.contains($0.id) }
      }
      sceneMemberCursors[stackID] = page.nextCursor.map(SceneMemberCursor.more) ?? .exhausted
      lastPageLoadError = nil
    } catch {
      guard generation == loadGeneration else { return }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
    }
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
  /// ONE request per DISTINCT touched scene, and only the four fields a write can change:
  /// `member_count`, `has_pick`, `matched_count` and `representative`. Everything else about the
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
        row.matchedCount = fresh.matchedCount
        row.representative = fresh.representative
        sceneRows[index] = .stack(row)
      }
    }
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
      await toggleSceneExpanded(stackID)
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
      await applyMark(verb.markState, to: [imageID])
    } else if selection.mode == .select {
      selection.addFromDrag(imageID)
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
    guard !markTargetImageIDs.isEmpty else { return }
    await applyMarkToTarget(.pick)
    if shiftHeld { advanceToNext() }
  }

  func handleDislikeShortcut(shiftHeld: Bool) async {
    guard !markTargetImageIDs.isEmpty else { return }
    await applyMarkToTarget(.dislike)
    if shiftHeld { advanceToNext() }
  }

  /// U — active in the grid AND the loupe (same scene-level dispatch either way; `AppCommands`
  /// does not know or care which screen is currently on top). Shift+U also advances, mirroring
  /// P/X (`ShortcutCatalog`'s own doc comment: "Shift held on P/X/U means 'mark and advance'").
  func handleClearShortcut(shiftHeld: Bool) async {
    guard !markTargetImageIDs.isEmpty else { return }
    await applyMarkToTarget(.none)
    if shiftHeld { advanceToNext() }
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

  /// WP13 P4 (IMGMGR-215): raise the shortcut help sheet. ONE method rather than two call sites
  /// setting the flag, because both surfaces that open it — the `?`/⌘/ key equivalents through
  /// `GridKeyboardActions`, and Compact's options-row button (`GridShortcutHelpControl`) — must
  /// stay the same action, the same rule `GridGroupControl`/`AppCommands` already follow for
  /// the view options themselves.
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
    guard let id = focusedImageID else { return false }
    let committed = await applyMark(state, to: [id])
    guard committed, preferences.autoAdvanceOnMark else { return committed }
    await loupeNext()
    return committed
  }

  /// Any effective tier change resets selection (pin: "any effective filter/tier/tree change").
  func setRowHeight(_ newValue: GridRowHeight) {
    guard rowHeight != newValue else { return }
    rowHeight = newValue
    selection.reset(.queryGenerationChange)
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
  /// P6: the SAME flag is now the "one ordered mark/refresh lane" (plan item 2) -- `applyMark`/
  /// `undoLastMark` still REFUSE via `tryAcquireLane()` (unchanged posture), while
  /// `authoritativeRefresh()` and `addTag` (diff-gate round 2, B5: a submitted tag must never be
  /// silently dropped by a busy lane -- its entry sheet is already dismissed by the time the
  /// write runs, unlike Pick/Dislike's always-visible, always-re-tappable button) QUEUE via
  /// `acquireLaneQueueing()` instead of refusing.
  private(set) var isMutatingMark = false

  /// FIFO of calls waiting for a busy lane -- see `acquireLaneQueueing()`/`releaseLane()`.
  private var laneWaiters: [CheckedContinuation<Void, Never>] = []

  /// The REFUSING acquisition `applyMark`/`undoLastMark` use: `false` (no-op for the caller) if
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
    guard tryAcquireLane() else { return false }
    let priors = explicitPriors ?? capturePriorSnapshots(for: imageIDs)
    guard !priors.isEmpty else {
      releaseLane()
      return false
    }
    defer { releaseLane() }
    // Diff-gate round 2, B2: the generation THIS mutation's priors were captured under. A
    // shoot/filter reload racing the network await already replaced `images` with fresh server
    // truth by the time this returns — completing (either branch) against a moved generation
    // would either stomp that fresh truth with a rollback/reconcile keyed by now-meaningless ids,
    // or record undo/recovery state that describes a scope the person has already left.
    let generation = loadGeneration
    optimisticallyApply(state, to: priors.map(\.imageID))
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
      guard generation == loadGeneration else { return false }
      reconcileRevisions(applied.revisions ?? [])
      undo.record(UndoEntry(appliedState: state, priorStates: priors))
      if priors.count > 1 { selection.bulkActionSucceeded() }
      lastMutationError = nil
      // WP12: the cover follows the pick. Still inside this call's own lane hold, so it is
      // serialised against other mutations by construction rather than by a second lock.
      await refreshScenesFor(priors.map(\.imageID))
      return true
    } catch {
      guard generation == loadGeneration else { return false }
      rollback(priors)
      let mutationError = (error as? GridServiceError) ?? .unreachable
      lastMutationError = mutationError
      // P6 item 3: the whole recovery sequence (re-read + diff) runs HERE, still inside this
      // call's own lane hold (`defer { releaseLane() }` above has not fired yet) — see
      // `handleConflict`'s own doc comment for why it must never go through
      // `authoritativeRefresh()`'s own lane acquisition.
      if mutationError == .conflict {
        let batch = priors.map {
          ConflictBatchEntry(imageID: $0.imageID, revisionSubmitted: $0.revisionBefore)
        }
        await handleConflict(intent: .setState(state), batch: batch)
      }
      return false
    }
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
  func undoLastMark() async {
    guard tryAcquireLane() else { return }
    guard let entry = undo.entry else {
      releaseLane()
      return
    }
    defer { releaseLane() }
    let groups = Dictionary(grouping: entry.priorStates, by: { $0.state })
      .sorted { $0.key.rawValue < $1.key.rawValue }

    var remaining = entry.priorStates
    var encounteredFailure = false

    for (targetState, snapshots) in groups {
      guard !encounteredFailure else { break }
      let ids = snapshots.map(\.imageID)
      let priors = capturePriorSnapshots(for: ids)
      let loadedIDs = Set(priors.map(\.imageID))
      guard !priors.isEmpty else {
        // Nothing currently loaded for this group — NOT settled. Leave every id in `remaining`
        // untouched (never remove) so a retry after a reload can still act on them for real.
        continue
      }
      // Diff-gate round 2, B2: fence THIS group's completion against a scope change racing the
      // network await, same reasoning as `applyMark`'s own `generation` capture.
      let generation = loadGeneration
      optimisticallyApply(targetState, to: priors.map(\.imageID))
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
        guard generation == loadGeneration else { return }
        reconcileRevisions(applied.revisions ?? [])
        // Only the ids actually submitted (the loaded subset) come out of the remainder — an
        // unloaded sibling in the same group was never attempted and stays pending.
        remaining.removeAll { loadedIDs.contains($0.imageID) }
        lastMutationError = nil
        await refreshScenesFor(priors.map(\.imageID))
      } catch {
        guard generation == loadGeneration else { return }
        rollback(priors)
        let mutationError = (error as? GridServiceError) ?? .unreachable
        lastMutationError = mutationError
        if mutationError == .conflict {
          let batch = priors.map {
            ConflictBatchEntry(imageID: $0.imageID, revisionSubmitted: $0.revisionBefore)
          }
          await handleConflict(intent: .setState(targetState), batch: batch)
          return  // the slot is now owned by conflictRecovery, not the remaining-tracking below
        }
        encounteredFailure = true
      }
    }

    if remaining.isEmpty {
      undo.clear()
    } else {
      undo.record(UndoEntry(appliedState: entry.appliedState, priorStates: remaining))
    }
  }

  // MARK: - Proxy pixels

  private var proxyCache: [String: Data] = [:]

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
    let key = "\(imageID)|\(tier.rawValue)|\(identityToken ?? "")"
    if let cached = proxyCache[key] { return cached }
    do {
      switch try await service.proxy(imageID: imageID, tier: tier, v: identityToken) {
      case .ok(let data):
        proxyCache[key] = data
        return data
      case .notModified:
        return proxyCache[key]
      case .notFound:
        return nil
      }
    } catch {
      return nil
    }
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
    await acquireLaneQueueing()
    let priors = explicitPriors ?? capturePriorTagSnapshots(for: imageIDs)
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

  private func optimisticallyApply(_ state: MarkStateValue, to imageIDs: [Int]) {
    mutateActionable(Set(imageIDs)) { $0.mark.state = state.payload }
  }

  private func rollback(_ priors: [PriorMarkSnapshot]) {
    let byID = Dictionary(uniqueKeysWithValues: priors.map { ($0.imageID, $0.state) })
    mutateActionable(Set(byID.keys)) { image in
      if let prior = byID[image.id] { image.mark.state = prior.payload }
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
