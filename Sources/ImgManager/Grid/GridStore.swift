import Foundation
import ImgManagerAPI

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
  /// packed rows of image ids, in the SAME order as `images`. A justified grid's column count
  /// varies per row (unlike a uniform `LazyVGrid`), so Up/Down navigation below looks up the
  /// focused tile's actual row/column position rather than dividing by a single constant.
  var rows: [[Int]] = []

  var focusedImageID: Int?
  /// `T`/the action bar's Tag control opens tag entry for the focused image (browse mode) or
  /// the current selection (Select mode); the actual write happens on submit, via `addTag`.
  var isTagEntryPresented = false

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
    // Pick Lock is deliberately left UNTOUCHED — `PickLockState.exit()`'s own doc comment pins
    // it "Grid-only, never the loupe" — and structurally a latched tap never reaches here
    // anyway (the `pickLock.state == .latched` branch above returns before this switch).
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
    if let idx = images.firstIndex(where: { $0.id == current }), images.indices.contains(idx + 1) {
      focusedImageID = images[idx + 1].id
      return
    }
    await fetchAndMergeNeighbours(after: current)
  }

  /// Previous is PURELY the retained-prefix local walk (fold-verified premise: GridStore
  /// retains a prefix of every loaded page through the paging frontier) — never a network call,
  /// disabled at index 0.
  func loupePrevious() {
    guard let current = focusedImageID,
      let idx = images.firstIndex(where: { $0.id == current }), idx > 0
    else { return }
    focusedImageID = images[idx - 1].id
  }

  /// A filmstrip thumbnail tap: the image is already loaded (it is IN `images`, or the
  /// filmstrip could not be rendering it), so this is a direct focus move, never a network call.
  func loupeFocus(on imageID: Int) {
    focusedImageID = imageID
  }

  var canLoupeGoPrevious: Bool {
    guard let current = focusedImageID, let idx = images.firstIndex(where: { $0.id == current })
    else { return false }
    return idx > 0
  }

  var canLoupeGoNext: Bool {
    guard let current = focusedImageID, let idx = images.firstIndex(where: { $0.id == current })
    else { return false }
    if idx + 1 < images.count { return true }
    return !loupeExhausted
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

  init(service: GridService) {
    self.service = service
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
    do {
      let page = try await service.images(query, cursor: nil, limit: 100)
      guard generation == loadGeneration else { return }
      images = page.items
      nextCursor = page.nextCursor
      lastPageLoadError = nil
    } catch {
      guard generation == loadGeneration else { return }
      lastPageLoadError = (error as? GridServiceError) ?? .unreachable
    }
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
    let previousFocus = focusedImageID
    images = snapshot
    nextCursor = nil
    lastPageLoadError = nil
    undo.clear()
    let survived = previousFocus.map { id in snapshot.contains { $0.id == id } } ?? false
    guard !survived else { return }
    focusedImageID = nil
    if isLoupeOpen { closeLoupe() }
  }

  /// Called by the view when the last loaded row is about to appear. Paging append: per
  /// selection semantics, this never clears and never implicitly selects the newly-appended
  /// rows (`SelectionState.pageAppended()` is a documented no-op called here for exactly that
  /// reason).
  func loadMoreIfNeeded(currentItemID: Int) async {
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

  // MARK: - Focus / arrow navigation

  func moveFocus(_ direction: GridArrowDirection) {
    guard !images.isEmpty else { return }
    guard let current = focusedImageID else {
      focusedImageID = images.first?.id
      return
    }
    // Fall back to flat left/right-only stepping if the view hasn't published packed rows yet
    // (e.g. before the first layout pass) — still correct, just without row-relative up/down.
    guard !rows.isEmpty,
      let rowIndex = rows.firstIndex(where: { $0.contains(current) }),
      let colIndex = rows[rowIndex].firstIndex(of: current)
    else {
      guard let idx = images.firstIndex(where: { $0.id == current }) else { return }
      let delta = (direction == .left) ? -1 : (direction == .right ? 1 : 0)
      let target = idx + delta
      guard delta != 0, images.indices.contains(target) else { return }
      focusedImageID = images[target].id
      return
    }
    switch direction {
    case .left:
      if colIndex > 0 {
        focusedImageID = rows[rowIndex][colIndex - 1]
      } else if rowIndex > 0 {
        focusedImageID = rows[rowIndex - 1].last
      }
    case .right:
      if colIndex + 1 < rows[rowIndex].count {
        focusedImageID = rows[rowIndex][colIndex + 1]
      } else if rowIndex + 1 < rows.count {
        focusedImageID = rows[rowIndex + 1].first
      }
    case .up:
      guard rowIndex > 0 else { return }
      let target = min(colIndex, rows[rowIndex - 1].count - 1)
      focusedImageID = rows[rowIndex - 1][target]
    case .down:
      guard rowIndex + 1 < rows.count else { return }
      let target = min(colIndex, rows[rowIndex + 1].count - 1)
      focusedImageID = rows[rowIndex + 1][target]
    }
  }

  /// Shift+advance's "advance": the next image in flat load order — distinct from the arrow
  /// keys' grid-relative `.right`, which a caller could reasonably also equate to "next", but
  /// this stays a separate named step so a culling advance never silently depends on
  /// `columnsPerRow` being set correctly by the view.
  private func advanceToNext() {
    guard !images.isEmpty else { return }
    guard let current = focusedImageID, let idx = images.firstIndex(where: { $0.id == current })
    else {
      focusedImageID = images.first?.id
      return
    }
    guard images.indices.contains(idx + 1) else { return }
    focusedImageID = images[idx + 1].id
  }

  // MARK: - Tile interaction (tap / long-press)

  func tapTile(_ imageID: Int) async {
    if pickLock.state == .latched {
      await applyMark(.pick, to: [imageID])
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
    if pickLock.state == .latched {
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
  func pointerDragCrossed(_ imageID: Int) async {
    guard dragSession.crossedTile(imageID) else { return }
    if pickLock.state == .latched {
      await applyMark(.pick, to: [imageID])
    } else if selection.mode == .select {
      selection.addFromDrag(imageID)
    }
  }

  // MARK: - Pick Lock

  func activatePickButton() async {
    // Lock entry disabled while Select is active (pin e) — the view also disables the control
    // visually; this guard is the source of truth independent of that.
    guard selection.mode != .select else { return }
    switch pickLock.activateFromPickButton() {
    case .applyPick:
      if let id = focusedImageID { await applyMark(.pick, to: [id]) }
    case .latch, .unlatch:
      break
    }
  }

  /// The amendment's discoverable "Lock Pick" long-press menu command — gate's unasked issue.
  /// Same mutual-exclusion guard as the button's own path (pin e); `PickLockState.forceLatch()`
  /// is itself a no-op if already latched, so this is safe to invoke unconditionally.
  func lockPickFromMenu() {
    guard selection.mode != .select else { return }
    pickLock.forceLatch()
  }

  // MARK: - Select mode

  func enterSelectExplicitly() {
    if pickLock.state == .latched { pickLock.unlatch() }
    selection.enterSelectExplicitly()
  }

  func done() {
    pickLock.exit()
    selection.reset(.doneOrEsc)
  }

  // MARK: - Shortcuts (P4: arrows, P, X, Shift+advance, T, Z; P5 adds Space/Enter and U)

  func handlePickShortcut(shiftHeld: Bool) async {
    guard let id = focusedImageID else { return }
    await applyMark(.pick, to: [id])
    if shiftHeld { advanceToNext() }
  }

  func handleDislikeShortcut(shiftHeld: Bool) async {
    guard let id = focusedImageID else { return }
    await applyMark(.dislike, to: [id])
    if shiftHeld { advanceToNext() }
  }

  /// U — active in the grid AND the loupe (same scene-level dispatch either way; `AppCommands`
  /// does not know or care which screen is currently on top). Shift+U also advances, mirroring
  /// P/X (`ShortcutCatalog`'s own doc comment: "Shift held on P/X/U means 'mark and advance'").
  func handleClearShortcut(shiftHeld: Bool) async {
    guard let id = focusedImageID else { return }
    await applyMark(.none, to: [id])
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
    guard focusedImageID != nil || !selection.members.isEmpty else { return }
    isTagEntryPresented = true
  }

  /// The images a tag action targets right now: the Select-mode membership when non-empty,
  /// otherwise the single focused tile — mirrors how `T`'s action-bar surface already reads in
  /// both modes rather than requiring a caller to branch on mode itself.
  var tagTargetImageIDs: [Int] {
    selection.mode == .select && !selection.members.isEmpty
      ? Array(selection.members) : focusedImageID.map { [$0] } ?? []
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
  /// "the guard is the source of truth independent of the view" posture `activatePickButton`'s
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
    let freshMarkByID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0.mark) })
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

  /// Applies `state` to every id in `imageIDs`. Preconditions are normally derived from the
  /// CURRENTLY LOADED `images` (an id not loaded is silently skipped — loaded-only membership
  /// means the caller should never have passed one anyway) — `explicitPriors` overrides this for
  /// exactly one caller (`applyConflictAgain`, diff-gate round 2 B6): a conflict-recovery retry
  /// must resubmit for every originally-rejected id INCLUDING one the active filter no longer
  /// shows, using the FRESH markview the recovery's own re-read already captured for it.
  func applyMark(
    _ state: MarkStateValue, to imageIDs: [Int], explicitPriors: [PriorMarkSnapshot]? = nil
  ) async {
    guard tryAcquireLane() else { return }
    let priors = explicitPriors ?? capturePriorSnapshots(for: imageIDs)
    guard !priors.isEmpty else {
      releaseLane()
      return
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
      guard generation == loadGeneration else { return }
      reconcileRevisions(applied.revisions ?? [])
      undo.record(UndoEntry(appliedState: state, priorStates: priors))
      if priors.count > 1 { selection.bulkActionSucceeded() }
      lastMutationError = nil
      mutationCommitCount += 1
    } catch {
      guard generation == loadGeneration else { return }
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
        guard generation == loadGeneration else { return }
        reconcileRevisions(applied.revisions ?? [])
        // Only the ids actually submitted (the loaded subset) come out of the remainder — an
        // unloaded sibling in the same group was never attempted and stays pending.
        remaining.removeAll { loadedIDs.contains($0.imageID) }
        lastMutationError = nil
        mutationCommitCount += 1
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
      guard generation == loadGeneration else { return }
      reconcileRevisions(applied.revisions ?? [])
      lastMutationError = nil
      mutationCommitCount += 1
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

  private func capturePriorSnapshots(for imageIDs: [Int]) -> [PriorMarkSnapshot] {
    imageIDs.compactMap { id in
      guard let img = images.first(where: { $0.id == id }) else { return nil }
      return PriorMarkSnapshot(
        imageID: id, state: MarkStateValue(img.mark.state), revisionBefore: img.mark.revision)
    }
  }

  private func optimisticallyApply(_ state: MarkStateValue, to imageIDs: [Int]) {
    let idSet = Set(imageIDs)
    for i in images.indices where idSet.contains(images[i].id) {
      images[i].mark.state = state.payload
    }
  }

  private func rollback(_ priors: [PriorMarkSnapshot]) {
    let byID = Dictionary(uniqueKeysWithValues: priors.map { ($0.imageID, $0.state) })
    for i in images.indices {
      if let prior = byID[images[i].id] {
        images[i].mark.state = prior.payload
      }
    }
  }

  private func reconcileRevisions(_ revisions: [Components.Schemas.MarkRevision]) {
    let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.imageId, $0.revision) })
    for i in images.indices {
      if let revision = byID[images[i].id] {
        images[i].mark.revision = revision
      }
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
    imageIDs.compactMap { id in
      guard let img = images.first(where: { $0.id == id }) else { return nil }
      return PriorTagSnapshot(
        imageID: id, tags: img.mark.tags ?? [], revisionBefore: img.mark.revision)
    }
  }

  private func optimisticallyAddTag(_ tag: String, to imageIDs: [Int]) {
    let idSet = Set(imageIDs)
    for i in images.indices where idSet.contains(images[i].id) {
      var tags = images[i].mark.tags ?? []
      if !tags.contains(tag) { tags.append(tag) }
      images[i].mark.tags = tags
    }
  }

  private func rollbackTag(_ tag: String, priors: [PriorTagSnapshot]) {
    let byID = Dictionary(uniqueKeysWithValues: priors.map { ($0.imageID, $0.tags) })
    for i in images.indices {
      if let priorTags = byID[images[i].id] {
        images[i].mark.tags = priorTags
      }
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
