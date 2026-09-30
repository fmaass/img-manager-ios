import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP29 P1 (IMGMGR-452), plan Decision 3: the breadcrumb is the shoot's name plus the SERVER's
/// `image_count` for that folder, from the tree that named it — never a count from loaded pages,
/// and no count at all for a folder no tree holds.
@Suite("Grid breadcrumb — name and server count (WP29 P1)")
struct GridBreadcrumbTests {

  private let tree: [FolderTreeTier: [Components.Schemas.FolderNode]] = [
    .incoming: [
      .init(
        descendantImageCount: 12, id: 1, imageCount: 12, kind: "dated",
        name: "2026-08-27 — Stub Shoot", path: "photo_incoming/stub"),
      .init(
        descendantImageCount: 15, id: 2, imageCount: 1, kind: "dated", name: "Parent",
        path: "photo_incoming/parent"),
    ]
  ]

  private func summary(folderId: Int, path: String) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId,
      kind: "dated", lastTouched: nil, nothingLeftUnmarked: false, path: path, picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "review_in_progress")!,
      sourceTier: "local", sync: nil, total: 99, unmarked: 1, withMasters: 0)
  }

  @Test("A tree folder reads its name and the server's own image count")
  func treeFolderCarriesNameAndCount() {
    let crumb = GridBreadcrumb.make(
      folderID: 1, treeFolders: tree, cachedTreeFolders: nil, summaries: [])
    #expect(crumb == GridBreadcrumb(title: "2026-08-27 — Stub Shoot", subtitle: "12 photos"))
  }

  @Test("The count is the folder's OWN image_count, singular for one")
  func ownCountSingular() {
    // `descendantImageCount` is 15 here; the breadcrumb states `image_count` (plan Phase 1).
    let crumb = GridBreadcrumb.make(
      folderID: 2, treeFolders: tree, cachedTreeFolders: nil, summaries: [])
    #expect(crumb?.subtitle == "1 photo")
  }

  @Test("Before the tree mounts, the remembered tree supplies name and count")
  func cachedTreeSuppliesTheCount() {
    let crumb = GridBreadcrumb.make(
      folderID: 1, treeFolders: [:], cachedTreeFolders: tree, summaries: [])
    #expect(crumb?.title == "2026-08-27 — Stub Shoot")
    #expect(crumb?.subtitle == "12 photos")
  }

  @Test("A folder only a summary names gets its name and NO count — never the summary's total")
  func summaryOnlyFolderHasNoCount() {
    let row = summary(folderId: 3, path: "photo_incoming/2026/2026-09-14-wandern")
    let crumb = GridBreadcrumb.make(
      folderID: 3, treeFolders: tree, cachedTreeFolders: nil, summaries: [row])
    #expect(crumb?.title == "2026-09-14-wandern")
    #expect(crumb?.subtitle == nil)
  }

  @Test("A shown folder nobody names takes the neutral title and no count; no folder, nothing")
  func fallbackAndNone() {
    let unnamed = GridBreadcrumb.make(
      folderID: 42, treeFolders: [:], cachedTreeFolders: nil, summaries: [])
    #expect(unnamed == GridBreadcrumb(title: WorkspaceTitle.fallback, subtitle: nil))
    #expect(
      GridBreadcrumb.make(folderID: nil, treeFolders: tree, cachedTreeFolders: nil, summaries: [])
        == nil)
  }

  @Test("The title is always WorkspaceTitle's — the breadcrumb adds no naming rule")
  func titleIsWorkspaceTitle() {
    let row = summary(folderId: 3, path: "photo_incoming/2026/2026-09-14-wandern")
    for id in [1, 2, 3, 42] {
      let crumb = GridBreadcrumb.make(
        folderID: id, treeFolders: tree, cachedTreeFolders: nil, summaries: [row])
      let name = WorkspaceTitle.name(
        folderID: id, treeFolders: tree, cachedTreeFolders: nil, summaries: [row])
      #expect(crumb?.title == name)
    }
  }

  @Test("Count text: zero, one, many and absent")
  func countText() {
    #expect(GridBreadcrumb.countText(0) == "0 photos")
    #expect(GridBreadcrumb.countText(1) == "1 photo")
    #expect(GridBreadcrumb.countText(12) == "12 photos")
    #expect(GridBreadcrumb.countText(nil) == nil)
  }
}
