import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-549 (design R3-2, r2 amendment 3): Pinned and Recent on this device, for one account on
/// one server — the pin round trip, Recent's order and cap, and every identity transition.
@MainActor
@Suite("ShootShortcutsStore — Pinned and Recent, account-guarded")
struct ShootShortcutsStoreTests {

  /// The live identity the store reads, changed by the test the way a sign-in or a server
  /// switch changes `AuthSession.status`.
  @MainActor
  private final class LiveIdentity {
    var value: ShootShortcutsStore.Identity?
    init(_ value: ShootShortcutsStore.Identity?) { self.value = value }
  }

  private static let alice = ShootShortcutsStore.Identity(
    subject: "alice", baseURL: "https://img.example")
  private static let bob = ShootShortcutsStore.Identity(
    subject: "bob", baseURL: "https://img.example")
  private static let aliceElsewhere = ShootShortcutsStore.Identity(
    subject: "alice", baseURL: "https://other.example")

  private func entry(_ id: Int, _ tier: String = "local") -> ShootShortcutsStore.Entry {
    .init(folderID: id, sourceTier: tier)
  }

  private func store(
    _ live: LiveIdentity, defaults: UserDefaults
  ) -> ShootShortcutsStore {
    let store = ShootShortcutsStore(defaults: defaults, currentIdentity: { live.value })
    store.bind(live.value)
    return store
  }

