import Foundation
import ImgManagerAPI

/// WHAT a gesture just addressed, as a type rather than as a bare integer.
///
/// Scene mode puts two different things in the same justified grid, and a collapsed scene card is
/// NOT a write target (the backend's own `StackBrowseStackRow` doc says why the cover's id cannot
/// be kept off the wire: "any rendition URL embeds an image id ... enforced at the CLIENT
/// actionability boundary"). While every layout key, packed row and hit-test frame was an `Int`,
/// the only thing standing between a pointer drag over a card and a mark on that card's cover was
/// remembering not to put the cover's id into the frame dictionary. This enum removes the
/// question: a card contributes `.stack`, and `.stack` has no image id to write to, so a Pick-Lock
/// drag or a Select drag that crosses a card cannot produce a mark payload or a selection entry —
/// there is nothing to produce one FROM.
///
/// Flat mode uses `.image` for every row, so its behaviour is unchanged by construction.
enum GridDisplayID: Hashable, Sendable {
  case image(Int)
  case stack(Int)

  /// The photograph this display thing IS, or nil because it is not one. The only sanctioned way
  /// to get an image id back out — a card answers `nil`, which is exactly the boundary.
  var imageID: Int? {
    guard case .image(let id) = self else { return nil }
    return id
  }
}

/// Flat browse (`GET /api/images`) or Scene browse (`GET /api/browse/stacks`). Not a query field:
/// the two modes call DIFFERENT endpoints with different row vocabularies and different cursors,
/// which is why this is a mode and never a `group_by` value on the wire.
enum GridDisplayMode: Sendable, Equatable {
  case flat
  case scene
}

/// One row exactly as `GET /api/browse/stacks` served it, narrowed once — at the service
/// boundary — from the generated `anyOf` union onto the `kind` discriminator the schema declares.
/// Every consumer downstream of `GridService` reads THIS, so the generated union's shape is
/// confined to a single mapping function.
enum SceneBrowseRow: Sendable, Equatable {
  case image(Components.Schemas.ImageSummary)
  case stack(Components.Schemas.StackBrowseStackRow)

  var displayID: GridDisplayID {
    switch self {
    case .image(let image): return .image(image.id)
    case .stack(let row): return .stack(row.stackId)
    }
  }

  /// Narrow ONE wire row out of the generated `anyOf` union, or `nil` for a row that is neither —
  /// which the caller treats as an unusable response rather than silently dropping a photograph.
  ///
  /// The schema discriminates on `kind`, and the generated code enforces that discriminator at
  /// DECODE time rather than leaving it to a check here: `kind` is declared `const`, OpenAPIKit
  /// reads a `const` as a one-element `enum`, and swift-openapi-generator turns a one-element
  /// string enum into a one-CASE Swift enum. So `StackBrowseImageRow.KindPayload` can only ever
  /// hold `.image` and `StackBrowseStackRow.KindPayload` only `.stack` — a row carrying
  /// `"kind": "stack"` cannot decode as an image row at all, and its `value1` comes back nil.
  /// (Its required-field sets are disjoint too — `image` versus `stack_id` and four others — so
  /// the two guards agree.) Reading `kind` again here would re-check what the decoder already
  /// refused to produce; asserting that it IS so is the contract probe's job, not a runtime
  /// branch's.
  static func narrow(_ payload: Components.Schemas.StackBrowsePage.ItemsPayloadPayload)
    -> SceneBrowseRow?
  {
    switch (payload.value1, payload.value2) {
    case (let imageRow?, nil): return .image(imageRow.image)
    case (nil, let stackRow?): return .stack(stackRow)
    default: return nil
    }
  }
}

/// IMGMGR-542 (R3-22): one open peek band — a scene's members shown as their own rows under its
/// card's row, without entering the scene. A band is NOT a route (`WorkspaceRoute` never names
/// one); `GridStore.peekBands` holds them in the order they were opened.
struct PeekBand: Sendable, Equatable {
  let stackID: Int
  /// The stream's scroll anchor when the chevron was pressed — the second restore candidate when
  /// the band closes with the viewport inside it. Nil-ed by `GridStore.revalidateBandAnchors()`
  /// once it no longer names a rendered row.
  var anchorAtOpen: GridDisplayID?
}

