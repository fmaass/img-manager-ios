import Foundation
import Observation

/// WP28 P1 (IMGMGR-448): the folder tree's view state, hoisted out of `FolderTreeSection` so the
/// surfaces that render the tree share it — the split's sidebar at Regular, and at Compact both
/// the Library tab and the Search tab (plan: "one shared tree model, so loading and expansion are
/// shared with Library"). `FolderTreeModel` stays what it is, the pure functions that turn this
/// state into rows; this object only holds what those functions read.
///
/// Owned by `RootView`, one per scene. Every mount of a `FolderTreeSection` still runs the ONE
/// fetch path (`runTreeLoad`) exactly as before; the generation below is what keeps two mounted
/// sections from publishing out of order, the same fence a pull-to-refresh racing the first load
/// already relied on.
@MainActor
@Observable
final class FolderTreeState {
  var load = FolderTreeLoad.loading
  /// The rows the reader has opened — folders AND month folds, hence the widened identity
  /// (`FolderTreeItemID`): a fold opens and closes like a branch and is selectable like nothing.
  var expandedBranches: Set<FolderTreeItemID> = []
  var expandedTiers: Set<FolderTreeTier> = []
  /// F3: which tree load is the current one. Advanced by every start, checked by every finish,
  /// and advanced by `endSession()` so a load started under the old session is never current.
  private(set) var loadGeneration = 0
  /// IMGMGR-462 (WP31 P3): whether this session's Compact launch opening has been applied (see
  /// `applyCompactLaunchOpening`). Re-armed by `endSession()`, so the next account opens the
  /// same way the first one did.
  private(set) var appliedCompactLaunchOpening = false

  /// IMGMGR-462 (WP31 P3): the tier branches the Compact tree opens with. Incoming alone — the
  /// tier new shoots land in — so its root-level shoots are one tap from their grid and two from
  /// Triage (plan AC 3: "shoot row, `gridTriageButton`"). Before this every tier launched closed
  /// and the walk was three taps (tier, row, Triage). Edits and Archive stay closed, and no row
  /// inside Incoming is opened: a shoot under a year container is still reached through its year
  /// and month rows, exactly as before.
  static let compactLaunchTiers: Set<FolderTreeTier> = [.incoming]

  /// Starts a load: advances the generation and returns it, the ticket its finish presents.
  func beginLoad() -> Int {
    loadGeneration += 1
    return loadGeneration
  }

  /// Publishes a finished load, resolved against the cached tree, only if it is still the
  /// current load and was not cancelled (`FolderTreeLoadGate`). Returns whether it published.
  @discardableResult
  func publish(_ fresh: FolderTreeLoad, generation: Int, cached: QueueStore.CachedTree?) -> Bool {
    let current = loadGeneration
    guard FolderTreeLoadGate.accepts(fresh, generation: generation, current: current) else {
      return false
    }
    load = FolderTreeLoad.resolve(fresh: fresh, cached: cached)
    return true
  }

  /// IMGMGR-462 (WP31 P3): opens `compactLaunchTiers` ONCE per session, at Compact, on the first
  /// published load that answered for Incoming. Additive (it never closes anything) and one-shot:
  /// after it ran, the reader's own disclosure choices stand — a tier closed by hand stays closed
  /// through a pull-to-refresh, a second mounted section (the Search tab shares this state) and a
  /// relaunch of the load. Regular is untouched: the split's sidebar launches exactly as before,
  /// and a Regular load does not consume the one-shot, so a later Compact mount (an iPad window
  /// narrowed into Slide Over) still opens the way the phone does.
  ///
  /// A load whose Incoming tier did not answer (still loading, or failed) consumes nothing: a
  /// retry that answers is the first load that can show the tier, so that is when it opens.
  func applyCompactLaunchOpening(layoutMode: LayoutMode) {
    guard layoutMode == .compact, !appliedCompactLaunchOpening, load.answered(.incoming) else {
      return
    }
    appliedCompactLaunchOpening = true
    expandedTiers.formUnion(Self.compactLaunchTiers)
  }

  /// The session boundary (sign-out, erased credentials), called beside
  /// `QueueStore.endSession()`. This object outlives the workspace view that used to own this
  /// state, so without it the next account would open on the previous account's folders and
  /// expansion. FENCE FIRST: advancing the generation drops every load still in flight for the
  /// old session, whenever it lands.
  func endSession() {
    loadGeneration += 1
    load = .loading
    expandedBranches = []
    expandedTiers = []
    appliedCompactLaunchOpening = false
  }
}