  @Test("pin then unpin round-trips, and pins keep pin order")
  func pinUnpinRoundTrip() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    shortcuts.togglePin(entry(5))
    shortcuts.togglePin(entry(3))
    #expect(shortcuts.pinned == [entry(5), entry(3)])
    #expect(shortcuts.isPinned(entry(5)))
    shortcuts.togglePin(entry(5))
    #expect(shortcuts.pinned == [entry(3)])
    #expect(!shortcuts.isPinned(entry(5)))
  }

  @Test("an entry is its folder AND its tier: the same id in another tier is another shoot")
  func entryMatchesFolderAndTier() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    shortcuts.togglePin(entry(5, "local"))
    #expect(!shortcuts.isPinned(entry(5, "archive")))
  }

  @Test("a repeat open moves the shoot to the front of Recent")
  func recentDedupesToFront() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    for id in [1, 2, 3, 1] { shortcuts.recordOpen(entry(id)) }
    #expect(shortcuts.recent == [entry(1), entry(3), entry(2)])
  }

  @Test("Recent keeps the last six opens")
  func recentIsCappedAtSix() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    for id in 1...8 { shortcuts.recordOpen(entry(id)) }
    #expect(shortcuts.recent.map(\.folderID) == [8, 7, 6, 5, 4, 3])
    #expect(ShootShortcutsStore.recentLimit == 6)
  }

  @Test("pinning never records an open")
  func pinningIsNotAnOpen() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    shortcuts.togglePin(entry(5))
    #expect(shortcuts.recent.isEmpty)
  }

  @Test("the same account on the same server gets its shortcuts back in a new store")
  func sameAccountRestores() {
    let defaults = makeEphemeralDefaults()
    let live = LiveIdentity(Self.alice)
    let first = store(live, defaults: defaults)
    first.togglePin(entry(5))
    first.recordOpen(entry(3))

    let second = store(live, defaults: defaults)
    #expect(second.pinned == [entry(5)])
    #expect(second.recent == [entry(3)])
  }

  @Test("an account change while the store stays alive clears it before and after bind")
  func accountChangeWhileAlive() {
    let defaults = makeEphemeralDefaults()
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: defaults)
    shortcuts.togglePin(entry(5))

    // The live identity moved, `bind` has not run yet: nothing of Alice's may show.
    live.value = Self.bob
    #expect(shortcuts.pinned.isEmpty)
    shortcuts.recordOpen(entry(9))
    #expect(shortcuts.recent.isEmpty)

    shortcuts.bind(Self.bob)
    #expect(shortcuts.pinned.isEmpty)
    #expect(shortcuts.recent.isEmpty)

    // Bob never wrote, so Alice's blob is still hers.
    live.value = Self.alice
    shortcuts.bind(Self.alice)
    #expect(shortcuts.pinned == [entry(5)])
  }

  @Test("a different server is a different identity")
  func serverChangeDiscards() {
    let defaults = makeEphemeralDefaults()
    let live = LiveIdentity(Self.alice)
    store(live, defaults: defaults).togglePin(entry(5))

    live.value = Self.aliceElsewhere
    let elsewhere = store(live, defaults: defaults)
    #expect(elsewhere.pinned.isEmpty)
  }

  @Test("sign-out erases memory and the persisted blob")
  func endSessionErases() {
    let defaults = makeEphemeralDefaults()
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: defaults)
    shortcuts.togglePin(entry(5))
    #expect(defaults.data(forKey: ShootShortcutsStore.key) != nil)

    shortcuts.endSession()
    #expect(defaults.data(forKey: ShootShortcutsStore.key) == nil)
    live.value = nil
    #expect(shortcuts.pinned.isEmpty)
    #expect(store(LiveIdentity(Self.alice), defaults: defaults).pinned.isEmpty)
  }

  @Test("signed out, the shortcuts live in memory only and are never promoted into an account")
  func anonymousHistoryIsDroppedOnSignIn() {
    let defaults = makeEphemeralDefaults()
    let live = LiveIdentity(nil)
    let shortcuts = store(live, defaults: defaults)
    shortcuts.recordOpen(entry(3))
    shortcuts.togglePin(entry(5))
    #expect(shortcuts.recent == [entry(3)])
    #expect(shortcuts.pinned == [entry(5)])
    #expect(defaults.data(forKey: ShootShortcutsStore.key) == nil)

    live.value = Self.alice
    shortcuts.bind(Self.alice)
    #expect(shortcuts.recent.isEmpty)
    #expect(shortcuts.pinned.isEmpty)
  }

  @Test("a malformed or unknown-version blob reads as empty and is overwritten by the next write")
  func malformedBlobReadsEmpty() throws {
    let defaults = makeEphemeralDefaults()
    defaults.set(Data("not json".utf8), forKey: ShootShortcutsStore.key)
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: defaults)
    #expect(shortcuts.pinned.isEmpty)
    shortcuts.togglePin(entry(5))
    #expect(ShootShortcutsStore.read(from: defaults)?.pinned == [entry(5)])

    let future = ShootShortcutsStore.Blob(
      version: 99, subject: "alice", baseURL: "https://img.example", pinned: [entry(7)],
      recent: [])
    defaults.set(try JSONEncoder().encode(future), forKey: ShootShortcutsStore.key)
    #expect(ShootShortcutsStore.read(from: defaults) == nil)
    #expect(store(live, defaults: defaults).pinned.isEmpty)
  }

  // MARK: - The open recorder (ruling g)

  /// A counting sink for the recorder's `@MainActor` `record` closure, so the tests count CALLS
  /// rather than read the deduplicated Recent list.
  @MainActor
  private final class Calls {
    var records: [ShootShortcutsStore.Entry] = []
  }

  @Test("a user open records into Recent and routes, in that one call")
  func recorderRecordsAndRoutes() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    var routed: [Int] = []
    let recorder = ShootOpenRecorder(
      shortcuts: shortcuts, isShoot: { _, _ in true },
      route: { id, _ in routed.append(id) })

    recorder.userOpened(id: 5, tier: .local)
    recorder.userOpened(id: 21, tier: .archive)
    #expect(routed == [5, 21])
    #expect(shortcuts.recent == [entry(21, "archive"), entry(5, "local")])
  }

  @Test("an open with an unknown tier routes but records nothing it could not draw")
  func recorderSkipsUnknownTier() {
    let live = LiveIdentity(Self.alice)
    let shortcuts = store(live, defaults: makeEphemeralDefaults())
    var routed: [Int] = []
    let recorder = ShootOpenRecorder(
      shortcuts: shortcuts, isShoot: { _, _ in true },
      route: { id, _ in routed.append(id) })

    recorder.userOpened(id: 5, tier: nil)
    #expect(routed == [5])
    #expect(shortcuts.recent.isEmpty)
  }

  @Test("a container open routes to its grid but is never recorded")
  func recorderSkipsContainers() {
    let calls = Calls()
    var routed: [Int] = []
    let recorder = ShootOpenRecorder(
      record: { calls.records.append($0) }, isShoot: { id, _ in id != 2 },
      route: { id, _ in routed.append(id) })

    recorder.userOpened(id: 2, tier: .local)
    #expect(routed == [2])
    #expect(calls.records.isEmpty)
    recorder.userOpened(id: 5, tier: .local)
    #expect(calls.records == [entry(5)])
  }

  /// The overflow grid's path, call for call: a tile tap (`pick`), then the sheet's `onDismiss`
  /// (`handOff`) — delivered TWICE here, as a second dismissal callback would — into the recorder
  /// with a counting sink. The count is of CALLS, which the deduplicated Recent list cannot show.
  @Test("one overflow tile selection reaches the recorder exactly once")
  func oneTileSelectionRecordsOnce() {
    let calls = Calls()
    var routeCalls = 0
    let recorder = ShootOpenRecorder(
      record: { calls.records.append($0) }, isShoot: { _, _ in true },
      route: { _, _ in routeCalls += 1 })

    var overflow = UntouchedOverflow()
    overflow.open()
    #expect(overflow.isPresented)
    overflow.pick(summary(31))
    #expect(!overflow.isPresented)
    #expect(calls.records.isEmpty, "Nothing opens while the sheet is still going away.")

    for _ in 0..<2 {
      overflow.handOff { id, tier in recorder.userOpened(id: id, tier: tier) }
    }
    #expect(calls.records == [entry(31)])
    #expect(routeCalls == 1)
  }

  @Test("an overflow sheet closed with Done or swiped away opens nothing")
  func overflowDismissedWithoutAPickOpensNothing() {
    var opened = 0
    var overflow = UntouchedOverflow()
    overflow.open()
    overflow.close()
    overflow.handOff { _, _ in opened += 1 }
    overflow.open()
    overflow.isPresented = false
    overflow.handOff { _, _ in opened += 1 }
    #expect(opened == 0)
  }

  // MARK: - The shoot predicate

  private func summary(
    _ folderID: Int, kind: String = "dated", sourceTier: String = "local"
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderID, kind: kind,
      lastTouched: nil, nothingLeftUnmarked: false,
      path: "photo_incoming/2026/2026-05-0\(folderID % 10)-x", picked: 0, previewOutstanding: 0,
      readiness: .init(rawValue: "ready_to_review")!, sourceTier: sourceTier, sync: nil,
      total: 1, unmarked: 1, untouched: true, withMasters: 0)
  }

  private func tree(
    _ nodes: [FolderTreeTier: [(Int, String)]]
  ) -> QueueStore.CachedTree {
    QueueStore.CachedTree(
      foldersByTier: nodes.mapValues { rows in
        rows.map { row in
          Components.Schemas.FolderNode(
            id: row.0, kind: row.1, name: "n\(row.0)", path: "p\(row.0)")
        }
      },
      fetchedAt: Date(timeIntervalSince1970: 0), subject: "alice")
  }

  @Test("a summary-backed shoot is a shoot; the tree answers for a folder with no summary")
  func shootPredicateSummaryThenTree() {
    let summaries = [summary(5), summary(4, kind: "template")]
    let remembered = tree([
      .incoming: [(2, "year"), (5, "dated"), (8, "dated_split")], .archive: [(20, "year")],
    ])
    func isShoot(_ id: Int, _ tier: GridSourceTier) -> Bool {
      ShootOpenRecorder.isSelectableShoot(
        id: id, tier: tier, summaries: summaries, tree: remembered)
    }
    #expect(isShoot(5, .local))
    #expect(!isShoot(4, .local), "A template folder's summary is not a shoot's.")
    #expect(!isShoot(2, .local), "A year container is not a shoot.")
    #expect(isShoot(8, .local), "A shoot the tree knows counts before its summary arrives.")
    #expect(!isShoot(20, .archive))
    #expect(!isShoot(5, .archive), "Folder 5 is a local shoot; the archive tier knows no 5.")
    #expect(!isShoot(99, .local), "A folder nothing knows is not recorded as a shoot.")
    #expect(
      !ShootOpenRecorder.isSelectableShoot(id: 8, tier: .local, summaries: [], tree: nil),
      "With no tree and no summary nothing is a shoot.")
  }

  @Test("the shortcuts key stays out of the Settings sheet's exact key set")
  func keyIsNotASettingsKey() {
    #expect(!SettingsPreferences.persistedKeys.contains(ShootShortcutsStore.key))
    #expect(ShootShortcutsStore.key == "sidebar.shortcuts")
  }
}
