import ImgManagerAPI
import SwiftUI

/// The "Folders" disclosure below the queue: the second way into the grid, on BOTH idioms since
/// P6 (IMGMGR-216). Built from the EXISTING `GET /api/folders` (`FolderNode`: parent_id + name),
/// NEVER from summaries (flat, no tree fields). Local and Archive tier branches; each row routes
/// through the ONE atomic `GridStore.selectShoot(folderID:sourceTier:)` entry point, so a tree
/// tap always sets the complete destination `(folderID, sourceTier)` in a single scope
/// transition — never a separate follow-up `applyFilterChange` call.
///
/// P6 (IMGMGR-216): this used to be iPad-only. `RootView.sidebar` passed `treeSection: nil` on
/// Compact, so the phone's only navigation was whichever shoots happened to be queue cards, and
/// every other shoot was unreachable there. No such branch exists anywhere now — one component,
/// both idioms — and `QueueView.treeSection` is non-optional so it cannot come back without a
/// type change. The ONLY thing that varies with the layout mode is the disclosure's INITIAL
/// expansion, decided once in `FolderTreePresentation` where a test can read it.
struct FolderTreeSection: View {
  let gridService: GridService
  let layoutMode: LayoutMode
  @Binding var selectedFolderID: Int?
  let onSelect: (Int, GridSourceTier) -> Void

  @State private var expansion = FolderTreeExpansion()
  @State private var localFolders: [Components.Schemas.FolderNode] = []
  @State private var archiveFolders: [Components.Schemas.FolderNode] = []
  @State private var didLoad = false

  var body: some View {
    DisclosureGroup(isExpanded: expansionBinding) {
      if didLoad {
        tierBranch("Local", folders: localFolders, tier: .local)
        tierBranch("Archive", folders: archiveFolders, tier: .archive)
      } else {
        // Compact opens this disclosure by default (see `FolderTreePresentation`), and the two
        // folder calls it waits on measured ~0.6 s (local) and ~2.5 s (archive) server-side
        // against production on 2026-08-30 — an already-open disclosure with no rows under it
        // reads as "this library has no folders" for those seconds. It says Loading instead.
        // (Regular keeps its collapsed default; this also fixes the same silence there for
        // anyone who expands during the first load.)
        ProgressView()
      }
    } label: {
      Text("Folders").accessibilityIdentifier("foldersDisclosure")
    }
    .task {
      if let tree = try? await gridService.folders(sourceTier: .local) {
        localFolders = tree.items
      }
      if let tree = try? await gridService.folders(sourceTier: .archive) {
        archiveFolders = tree.items
      }
      didLoad = true
    }
  }

  /// Derived on every read, never frozen at mount: `RootView.layoutMode` is still `.compact`
  /// when this section first mounts (`RootView.swift:28`; `applyWidth` only corrects it on the
  /// first `.onGeometryChange` pass), so a value captured at mount time makes an iPad launch
  /// inherit Compact's opened default and start with the secondary tree expanded, against D13.
  /// `FolderTreeExpansion` holds the reader's own choice instead, and defers to the CURRENT
  /// mode until there is one.
  private var expansionBinding: Binding<Bool> {
    Binding(
      get: { expansion.isExpanded(in: layoutMode) },
      set: { expansion.setExpanded($0) })
  }

  @ViewBuilder
  private func tierBranch(
    _ title: String, folders: [Components.Schemas.FolderNode], tier: GridSourceTier
  ) -> some View {
    let shoots = FolderTreePresentation.shootRows(for: layoutMode, folders: folders)
    if !shoots.isEmpty {
      DisclosureGroup {
        ForEach(shoots, id: \.id) { folder in
          // Same row-navigation pattern as the pre-P7 sidebar (RootView's own doc comment on
          // this exact fix): `.simultaneousGesture` layered on TOP of the enclosing List's own
          // selection recognizer, never a bare `Button` and never `.onChange(of:
          // selectedFolderID)` — a plain Button never pushes NavigationSplitView's column on
          // Compact, and onChange never fires on a same-value re-tap.
          Text(folder.name)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(folder.id)
            // Stable, id-derived identifiers so the UI test drives the REAL rows rather than
            // matching a localizable label (the shoot name is server data).
            .accessibilityIdentifier("folderRow-\(folder.id)")
            .simultaneousGesture(
              TapGesture().onEnded {
                selectedFolderID = folder.id
                onSelect(folder.id, tier)
              }
            )
        }
      } label: {
        Text(title).accessibilityIdentifier("folderTreeTier-\(title)")
      }
    }
  }
}

/// Whether the "Folders" disclosure is open, as a value a test can drive. A reader's own choice
/// wins from the moment it is made; until then the answer is re-derived from the CURRENT layout
/// mode on every read. That distinction is the whole point (diff-gate round 1, blocker 1): the
/// first shipped version seeded `@State` at mount time, when `RootView.layoutMode` is still its
/// pre-geometry `.compact` default, so an iPad launch started with the secondary tree expanded
/// and D13's Regular-collapsed contract was broken by a value nobody could see.
struct FolderTreeExpansion {
  private var readerChoice: Bool?

  init(readerChoice: Bool? = nil) { self.readerChoice = readerChoice }

  func isExpanded(in mode: LayoutMode) -> Bool {
    readerChoice ?? FolderTreePresentation.startsExpanded(in: mode)
  }

  mutating func setExpanded(_ expanded: Bool) { readerChoice = expanded }
}

/// The two — and only two — presentation decisions the folder tree makes, both pure and both
/// readable by a test. P6 (IMGMGR-216) exists because the equivalent decision used to be an
/// inline ternary in `RootView.sidebar` (`treeSection: layoutMode == .compact ? nil : …`), where
/// nothing could assert it and the phone silently had no browse surface at all. Neither function
/// reads the device idiom — `LayoutMode` is resolved from measured width
/// plus `horizontalSizeClass` (`LayoutResolver`), and this is the one place the tree consults it.
enum FolderTreePresentation {
  /// The Folders disclosure opens itself on Compact, where it is the only way to reach a shoot
  /// that is not currently a queue card; on Regular it stays the collapsed SECONDARY surface
  /// below the queue (D13, unchanged since WP8 P7). Nothing else about the tree varies by mode.
  static func startsExpanded(in mode: LayoutMode) -> Bool { mode == .compact }

  /// The shoot rows the tree offers. `mode` is taken and DELIBERATELY not consulted: "the phone
  /// reaches every shoot the iPad reaches" is this phase's acceptance criterion, so the mode is
  /// routed through the one function a test can pin
  /// (`FolderTreeSectionTests.compactRendersTheSameShootSetAsRegular`) instead of being absent
  /// from the type system entirely. Any future mode-dependent filtering has to be written here,
  /// and goes RED there. Which leaves are shoots stays `ShootListFilter`'s single definition —
  /// the server's `kind` vocabulary, never a second client-side classification.
  static func shootRows(
    for mode: LayoutMode, folders: [Components.Schemas.FolderNode]
  ) -> [Components.Schemas.FolderNode] {
    ShootListFilter.shoots(folders)
  }
}
