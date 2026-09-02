import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// The DEBUG fixture's `/api/facets` answer, pinned by shape.
///
/// **Provenance, stated plainly (diff-gate round 1, B2).** This suite is GREEN the moment it lands
/// and never had an isolated RED, because no honest one was available. The phase claimed the
/// fixture expansion's RED was `FilterPopoverUITests`' "the `≥ 4` row states a count above zero"
/// assertion; that claim does not hold. At `6391916` neither the funnel nor any popover row
/// existed, so that assertion failed on a missing element whatever the fixture contained — it
/// could not discriminate a thin fixture from an absent surface. The fixture expansion and the
/// implementation then landed in the same commit (`2a5a9e0`), so no commit ever isolated it.
/// History is not being rewritten for this; the suite is written POST HOC and says so.
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

    /// One dimension's buckets as value -> count. `uniqueKeysWithValues` is deliberate: a fixture
    /// emitting the same bucket twice is malformed, and trapping here is a hard failure rather
    /// than a silent last-one-wins read.
    private func buckets(
      _ dimension: KeyPath<Components.Schemas.ImageFacets, [Components.Schemas.FacetCount]?>
    ) -> [String: Int] {
      Dictionary(
        uniqueKeysWithValues: (fixture()[keyPath: dimension] ?? []).map { ($0.value, $0.count) })
    }

    /// **What the previous version of this test did NOT do (diff-gate round 2).** It checked the
    /// bucket NAMES plus `suffix(>= 4) > bucket("4")` — and a CUMULATIVE fixture satisfies both:
    /// `{unset:4, 2:8, 3:7, 4:5, 5:2}` gives 5 + 2 = 7 > 5 and would have passed unchanged. The
    /// commit that added it therefore overclaimed; exactness was not pinned at all.
    ///
    /// What actually discriminates the two shapes is the PARTITION invariant below, plus pinning
    /// each bucket to its literal here. Exact buckets are disjoint and sum to `total`; a
    /// cumulative shape double-counts and overshoots — that counter-example sums to 26 against a
    /// total of 12.
    @Test("Rating arrives as EXACT-value buckets, pinned per value")
    func ratingBucketsAreExactValued() {
      #expect(buckets(\.rating) == ["unset": 4, "2": 1, "3": 2, "4": 3, "5": 2])
      // The suffix sums the `>= N` rows rest on, over that exact shape.
      #expect(FilterPopoverModel.ratingAtLeast(3, in: fixture()) == 7)
      #expect(FilterPopoverModel.ratingAtLeast(4, in: fixture()) == 5)
      #expect(FilterPopoverModel.ratingAtLeast(5, in: fixture()) == 2)
    }

    /// The invariant that separates an exact wire shape from a cumulative one, on every dimension
    /// the popover declares.
    ///
    /// Not an invented rule: each facet dimension is computed with its OWN filter excluded and
    /// every other active filter applied, so a dimension whose values are mutually exclusive
    /// partitions the same result set. The live probe bears that out — `rating`, `mark`,
    /// `has_master` and `ext` each summed to exactly `total` (33), while `good`, `label` and
    /// `keyword` did not (4, 4 and 6), because an image can carry several keywords or none. Only
    /// the four DECLARED dimensions are asserted, for that reason.
    @Test("Each declared dimension partitions the fixture's twelve images")
    func everyDeclaredDimensionPartitionsTheResultSet() {
      let total = fixture().total
      #expect(buckets(\.rating).values.reduce(0, +) == total)
      #expect(buckets(\.mark).values.reduce(0, +) == total)
      #expect(buckets(\.hasMaster).values.reduce(0, +) == total)
      #expect(buckets(\.ext).values.reduce(0, +) == total)
    }

    /// All three states, and one of them a REAL zero — the popover's zero-disabled path has no
    /// other source of evidence on the iPad legs. Pinned by literal AND by the two properties that
    /// make the literal matter, so a future re-balancing of the counts still has to keep both.
    @Test("Mark arrives tri-state including a genuine zero")
    func markIsTriStateWithAZero() {
      #expect(buckets(\.mark) == ["pick": 4, "dislike": 0, "none": 8])
      #expect(buckets(\.mark).values.contains(0))
      #expect(buckets(\.mark).values.contains(where: { $0 > 0 }))
    }

    @Test("has_master arrives both ways, and ext carries at least two values")
    func theRemainingDeclaredDimensionsAreAnswered() {
      #expect(buckets(\.hasMaster) == ["true": 5, "false": 7])
      #expect(buckets(\.ext) == ["jpg": 9, "arw": 3])
      #expect(buckets(\.ext).count >= 2)
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
