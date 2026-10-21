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

  /// A summary as the server sends one, with the two fields these tests care about spelled at
  /// the call site: which folder it is about, and what readiness the SERVER put on it.
  private func summary(
    folderId: Int, readiness: String, decided: Int = 0, unmarked: Int = 0,
    previewOutstanding: Int = 0, untouched: Bool = false
  ) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: decided, disliked: 0, edited: 0, folderId: folderId,
      kind: "dated", lastTouched: nil, nothingLeftUnmarked: unmarked == 0, path: "p\(folderId)",
      picked: 0, previewOutstanding: previewOutstanding,
      readiness: .init(rawValue: readiness)!, sourceTier: "local", sync: nil,
      total: decided + unmarked, unmarked: unmarked, untouched: untouched, withMasters: 0)
  }

  /// IMGMGR-549 (R3-1): the hollow ring replaces the readiness caption. It is the SERVER's
  /// `untouched` flag joined by `folder_id` — the fixture's counts contradict it on purpose
  /// (everything decided under a served `untouched: true`), so a client that derived the ring
  /// from counts would fail here.
  @Test("the ring shows the SERVED untouched flag on a shoot row, never one derived from counts")
  func theRingShowsTheServedFlag() {
    let shoot = node(id: 60, kind: "dated", descendant: 12, own: 12)
    let touched = node(id: 61, kind: "dated", descendant: 3, own: 3)
    let index = FolderTreeRowPresentation.index([
      summary(folderId: 60, readiness: "ready_for_editing", decided: 12, untouched: true),
      summary(folderId: 61, readiness: "ready_to_review", untouched: false),
    ])

    #expect(FolderTreeRowPresentation.showsUntouchedRing(for: shoot, summaries: index))
    #expect(!FolderTreeRowPresentation.showsUntouchedRing(for: touched, summaries: index))
  }

  /// The two absences: a shoot the summaries say nothing about, and a container — which is not
  /// a shoot and must not borrow a summary row keyed to its id.
  @Test("no summary means no ring, and a container never carries one")
  func aFolderWithoutASummaryCarriesNoRing() {
    let unlisted = node(id: 62, kind: "dated", descendant: 3, own: 3)
    let container = node(id: 2, kind: "other", descendant: 12, own: 0)
    let index = FolderTreeRowPresentation.index([
      summary(folderId: 60, readiness: "review_in_progress", untouched: true),
      summary(folderId: 2, readiness: "ready_to_review", untouched: true),
    ])

    #expect(!FolderTreeRowPresentation.showsUntouchedRing(for: unlisted, summaries: index))
    #expect(!FolderTreeRowPresentation.showsUntouchedRing(for: container, summaries: index))
  }

  /// The join table itself, and the ring's own handle.
  @Test("the summaries index is keyed by folder_id, and the ring handle by the same id")
  func theIndexIsKeyedByFolderID() {
    let index = FolderTreeRowPresentation.index([
      summary(folderId: 7, readiness: "sync_problem"),
      summary(folderId: 9, readiness: "historical_unreviewed"),
    ])

    #expect(Set(index.keys) == [7, 9])
    #expect(index[7]?.readiness.rawValue == "sync_problem")
    #expect(FolderTreeRowPresentation.untouchedIdentifier(for: 7) == "folderUntouched-7")
    #expect(FolderTreeRowPresentation.untouchedIdentifier(for: 42) == "folderUntouched-42")
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

  /// The identifiers the UI tests drive (`FolderTreeRowAnatomyUITests`, and the two shipped tree
  /// tests) are derived here and nowhere else, so a rename cannot leave a test hunting for a
  /// handle the app stopped emitting. Keyed by the server's folder id, like every other
  /// identifier in this tree.
  ///
  /// The row's own two strings are UNCHANGED from 4753450 — what moved (diff-gate r1, B1) is the
  /// element they are applied to: the name text, never the row container, because a container
  /// identifier overrides its descendants' (GridView.swift:743-747) and would hide the cover and
  /// subline handles below.
  @Test("row, cover and subline identifiers are keyed by the server's folder id")
  func identifiersAreKeyedByFolderID() {
    let shoot = node(id: 1, kind: "dated", descendant: 12, own: 12)
    let container = node(id: 2, kind: "other", descendant: 12, own: 0)

    #expect(FolderTreeRowPresentation.rowIdentifier(for: shoot, id: 1) == "folderRow-1")
    #expect(FolderTreeRowPresentation.rowIdentifier(for: container, id: 2) == "folderContainer-2")
    #expect(FolderTreeRowPresentation.thumbnailIdentifier(for: 1) == "folderRowThumbnail-1")
    #expect(FolderTreeRowPresentation.thumbnailIdentifier(for: 3) == "folderRowThumbnail-3")
    #expect(FolderTreeRowPresentation.sublineIdentifier(for: 1) == "folderRowSubline-1")
    #expect(FolderTreeRowPresentation.sublineIdentifier(for: 3) == "folderRowSubline-3")
  }
}