/// One open band as the packer takes it: the scene's id and its members as display rows.
struct SceneBand: Sendable, Equatable {
  let stackID: Int
  let rows: [SceneDisplayRow]
}

/// How much of one opened scene's membership is still unread. Absent from
/// `GridStore.sceneMemberCursors` means "never opened"; `.exhausted` means "fully loaded" — a
/// distinction a bare `String?` cannot make without a second set beside it.
enum SceneMemberCursor: Sendable, Equatable {
  case more(String)
  case exhausted
}

/// One row as the GRID lays it out: a photograph, or a scene card that knows whether it is open.
///
/// Mirrors the web's `DisplayRow` (`frontend/src/lib/stacks.ts`) including its keying rule — the
/// identity is the typed `GridDisplayID`, so `image 7` and `stack 7` can never collide the way two
/// raw `7`s would.
enum SceneDisplayRow: Sendable, Equatable, Identifiable {
  case image(Components.Schemas.ImageSummary)
  case stack(Components.Schemas.StackBrowseStackRow)

  var id: GridDisplayID {
    switch self {
    case .image(let image): return .image(image.id)
    case .stack(let row): return .stack(row.stackId)
    }
  }

  /// The aspect ratio the justified packer lays this row out at. A card is drawn from its
  /// representative, so it packs like the photograph it shows; the same 1.0 fallback the flat grid
  /// already uses covers an image with no measured ratio.
  var aspectRatio: Double {
    switch self {
    case .image(let image): return image.aspectRatio ?? 1.0
    case .stack(let row): return row.representative.aspectRatio ?? 1.0
    }
  }
}

/// The derivations Scene mode's whole safety argument rests on, kept pure and free-standing so
/// they are testable without a store, a view or a network — the same shape the web keeps them in
/// (`frontend/src/lib/stacks.ts`). Two of them are the boundary itself (`displayRows`,
/// `actionableImages`); three are what WP14 lane B needed on top of it — where an open band hangs
/// its control, and the arithmetic behind the ✓N badge; and `openSceneMembers` is IMGMGR-406's
/// filmstrip scope, asked of that same state.
enum SceneRowBuilder {

  /// The display sequence: the served rows in the SERVER's order, with each OPEN scene REPLACED
  /// IN PLACE by its members.
  ///
  /// **The swap is the point (IMGMGR-240).** Until this story an open scene rendered its card AND
  /// every member behind it, so an N-member scene occupied N+1 cells and the cover appeared twice
  /// — once as the card's thumbnail and again as the member it actually is. The card is not a
  /// summary of an open scene; it is the CLOSED representation OF one. So opening swaps: the
  /// members take the scene's own position in the stream and no image id is emitted twice. Same
  /// semantics the web shipped in `frontend/src/lib/stacks.ts`, so the two surfaces agree.
  ///
  /// The card survives in exactly ONE open state, deliberately: while the membership is still on
  /// the wire (or came back empty). Expansion is committed the instant the reader asks for it —
  /// before the member request settles — so without this the scene would vanish from the stream
  /// entirely while it loaded, taking with it the only control left to close or retry it. That is
  /// why this never yields zero rows for a scene at any point of the lifecycle.
  static func displayRows(rows: [SceneBrowseRow]) -> [SceneDisplayRow] {
    // WP442 P12 (IMGMGR-540): the stream ALWAYS shows cards plus loose photographs; the in-place
    // swap of a card for its members is gone — a card tap pushes the scene instead.
    rows.map { row in
      switch row {
      case .image(let image): return .image(image)
      case .stack(let stack): return .stack(stack)
      }
    }
  }

  /// IMGMGR-542 (R3-22): the stream as marks, focus and selection see it — each card followed by
  /// the members of its OPEN peek band, in the card's place. The packer never reads this: it packs
  /// `displayRows(rows:)` and hangs each band under its card's packed row
  /// (`GridSectionLayout.renderRows`), so a member never shares a row with another card. A card
  /// stays `.stack`, so it is still never a write target (ADR-0005).
  static func bandedDisplayRows(rows: [SceneBrowseRow], bands: [SceneBand]) -> [SceneDisplayRow] {
    let byStack = Dictionary(bands.map { ($0.stackID, $0.rows) }, uniquingKeysWith: { a, _ in a })
    var out: [SceneDisplayRow] = []
    for row in displayRows(rows: rows) {
      out.append(row)
      if case .stack(let stack) = row, let members = byStack[stack.stackId] {
        out.append(contentsOf: members)
      }
    }
    return out
  }

