import ImgManagerAPI

/// WP13 P5b (IMGMGR-221, part 2): the sort and group-by vocabulary this client OFFERS, declared
/// as data so the "is it a subset of the server's?" question is a test rather than a reading of
/// two files in two repositories.
///
/// The server's own vocabularies are fifteen sort keys (`app/api/sort_keys.py`) and nine group-by
/// keys (`app/api/group_keys.py`). This client offers SIX of each — the touch subset the audit's
/// story 10 justifies (gap audit /link/3282). The authority a test checks against is NOT a second
/// hand-written list of the server's fifteen/nine: it is the GENERATED payload enum's own
/// `init(rawValue:)`, which is the vendored contract itself. A key this client offers that the
/// server does not know therefore cannot compile-and-pass; it fails
/// `SortGroupOptionsTests.everyOfferedKeyIsInTheServerVocabulary` at the round-trip.
enum SortKey: String, CaseIterable, Sendable, Equatable {
  case dateTaken = "date_taken"
  case filename
  case rating
  case iso
  case camera
  case lens

  /// The menu's own words. Sentence case, the value a reader would say out loud — never the
  /// wire name, which is what `rawValue` is for.
  var title: String {
    switch self {
    case .dateTaken: return "Date"
    case .filename: return "Filename"
    case .rating: return "Rating"
    case .iso: return "ISO"
    case .camera: return "Camera"
    case .lens: return "Lens"
    }
  }
}

/// Ascending or descending, over whichever `SortKey` is active — the server applies it to the
/// whole order (`direction`'s own description in the browse contract).
enum SortDirection: String, CaseIterable, Sendable, Equatable {
  case asc
  case desc

  var title: String {
    switch self {
    case .asc: return "Ascending"
    case .desc: return "Descending"
    }
  }

  /// The arrow the control's own label carries, so the current direction is readable without
  /// opening the menu (the discoverability half of IMGMGR-221 — an icon-only control behind an
  /// overflow chevron is exactly what the owner could not find, gap audit /link/3282).
  var arrow: String {
    switch self {
    case .asc: return "↑"
    case .desc: return "↓"
    }
  }

  var reversed: SortDirection { self == .asc ? .desc : .asc }
}

/// The six group-by dimensions offered on touch. `hour`, `week` and `year` are the server's other
/// three and are deliberately NOT offered: too fine and too coarse for a shoot-scoped grid.
enum GroupByKey: String, CaseIterable, Sendable, Equatable {
  case day
  case month
  case camera
  case lens
  case iso
  case location

  var title: String {
    switch self {
    case .day: return "Day"
    case .month: return "Month"
    case .camera: return "Camera"
    case .lens: return "Lens"
    case .iso: return "ISO"
    case .location: return "Location"
    }
  }

  /// The five TIME keys (`hour`, `day`, `week`, `month`, `year`) are the ones whose labels the
  /// server renders in a named timezone, and the only ones whose `/api/image-groups` response
  /// carries a non-nil `timezone` (live-probed 2026-08-30: `day` → `Europe/Zurich`, `camera` and
  /// `location` → null). A section header states that zone for exactly these — estate ADR-0007
  /// (/link/2553), "a rendered local time names its zone".
  var isTimeKey: Bool {
    switch self {
    case .day, .month: return true
    case .camera, .lens, .iso, .location: return false
    }
  }
}

/// Scene ⟷ `group_by` as ONE single-select state (ADR-0005 decision 6; gate round 1 BLOCKING
/// finding). Scene is a MODE — a different endpoint with a different row vocabulary — and
/// `group_by` is a wire parameter on the flat endpoint, so the two can never both be on. Making
/// the menu a single-select list over THIS type is what makes that exclusivity structural rather
/// than a rule two independent controls have to remember.
enum GroupingChoice: Sendable, Hashable {
  case none
  case scene
  case key(GroupByKey)

  /// The `group_by` wire value this choice asks for, or nil because it asks for none. `.scene`
  /// answers nil too — it is not a `group_by` value and never reaches the wire as one.
  var groupByKey: GroupByKey? {
    guard case .key(let key) = self else { return nil }
    return key
  }
}

/// The three fields ADR-0005 decision 6 calls "the presentation": what entering Scene mode
/// SUSPENDS and leaving it RESTORES, exactly. Not the filters — a facet edit made while Scene was
/// on survives the way back, because it describes WHICH photographs, not how they are arranged.
struct SortGroupPresentation: Sendable, Equatable {
  var sort: String?
  var direction: String?
  var groupBy: String?

  init(sort: String? = nil, direction: String? = nil, groupBy: String? = nil) {
    self.sort = sort
    self.direction = direction
    self.groupBy = groupBy
  }

  /// Read the presentation OUT of a query.
  init(of query: GridImagesQuery) {
    self.init(sort: query.sort, direction: query.direction, groupBy: query.groupBy)
  }

  /// Write it back IN, touching those three fields and nothing else.
  func applied(to query: GridImagesQuery) -> GridImagesQuery {
    var next = query
    next.sort = sort
    next.direction = direction
    next.groupBy = groupBy
    return next
  }

  /// The presentation Scene browse itself sends, which is none of the three: `/api/browse/stacks`
  /// takes no sort key and no `group_by` at all (ADR-0005 decision 1).
  static let cleared = SortGroupPresentation()
}

