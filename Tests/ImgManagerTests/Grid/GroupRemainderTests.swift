import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-541: the pure rules of the Mark/Rating remainder — which rows are in it, and how its
/// row and the section headers read.
@Suite("GroupRemainder — the null bucket of Mark and Rating")
struct GroupRemainderTests {
  private func image(id: Int, groupKey: String?) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, groupKey: groupKey,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: nil, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  static let otherKeys: [GroupByKey?] = [.camera, .lens, .iso, .location, nil]

  private var page: [Components.Schemas.ImageSummary] {
    [
      image(id: 1, groupKey: "pick"), image(id: 2, groupKey: "dislike"),
      image(id: 3, groupKey: nil), image(id: 4, groupKey: nil),
    ]
  }

  @Test("The null bucket goes to the remainder", arguments: [GroupByKey.mark, .rating])
  func splitSendsTheNullBucketToTheRemainderForMarkAndRating(groupBy: GroupByKey) {
    let cut = GroupRemainder.split(page, groupBy: groupBy)
    #expect(cut.stream.map(\.id) == [1, 2])
    #expect(cut.remainder.map(\.id) == [3, 4])
  }

  @Test("Every other key's Unknown stays in the stream", arguments: Self.otherKeys)
  func splitLeavesCameraUnknownInTheStream(groupBy: GroupByKey?) {
    let cut = GroupRemainder.split(page, groupBy: groupBy)
    #expect(cut.stream.map(\.id) == [1, 2, 3, 4])
    #expect(cut.remainder.isEmpty)
    #expect(!GroupRemainder.isRemainder(groupKey: nil, groupBy: groupBy))
  }

  @Test("The row title is singular for one photograph and names what is missing")
  func rowTitleSingularAndPlural() {
    #expect(GroupRemainder.rowTitle(count: 1, groupBy: .mark) == "1 photo without a mark")
    #expect(GroupRemainder.rowTitle(count: 493, groupBy: .mark) == "493 photos without a mark")
    #expect(GroupRemainder.rowTitle(count: 2, groupBy: .rating) == "2 photos without a rating")
    #expect(GroupRemainder.rowTitle(count: 0, groupBy: .rating) == "0 photos without a rating")
  }

  @Test("Mark headers read Picks and Dislikes")
  func markHeaderTitlesArePicksAndDislikes() {
    #expect(GroupRemainder.headerTitle(groupBy: .mark, key: "pick", label: "Pick") == "Picks")
    #expect(
      GroupRemainder.headerTitle(groupBy: .mark, key: "dislike", label: "Dislike") == "Dislikes")
    #expect(GroupRemainder.usesDotHeader(.mark) && GroupRemainder.usesDotHeader(.rating))
    #expect(!GroupRemainder.usesDotHeader(.camera) && !GroupRemainder.usesDotHeader(nil))
  }

  @Test("Rating and every other key use the server's label verbatim")
  func ratingHeaderUsesTheServerLabel() {
    #expect(GroupRemainder.headerTitle(groupBy: .rating, key: "5", label: "5") == "5")
    #expect(GroupRemainder.headerTitle(groupBy: .camera, key: "pick", label: "pick") == "pick")
  }
}