  /// The entered scene's screen: its members, capture-ordered, tombstones included.
  static func enteredSceneRows(
    members: [Components.Schemas.ImageSummary]
  ) -> [SceneDisplayRow] {
    members.map(SceneDisplayRow.image)
  }

  /// The band of the OPEN scene this photograph belongs to, in display order — or `nil` because it
  /// belongs to none (a loose photograph, or a member of a scene nobody has open).
  ///
  /// IMGMGR-406, owner decision 2026-09-05 option (a): the loupe's filmstrip is "this scene",
  /// not "everything on screen", so it needs the membership question answered the same way the
  /// band itself is drawn — from `expanded` and `members`, the state `displayRows` above already
  /// renders, never a second fetch and never a cached band of a scene the reader has CLOSED
  /// (`GridStore.leaveScene` keeps those members in hand deliberately, so the fence on
  /// `expanded` is what keeps a closed scene's photographs out of every consumer of this).
  /// Iterating the expanded ids in sorted order keeps the answer deterministic even though a
  /// photograph can only ever be in one of them.
  static func openSceneMembers(
    containing imageID: Int,
    expanded: Set<Int>,
    members: [Int: [Components.Schemas.ImageSummary]]
  ) -> [Components.Schemas.ImageSummary]? {
    for stackID in expanded.sorted() {
      guard let band = members[stackID], band.contains(where: { $0.id == imageID }) else {
        continue
      }
      return band
    }
    return nil
  }

  /// One member's pick transition, as the ✓N badge sees it (IMGMGR-241).
  struct PickTransition: Sendable, Equatable {
    let imageID: Int
    let wasPicked: Bool
    let isPicked: Bool
  }

  /// What a batch of transitions does to each OPEN scene's `picked_count`, per scene.
  ///
  /// Only members the client actually holds can contribute: a photograph inside a scene nobody
  /// opened is not in `members`, and its scene's badge is left to the server's own re-read. A
  /// state that did not cross the pick boundary contributes nothing — picking an already-picked
  /// photograph must not count it twice.
  static func pickCountDeltas(
    _ transitions: [PickTransition],
    members: [Int: [Components.Schemas.ImageSummary]]
  ) -> [Int: Int] {
    var deltas: [Int: Int] = [:]
    for transition in transitions where transition.wasPicked != transition.isPicked {
      let step = transition.isPicked ? 1 : -1
      for (stackID, loaded) in members {
        guard loaded.contains(where: { $0.id == transition.imageID }) else { continue }
        deltas[stackID, default: 0] += step
      }
    }
    return deltas
  }

  /// A badge count can never go negative, whatever arithmetic a racing write produces — the same
  /// clamp the web's optimistic sibling applies (`library.ts`, `Math.max(0, …)`).
  static func clampedCount(_ count: Int, delta: Int) -> Int { max(0, count + delta) }

  /// The photographs on screen, in display order — "what a gesture may act on at all".
  ///
  /// Loose photographs and the members of EXPANDED scenes; NEVER a collapsed card's cover. This is
  /// the one list `GridStore` hands to marking, tagging, undo, focus, arrow navigation and the
  /// loupe, so "no hidden member is ever written, and no visible member is ever missed" is a
  /// property of the derivation rather than a promise each of a dozen call sites has to keep.
  static func actionableImages(_ rows: [SceneDisplayRow]) -> [Components.Schemas.ImageSummary] {
    rows.compactMap { row in
      guard case .image(let image) = row else { return nil }
      return image
    }
  }
}

extension Array {
  /// Bounds-checked read, for the outward search that walks a packed row looking for the nearest
  /// photograph either side of a column — an index one step past either end is an ordinary,
  /// expected outcome there, not a programmer error worth trapping on.
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
