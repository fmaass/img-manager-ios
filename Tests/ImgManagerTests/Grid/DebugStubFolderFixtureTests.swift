import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// IMGMGR-350 P2: the DEBUG fixture's `/api/folders` answer is SCOPED, and this is what says so.
///
/// Why it has to be (plan gate round 1, B2): the stub returned one taxonomy for every folders
/// request whatever the query, so all three tier branches of the new home would have rendered the
/// same folders and `TierHomeUITests` could have walked a shape the real API never returns —
/// `edits` and `incoming` are the SAME `source_tier` and differ only in the `tree` prefix
/// (img-manager `app/api/folders.py:33-59`), which a per-tier fixture is the only way to model.
///
/// Kinds and counts stay the live vocabulary and the live shape (IMGMGR-173, probed 2026-08-30):
/// dated leaves under year containers, an archive whose mirrored folders report zero.
@Suite("DEBUG folder fixture — one taxonomy per (source_tier, tree)")
struct DebugStubFolderFixtureTests {

  #if DEBUG
    private func fixture(_ tier: FolderTreeTier) -> [Components.Schemas.FolderNode] {
      DebugStubTransport.fixtureFolders(
        sourceTier: tier.sourceTier.rawValue, tree: tier.treePrefix)
    }

    private func ids(_ nodes: [Components.Schemas.FolderNode]) -> Set<Int> {
      Set(nodes.map(\.id))
    }

    /// Every folder id a tier's RENDERED rows carry, folds walked through — a month row has no id
    /// of its own, so this is exactly the set of real folders on screen.
    private func renderedFolderIDs(_ tier: FolderTreeTier) -> Set<Int> {
      var found: Set<Int> = []
      func walk(_ items: [FolderTreeItem]) {
        for item in items {
          if let node = item.node { found.insert(node.id) }
          walk(item.children)
        }
      }
      walk(FolderTreeModel.tierItems(FolderTreeModel.forest(fixture(tier)), tier: tier))
      return found
    }

    @Test("each browse tier answers with its own non-empty taxonomy, sharing no folder id")
    func eachTierAnswersWithItsOwnDisjointTaxonomy() {
      let incoming = ids(fixture(.incoming))
      let edits = ids(fixture(.edits))
      let archive = ids(fixture(.archive))

      #expect(!incoming.isEmpty)
      #expect(!edits.isEmpty)
      #expect(!archive.isEmpty)
      #expect(incoming.isDisjoint(with: edits))
      #expect(incoming.isDisjoint(with: archive))
      #expect(edits.isDisjoint(with: archive))
    }

    /// The routing itself, through the transport's own `send` rather than through the fixture
    /// accessor: what the app receives is decided by the QUERY the generated client built, which
    /// is the half a content-only assertion cannot see.
    @Test("the transport routes each folders request by its own (source_tier, tree)")
    func theTransportRoutesByTheRequestedPair() async throws {
      let transport = DebugStubTransport()

      let edits = try await folderIDs(
        from: transport, path: "/api/folders?source_tier=local&tree=photo_edits")
      let incoming = try await folderIDs(
        from: transport, path: "/api/folders?source_tier=local&tree=photo_incoming")
      let archive = try await folderIDs(from: transport, path: "/api/folders?source_tier=archive")

      #expect(edits == [10, 11])
      #expect(incoming.contains(1))
      #expect(!incoming.contains(11))
      #expect(archive == [20, 21, 22])
    }

    private func folderIDs(from transport: DebugStubTransport, path: String) async throws
      -> Set<Int>
    {
      let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
      let (_, body) = try await transport.send(
        request, body: nil, baseURL: URL(string: "https://example.invalid")!,
        operationID: Operations.FolderTreeApiFoldersGet.id)
      let data = try await Data(collecting: try #require(body), upTo: 1_000_000)
      let tree = try JSONDecoder().decode(Components.Schemas.FolderTree.self, from: data)
      return Set(tree.items.map(\.id))
    }

    /// The Edits tier is a browse destination of its own, not a second view of Incoming: its
    /// shoot is reachable there and exists nowhere else.
    @Test("the Edits walk reaches a shoot the Incoming tier does not have")
    func theEditsWalkReachesAShootIncomingLacks() {
      let editsShoots = FolderTreeModel.selectableShoots(
        in: FolderTreeModel.forest(fixture(.edits)))
      let incomingShoots = FolderTreeModel.selectableShoots(
        in: FolderTreeModel.forest(fixture(.incoming)))

      #expect(editsShoots.map(\.id) == [11])
      #expect(!incomingShoots.map(\.id).contains(11))
      // And the tier's own root row is hoisted away, so that shoot is a row of the tier itself.
      #expect(renderedFolderIDs(.edits) == [11])
    }

    /// IMGMGR-350 P3: the badge is a `folder_id` join, so a summary whose folder the tree does
    /// not render is a badge nobody can see. The fixture's summaries used to be ids 101-106
    /// against a tree of ids 1-4 — an empty join on every row, and a badge suite that would have
    /// been green against a screen with no badges on it.
    @Test("every fixture summary joins onto a folder the tree actually renders")
    func everyFixtureSummaryJoinsOntoARenderedFolder() {
      let rendered = renderedFolderIDs(.incoming)
        .union(renderedFolderIDs(.edits))
        .union(renderedFolderIDs(.archive))
      let summaryIDs = Set(DebugStubTransport.fixtureSummaries().map(\.folderId))

      #expect(summaryIDs == [1, 3, 5, 11, 21, 22])
      #expect(summaryIDs.isSubset(of: rendered))
      // Every readiness value the string table knows is represented, so the badge suite walks a
      // real vocabulary rather than one value repeated six times.
      #expect(
        Set(DebugStubTransport.fixtureSummaries().map(\.readiness.rawValue)).count
          == ReadinessSection.allCases.count)
    }

    /// The control for IMGMGR-350's "no prune in this package" default (Context default 6): the
    /// archive's mirrored, zero-count folder is STILL a row. A follow-up ticket under IMGMGR-322
    /// adds the web's prune behind a persisted toggle, and this assertion is what it inverts.
    @Test("the archive keeps its zero-count mirrored folder beside a real shoot")
    func theArchiveKeepsItsMirroredZeroCountFolder() {
      let archive = fixture(.archive)
      let mirrored = archive.first { $0.id == 22 }
      let real = archive.first { $0.id == 21 }

      #expect(mirrored?.descendantImageCount == 0)
      #expect(real?.descendantImageCount == 4)
      #expect(renderedFolderIDs(.archive) == [20, 21, 22])
    }
  #endif
}
