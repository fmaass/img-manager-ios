import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// The DEBUG fixture's `/api/facets` answer, pinned by shape.
///
/// **Provenance, stated plainly (diff-gate round 1, B2).** This test is GREEN the moment it lands
/// and never had an isolated RED, because no honest one was available. The phase claimed the
/// fixture expansion's RED was `FilterPopoverUITests`' "the `≥ 4` row states a count above zero"
/// assertion; that claim does not hold. At `6391916` neither the funnel nor any popover row
/// existed, so that assertion failed on a missing element whatever the fixture contained — it
/// could not discriminate a thin fixture from an absent surface. The fixture expansion and the
/// implementation then landed in the same commit (`2a5a9e0`), so no commit ever isolated it.
/// History is not being rewritten for this; the test is written POST HOC and says so.
///
/// It still earns its place going forward: the fixture is the only response the iPad UI legs ever
/// read, so an edit that quietly drops the zero-count mark row would make the popover's
/// zero-disabled assertion vacuous rather than failing it. That regression fails HERE instead.
///
/// Numbers come from the live probe's own shape (`GET /api/facets`, HTTP 200, 2026-09-01), not
/// from invention: exact-value rating buckets plus `unset`, `mark` in all three states including a
/// genuine zero, `has_master` both ways.
@Suite("DEBUG facets fixture (WP16 P3, B9: the response the iPad UI legs read)")
struct DebugStubFacetsFixtureTests {

  #if DEBUG
    private func fixture() -> Components.Schemas.ImageFacets {
      DebugStubTransport.fixtureFacets()
    }

    /// `rating` must arrive as EXACT-value buckets, and the `>= 4` row the UI test reads must come
    /// out non-zero — otherwise that assertion passes or fails for reasons unrelated to the
    /// popover.
    @Test("Rating arrives as exact-value buckets whose >= 4 suffix sum is non-zero")
    func ratingBucketsSupportTheSuffixSum() {
      let rating = fixture().rating ?? []
      #expect(rating.contains(where: { $0.value == "unset" }))
      let numeric = rating.compactMap { Int($0.value) }.sorted()
      #expect(numeric == [2, 3, 4, 5])
      #expect(FilterPopoverModel.ratingAtLeast(4, in: fixture()) > 0)
      // Exact-value, not cumulative: a cumulative wire shape would make >= 4 equal the "4" bucket
      // and the suffix sum a no-op, which is the premise the whole rating row rests on.
      let four = rating.first(where: { $0.value == "4" })?.count ?? 0
      #expect(FilterPopoverModel.ratingAtLeast(4, in: fixture()) > four)
    }

    /// All three states, and one of them a REAL zero — the popover's zero-disabled path has no
    /// other source of evidence on the iPad legs.
    @Test("Mark arrives tri-state including a genuine zero")
    func markIsTriStateWithAZero() {
      let mark = fixture().mark ?? []
      #expect(Set(mark.map(\.value)) == ["pick", "dislike", "none"])
      #expect(mark.contains(where: { $0.count == 0 }))
      #expect(mark.contains(where: { $0.count > 0 }))
    }

    @Test("has_master arrives both ways, and ext carries at least two values")
    func theRemainingDeclaredDimensionsAreAnswered() {
      #expect(Set((fixture().hasMaster ?? []).map(\.value)) == ["true", "false"])
      #expect((fixture().ext ?? []).count >= 2)
    }

    /// The one number that must stay consistent with `fixtureImages()`'s twelve rows: a `total`
    /// that drifted from the page would make the grid and its own facet counts describe different
    /// scopes.
    @Test("total stays consistent with the fixture's twelve images")
    func totalMatchesTheFixturePage() {
      #expect(fixture().total == 12)
    }
  #endif
}
