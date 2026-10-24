#if DEBUG
  import Foundation
  import ImgManagerAPI

  /// IMGMGR-541 (`-UITestMarkGroups`): one 500-photograph shoot for the Mark/Rating remainder,
  /// served by `DebugStubTransport` in place of the twelve-photograph fixture.
  ///
  /// Photographs 9001…9500. Marks: 9001…9005 picked, 9006…9007 disliked, 9008…9010 an explicit
  /// `none`, the rest no mark at all — one bucket, as the server buckets them. Ratings: 3×5
  /// (9001…9003), 2×4, 2×1, then 3×0 and 3×-1, which fall in the null bucket with the unrated.
  /// Grouped pages follow the server's order (`app/api/groups.py` at the vendored commit): groups
  /// ascending, the null bucket last, whatever the direction; the direction orders photographs
  /// only within a group. `group_key` and the header counts are computed from the LIVE mark
  /// state, so a mark made in the app moves the photograph on the next request, as on a server.
  ///
  /// IMGMGR-626: cursors are KEYSET cursors, as the server's are — `mg-<group key>-<id>` names
  /// the page's last photograph AND the group it sat in when the cursor was issued, and a request
  /// resumes after that position in the order served NOW. So a cursor issued before a mark moved
  /// its photograph still resolves, to the photographs that follow its old place.
  enum DebugMarkGroupsFixture {
    static var isOn: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestMarkGroups")
    }

    static let ids = Array(9001...9500)
    private static let pageSize = 100
    private static let cursorPrefix = "mg-"

    /// The fixture's own seed for `id`, or nil when the fixture is off or `id` is not its own.
    static func seededMark(_ id: Int) -> String? {
      guard isOn, (9001...9500).contains(id) else { return nil }
      switch id {
      case 9001...9005: return "pick"
      case 9006...9007: return "dislike"
      default: return "none"
      }
    }

    static func rating(_ id: Int) -> Int? {
      switch id {
      case 9001...9003: return 5
      case 9004...9005: return 4
      case 9006...9007: return 1
      case 9008...9010: return 0
      case 9011...9013: return -1
      default: return nil
      }
    }

    private static func groupKey(_ id: Int, groupBy: String?, mark: String) -> String? {
      switch groupBy {
      case "mark": return mark == "none" ? nil : mark
      case "rating": return rating(id).flatMap { (1...5).contains($0) ? String($0) : nil }
      default: return nil
      }
    }

    /// A group's place: pick, dislike; 5…1; the null bucket always last.
    private static func rank(_ key: String?) -> Int {
      switch key {
      case nil: return Int.max
      case "pick": return 0
      case "dislike": return 1
      case let key?: return 5 - (Int(key) ?? 0)
      }
    }

    private static func ordered(
      groupBy: String?, direction: String?, marks: (Int) -> String
    ) -> [Int] {
      let within: [Int] = direction == "desc" ? ids.reversed() : ids
      guard groupBy == "mark" || groupBy == "rating" else { return within }
      let ranked = within.enumerated().map { offset, id in
        (rank: rank(groupKey(id, groupBy: groupBy, mark: marks(id))), offset: offset, id: id)
      }
      return ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.map(\.id)
    }

    static func page(query: [String: String], marks: (Int) -> String)
      -> Components.Schemas.ImagePage
    {
      let groupBy = query["group_by"]
      let direction = query["direction"]
      let order = ordered(groupBy: groupBy, direction: direction, marks: marks)
      var start = 0
      if let cursor = query["cursor"] {
        start = resumeIndex(
          after: cursor, in: order, groupBy: groupBy, direction: direction, marks: marks)
      }
      let end = min(start + pageSize, order.count)
      let items = order[start..<end].map { image($0, groupBy: groupBy, mark: marks($0)) }
      var next: String?
      if end < order.count, let last = items.last {
        next = "\(cursorPrefix)\(last.groupKey ?? nullToken)-\(last.id)"
      }
      return Components.Schemas.ImagePage(items: items, limit: pageSize, nextCursor: next)
    }

    /// The null bucket's token inside a cursor.
    private static let nullToken = "_"

    /// Where a keyset cursor resumes: the first photograph whose (group rank, place within the
    /// group) sorts after the cursor's — its group as ISSUED, not where its photograph is now.
    private static func resumeIndex(
      after cursor: String, in order: [Int], groupBy: String?, direction: String?,
      marks: (Int) -> String
    ) -> Int {
      let parts = cursor.dropFirst(cursorPrefix.count).split(separator: "-", maxSplits: 1)
      guard parts.count == 2, let id = Int(parts[1]) else { return order.count }
      let key: String? = parts[0] == nullToken ? nil : String(parts[0])
      let within: [Int] = direction == "desc" ? ids.reversed() : ids
      let place = Dictionary(uniqueKeysWithValues: within.enumerated().map { ($1, $0) })
      let anchor = (rank(key), place[id] ?? Int.max)
      let index = order.firstIndex { photo in
        let photoRank = rank(groupKey(photo, groupBy: groupBy, mark: marks(photo)))
        return (photoRank, place[photo] ?? Int.max) > anchor
      }
      return index ?? order.count
    }

    static func groups(query: [String: String], marks: (Int) -> String)
      -> Components.Schemas.ImageGroups
    {
      let groupBy = query["group_by"] == "rating" ? "rating" : "mark"
      var keys: [String?] = []
      var counts: [String?: Int] = [:]
      for id in ordered(groupBy: groupBy, direction: nil, marks: marks) {
        let key = groupKey(id, groupBy: groupBy, mark: marks(id))
        if counts[key] == nil { keys.append(key) }
        counts[key, default: 0] += 1
      }
      let headers = keys.map {
        Components.Schemas.GroupHeader(count: counts[$0] ?? 0, key: $0, label: label($0))
      }
      return Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: groupBy == "rating" ? .rating : .mark, headers: headers,
        timezone: nil, total: ids.count)
    }

    private static func label(_ key: String?) -> String {
      switch key {
      case nil: return "Unknown"
      case "pick": return "Pick"
      case "dislike": return "Dislike"
      case let key?: return key
      }
    }

    private static func image(_ id: Int, groupBy: String?, mark: String)
      -> Components.Schemas.ImageSummary
    {
      Components.Schemas.ImageSummary(
        aspectRatio: 1.5, capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
        ext: "jpg", filename: "MG_\(id).jpg", folderId: 1,
        groupKey: groupKey(id, groupBy: groupBy, mark: mark), hasEdit: false, id: id,
        lightroom: .init(good: false, rating: rating(id), sidecarPresent: false),
        mark: .init(
          revision: "r\(id)", state: Components.Schemas.MarkView.StatePayload(rawValue: mark)),
        missing: false,
        proxies: .init(additionalProperties: [
          "grid": .init(height: 400, url: nil, verdict: .ok, width: 600),
          "preview": .init(height: 1600, url: nil, verdict: .ok, width: 2400),
        ]),
        sourceKind: "camera_original", sourceLabel: "MG_\(id).ARW", sourceTier: "local")
    }
  }
#endif
