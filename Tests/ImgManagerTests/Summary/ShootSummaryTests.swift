import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP28 P3 (IMGMGR-450), plan Decision 2: the Summary is the server's `FolderSummary`, verbatim —
/// complete, incomplete, zero-photo and absent — and never a count derived from grid pages.
@Suite("Shoot Summary from the server's FolderSummary (WP28 P3)")
struct ShootSummaryTests {

  private func summary(
    folderId: Int = 1, total: Int, picked: Int, disliked: Int, unmarked: Int,
    nothingLeftUnmarked: Bool, sync: Components.Schemas.FolderSyncCounts? = nil
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: picked + disliked, disliked: disliked, edited: 0,
      folderId: folderId, kind: "dated", lastTouched: nil,
      nothingLeftUnmarked: nothingLeftUnmarked, path: "photo_incoming/\(folderId)",
      picked: picked, previewOutstanding: 0, readiness: .init(rawValue: "review_in_progress")!,
      sourceTier: "local", sync: sync, total: total, unmarked: unmarked, untouched: false,
      withMasters: 0)
  }

  @Test("Complete: the server's counts and its banner")
  func complete() {
    let value = ShootSummary(
      summary(
        total: 32, picked: 28, disliked: 4, unmarked: 0, nothingLeftUnmarked: true,
        sync: .init(never: 32, refused: 0, stale: 0, synced: 0)))
    #expect(value.counts == ShootSummary.Counts(total: 32, picked: 28, disliked: 4, unmarked: 0))
    #expect(value.showsNothingLeftUnmarkedBanner)
    #expect(value.sync == ShootSummary.Sync(synced: 0, stale: 0, never: 32, refused: 0))
  }

  @Test("Incomplete: counts without the banner")
  func incomplete() {
    let value = ShootSummary(
      summary(total: 40, picked: 10, disliked: 2, unmarked: 28, nothingLeftUnmarked: false))
    #expect(value.counts == ShootSummary.Counts(total: 40, picked: 10, disliked: 2, unmarked: 28))
    #expect(value.showsNothingLeftUnmarkedBanner == false)
    #expect(value.sync == nil)
  }

  /// The banner is the SERVER's word, not an inference: `unmarked == 0` with the flag false shows
  /// none, and the flag true with unmarked photos left (a contradiction the fixture carries on
  /// purpose, folder 3) still shows it.
  @Test("The banner follows nothing_left_unmarked alone, never unmarked == 0")
  func bannerFollowsTheServerFlagAlone() {
    let zeroButFalse = ShootSummary(
      summary(total: 5, picked: 5, disliked: 0, unmarked: 0, nothingLeftUnmarked: false))
    #expect(zeroButFalse.showsNothingLeftUnmarkedBanner == false)
    let trueWithUnmarked = ShootSummary(
      summary(total: 12, picked: 4, disliked: 1, unmarked: 7, nothingLeftUnmarked: true))
    #expect(trueWithUnmarked.showsNothingLeftUnmarkedBanner)
    #expect(trueWithUnmarked.counts?.unmarked == 7)
  }

  @Test("Zero-photo: real zeros, not 'unavailable'")
  func zeroPhoto() {
    let value = ShootSummary(
      summary(total: 0, picked: 0, disliked: 0, unmarked: 0, nothingLeftUnmarked: false))
    #expect(value.counts == ShootSummary.Counts(total: 0, picked: 0, disliked: 0, unmarked: 0))
    #expect(value != .unavailable)
    #expect(value.showsNothingLeftUnmarkedBanner == false)
  }

  @Test("nil: Counts unavailable and no banner")
  func absent() {
    let value = ShootSummary(nil)
    #expect(value == .unavailable)
    #expect(value.counts == nil)
    #expect(value.showsNothingLeftUnmarkedBanner == false)
    #expect(value.sync == nil)
  }

  @Test("A sync tally with absent fields reads them as the schema's default, 0")
  func syncDefaults() {
    let value = ShootSummary(
      summary(
        total: 3, picked: 1, disliked: 0, unmarked: 2, nothingLeftUnmarked: false,
        sync: .init(stale: 2)))
    #expect(value.sync == ShootSummary.Sync(synced: 0, stale: 2, never: 0, refused: 0))
  }

  @Test("The selected folder's summary is a folder_id join; no folder or no row is unavailable")
  func forFolderJoins() {
    let rows = [
      summary(
        folderId: 1, total: 40, picked: 10, disliked: 2, unmarked: 28, nothingLeftUnmarked: false),
      summary(
        folderId: 3, total: 12, picked: 4, disliked: 1, unmarked: 7, nothingLeftUnmarked: true),
    ]
    #expect(ShootSummary.forFolder(3, in: rows).counts?.total == 12)
    #expect(ShootSummary.forFolder(1, in: rows).counts?.total == 40)
    #expect(ShootSummary.forFolder(4, in: rows) == .unavailable)
    #expect(ShootSummary.forFolder(nil, in: rows) == .unavailable)
    #expect(ShootSummary.forFolder(1, in: []) == .unavailable)
  }
}

