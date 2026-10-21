import Foundation
import ImgManagerAPI
import Observation

/// IMGMGR-549 (design R3-2): the sidebar's Pinned and Recent shoots — kept on THIS device, for
/// the signed-in account on this server only.
///
/// One Codable blob under `sidebar.shortcuts`, outside `SettingsPreferences.persistedKeys` (that
/// list is the Settings sheet's exact key set). The blob carries the identity it was written
/// for, the QueueSnapshot rule (`QueueStore.replaySnapshotIfNeeded`): a blob whose subject or
/// server differs from the bound identity is never shown.
///
/// Identity transitions:
/// - `bind(_:)` with a DIFFERENT identity first clears memory, then loads the persisted blob only
///   when it was written for the new identity; otherwise it starts empty. Unauthenticated memory
///   (a `nil` identity) is never promoted into an account.
/// - Writes persist only while bound to a signed-in identity, and always carry that identity.
/// - Reads are empty whenever the LIVE identity (`currentIdentity`) differs from the bound one,
///   so the rows of the account that just left cannot render in the moment before `RootView`'s
///   `bind` runs.
/// - `endSession()` (the sign-out erase path) clears memory and removes the key.
/// - A malformed blob, or one with an unknown version, reads as empty and is overwritten by the
///   next write.
@Observable
@MainActor
final class ShootShortcutsStore {

  /// Who the shortcuts belong to: the signed-in subject on one server.
  struct Identity: Equatable, Sendable {
    var subject: String
    var baseURL: String
  }

  /// One remembered shoot. The tier is the wire `source_tier`, and the summary join matches BOTH
  /// fields, because `local` holds Incoming and Edits alike.
  struct Entry: Codable, Equatable, Hashable, Sendable {
    var folderID: Int
    var sourceTier: String
  }

  /// The persisted shape. `version` is checked on read, so a future layout cannot be misread.
  struct Blob: Codable, Equatable, Sendable {
    var version: Int
    var subject: String
    var baseURL: String
    var pinned: [Entry]
    var recent: [Entry]
  }

  nonisolated static let key = "sidebar.shortcuts"
  nonisolated static let version = 1
  /// "Recent = the last 6 opened on this device" (R3-2).
  nonisolated static let recentLimit = 6

  private let defaults: UserDefaults
  private let currentIdentity: @MainActor () -> Identity?

  private(set) var boundIdentity: Identity?
  private var storedPinned: [Entry] = []
  private var storedRecent: [Entry] = []

  init(
    defaults: UserDefaults = .standard,
    currentIdentity: @escaping @MainActor () -> Identity?
  ) {
    self.defaults = defaults
    self.currentIdentity = currentIdentity
  }

  /// Pinned shoots, in pin order.
  var pinned: [Entry] { isLive ? storedPinned : [] }

  /// Recently opened shoots, newest first, at most `recentLimit`.
  var recent: [Entry] { isLive ? storedRecent : [] }

  func isPinned(_ entry: Entry) -> Bool { pinned.contains(entry) }

  /// Binds the store to `identity` (RootView calls this whenever its auth identity changes).
  func bind(_ identity: Identity?) {
    guard identity != boundIdentity else { return }
    storedPinned = []
    storedRecent = []
    boundIdentity = identity
    guard let identity, let blob = Self.read(from: defaults), blob.subject == identity.subject,
      blob.baseURL == identity.baseURL
    else { return }
    storedPinned = blob.pinned
    storedRecent = Array(blob.recent.prefix(Self.recentLimit))
  }

  /// Pins `entry` at the end of the pin order, or unpins it when it is already pinned.
  func togglePin(_ entry: Entry) {
    guard isLive else { return }
    if let index = storedPinned.firstIndex(of: entry) {
      storedPinned.remove(at: index)
    } else {
      storedPinned.append(entry)
    }
    persist()
  }

  /// A user open: moves `entry` to the front of Recent, capped at `recentLimit`.
  func recordOpen(_ entry: Entry) {
    guard isLive else { return }
    storedRecent.removeAll { $0 == entry }
    storedRecent.insert(entry, at: 0)
    if storedRecent.count > Self.recentLimit {
      storedRecent.removeLast(storedRecent.count - Self.recentLimit)
    }
    persist()
  }

  /// The sign-out erase: memory and the persisted blob both go.
  func endSession() {
    storedPinned = []
    storedRecent = []
    boundIdentity = nil
    defaults.removeObject(forKey: Self.key)
  }

