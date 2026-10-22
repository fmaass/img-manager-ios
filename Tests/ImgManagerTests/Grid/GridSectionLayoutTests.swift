import CoreGraphics
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P5b (IMGMGR-221 part 2): the grouped grid renders as SECTIONS THE SERVER VOUCHES FOR.
///
/// The failure this suite exists to catch is the one the gate named in round 1: a literal
/// implementation that sends `group_by`, gets a re-ordered page back, renders it as ordinary
/// tiles, and passes every "did the parameter go out" test while shipping re-ordered photographs
/// with no sections at all.
@Suite("Grid section layout (WP13 P5b)")
struct GridSectionLayoutTests {

  private func image(id: Int, groupKey: String?, aspect: Double = 1.0)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: aspect, ext: "jpg", filename: "img\(id).jpg", folderId: 1, groupKey: groupKey,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func header(key: String?, label: String, count: Int) -> Components.Schemas.GroupHeader {
    Components.Schemas.GroupHeader(count: count, key: key, label: label)
  }

  /// Every tile's `grid` tier is available at a size no cap can bite on, so the packer output
  /// is decided purely by geometry — the section boundaries — and never by a placeholder branch.
  private let alwaysAvailable: (GridDisplayID, ProxyTier) -> ProxyAvailability = {
    _, _ in
    .ok(width: 4000, height: 4000)
  }

  /// Three groups, two photographs each, in the order a grouped page serves them.
  private var threeSectionStream: [SceneDisplayRow] {
    [
      image(id: 1, groupKey: "SONY ILCE-7RM5"), image(id: 2, groupKey: "SONY ILCE-7RM5"),
      image(id: 3, groupKey: "FUJIFILM X-T2"), image(id: 4, groupKey: "FUJIFILM X-T2"),
      image(id: 5, groupKey: nil), image(id: 6, groupKey: nil),
    ].map(SceneDisplayRow.image)
  }

  /// The server's OWN counts — deliberately far larger than the six rows on the page, which is
  /// the whole point: a client-side tally produces the page count and fails.
  private var threeSectionHeaders: [GroupKey: Components.Schemas.GroupHeader] {
    [
      GroupKey.known("SONY ILCE-7RM5"): header(
        key: "SONY ILCE-7RM5", label: "SONY ILCE-7RM5", count: 36568),
      GroupKey.known("FUJIFILM X-T2"): header(
        key: "FUJIFILM X-T2", label: "FUJIFILM X-T2", count: 280),
      GroupKey.unknown: header(key: nil, label: "Unknown", count: 213),
    ]
  }

  private func render(
    rows: [SceneDisplayRow],
    groupBy: GroupByKey?,
    headers: [GroupKey: Components.Schemas.GroupHeader],
    timezone: String? = nil,
    paneWidth: CGFloat = 800,
    targetRowHeight: CGFloat = 200,
    remainderCount: Int? = nil
  ) -> [GridRenderRow] {
    GridSectionLayout.renderRows(
      rows: rows, groupBy: groupBy, headers: headers, timezone: timezone,
      paneWidth: paneWidth, targetRowHeight: targetRowHeight, displayScale: 2,
      remainderCount: remainderCount, availability: alwaysAvailable)
  }

  @Test("A header row is emitted at every group-key boundary, with the SERVER's label and count")
  func aHeaderRowIsEmittedAtEveryGroupKeyBoundaryWithTheServersLabelAndCount() {
    let rendered = render(
      rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders)

    let headers: [GroupHeaderRow] = rendered.compactMap {
      if case .header(let header) = $0 { return header }
      return nil
    }
    #expect(headers.count == 3)
    #expect(headers.map(\.label) == ["SONY ILCE-7RM5", "FUJIFILM X-T2", "Unknown"])
    // The SERVER's counts, not the page's. Six photographs are loaded; if any of these three
    // numbers were 2 (or 6), the client tallied and this test is doing its job.
    #expect(headers.map(\.count) == [36568, 280, 213])
    #expect(!headers.map(\.count).contains(2))
    #expect(!headers.map(\.count).contains(6))
    // The Unknown bucket is the server's own label for `key: null` — never a client-invented
    // word for absent metadata.
    #expect(headers.last?.key == GroupKey.unknown)

    // Each header precedes its OWN section's first tile.
    let sequence: [String] = rendered.map {
      switch $0 {
      case .header(let header): return "H:\(header.label)"
      case .tiles(let row): return "T:\(row.cells.map { String(describing: $0.id) }.joined())"
      case .remainder(let remainder): return "R:\(remainder.title)"
      }
    }
    #expect(sequence.first == "H:SONY ILCE-7RM5")
    #expect(sequence.filter { $0.hasPrefix("H:") }.count == 3)
  }

