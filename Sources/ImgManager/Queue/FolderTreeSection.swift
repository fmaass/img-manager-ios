import ImgManagerAPI
import SwiftUI

/// Q5: the iPad-only SECONDARY, collapsed "Folders" disclosure below the queue sidebar — built
/// from the EXISTING `GET /api/folders` (`FolderNode`: parent_id + name), NEVER from summaries
/// (flat, no tree fields). Local and Archive tier branches; each row routes through the ONE
/// atomic `GridStore.selectShoot(folderID:sourceTier:)` entry point, so a tree tap always sets
/// the complete destination `(folderID, sourceTier)` in a single scope transition — never a
/// separate follow-up `applyFilterChange` call.
struct FolderTreeSection: View {
  let gridService: GridService
  @Binding var selectedFolderID: Int?
  let onSelect: (Int, GridSourceTier) -> Void

  @State private var isExpanded = false
  @State private var localFolders: [Components.Schemas.FolderNode] = []
  @State private var archiveFolders: [Components.Schemas.FolderNode] = []

  var body: some View {
    DisclosureGroup("Folders", isExpanded: $isExpanded) {
      tierBranch("Local", folders: localFolders, tier: .local)
      tierBranch("Archive", folders: archiveFolders, tier: .archive)
    }
    .task {
      if let tree = try? await gridService.folders(sourceTier: .local) {
        localFolders = tree.items
      }
      if let tree = try? await gridService.folders(sourceTier: .archive) {
        archiveFolders = tree.items
      }
    }
  }

  @ViewBuilder
  private func tierBranch(
    _ title: String, folders: [Components.Schemas.FolderNode], tier: GridSourceTier
  ) -> some View {
    let shoots = ShootListFilter.shoots(folders)
    if !shoots.isEmpty {
      DisclosureGroup(title) {
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
            .simultaneousGesture(
              TapGesture().onEnded {
                selectedFolderID = folder.id
                onSelect(folder.id, tier)
              }
            )
        }
      }
    }
  }
}

/// TEMPORARY — mutation-loop RED probe (disciplined-implementation §1: a test written against
/// already-working code proves nothing until it has been seen failing for the BEHAVIOUR's
/// absence). These two bodies reproduce the PRE-P6 behaviour on purpose — Compact reaches no
/// shoot at all, and the disclosure never opens itself — so this commit's gate run shows
/// `FolderTreeSectionTests` red. The next commit replaces them with the real decisions and wires
/// them into the view. `ShootListFilter.shootKinds` is mutated in the same commit and for the
/// same reason.
enum FolderTreePresentation {
  static func startsExpanded(in mode: LayoutMode) -> Bool { false }

  static func shootRows(
    for mode: LayoutMode, folders: [Components.Schemas.FolderNode]
  ) -> [Components.Schemas.FolderNode] {
    mode == .compact ? [] : ShootListFilter.shoots(folders)
  }
}
