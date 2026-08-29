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
  case stack(row: Components.Schemas.StackBrowseStackRow, isExpanded: Bool)

  var id: GridDisplayID {
    switch self {
    case .image(let image): return .image(image.id)
    case .stack(let row, _): return .stack(row.stackId)
    }
  }

  /// The aspect ratio the justified packer lays this row out at. A card is drawn from its
  /// representative, so it packs like the photograph it shows; the same 1.0 fallback the flat grid
  /// already uses covers an image with no measured ratio.
  var aspectRatio: Double {
    switch self {
    case .image(let image): return image.aspectRatio ?? 1.0
    case .stack(let row, _): return row.representative.aspectRatio ?? 1.0
    }
  }
}

/// The two derivations Scene mode's whole safety argument rests on, kept pure and free-standing so
/// they are testable without a store, a view or a network — the same shape the web keeps them in
/// (`frontend/src/lib/stacks.ts`).
enum SceneRowBuilder {

  /// The display sequence: the served rows in the SERVER's order, each EXPANDED scene followed by
  /// the members loaded for it so far.
  ///
  /// An expanded scene whose members have not arrived yet renders as the card alone — the honest
  /// intermediate state, never a guess at what it contains.
  static func displayRows(
    rows: [SceneBrowseRow],
    expanded: Set<Int>,
    members: [Int: [Components.Schemas.ImageSummary]]
  ) -> [SceneDisplayRow] {
    var out: [SceneDisplayRow] = []
    for row in rows {
      switch row {
      case .image(let image):
        out.append(.image(image))
      case .stack(let stack):
        let isExpanded = expanded.contains(stack.stackId)
        out.append(.stack(row: stack, isExpanded: isExpanded))
        guard isExpanded else { continue }
        for member in members[stack.stackId] ?? [] {
          out.append(.image(member))
        }
      }
    }
    return out
  }

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