  private var isLive: Bool { currentIdentity() == boundIdentity }

  private func persist() {
    guard let identity = boundIdentity else { return }
    let blob = Blob(
      version: Self.version, subject: identity.subject, baseURL: identity.baseURL,
      pinned: storedPinned, recent: storedRecent)
    guard let data = try? JSONEncoder().encode(blob) else { return }
    defaults.set(data, forKey: Self.key)
  }

  /// The persisted blob, or `nil` for an absent, undecodable or unknown-version one.
  static func read(from defaults: UserDefaults) -> Blob? {
    guard let data = defaults.data(forKey: key),
      let blob = try? JSONDecoder().decode(Blob.self, from: data), blob.version == version
    else { return nil }
    return blob
  }
}

/// The ONE place a user's open of a shoot is recorded into Recent (IMGMGR-549 ruling g): every
/// row tap — tree rows, the sidebar's section rows, the overflow grid's tiles and the Compact
/// rows — reaches the grid through `RootView.selectShoot`, which is this. Restore, Handoff and the
/// DEBUG auto-select call `GridStore.selectShoot` directly and never pass through here, and the
/// rows' Pin/Unpin menu actions call only `ShootShortcutsStore.togglePin`.
///
/// Recent is recent SHOOTS: a container or year row also routes through here (it opens its
/// subtree's grid), but `isShoot` refuses it BEFORE anything is recorded, so six container opens
/// cannot push the shoots out of the six-entry list.
@MainActor
struct ShootOpenRecorder {
  /// Where a recorded open goes — `ShootShortcutsStore.recordOpen` in the app; a counter in the
  /// tests, which must see each call rather than the deduplicated list.
  let record: @MainActor (ShootShortcutsStore.Entry) -> Void
  /// Whether this folder, in this tier, is a selectable shoot (`isSelectableShoot(...)`).
  let isShoot: @MainActor (Int, GridSourceTier) -> Bool
  let route: (Int, GridSourceTier?) -> Void

  init(
    record: @escaping @MainActor (ShootShortcutsStore.Entry) -> Void,
    isShoot: @escaping @MainActor (Int, GridSourceTier) -> Bool,
    route: @escaping (Int, GridSourceTier?) -> Void
  ) {
    self.record = record
    self.isShoot = isShoot
    self.route = route
  }

  init(
    shortcuts: ShootShortcutsStore,
    isShoot: @escaping @MainActor (Int, GridSourceTier) -> Bool,
    route: @escaping (Int, GridSourceTier?) -> Void
  ) {
    self.init(record: { shortcuts.recordOpen($0) }, isShoot: isShoot, route: route)
  }

  /// Records the open when the tier is one the client knows (an unknown wire tier is not a row
  /// the join could draw) and the folder is a shoot, then routes it — routing never depends on
  /// whether it was recorded.
  func userOpened(id: Int, tier: GridSourceTier?) {
    if let tier, isShoot(id, tier) {
      record(.init(folderID: id, sourceTier: tier.rawValue))
    }
    route(id, tier)
  }

  /// The shoot test the app hands `isShoot`: the folder's SUMMARY when the server sent one (a
  /// summary-backed row — Untouched, Pinned, Recent, an overflow tile — always has one), else
  /// its node in the remembered tree, through the tree's own `FolderTreeNode.isSelectableShoot`
  /// predicate (a tree row whose summary has not arrived). Both are `ShootListFilter.shootKinds`.
  /// A folder neither knows is not recorded: an open is only remembered as a shoot when
  /// something says it is one.
  static func isSelectableShoot(
    id: Int, tier: GridSourceTier, summaries: [Components.Schemas.FolderSummary],
    tree: QueueStore.CachedTree?
  ) -> Bool {
    if let summary = summaries.first(where: {
      $0.folderId == id && $0.sourceTier == tier.rawValue
    }) {
      return ShootListFilter.shootKinds.contains(summary.kind)
    }
    for treeTier in FolderTreeTier.allCases where treeTier.sourceTier == tier {
      if let node = tree?.foldersByTier[treeTier]?.first(where: { $0.id == id }) {
        // `FolderTreeNode.isSelectableShoot`, read off the wire node it wraps.
        return ShootListFilter.shootKinds.contains(node.kind)
      }
    }
    return false
  }
}
