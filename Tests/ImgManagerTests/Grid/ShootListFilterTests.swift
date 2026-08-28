import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-173: the sidebar filtered on `kind == "day"`, a value the API never emits — the
/// shoot list was empty against production while fixtures using the same invented value
/// kept every test green. This suite pins the filter to the backend's REAL `FolderKind`
/// vocabulary; reverting the filter to `"day"` (or any single stale value) goes RED here.
@Suite("Shoot-list filter — pinned to the API's real FolderKind vocabulary")
struct ShootListFilterTests {

  private func node(id: Int, kind: String) -> Components.Schemas.FolderNode {
    .init(id: id, kind: kind, name: "n\(id)", path: "p\(id)")
  }

  @Test("admits exactly the dated-shoot kinds, in input order")
  func admitsDatedKinds() {
    let nodes = [
      node(id: 1, kind: "dated"),
      node(id: 2, kind: "import"),
      node(id: 3, kind: "dated_split"),
      node(id: 4, kind: "template"),
    ]
    #expect(ShootListFilter.shoots(nodes).map(\.id) == [1, 3])
  }

  @Test("rejects every non-shoot kind the classifier can emit")
  func rejectsNonShootKinds() {
    let nodes = ["import", "project", "template", "other"].enumerated().map {
      node(id: $0.offset, kind: $0.element)
    }
    #expect(ShootListFilter.shoots(nodes).isEmpty)
  }

  @Test("rejects the retired \"day\" value — the IMGMGR-173 regression pin")
  func rejectsRetiredDayKind() {
    #expect(ShootListFilter.shoots([node(id: 1, kind: "day")]).isEmpty)
    #expect(!ShootListFilter.shootKinds.contains("day"))
  }
}
