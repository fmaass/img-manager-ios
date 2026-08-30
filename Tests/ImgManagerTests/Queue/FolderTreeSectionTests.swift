import ImgManagerAPI
import Testing

@testable import ImgManager

/// P6 (IMGMGR-216): `RootView.sidebar` passed `treeSection: nil` on Compact, so the iPhone had
/// zero browse surface beyond its queue cards — a shoot that was not currently a queue card was
/// unreachable on the phone. The phase's acceptance property is "a Compact-idiom folder
/// navigation reaching every shoot the iPad reaches"; these pins are that property.
///
/// The fixture's `kind` values are the LIVE vocabulary, never an invented one: probed 2026-08-30
/// against the deployed backend (`GET /api/folders`, both tiers, read-only through the running
/// `img-manager` container) — {other, dated, template, import, dated_split, project} over 855
/// rows (local 166, archive 689), of which 465 are shoot rows (local 110, archive 355). That is
/// the IMGMGR-173 discipline: a server vocabulary is pinned against the real API, never against
/// a fixture the same suite wrote.
@Suite("Folder tree presentation — one component, both idioms")
struct FolderTreeSectionTests {

  private func node(id: Int, kind: String) -> Components.Schemas.FolderNode {
    .init(id: id, kind: kind, name: "n\(id)", path: "p\(id)")
  }

  /// One tier's worth of rows in the live vocabulary, in wire order: two shoot leaves among four
  /// non-shoot containers.
  private var folders: [Components.Schemas.FolderNode] {
    [
      node(id: 2, kind: "other"),
      node(id: 60, kind: "dated"),
      node(id: 61, kind: "template"),
      node(id: 62, kind: "import"),
      node(id: 63, kind: "dated_split"),
      node(id: 64, kind: "project"),
    ]
  }

  @Test("Compact renders the same shoot set as Regular")
  func compactRendersTheSameShootSetAsRegular() {
    let compact = FolderTreePresentation.shootRows(for: .compact, folders: folders)
    let regular2 = FolderTreePresentation.shootRows(for: .regular2, folders: folders)
    let regular3 = FolderTreePresentation.shootRows(for: .regular3, folders: folders)
    // Stated positively first: a mode that renders NOTHING would satisfy set equality with
    // another empty mode, so the reachable set is pinned by value before it is compared.
    #expect(compact.map(\.id) == [60, 63])
    #expect(compact.map(\.id) == regular2.map(\.id))
    #expect(compact.map(\.id) == regular3.map(\.id))
  }

  @Test("the Folders disclosure opens itself on Compact and stays collapsed on Regular")
  func foldersDisclosureOpensOnCompactOnly() {
    #expect(FolderTreePresentation.startsExpanded(in: .compact))
    #expect(!FolderTreePresentation.startsExpanded(in: .regular2))
    #expect(!FolderTreePresentation.startsExpanded(in: .regular3))
  }

  /// Diff-gate round 1, blocker 1. `RootView.layoutMode` is `.compact` until the first
  /// `.onGeometryChange` pass resolves it (`RootView.swift:28`), and this section mounts before
  /// that — so an expansion frozen at mount time makes an iPad launch open the secondary tree,
  /// against D13. The state model must answer from the CURRENT mode until the reader has chosen.
  @Test("a Regular launch never inherits the transient Compact default")
  func regularLaunchStaysCollapsedThroughTheUnresolvedCompactDefault() {
    var expansion = FolderTreeExpansion()
    #expect(expansion.isExpanded(in: .compact))
    #expect(!expansion.isExpanded(in: .regular2))
    #expect(!expansion.isExpanded(in: .regular3))

    // And once the reader has chosen, the choice wins in every mode — a resize must not stomp it.
    expansion.setExpanded(true)
    #expect(expansion.isExpanded(in: .regular2))
    #expect(expansion.isExpanded(in: .regular3))
    expansion.setExpanded(false)
    #expect(!expansion.isExpanded(in: .compact))
  }
}
