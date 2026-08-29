import ImgManagerAPI

/// The two tiers every tier-aware query names, and the four DISTINCT generated payload types
/// the same two cases have to be spelled as (one per endpoint — swift-openapi-generator emits a
/// separate nested enum for each operation's query, so there is no single shared type to map
/// onto).
///
/// WP12 (IMGMGR-199) moved this enum out of `GridService.swift` UNCHANGED. `QueueModels.swift`
/// references it (`QueueCardDestination.route`), and `QueueModels.swift` is one of the files
/// compiled into BOTH the app and the widget extension — while `GridService.swift` pulls in the
/// whole grid stack (`GridImagesQuery`, `MarkStateValue`, `ProxyFetchResult`, …) that an
/// extension has no business containing. Splitting the one self-contained type out is what lets
/// the queue vocabulary cross the target boundary; nothing about the type itself changed.

enum GridSourceTier: String, Sendable, Equatable {
  case local
  case archive

  /// WP8 P7 (Q5): the folder-TREE endpoint's own distinct generated payload type — added
  /// alongside the three images/facets/neighbours mappings already here when `folders(
  /// sourceTier:)` stopped hardcoding `.local`.
  var folderTreePayload: Operations.FolderTreeApiFoldersGet.Input.Query.SourceTierPayload {
    switch self {
    case .local: return .local
    case .archive: return .archive
    }
  }

  var listImagesPayload: Operations.ListImagesApiImagesGet.Input.Query.SourceTierPayload {
    switch self {
    case .local: return .local
    case .archive: return .archive
    }
  }

  var facetsPayload: Operations.ImageFacetsApiFacetsGet.Input.Query.SourceTierPayload {
    switch self {
    case .local: return .local
    case .archive: return .archive
    }
  }

  var neighboursPayload:
    Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.SourceTierPayload
  {
    switch self {
    case .local: return .local
    case .archive: return .archive
    }
  }
}
