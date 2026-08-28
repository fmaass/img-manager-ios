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

/// P6 (IMGMGR-116): the adjudicated 409 recovery state — non-modal by construction (plan item
/// 3, "no alerts, no auto-opening popovers, no modality anywhere in this flow"). Nil except
/// while one rejected batch's recovery is live; `handleConflict` creates it, `applyConflictAgain`/
/// `dismissConflictRecovery` end it, `retryConflictRefresh` re-attempts the read from
/// `.readFailed`. The 409 body itself is never decoded (backend does not type it, IMGMGR-177) —
/// every case here is derived purely from a sanctioned re-read (`performAuthoritativeRefresh`)
/// diffed against the `priors` the REJECTED request itself was built from.
enum ConflictRecovery: Sendable, Equatable {
  /// The re-read is in flight; nothing to show yet beyond "something was refused".
  case reading(state: MarkStateValue, priors: [PriorMarkSnapshot])
  /// The re-read succeeded: `changedIDs` is the subset whose re-read revision differs from the
  /// precondition the rejected request submitted (or, if the diff found nothing — "a revision
  /// raced back" — the WHOLE submitted batch, per plan item 3's named fallback).
  case identified(state: MarkStateValue, priors: [PriorMarkSnapshot], changedIDs: Set<Int>)
  /// The re-read itself failed (network/unreachable) — "Couldn't refresh" + Retry Refresh; Apply
  /// Again is unavailable from this state (no fresh revision exists yet to resubmit with).
  case readFailed(state: MarkStateValue, priors: [PriorMarkSnapshot])
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

