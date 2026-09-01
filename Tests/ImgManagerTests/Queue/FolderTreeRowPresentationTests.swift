import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP16 P5 (p3332 decision 2, IMGMGR-296). The Folders tree's SHOOT rows take the drawer-row
/// anatomy the queue cards already ship (a cover thumbnail and a count subline); its CONTAINER
/// rows keep exactly the layout they had, trailing count included. These are the pure decisions
/// behind that split, so "which rows get a cover" and "what the subline says" are values a test
/// reads rather than a shape only a screenshot could disagree with.
///
/// The fixture's `kind` values are the LIVE vocabulary (`ShootListFilter.shootKinds`, pinned
/// against the real API by IMGMGR-173): `dated`/`dated_split` navigate, everything else is a
/// container.
@Suite("Folder tree row anatomy — cover and subline on shoots only")
struct FolderTreeRowPresentationTests {

  private func node(
    id: Int, kind: String, descendant: Int, own: Int, children: [FolderTreeNode] = []
  ) -> FolderTreeNode {
    FolderTreeNode(
      folder: .init(
        descendantImageCount: descendant, id: id, imageCount: own, kind: kind, name: "n\(id)",
        path: "p\(id)"),
      children: children)
  }

  @Test("only shoot rows get a cover and a subline — a container keeps its trailing count")
  func coverAndSublineAreShootOnly() {
    let shoot = node(id: 60, kind: "dated", descendant: 12, own: 12)
    let split = node(id: 63, kind: "dated_split", descendant: 4, own: 4)
    let container = node(id: 2, kind: "other", descendant: 12, own: 0)
    let template = node(id: 4, kind: "template", descendant: 3, own: 3)

    #expect(FolderTreeRowPresentation.showsThumbnail(shoot))
    #expect(FolderTreeRowPresentation.showsThumbnail(split))
    #expect(!FolderTreeRowPresentation.showsThumbnail(container))
    #expect(!FolderTreeRowPresentation.showsThumbnail(template))

    #expect(FolderTreeRowPresentation.subline(for: shoot) == "12 photos")
    #expect(FolderTreeRowPresentation.subline(for: split) == "4 photos")
    #expect(FolderTreeRowPresentation.subline(for: container) == nil)
    #expect(FolderTreeRowPresentation.subline(for: template) == nil)

    // The count MOVES on a shoot row rather than being duplicated, and a container's row is
    // untouched by this phase — both halves of "no capability dropped, nothing shown twice".
    #expect(FolderTreeRowPresentation.trailingCount(for: shoot) == nil)
    #expect(FolderTreeRowPresentation.trailingCount(for: container) == "12")
    #expect(FolderTreeRowPresentation.trailingCount(for: template) == "3")
  }

  /// The subline states the SERVER's `descendant_image_count` — the same number the row already
  /// showed, and exactly the population a tap opens. The fixture makes every client-derivable
  /// alternative distinct from it: the shoot owns 9 images and holds one child reporting 3,
  /// while the server says 40. A client that reported the folder's own count (9), its child's
  /// (3), or rolled the two up itself (12) states a different number and fails here.
  @Test("the subline is the server's descendant count, never a client-side recomputation")
  func sublineIsTheServersOwnRollUp() {
    let child = node(id: 4, kind: "template", descendant: 3, own: 3)
    let shoot = node(id: 3, kind: "dated", descendant: 40, own: 9, children: [child])

    #expect(FolderTreeRowPresentation.subline(for: shoot) == "40 photos")
    // Named explicitly so a future rewrite that "fixes" the number has to argue with the test:
    // 9 is the folder's own count, 3 its child's, 12 their sum.
    #expect(FolderTreeRowPresentation.subline(for: shoot) != "9 photos")
    #expect(FolderTreeRowPresentation.subline(for: shoot) != "3 photos")
    #expect(FolderTreeRowPresentation.subline(for: shoot) != "12 photos")
  }

  /// The identifiers the UI test drives (`FolderTreeRowAnatomyUITests`) are derived here and
  /// nowhere else, so a rename cannot leave the test hunting for a handle the app stopped
  /// emitting. Keyed by the server's folder id, like every other identifier in this tree.
  @Test("cover and subline identifiers are keyed by the server's folder id")
  func identifiersAreKeyedByFolderID() {
    #expect(FolderTreeRowPresentation.thumbnailIdentifier(for: 1) == "folderRowThumbnail-1")
    #expect(FolderTreeRowPresentation.thumbnailIdentifier(for: 3) == "folderRowThumbnail-3")
    #expect(FolderTreeRowPresentation.sublineIdentifier(for: 1) == "folderRowSubline-1")
    #expect(FolderTreeRowPresentation.sublineIdentifier(for: 3) == "folderRowSubline-3")
  }
}
