#if DEBUG
  import Foundation
  import ImgManagerAPI

  /// IMGMGR-542 (R3-22): the peek-band folders `DebugStubTransport` serves in place of the
  /// one-scene fixture.
  ///
  /// `-UITestPeekBands` (functional): six scenes 7001…7006 of 7, 12, 18, 25, 33 and 40 members,
  /// between eight loose photographs 7101…7108. Every scene's membership is one page.
  ///
  /// `-UITestPeekBandsMeasure` (the measurement's STAND-IN, not the real largest folder): 240
  /// scenes 80001…80240 and 240 loose photographs 90001…90240 in one folder, served as three
  /// browse pages of 160 rows. Scenes 1–3 hold 60 members each and sit seven rows apart at the
  /// top, so their cards land on different grid rows; every other scene holds 8. The measure flag
  /// wins when both are passed.
  ///
  /// Marks come from the transport's live mark state, so a mark made in the app is what the next
  /// read serves, as on a server.
  enum DebugPeekBandsFixture {
    static var isMeasure: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestPeekBandsMeasure")
    }
    static var isFunctional: Bool {
      !isMeasure && ProcessInfo.processInfo.arguments.contains("-UITestPeekBands")
    }
    static var isOn: Bool { isMeasure || isFunctional }

    // MARK: Stand-in constants, printed verbatim by the measurement.

    static let standInStackCount = 240
    static let standInOpenedMemberCounts = [60, 60, 60]
    static let measureSceneIDs = Array(80001...80240)

    // MARK: Functional constants.

    static let functionalSceneIDs = Array(7001...7006)
    static let functionalMemberCounts = [7, 12, 18, 25, 33, 40]
    static let functionalLooseIDs = Array(7101...7108)

    private static let browsePageSize = 160
    private static let cursorPrefix = "pb-"

    private enum Row {
      case scene(Int)
      case loose(Int)
    }

    /// The folder's stream, in capture order.
    private static var rows: [Row] {
      if isMeasure {
        let loose = Array(90001...90240)
        var out: [Row] = [.scene(80001)]
        out += loose[0..<6].map(Row.loose)
        out.append(.scene(80002))
        out += loose[6..<12].map(Row.loose)
        out.append(.scene(80003))
        var rest = loose[12...].makeIterator()
        for id in 80004...80240 {
          out.append(.scene(id))
          if let next = rest.next() { out.append(.loose(next)) }
        }
        while let next = rest.next() { out.append(.loose(next)) }
        return out
      }
      let l = functionalLooseIDs
      let s = functionalSceneIDs
      return [
        .loose(l[0]), .scene(s[0]), .loose(l[1]), .scene(s[1]), .loose(l[2]), .loose(l[3]),
        .scene(s[2]), .loose(l[4]), .scene(s[3]), .scene(s[4]), .loose(l[5]), .scene(s[5]),
        .loose(l[6]), .loose(l[7]),
      ]
    }

    static func memberCount(of stackID: Int) -> Int {
      if let index = functionalSceneIDs.firstIndex(of: stackID) {
        return functionalMemberCounts[index]
      }
      if let index = measureSceneIDs.firstIndex(of: stackID) {
        return index < standInOpenedMemberCounts.count ? standInOpenedMemberCounts[index] : 8
      }
      return 0
    }

    /// Member ids: the scene id × 100 + 1…n, disjoint from every loose id and every other scene.
    static func memberIDs(of stackID: Int) -> [Int] {
      let count = memberCount(of: stackID)
      return count == 0 ? [] : (1...count).map { stackID * 100 + $0 }
    }

    static func browsePage(cursor: String?, marks: (Int) -> String)
      -> Components.Schemas.StackBrowsePage
    {
      let all = rows
      let start = cursor.flatMap { Int($0.dropFirst(cursorPrefix.count)) } ?? 0
      let end = min(start + browsePageSize, all.count)
      let items: [Components.Schemas.StackBrowsePage.ItemsPayloadPayload] = all[start..<end].map {
        row in
        switch row {
        case .loose(let id):
          return .init(value1: .init(image: image(id, mark: marks(id)), kind: .image), value2: nil)
        case .scene(let id):
          return .init(value1: nil, value2: stackRow(id, marks: marks))
        }
      }
      return Components.Schemas.StackBrowsePage(
        items: items, limit: browsePageSize,
        nextCursor: end < all.count ? "\(cursorPrefix)\(end)" : nil)
    }

    static func memberPage(stackID: Int, marks: (Int) -> String)
      -> Components.Schemas.StackMemberPage
    {
      Components.Schemas.StackMemberPage(
        items: memberIDs(of: stackID).map { image($0, mark: marks($0)) }, limit: 100,
        nextCursor: nil, stackId: stackID)
    }

    static func stackRow(_ stackID: Int, marks: (Int) -> String)
      -> Components.Schemas.StackBrowseStackRow
    {
      let members = memberIDs(of: stackID).map { image($0, mark: marks($0)) }
      let picked = members.filter { $0.mark.state == .pick }.count
      return Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(stackID)),
        editedCount: 0, hasPick: picked > 0, kind: .stack,
        matchedCount: members.count, memberCount: members.count, pickedCount: picked,
        representative: members.first ?? image(stackID * 100 + 1, mark: "none"),
        stackId: stackID)
    }

    /// Four aspect ratios in turn, so a band's rows are really justified rather than a grid of
    /// equal tiles.
    private static func image(_ id: Int, mark: String) -> Components.Schemas.ImageSummary {
      let aspect = [1.5, 0.667, 1.333, 1.0][id % 4]
      return Components.Schemas.ImageSummary(
        aspectRatio: aspect, capturedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(id)),
        ext: "jpg", filename: "PB_\(id).jpg", folderId: 1, groupKey: nil, hasEdit: false, id: id,
        lightroom: .init(good: false, rating: nil, sidecarPresent: false),
        mark: .init(
          revision: "r\(id)", state: Components.Schemas.MarkView.StatePayload(rawValue: mark)),
        missing: false,
        proxies: .init(additionalProperties: [
          "grid": .init(height: 400, url: nil, verdict: .ok, width: Int(400 * aspect)),
          "preview": .init(height: 1600, url: nil, verdict: .ok, width: Int(1600 * aspect)),
        ]),
        sourceKind: "camera_original", sourceLabel: "PB_\(id).ARW", sourceTier: "local")
    }
  }
#endif