/// One section's identity, including the server's explicit Unknown bucket.
///
/// `GroupHeader.key` is nullable and `ImageSummary.group_key` is nullable, and BOTH nulls mean the
/// same thing — "this image's metadata for the grouped dimension is absent" — which the server
/// labels itself (live probe 2026-08-30: `group_by=location` returned exactly one header,
/// `{key: null, label: "Unknown", count: 255}`). A `String?` dictionary key cannot express that;
/// this enum can, so the Unknown bucket looks up like any other section instead of needing a
/// second code path.
enum GroupKey: Hashable, Sendable {
  case known(String)
  case unknown

  init(_ raw: String?) {
    self = raw.map(GroupKey.known) ?? .unknown
  }
}

/// The declared offered subsets, in menu order, plus the round-trip that proves each one is a
/// value the GENERATED client can actually put on the wire.
///
/// Pinned as data because the plan pins the known-unknown that way: "whether the six-key sort
/// subset is the right six … the subset is data in one constant; if the premise gate or the owner
/// names a different set, it changes there and the subset test changes with it — no structural
/// rework."
enum SortGroupOptions {
  static let sortKeys: [SortKey] = SortKey.allCases
  static let directions: [SortDirection] = SortDirection.allCases
  static let groupKeys: [GroupByKey] = GroupByKey.allCases

  /// The single-select Group menu's full list, in order: None, Scene, then the six dimensions.
  static let groupingChoices: [GroupingChoice] =
    [.none, .scene] + GroupByKey.allCases.map(GroupingChoice.key)

  /// The default presentation — the server's own defaults (`sort=date_taken`, `direction=asc`),
  /// stated here rather than left implicit so the menu can render a checkmark before the reader
  /// has chosen anything.
  static let defaultSortKey: SortKey = .dateTaken
  static let defaultDirection: SortDirection = .asc

  // MARK: - Round-trip against the generated (vendored) contract

  /// Does the server's `/api/images` vocabulary contain this raw sort key? Answered by the
  /// GENERATED enum, which is the vendored document — never by a second hand-written list.
  static func serverAcceptsSortKey(_ raw: String) -> Bool {
    Operations.ListImagesApiImagesGet.Input.Query.SortPayload(rawValue: raw) != nil
  }

  static func serverAcceptsDirection(_ raw: String) -> Bool {
    Operations.ListImagesApiImagesGet.Input.Query.DirectionPayload(rawValue: raw) != nil
  }

  static func serverAcceptsGroupByKey(_ raw: String) -> Bool {
    Operations.ListImagesApiImagesGet.Input.Query.GroupByPayload(rawValue: raw) != nil
  }

  /// The neighbours endpoint takes the SAME three, and the loupe-divergence guard rests on that
  /// being true — so it is checked, not assumed.
  static func neighboursAcceptSortKey(_ raw: String) -> Bool {
    Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.SortPayload(rawValue: raw)
      != nil
  }

  static func neighboursAcceptGroupByKey(_ raw: String) -> Bool {
    Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.GroupByPayload(
      rawValue: raw) != nil
  }

  /// `/api/image-groups` — the only truthful header source — takes the same eleven group keys.
  static func imageGroupsAcceptGroupByKey(_ raw: String) -> Bool {
    Operations.ImageGroupsApiImageGroupsGet.Input.Query.GroupByPayload(rawValue: raw) != nil
  }
}

extension SortKey {
  /// The four DISTINCT generated payload types the same six cases have to be spelled as — the
  /// same shape (and the same reason) as `GridSourceTier`'s: swift-openapi-generator emits a
  /// separate nested enum per operation's query, so there is no single shared type to map onto.
  var listImagesPayload: Operations.ListImagesApiImagesGet.Input.Query.SortPayload {
    switch self {
    case .dateTaken: return .dateTaken
    case .filename: return .filename
    case .rating: return .rating
    case .iso: return .iso
    case .camera: return .camera
    case .lens: return .lens
    }
  }

  var neighboursPayload:
    Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.SortPayload
  {
    switch self {
    case .dateTaken: return .dateTaken
    case .filename: return .filename
    case .rating: return .rating
    case .iso: return .iso
    case .camera: return .camera
    case .lens: return .lens
    }
  }
}

extension GroupByKey {
  var listImagesPayload: Operations.ListImagesApiImagesGet.Input.Query.GroupByPayload {
    switch self {
    case .day: return .day
    case .month: return .month
    case .camera: return .camera
    case .lens: return .lens
    case .iso: return .iso
    case .location: return .location
    }
  }

  var neighboursPayload:
    Operations.ImageNeighboursApiImagesImageIdNeighboursGet.Input.Query.GroupByPayload
  {
    switch self {
    case .day: return .day
    case .month: return .month
    case .camera: return .camera
    case .lens: return .lens
    case .iso: return .iso
    case .location: return .location
    }
  }

  var imageGroupsPayload: Operations.ImageGroupsApiImageGroupsGet.Input.Query.GroupByPayload {
    switch self {
    case .day: return .day
    case .month: return .month
    case .camera: return .camera
    case .lens: return .lens
    case .iso: return .iso
    case .location: return .location
    }
  }
}