  @Test("Ungrouped renders exactly as it shipped: one packing pass, zero headers")
  func ungroupedRendersWithNoHeadersAtAll() {
    let rendered = render(rows: threeSectionStream, groupBy: nil, headers: threeSectionHeaders)
    #expect(rendered.allSatisfy { $0.packedRow != nil })
    // POSITIVE CONTROL (LSN-0033): the same derivation DOES produce headers when grouped, so
    // the zero above is the ungrouped rule rather than a broken call.
    let grouped = render(rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders)
    #expect(grouped.contains { $0.packedRow == nil })
  }

  @Test("No header is invented when the server has not vouched for one")
  func noHeaderIsInventedWithoutTheServersAnswer() {
    // Headers absent entirely (fetch failed or not yet landed): the stream renders unsectioned
    // rather than with invented labels — and, critically, every photograph still renders.
    let noHeaders = render(rows: threeSectionStream, groupBy: .camera, headers: [:])
    #expect(noHeaders.allSatisfy { $0.packedRow != nil })
    #expect(GridSectionLayout.navigationRows(noHeaders).flatMap { $0 }.count == 6)

    // One key missing from an otherwise-populated set: that section's tiles render, its header
    // does not, and no other section loses its own.
    var partial = threeSectionHeaders
    partial[GroupKey.unknown] = nil
    let rendered = render(rows: threeSectionStream, groupBy: .camera, headers: partial)
    let labels: [String] = rendered.compactMap {
      if case .header(let header) = $0 { return header.label }
      return nil
    }
    #expect(labels == ["SONY ILCE-7RM5", "FUJIFILM X-T2"])
    #expect(GridSectionLayout.navigationRows(rendered).flatMap { $0 }.count == 6)
  }

  @Test("No justified row straddles a section boundary")
  func noJustifiedRowStraddlesASectionBoundary() {
    // A pane wide enough that all six 1:1 tiles at 200 pt would pack into ONE row if they were
    // packed together (6 × 200 + spacing < 1600): the unsectioned control below proves exactly
    // that, so a straddling row is a real possibility this test rules out rather than a
    // geometry that could never have happened.
    let unsectioned = render(
      rows: threeSectionStream, groupBy: nil, headers: [:], paneWidth: 1600)
    #expect(GridSectionLayout.navigationRows(unsectioned).count == 1)

    let rendered = render(
      rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders,
      paneWidth: 1600)
    let keyByID: [GridDisplayID: GroupKey] = Dictionary(
      uniqueKeysWithValues: threeSectionStream.map { ($0.id, GridSectionLayout.groupKey(of: $0)) })
    for row in GridSectionLayout.navigationRows(rendered) {
      let keys = Set(row.compactMap { keyByID[$0] })
      #expect(keys.count == 1, "a packed row spans \(keys.count) group keys: \(row)")
    }
    // And the sections really were packed separately: three rows, one per group.
    #expect(GridSectionLayout.navigationRows(rendered).count == 3)
  }

  @Test("Header rows are absent from GridStore.rows and from actionableImages")
  func headerRowsAreAbsentFromGridStoreRowsAndFromActionableImages() {
    let rendered = render(
      rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders)
    #expect(rendered.contains { $0.packedRow == nil })  // headers ARE in the rendered sequence

    let navigation = GridSectionLayout.navigationRows(rendered)
    let navigable = navigation.flatMap { $0 }
    // POSITIVE CONTROL: the six tile ids ARE present, so "no header ids" below is a filter
    // that ran rather than an empty projection.
    #expect(navigable == (1...6).map(GridDisplayID.image))
    // Every navigable id is a photograph. A header cannot even be spelled as a `GridDisplayID`
    // (that type gains no case), so this asserts the projection kept the vocabulary intact.
    #expect(navigable.allSatisfy { $0.imageID != nil })
    #expect(navigation.count == rendered.compactMap { $0.packedRow }.count)
    #expect(navigation.count < rendered.count)  // the headers were dropped, not counted

    // `actionableImages`' own derivation over the same stream: photographs only, headers being
    // structurally incapable of entering it.
    #expect(SceneRowBuilder.actionableImages(threeSectionStream).map(\.id) == Array(1...6))
  }