/// WP28 P3: the grid's title reuses the names the sidebar already shows — the tree row's
/// `node.name` (the mounted tree's, else the store's remembered one), else the Needs-review row's
/// `NeedsReview.shootName(for:)` — and, for a shown folder nobody names yet, the neutral fallback.
@Suite("Workspace title from existing display names (WP28 P3)")
struct WorkspaceTitleTests {

  private let tree: [FolderTreeTier: [Components.Schemas.FolderNode]] = [
    .incoming: [
      .init(
        descendantImageCount: 12, id: 1, imageCount: 12, kind: "dated",
        name: "2026-08-27 — Stub Shoot", path: "photo_incoming/stub")
    ]
  ]

  private func summary(folderId: Int, path: String) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId,
      kind: "dated", lastTouched: nil, nothingLeftUnmarked: false, path: path, picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "review_in_progress")!,
      sourceTier: "local", sync: nil, total: 1, unmarked: 1, untouched: false, withMasters: 0)
  }

  @Test("The tree row's name wins over the summary's path leaf")
  func treeNameWins() {
    let row = summary(folderId: 1, path: "photo_incoming/stub")
    let name = WorkspaceTitle.name(
      folderID: 1, treeFolders: tree, cachedTreeFolders: nil, summaries: [row])
    #expect(name == "2026-08-27 — Stub Shoot")
  }

  @Test("A folder the tree has not loaded takes the Needs-review row's name")
  func summaryFallback() {
    let row = summary(folderId: 3, path: "photo_incoming/2026/2026-09-14-wandern")
    let name = WorkspaceTitle.name(
      folderID: 3, treeFolders: tree, cachedTreeFolders: nil, summaries: [row])
    #expect(name == NeedsReview.shootName(for: row))
    #expect(name == "2026-09-14-wandern")
  }

  @Test("Before the tree mounts, the store's remembered tree names the folder")
  func cachedTreeNames() {
    let row = summary(folderId: 1, path: "photo_incoming/stub")
    let name = WorkspaceTitle.name(
      folderID: 1, treeFolders: [:], cachedTreeFolders: tree, summaries: [row])
    #expect(name == "2026-08-27 — Stub Shoot")
    let live: [FolderTreeTier: [Components.Schemas.FolderNode]] = [
      .incoming: [
        .init(
          descendantImageCount: 12, id: 1, imageCount: 12, kind: "dated", name: "Renamed",
          path: "photo_incoming/stub")
      ]
    ]
    let fresh = WorkspaceTitle.name(
      folderID: 1, treeFolders: live, cachedTreeFolders: tree, summaries: [row])
    #expect(fresh == "Renamed")
  }

  /// Final audit F1: a cold restore pushes the grid before the Library tree mounts, and the title
  /// hosts the Summary entry — so a shown folder nobody names yet still gets a title.
  @Test("A shown folder nobody names takes the neutral title; no folder has none")
  func fallbackTitle() {
    let none = WorkspaceTitle.name(
      folderID: nil, treeFolders: tree, cachedTreeFolders: tree, summaries: [])
    #expect(none == nil)
    let unnamed = WorkspaceTitle.name(
      folderID: 99, treeFolders: tree, cachedTreeFolders: tree, summaries: [])
    #expect(unnamed == WorkspaceTitle.fallback)
    #expect(unnamed?.isEmpty == false)
    let cold = WorkspaceTitle.name(
      folderID: 4, treeFolders: [:], cachedTreeFolders: nil, summaries: [])
    #expect(cold == WorkspaceTitle.fallback)
  }
}
