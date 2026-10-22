import ImgManagerAPI

/// IMGMGR-541 (R3-6, R3-21): grouped by Mark or Rating, the photographs without one are never
/// headed in the stream. They are ONE row, "493 photos without a mark ›", entered like a scene.
///
/// The server's bucketing, read from its source at the vendored commit `22726eec`
/// (`app/api/groups.py:102-128`, `group_keys.py:74-76`):
/// - `group_by=mark`: a photograph with no Mark row and one with an explicit `none` are ONE
///   bucket, wire key `null` (label "Unknown"), ordered LAST; `pick` ("Pick") then `dislike`
///   ("Dislike") before it.
/// - `group_by=rating`: 1…5 are the buckets `"5"`…`"1"`, ordered 5→1; NULL, 0 and -1 are the one
///   `null` bucket, LAST.
/// - Group order is ascending, nulls last, whatever the sort direction; the direction orders
///   photographs only WITHIN a group.
///
/// So a grouped stream reaches the remainder exactly once, at its end, and everything after the
/// first remainder row is remainder too. That is what lets the stream stop paging there.
enum GroupRemainder {
  /// The `.group(key:value:)` route's value for the remainder. A route token only — it never
  /// reaches the wire (the wire spells the bucket as a null key).
  static let routeValue = "remainder"

  /// Is this photograph's `group_key` the remainder bucket under `groupBy`? Only Mark and Rating
  /// have one; every other key's null is the ordinary, headed Unknown section.
  static func isRemainder(groupKey: String?, groupBy: GroupByKey?) -> Bool {
    guard let groupBy, groupBy.hasRemainder else { return false }
    return groupKey == nil
  }

  /// One page cut in two at the remainder boundary, order preserved. Ungrouped, or grouped by a
  /// key without a remainder, everything is `stream`.
  static func split(
    _ items: [Components.Schemas.ImageSummary], groupBy: GroupByKey?
  ) -> (stream: [Components.Schemas.ImageSummary], remainder: [Components.Schemas.ImageSummary]) {
    guard groupBy?.hasRemainder == true else { return (items, []) }
    var stream: [Components.Schemas.ImageSummary] = []
    var remainder: [Components.Schemas.ImageSummary] = []
    for item in items {
      if isRemainder(groupKey: item.groupKey, groupBy: groupBy) {
        remainder.append(item)
      } else {
        stream.append(item)
      }
    }
    return (stream, remainder)
  }

  /// "1 photo without a mark", "493 photos without a rating". The row draws its own chevron.
  static func rowTitle(count: Int, groupBy: GroupByKey) -> String {
    let noun = count == 1 ? "photo" : "photos"
    let what = groupBy == .rating ? "a rating" : "a mark"
    return "\(count) \(noun) without \(what)"
  }

  /// A section's title. The server labels the mark buckets in the singular ("Pick", "Dislike");
  /// the grid names the groups ("Picks", "Dislikes", R3-6). Every other key uses the server's
  /// own label verbatim.
  static func headerTitle(groupBy: GroupByKey?, key: String?, label: String) -> String {
    guard groupBy == .mark else { return label }
    switch key {
    case "pick": return "Picks"
    case "dislike": return "Dislikes"
    default: return label
    }
  }

  /// Mark and Rating headers read "Picks · 5" as one line (R3-6); the other keys keep their
  /// label-and-count header.
  static func usesDotHeader(_ groupBy: GroupByKey?) -> Bool {
    groupBy?.hasRemainder == true
  }
}