  @Test("Every render row has a stable, non-index identity")
  func everyRenderRowHasAStableNonIndexIdentity() {
    let rendered = render(
      rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders, paneWidth: 300)
    let ids = rendered.map(\.id)
    #expect(Set(ids).count == ids.count)
    // A header's id is its group key; a tile row's is its leading cell's display id — never a
    // position (IMGMGR-210; index identity is what crashed 0.7.0 (9)).
    for row in rendered {
      switch row {
      case .header(let header): #expect(row.id == .header(header.key))
      case .tiles(let packed): #expect(row.id == .tiles(packed.cells[0].id))
      case .remainder: #expect(row.id == .remainder)
      }
    }

    // Stability under a shift: prepend a whole new leading section and the ORIGINAL rows keep
    // the exact ids they had, at different positions. Index identity cannot do this.
    var shifted = [SceneDisplayRow.image(image(id: 99, groupKey: "NIKON Z8"))]
    shifted.append(contentsOf: threeSectionStream)
    var shiftedHeaders = threeSectionHeaders
    shiftedHeaders[GroupKey.known("NIKON Z8")] = header(
      key: "NIKON Z8", label: "NIKON Z8", count: 5)
    let after = render(
      rows: shifted, groupBy: .camera, headers: shiftedHeaders, paneWidth: 300)
    #expect(after.count == rendered.count + 2)  // one header + one tile row prepended
    #expect(Array(after.map(\.id).dropFirst(2)) == ids)
  }

  /// IMGMGR-541, a deliberate rewrite: this asserted that a Day header carried the server's
  /// zone. Day and Month are no longer offered, so no offered key is a time key, and a header
  /// never states a zone even when a response hands one over.
  @Test("No offered key renders a timezone, even when the response names one")
  func aTimezoneRendersForNoOfferedKey() {
    // A non-time key's response carries `timezone: null`; even handed one, the header states
    // none — a camera name is not a rendered local time.
    let cameraKey = render(
      rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders,
      timezone: "Europe/Zurich")
    for row in cameraKey {
      if case .header(let header) = row { #expect(header.timezone == nil) }
    }
  }

  // MARK: - IMGMGR-541: Mark/Rating sections and the remainder row

  /// Picks then Dislikes, as the stream holds them once the remainder is cut off.
  private var markStream: [SceneDisplayRow] {
    [
      image(id: 1, groupKey: "pick"), image(id: 2, groupKey: "pick"),
      image(id: 3, groupKey: "dislike"),
    ].map(SceneDisplayRow.image)
  }

  private var markHeaders: [GroupKey: Components.Schemas.GroupHeader] {
    [
      .known("pick"): header(key: "pick", label: "Pick", count: 5),
      .known("dislike"): header(key: "dislike", label: "Dislike", count: 2),
      .unknown: header(key: nil, label: "Unknown", count: 493),
    ]
  }

  private func headerTitles(_ rows: [GridRenderRow]) -> [String] {
    rows.compactMap {
      switch $0 {
      case .header(let header): return header.usesDot ? header.dotTitle : header.label
      case .remainder(let row): return row.title
      case .tiles: return nil
      }
    }
  }

  @Test("The remainder row follows the last marked section")
  func remainderRowFollowsTheLastMarkedSection() {
    let rows = render(
      rows: markStream, groupBy: .mark, headers: markHeaders, remainderCount: 493)
    #expect(headerTitles(rows) == ["Picks · 5", "Dislikes · 2", "493 photos without a mark"])
    #expect(rows.last == .remainder(GroupRemainderRow(groupBy: .mark, count: 493)))
    #expect(rows.last?.id == .remainder)
  }

  @Test("The null key never gets a header under Mark or Rating")
  func nullKeyNeverGetsAHeaderUnderMarkOrRating() {
    var stream = markStream
    stream.append(.image(image(id: 9, groupKey: nil)))
    for groupBy in [GroupByKey.mark, .rating] {
      let rows = render(rows: stream, groupBy: groupBy, headers: markHeaders)
      #expect(!rows.contains { $0.id == .header(.unknown) })
    }
    let camera = render(rows: threeSectionStream, groupBy: .camera, headers: threeSectionHeaders)
    #expect(camera.contains { $0.id == .header(.unknown) }, "camera keeps its Unknown header")
  }

  @Test("No remainder row until the headers vouch for the query")
  func noRemainderRowUntilHeadersVouch() {
    let rows = render(rows: markStream, groupBy: .mark, headers: [:], remainderCount: 493)
    #expect(!rows.contains { $0.id == .remainder })
    #expect(!rows.contains { $0.id == .header(.known("pick")) })
  }

  @Test("An all-unmarked folder renders the remainder row alone")
  func anEmptyStreamRendersOnlyTheRemainderRow() {
    let rows = render(rows: [], groupBy: .mark, headers: markHeaders, remainderCount: 500)
    #expect(rows == [.remainder(GroupRemainderRow(groupBy: .mark, count: 500))])
  }

  @Test("No remainder row when its count is zero or unknown")
  func noRemainderRowWhenItsCountIsZero() {
    for count in [0, nil] as [Int?] {
      let rows = render(
        rows: markStream, groupBy: .mark, headers: markHeaders, remainderCount: count)
      #expect(!rows.contains { $0.id == .remainder })
      #expect(headerTitles(rows) == ["Picks · 5", "Dislikes · 2"])
    }
  }
}