  func selectShoot(folderID: Int) async {
    guard query.folderID != folderID else {
      // P6: genuine re-entry into the ALREADY-selected shoot — no scope change, so none of the
      // resets below apply, but the plan requires this to refresh rather than the prior bare
      // no-op (`selectShoot`'s own doc history: "P6 changes this for genuine re-entry").
      await authoritativeRefresh()
      return
    }
    query.folderID = folderID
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
    await acquireLaneForRefresh()
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
  /// `undoLastMark`/`addTag` still REFUSE via `tryAcquireLane()` (unchanged posture), while
  /// `authoritativeRefresh()` QUEUES via `acquireLaneForRefresh()` instead of refusing (a
  /// required lifecycle refresh must never become a dropped no-op).
  private(set) var isMutatingMark = false

  /// FIFO of refresh calls waiting for a busy lane -- see `acquireLaneForRefresh()`/`releaseLane()`.
  private var laneWaiters: [CheckedContinuation<Void, Never>] = []

  /// The REFUSING acquisition every mark/undo/tag mutation uses: `false` (no-op for the caller)
  /// if the lane is already held by anything (another mutation OR a refresh in progress).
  private func tryAcquireLane() -> Bool {
    guard !isMutatingMark else { return false }
    isMutatingMark = true
    return true
  }

  /// The QUEUEING acquisition `authoritativeRefresh()` uses: waits for the lane instead of
  /// refusing. A waiter that is resumed by `releaseLane()` is already holding the lane at that
  /// point -- the handoff never sets `isMutatingMark` false in between, so nothing else can slip
  /// in ahead of a queued refresh once the current holder releases.
  private func acquireLaneForRefresh() async {
    guard isMutatingMark else {
      isMutatingMark = true
      return
    }
    await withCheckedContinuation { continuation in
      laneWaiters.append(continuation)
    }
  }

  /// Releases the lane -- handing it DIRECTLY to the oldest queued refresh waiter if one exists
  /// (the waiter proceeds already holding it), otherwise actually freeing it.
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

  /// Entered from `applyMark`'s `.conflict` catch, which already rolled the optimistic batch
  /// back and still HOLDS the lane (its own `defer { releaseLane() }` has not run yet) -- so the
  /// re-read here goes through the lane-less `performAuthoritativeRefresh()` core, never
  /// `authoritativeRefresh()` itself (which would try to re-acquire the very lane this call is
  /// still inside of and deadlock).
  private func handleConflict(state: MarkStateValue, priors: [PriorMarkSnapshot]) async {
    // Item 2: "Clear/invalidate the undo slot ... on refusal recovery" -- unconditionally,
    // before the re-read even starts, since an existing undo entry's priors are already suspect
    // the instant a write anywhere in this batch was refused for being stale.
    undo.clear()
    await performRecoveryReread(state: state, priors: priors)
  }

  /// `Retry Refresh` (plan item 6) from `.readFailed` -- a fresh top-level entry point (the
  /// original `applyMark` call has long since returned), so THIS acquires the lane itself,
  /// refusing like any other user-initiated mutation action if something else is in flight.
  func retryConflictRefresh() async {
    guard case .readFailed(let state, let priors) = conflictRecovery else { return }
    guard tryAcquireLane() else { return }
    defer { releaseLane() }
    await performRecoveryReread(state: state, priors: priors)
  }

  /// The shared re-read + diff, run by both `handleConflict` (lane already held by the caller)
  /// and `retryConflictRefresh` (lane held by ITS OWN acquisition just above).
  private func performRecoveryReread(state: MarkStateValue, priors: [PriorMarkSnapshot]) async {
    conflictRecovery = .reading(state: state, priors: priors)
    let refreshed = await performAuthoritativeRefresh()
    // A newer recovery attempt for this SAME rejected batch may already have superseded this one
    // (e.g. a concurrent `retryConflictRefresh` -- unlikely under the lane, but checked rather
    // than assumed); if so, leave whatever it left behind untouched.
    guard case .reading(let stillState, let stillPriors) = conflictRecovery,
      stillState == state, stillPriors == priors
    else { return }
    guard refreshed else {
      conflictRecovery = .readFailed(state: state, priors: priors)
      return
    }
    // Item 3.3: diff the RE-READ revision against the precondition the rejected request
    // submitted -- this IS "the affected batch", derived purely through the sanctioned list
    // re-read, never a decode of the untyped 409 body. An id absent from the refreshed query
    // entirely (it no longer matches the current filter) counts as changed too -- the only way
    // it could have left the query is a state/tag change on the server.
    let freshRevisionByID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0.mark.revision) })
    var changed = Set<Int>()
    for prior in priors {
      if let fresh = freshRevisionByID[prior.imageID] {
        if fresh != prior.revisionBefore { changed.insert(prior.imageID) }
      } else {
        changed.insert(prior.imageID)
      }
    }
    // Item 3.3's named fallback: "If the diff finds no differing image -- e.g. a revision raced
    // back -- fall back to marking the whole batch" rather than silently showing nothing refused.
    if changed.isEmpty { changed = Set(priors.map(\.imageID)) }
    conflictRecovery = .identified(state: state, priors: priors, changedIDs: changed)
  }

  /// `Apply Again` (plan item 5): resubmits the REJECTED intent, but through the ordinary
  /// `applyMark` path -- since the re-read already replaced `images` with server truth, the
  /// preconditions `applyMark` builds are the FRESH revisions automatically, with no separate
  /// resubmission machinery needed. Never called automatically (item 5: "Never auto-reapply") --
  /// only this explicit call site exists, wired to the banner's button.
  func applyConflictAgain() async {
    guard case .identified(let state, let priors, _) = conflictRecovery else { return }
    conflictRecovery = nil
    await applyMark(state, to: priors.map(\.imageID))
  }

  /// `Keep Server Version` (plan item 5): dismisses the recovery surface with no further write --
  /// `images` already carries server truth from the re-read, so there is nothing left to do.
  func dismissConflictRecovery() {
    conflictRecovery = nil
  }

  /// Applies `state` to every id in `imageIDs` that is CURRENTLY loaded (an id not present in
  /// `images` is silently skipped — there is nothing loaded to snapshot a precondition from,
  /// and loaded-only membership means the caller should never have passed one anyway).
  func applyMark(_ state: MarkStateValue, to imageIDs: [Int]) async {
    guard tryAcquireLane() else { return }
    let priors = capturePriorSnapshots(for: imageIDs)
    guard !priors.isEmpty else {
      releaseLane()
      return
    }
    defer { releaseLane() }
    optimisticallyApply(state, to: priors.map(\.imageID))
    let preconditions = priors.map {
      Components.Schemas.MarkPrecondition(imageId: $0.imageID, revision: $0.revisionBefore)
    }
    do {
      let applied = try await service.setMarkState(
        imageIDs: priors.map(\.imageID), state: state, preconditions: preconditions)
      reconcileRevisions(applied.revisions ?? [])
      undo.record(UndoEntry(appliedState: state, priorStates: priors))
      if priors.count > 1 { selection.bulkActionSucceeded() }
      lastMutationError = nil
    } catch {
      rollback(priors)
      let mutationError = (error as? GridServiceError) ?? .unreachable
      lastMutationError = mutationError
      // P6 item 3: the whole recovery sequence (re-read + diff) runs HERE, still inside this
      // call's own lane hold (`defer { releaseLane() }` above has not fired yet) — see
      // `handleConflict`'s own doc comment for why it must never go through
      // `authoritativeRefresh()`'s own lane acquisition.
      if mutationError == .conflict {
        await handleConflict(state: state, priors: priors)
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
      optimisticallyApply(targetState, to: priors.map(\.imageID))
      let preconditions = priors.map {
        Components.Schemas.MarkPrecondition(imageId: $0.imageID, revision: $0.revisionBefore)
      }
      do {
        let applied = try await service.setMarkState(
          imageIDs: priors.map(\.imageID), state: targetState, preconditions: preconditions)
        reconcileRevisions(applied.revisions ?? [])
        // Only the ids actually submitted (the loaded subset) come out of the remainder — an
        // unloaded sibling in the same group was never attempted and stays pending.
        remaining.removeAll { loadedIDs.contains($0.imageID) }
        lastMutationError = nil
      } catch {
        rollback(priors)
        lastMutationError = (error as? GridServiceError) ?? .unreachable
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

  /// P6: joins the SAME serialized mutation lane state/undo already use (`tryAcquireLane()`) —
  /// previously tags were entirely outside it, so a tag write and a concurrent Pick/Dislike/Undo
  /// could interleave their optimistic snapshots. A conflict here still just rolls back and
  /// surfaces `lastMutationError` (the new "Changed elsewhere" recovery state machine is scoped
  /// to `applyMark`'s state mutations only — see the phase ledger's scope note).
  func addTag(_ tag: String, to imageIDs: [Int]) async {
    guard tryAcquireLane() else { return }
    let priors = capturePriorTagSnapshots(for: imageIDs)
    guard !priors.isEmpty else {
      releaseLane()
      return
    }
    defer { releaseLane() }
    optimisticallyAddTag(tag, to: priors.map(\.imageID))
    let preconditions = priors.map {
      Components.Schemas.MarkPrecondition(imageId: $0.imageID, revision: $0.revisionBefore)
    }
    do {
      let applied = try await service.editMarkTags(
        imageIDs: priors.map(\.imageID), operation: .add, tag: tag, preconditions: preconditions)
      reconcileRevisions(applied.revisions ?? [])
      lastMutationError = nil
    } catch {
      rollbackTag(tag, priors: priors)
      lastMutationError = (error as? GridServiceError) ?? .unreachable
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

  private struct PriorTagSnapshot {
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
