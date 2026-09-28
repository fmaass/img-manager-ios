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
  }
}
