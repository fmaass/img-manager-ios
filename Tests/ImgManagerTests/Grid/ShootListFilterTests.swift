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

  /// The IMGMGR-173 guard, re-pinned against a LIVE reading of the deployed API rather than
  /// against a fixture this suite also wrote. Probe, 2026-08-30, `GET /api/folders` for both
  /// tiers through the running `img-manager` container (read-only, HTTP 200 both): the complete
  /// `kind` vocabulary on the wire is {other, dated, template, import, dated_split, project} —
  /// 855 rows (local 166, archive 689), of which 465 are shoot rows (local 110, archive 355).
  /// `"day"` does not occur in either tier.
  @Test("rejects the retired \"day\" value and accepts exactly the live vocabulary")
  func rejectsTheRetiredDayKindAndAcceptsTheLiveVocabulary() {
    let liveVocabulary = ["other", "dated", "template", "import", "dated_split", "project"]
    let nodes = liveVocabulary.enumerated().map { node(id: $0.offset, kind: $0.element) }
    #expect(ShootListFilter.shoots(nodes).map(\.kind) == ["dated", "dated_split"])
    #expect(ShootListFilter.shootKinds == ["dated", "dated_split"])
    #expect(ShootListFilter.shoots([node(id: 99, kind: "day")]).isEmpty)
  }
}
