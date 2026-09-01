import Foundation
import ImgManagerAPI

/// The six server-derived readiness states (WP7 P4, IMGMGR-110) rendered as queue sections.
/// Raw values are the schema's OWN snake_case wire strings (verified against the deployed
/// v0.9.2 schema, `wp7native-schema-enums.txt`) — never the generated enum's camelCased Swift
/// case name, which this type deliberately never spells anywhere in this file. That means a
/// schema vocabulary drift makes `ReadinessSection(rawValue:)` return `nil` (silently excluded
/// from every section, per `QueueSort.sections(from:)` below), not a wrong-but-compiling case —
/// the exact IMGMGR-173 discipline `ShootListFilter` already established for `kind`.
enum ReadinessSection: String, CaseIterable, Sendable, Equatable {
  case reviewInProgress = "review_in_progress"
  case readyToReview = "ready_to_review"
  case syncProblem = "sync_problem"
  case readyForEditing = "ready_for_editing"
  case needsPreviews = "needs_previews"
  case historicalUnreviewed = "historical_unreviewed"

  /// Q1 binding order — PRESENTATION ordering only, never a classification. This is also
  /// literally the iteration order `QueueSort.sections(from:)` walks; there is no second
  /// ordering anywhere else in this phase.
  static let displayOrder: [ReadinessSection] = [
    .reviewInProgress, .readyToReview, .syncProblem,
    .readyForEditing, .needsPreviews, .historicalUnreviewed,
  ]

  /// Q1: "first three" (in display order) default-expanded, the remaining three
  /// default-collapsed (their headers still show item counts).
  var isDefaultExpanded: Bool {
    switch self {
    case .reviewInProgress, .readyToReview, .syncProblem: return true
    case .readyForEditing, .needsPreviews, .historicalUnreviewed: return false
    }
  }

  var title: String {
    switch self {
    case .reviewInProgress: return "Review in progress"
    case .readyToReview: return "Ready to review"
    case .syncProblem: return "Sync problem"
    case .readyForEditing: return "Ready for editing"
    case .needsPreviews: return "Needs previews"
    case .historicalUnreviewed: return "Historical, unreviewed"
    }
  }
}

/// Q2's worst-present sync signal — one compact indicator per folder, computed by DIRECT field
/// inspection of `FolderSyncCounts` (never summed across states, never re-derived from anything
/// else). `nil` means "render no sync signal" (Q2: an absent rollup or all-four-zero both mean
/// this — all-zero is never presented as synced).
struct SyncSignal: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case refused, stale, never, synced
  }
  let kind: Kind
  let count: Int

  /// Precedence refused > stale > never > synced — the FIRST non-zero count in that order wins;
  /// its OWN count is what is shown, never a sum across states. Each field on the generated
  /// `FolderSyncCounts` is `Int?` (the schema gives each a `default: 0` but omits ALL FOUR from
  /// `required` — verified against the vendored openapi.json, correcting an earlier assumption
  /// that only `sync` itself, not its own fields, was optional) — `?? 0` is the field's own
  /// documented default, never an invented fallback.
  static func compute(from sync: Components.Schemas.FolderSyncCounts?) -> SyncSignal? {
    guard let sync else { return nil }
    let refused = sync.refused ?? 0
    let stale = sync.stale ?? 0
    let never = sync.never ?? 0
    let synced = sync.synced ?? 0
    if refused > 0 { return SyncSignal(kind: .refused, count: refused) }
    if stale > 0 { return SyncSignal(kind: .stale, count: stale) }
    if never > 0 { return SyncSignal(kind: .never, count: never) }
    if synced > 0 { return SyncSignal(kind: .synced, count: synced) }
    return nil
  }
}

/// Diff-gate round-3 closure, B1: a queue card's destination is atomically `(folderId, nil)` —
/// entering a shoot via the queue ALWAYS clears any prior tree-tier filter in the SAME scope
/// transition, regardless of which tier the summary's OWN data happens to live in (that tier is
/// `heroTaskID`'s/`HeroThumbnailLoader`'s concern for fetching the right hero image, never
/// routing's). Pulled out as a pure function — the exact function `QueueCardRow`'s tap gesture
/// calls, so a test proves the PRODUCTION forwarding decision, not a re-implementation of it —
/// same discipline as `RootRouting`/`LayoutResolver`/`ForegroundRefresh`.
enum QueueCardDestination {
  static func route(for summary: Components.Schemas.FolderSummary) -> (
    folderID: Int, sourceTier: GridSourceTier?
  ) {
    (summary.folderId, nil)
  }
}

/// Groups and orders the flat `folder-summaries` response into rendering sections. Q1's
/// presentation ordering ONLY — the section identity itself comes straight from `FolderSummary.
/// readiness`, never recomputed (Q4 drift hazard: "recomputing readiness from counts/sync/
/// dates" is explicitly named as a spec violation). This is the ONE grouping/sorting authority
/// for the queue; no view here re-derives an order of its own.
enum QueueSort {
  struct Section: Equatable {
    let section: ReadinessSection
    let items: [Components.Schemas.FolderSummary]
  }

  /// Zero-item sections are omitted entirely (Q1: "Zero-item sections not rendered").
  ///
  /// IMGMGR-264 (owner directive, 2026-08-31): grouping ONLY — the WITHIN-section order is the
  /// server's. `/api/folder-summaries` orders folders by name descending (the names are dates, so
  /// newest first) with a `folder_id` tiebreak, one implementation both clients consume. The
  /// client used to re-sort by `last_touched` descending, which answers a different question
  /// ("what did I touch last", not "which shoot is newest") and silently overrode whatever order
  /// the server chose. The accumulation below is explicitly order-preserving rather than relying
  /// on `Dictionary(grouping:)`'s undocumented within-bucket ordering.
  static func sections(from summaries: [Components.Schemas.FolderSummary]) -> [Section] {
    var grouped: [ReadinessSection: [Components.Schemas.FolderSummary]] = [:]
    for summary in summaries {
      guard let key = ReadinessSection(rawValue: summary.readiness.rawValue) else { continue }
      grouped[key, default: []].append(summary)
    }
    return ReadinessSection.displayOrder.compactMap { key in
      guard let items = grouped[key], !items.isEmpty else { return nil }
      return Section(section: key, items: items)
    }
  }
}
