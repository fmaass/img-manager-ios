import Foundation

/// The three places the folder tree stacks at its top level, and the SERVER scope each one asks
/// for — the native twin of the web's `EntryPoint`
/// (img-manager `frontend/src/lib/entryPoint.ts:15`, `:30-38`, read-only).
///
/// Deliberately NOT `GridSourceTier`, and this is the whole reason the type exists. That one is
/// the `source_tier` query value and has exactly two cases, `local` and `archive`
/// (`GridSourceTier.swift:15-27`); `edits` is not a source tier at all but a TREE-ROLE PREFIX
/// inside the local store — `GET /api/folders` takes `tree` separately and documents it as
/// "tree-role prefix within a local store (default: the incoming spine)"
/// (img-manager `app/api/folders.py:38`, resolved at `:54`). A browse tier is therefore the PAIR
/// `(source_tier, tree)`, and this is the one place that says which pair each place means.
///
/// `allCases` is the order the tree stacks them in — the ticket's own Incoming / Edits / Archive,
/// matching the web's `TIER_ORDER` (`entryPoint.ts:25`).
enum FolderTreeTier: String, Sendable, Equatable, CaseIterable {
  case incoming
  case edits
  case archive

  /// The store this tier reads. Incoming and Edits are the SAME store, told apart by the prefix
  /// below — that is the fact `GridSourceTier` cannot express.
  var sourceTier: GridSourceTier {
    switch self {
    case .incoming, .edits: return .local
    case .archive: return .archive
    }
  }

  /// The `tree` prefix this tier narrows the local store by. The values are the server's own
  /// defaults, verbatim: `PHOTO_TREE_ORIGINALS` = `photo_incoming` and `PHOTO_TREE_EDITS` =
  /// `photo_edits` (img-manager `app/config.py:113-114`), which are also the two strings the web
  /// sends (`entryPoint.ts:33`, `:35`). `nil` for the archive, whose store is whole — the server
  /// applies no prefix there unless one is asked for (`app/api/folders.py:54`).
  ///
  /// Naming `photo_incoming` explicitly rather than sending `tree: nil` is behaviour-preserving
  /// against the deployed configuration for exactly that reason: `nil` resolves server-side to
  /// `PHOTO_TREE_ORIGINALS`, which IS `photo_incoming`.
  var treePrefix: String? {
    switch self {
    case .incoming: return "photo_incoming"
    case .edits: return "photo_edits"
    case .archive: return nil
    }
  }

  /// What the tier's row says on screen. The ticket's vocabulary (IMGMGR-350: "Incoming / Edits /
  /// Archive"), not the web's lowercase-verbatim tier key (`entryPoint.ts:23`) and not the
  /// pre-350 native pair ("Local" / "Archive", `FolderTreeSection.swift:68-69`).
  var label: String {
    switch self {
    case .incoming: return "Incoming"
    case .edits: return "Edits"
    case .archive: return "Archive"
    }
  }
}
