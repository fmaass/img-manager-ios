import ImgManagerAPI
import SwiftUI

/// One grid cell: resolves its tier/size via `GridTierResolver` (never upscaling), fetches
/// proxy bytes through `GridStore` (cached), and shows the badge priority the plan pins:
/// changed elsewhere → tick (Select) → mark (Pick/Dislike) → Edited → Lightroom rating → source
/// kind, at most two, each optional one gated by its R3-5 overlay (`TileBadgeItem.items`).
struct TileView: View {
  let image: Components.Schemas.ImageSummary
  let plan: TileRenderPlan
  let isFocused: Bool
  let isSelected: Bool
  let isSelectMode: Bool
  /// WP13 P5a (IMGMGR-221): the More menu's "Filename plates" toggle, resolved ONCE by
  /// `GridView` from `GridPreferences` and passed down — never re-read here, so every tile in a
  /// pass draws the same answer.
  let showsFilenamePlate: Bool
  @State private var proxyImage: PlatformImage?
  /// The render key `proxyImage` was decoded from (R3-15 stale-completion guard).
  @State private var loadedKey: TileRenderKey?
  /// IMGMGR-544: what `proxyImage` was rendered as. The look glyph follows THIS, never the saved
  /// row alone: a looked render that failed paints unlooked pixels and shows no glyph.
  @State private var paintedRendering: LoupeRendering?
  let store: GridStore
  /// WP13 P11 (IMGMGR-220): the pointer-hover seam, injectable in the shape of
  /// `GridView.pointerGestureInstaller` so a spy can prove this cell really installs the effect.
  /// Pointer presence is a RUNTIME fact — nothing here branches on the device idiom.
  var hoverEffectInstaller: HoverEffectInstaller = .live
  /// IMGMGR-475: whether `GridView` lays the quick-pick corner (`MarkCornerTarget`) over this
  /// tile's badges. When it does, the badges step out of the accessibility tree: the corner
  /// speaks every status they draw instead, and a badge element — which answers to this tile's identifier —
  /// would otherwise sit inside the corner, so a tap aimed at "the tile" could land on it.
  var hasMarkCorner: Bool = false
  /// R3-5 (IMGMGR-539): the More › View › Tile overlays toggles, resolved ONCE by `GridView`
  /// (`TileOverlaySet(preferences:)`) and passed down like `showsFilenamePlate`.
  var overlays: TileOverlaySet = .defaults
  /// IMGMGR-551 (R3-7): the Square layout centre-crops the photograph to fill its `edge × edge`
  /// cell; the justified layout (false) keeps `.fit` inside the packed size, unchanged.
  var cropsToFill: Bool = false

  var body: some View {
    hoverEffectInstaller.apply(cell)
  }

  private var cell: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        // The tombstone question is asked BEFORE the proxy question — see `TilePresentation`.
        switch TilePresentation.resolve(missing: image.missing, plan: plan) {
        case .tombstone:
          missingTile
        case .display(let tier, let size):
          content(tier: tier, size: size)
        case .placeholder(let reason):
          placeholder(reason: reason)
        }
      }
      badges
    }
    // ONE accessibility element per photograph (the `SceneCardView` precedent): the photo and its
    // badges merge into the element that answers to `gridTile-<id>`. Left as separate children,
    // every badge — and the empty badge row of a tile with none — surfaced as a further element
    // under the same identifier, so a query for "the tile" matched several elements and could
    // never resolve to one (it read as not hittable while the tile sat in full view). The plate
    // below stays its own element (`tileFilenamePlate`).
    .accessibilityElement(children: .combine)
    // An OVERLAY, never an extra row in a stack: the justified layout renders exactly the size
    // `packWithTierPlan` computed for this tile, so a plate that added height would put a second
    // size computation in the grid (`GridView`'s own doc comment forbids exactly that).
    .overlay(alignment: .bottom) { filenamePlate }
    .overlay(
      RoundedRectangle(cornerRadius: 2)
        .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
    )
    .contentShape(Rectangle())
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    // A stable, non-positional handle for the UI-test lane (WP13 P1's retained Select-mode
    // screenshots): the tiles are otherwise unnamed, and a screenshot test that selects
    // photographs by screen COORDINATE proves nothing reproducibly. Keyed by IMAGE ID, not
    // shared: one tile surfaces as more than one element (the photograph and, when shown, its
    // filename plate), so a shared identifier makes "tap element 0, then element 1" tap the same
    // photograph twice — selecting it and then deselecting it, which is exactly how the first
    // version of that test read "0 selected".
    .accessibilityIdentifier("gridTile-\(image.id)")
    // IMGMGR-539: in a DEBUG fixture run only, the badges this tile DRAWS, as the value of the
    // ONE `gridTile-<id>` element — the badges merge into it, so they cannot be queried as
    // elements of their own. Release builds carry no value here.
    .modifier(
      TileFixtureBadgeReadback(
        items: shownBadges, rating: image.lightroom.rating, sourceKind: image.sourceKind)
    )
    // ≥44×44pt hit region (fold item 4) even for a tile whose rendered/reflowed size is
    // smaller — the tap target is never shrunk along with a capped/placeholder tile.
    .frame(minWidth: 44, minHeight: 44)
  }

  @ViewBuilder
  private func content(tier: ProxyTier, size: CGSize) -> some View {
    Group {
      if let proxyImage {
        PlatformImageView(image: proxyImage)
          .aspectRatio(contentMode: cropsToFill ? .fill : .fit)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(width: size.width, height: size.height)
    .modifier(CentreCrop(isActive: cropsToFill))
    // R3-15: keyed on the proxy's local identity (token + reported dimensions), so a row adopted
    // from a 400-px to an 800-px grid file reloads even though its image id and tier are the same.
    // The request is built from the same key, so the key and the bytes cannot disagree.
    // IMGMGR-544: the key also carries the SAVED look (and the looked cache's epoch), so saving
    // or removing a look reloads the tile; decoding happens inside `tileImage`, so an undecodable
    // looked 200 falls back to the unlooked pixels instead of leaving the tile as it was.
    .task(id: store.tileRenderKey(image: image, tier: tier)) {
      let key = store.tileRenderKey(image: image, tier: tier)
      // A different photograph never shows the previous one's pixels (nor its glyph); the same
      // photograph keeps its old pixels and their rendering until the new bytes decode, so an
      // adoption does not flash blank.
      if key.proxy.imageID != loadedKey?.proxy.imageID {
        proxyImage = nil
        paintedRendering = nil
      }
      let render = await store.tileImage(key) { PlatformImage(data: $0) }
      guard let decoded = render.image else { return }
      // A superseded load is cancelled by `.task(id:)` when the key changes, and writes nothing.
      // The check and the writes are synchronous — no suspension point between them — so a
      // completion cannot land after its key was replaced. (SwiftUI runtime behaviour: the unit
      // tests do not exercise cancellation.)
      if !Task.isCancelled {
        proxyImage = decoded
        paintedRendering = render.rendering
        loadedKey = key
      }
    }
  }

  /// The tombstone presentation: the photograph is gone from the tier, whatever the proxy cache
  /// still holds. Distinct from `placeholder(reason: .missing)`, which means "no proxy has been
  /// generated at this tier yet" — a preparation state about the DERIVATIVE, not about the
  /// original. Sharing one visual would make "not rendered yet" and "no longer exists" the same
  /// message, and only one of them is permanent.
  @ViewBuilder
  private var missingTile: some View {
    ZStack {
      Rectangle().fill(.tertiary)
      Image(systemName: "questionmark.square.dashed")
    }
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityLabel("Missing — this photograph is no longer on the store")
    .accessibilityIdentifier("tileMissing")
  }

  @ViewBuilder
  private func placeholder(reason: TilePlaceholderReason) -> some View {
    ZStack {
      Rectangle().fill(.tertiary)
      switch reason {
      case .pending:
        ProgressView()
      case .permanentFail:
        Image(systemName: "exclamationmark.triangle")
      case .missing:
        Image(systemName: "photo")
      }
    }
    .frame(minWidth: 44, minHeight: 44)
  }

  /// The FILENAME, and only ever the filename — never a path (p3220 §4.5, the path-leak
  /// contract). `ImageSummary.filename` is the same string the inspector already renders;
  /// `ImageSummary` carries no path at all, so there is nothing here that could leak one.
  @ViewBuilder
  private var filenamePlate: some View {
    if let text = Self.plateText(for: image, showsPlate: showsFilenamePlate) {
      Text(text)
        .font(.caption2)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("tileFilenamePlate")
    }
  }

  /// A pure function so "the plate says the filename, and says nothing when it is off" is
  /// testable without a render host — the same posture `ArrangeModel.groupTitle(for:)` uses.
  static func plateText(
    for image: Components.Schemas.ImageSummary, showsPlate: Bool
  ) -> String? {
    guard showsPlate else { return nil }
    return image.filename
  }

  @ViewBuilder
  private var badges: some View {
    // Priority order: changed elsewhere → tick (Select) → mark → Edited → Lightroom rating →
    // source kind, at most two shown (`TileBadgeItem.items`, the R3-5 overlays applied first).
    HStack(spacing: 2) {
      ForEach(shownBadges, id: \.self) { item in
        badge(item)
          .font(.caption2)
          .padding(3)
          .background(.black.opacity(0.55), in: Circle())
          // WP16 P1 (p3332 decision 5): the three mark badges take the palette, the other badges
          // stay white. The glyph, the priority order and the two-badge cap are unchanged.
          .foregroundStyle(item.markRole.map { MarkPalette.color(for: $0) } ?? Color.white)
      }
    }
    .padding(3)
    .accessibilityHidden(hasMarkCorner)
  }

  /// One badge's drawing: its symbol, or the content the item carries (R3-5: the Lightroom
  /// rating's "★N", the source kind's own glyph). Spoken by its own label.
  @ViewBuilder
  private func badge(_ item: TileBadgeItem) -> some View {
    switch item.content(rating: image.lightroom.rating, sourceKind: image.sourceKind) {
    case .rating(let stars)?:
      Text(TileBadgeContent.ratingText(stars))
        .accessibilityLabel(TileBadgeContent.ratingLabel(stars))
    case .sourceKind(let symbol, let label)?:
      Image(systemName: symbol)
        .accessibilityLabel(label)
    case .symbol(let symbol)?:
      Image(systemName: symbol)
    case nil:
      Image(systemName: item.systemImage)
    }
  }

  /// IMGMGR-544: the tile shows looked pixels right now — it presents its photograph (not a
  /// tombstone or a placeholder) and the pixels it painted were a looked render.
  private var rendersLook: Bool {
    guard proxyImage != nil, let paintedRendering, TileBadgeItem.isLooked(paintedRendering)
    else { return false }
    if case .display = TilePresentation.resolve(missing: image.missing, plan: plan) { return true }
    return false
  }

  /// The badges this tile DRAWS: the overlay-filtered priority list, capped. One computation
  /// feeds both the drawn row and the fixture-only readback, so the two cannot disagree.
  private var shownBadges: [TileBadgeItem] {
    let items = TileBadgeItem.items(
      changedElsewhere: store.changedElsewhereImageIDs.contains(image.id),
      selected: isSelectMode && isSelected, mark: image.mark.state, hasEdit: image.hasEdit,
      rendersLook: rendersLook,
      rating: image.lightroom.rating, sourceKind: image.sourceKind, overlays: overlays)
    return TileBadgeItem.drawn(items)
  }
}

/// R3-5 (IMGMGR-539): which optional tile overlays are on, resolved ONCE per body pass by
/// `GridView` on the main actor and handed to every tile as a value — a tile never reads the
/// main-actor `GridPreferences` itself, so every tile in a pass draws the same answer.
struct TileOverlaySet: Equatable, Sendable {
  var marks: Bool
  var edited: Bool
  var lightroomRating: Bool
  var sourceKind: Bool
  var filename: Bool

  /// The shipped defaults: marks and edited on, the rest off. Spelled as literals because
  /// `GridPreferences`' statics are main-actor isolated; `TileOverlayTests.defaults` proves the
  /// two agree.
  static let defaults = TileOverlaySet(
    marks: true, edited: true, lightroomRating: false, sourceKind: false, filename: false)
}

extension TileOverlaySet {
  @MainActor
  init(preferences: GridPreferences) {
    self.init(
      marks: preferences.overlayMarks, edited: preferences.overlayEdited,
      lightroomRating: preferences.overlayLightroomRating,
      sourceKind: preferences.overlaySourceKind, filename: preferences.filenamePlates)
  }
}

/// What a badge shows beyond its plain symbol. Separate from `TileBadgeItem` so that type stays
/// payload-free and `CaseIterable` (the mark-colour truth table iterates it).
enum TileBadgeContent: Equatable, Sendable {
  case symbol(String)
  case rating(Int)
  case sourceKind(symbol: String, label: String)

  /// The drawn rating: "★3".
  static func ratingText(_ stars: Int) -> String { "★\(stars)" }

  /// The spoken rating: "Lightroom rating 3".
  static func ratingLabel(_ stars: Int) -> String { "Lightroom rating \(stars)" }

  /// The source-kind glyph per `source_kind`; nil for an unknown or absent kind (no badge).
  static func sourceKindSymbol(_ sourceKind: String?) -> String? {
    switch sourceKind {
    case "raw_embedded": return "camera"
    case "image_raster": return "photo"
    case "master": return "slider.horizontal.3"
    case "web_preview", "template_export": return "globe"
    default: return nil
    }
  }
}

/// IMGMGR-539: the tile's drawn badges as `badges=<item>,<item>` on its accessibility value,
/// only when the DEBUG stub fixture is running (the UI wiring test reads it); otherwise the
/// content is returned untouched.
struct TileFixtureBadgeReadback: ViewModifier {
  let items: [TileBadgeItem]
  let rating: Int?
  let sourceKind: String?

  @ViewBuilder
  func body(content view: Content) -> some View {
    #if DEBUG
      if DebugStubLaunch.isActive {
        view.accessibilityValue("badges=" + items.map { readback($0) }.joined(separator: ","))
      } else {
        view
      }
    #else
      view
    #endif
  }

  /// One drawn badge: its case name, plus the drawn rating for the Lightroom slot
  /// ("lightroomRating(★3)").
  private func readback(_ item: TileBadgeItem) -> String {
    switch item.content(rating: rating, sourceKind: sourceKind) {
    case .rating(let stars)?: return "\(item)(\(TileBadgeContent.ratingText(stars)))"
    default: return "\(item)"
    }
  }
}

/// One badge a tile can show. Top-level and internal since WP16 P1 (p3332 decision 5): the mark
/// colours are a truth table over exactly these cases, and a table nothing outside `TileView`
/// could name is a table no test could read. R3-5 (IMGMGR-539): `.good` became
/// `.lightroomRating` in the same slot (it now draws the rating, "★N"), and `.sourceKind` is
/// appended last, so no existing pair changes relative order.
enum TileBadgeItem: Hashable, CaseIterable, Sendable {
  case selected, pick, dislike, edited, look, lightroomRating, changedElsewhere, sourceKind

  /// At most two badges on a tile.
  static let cap = 2

  var systemImage: String {
    switch self {
    case .selected: return "checkmark.circle.fill"
    case .pick: return "hand.thumbsup.fill"
    case .dislike: return "hand.thumbsdown.fill"
    case .edited: return "pencil.circle.fill"
    case .look: return "camera.filters"
    case .lightroomRating: return "star.fill"
    case .changedElsewhere: return "arrow.triangle.2.circlepath"
    case .sourceKind: return "doc"
    }
  }

  /// The payload this item draws, or nil when it has none to draw. `.lightroomRating` needs a
  /// rating in 1...5 (nil, 0 "unrated", -1 "rejected" and anything else draw nothing);
  /// `.sourceKind` needs a known kind. The other items are their symbol.
  func content(rating: Int?, sourceKind: String?) -> TileBadgeContent? {
    switch self {
    case .lightroomRating:
      guard let rating, (1...5).contains(rating) else { return nil }
      return .rating(rating)
    case .sourceKind:
      guard let symbol = TileBadgeContent.sourceKindSymbol(sourceKind) else { return nil }
      return .sourceKind(symbol: symbol, label: LoupeFidelityLabel.label(sourceKind: sourceKind))
    case .selected, .pick, .dislike, .edited, .look, .changedElsewhere:
      return .symbol(systemImage)
    }
  }

  /// The badges a tile DRAWS: the eligible list (`items`) capped at `cap`. The one function
  /// both the drawn row and the fixture readback use.
  static func drawn(_ eligible: [TileBadgeItem]) -> [TileBadgeItem] {
    Array(eligible.prefix(cap))
  }

  /// Whether a painted rendering went through a look (IMGMGR-544): `.looked` only; a fallback
  /// painted unlooked pixels.
  static func isLooked(_ rendering: LoupeRendering) -> Bool {
    if case .looked = rendering { return true }
    return false
  }

  /// The tile's badge list in priority order, BEFORE the cap: changed elsewhere and the Select
  /// tick are mandatory; the mark, Edited, the Lightroom rating and the source kind each follow
  /// their overlay. An item with nothing to draw is not emitted, so it never takes a slot.
  ///
  /// IMGMGR-544: `.look` (after Edited) is always on — no overlay gates it — and is eligible
  /// only when the tile PAINTED a looked render (`rendersLook`) and the photograph has no
  /// Lightroom edit: the look glyph and the edit pencil never appear together.
  static func items(
    changedElsewhere: Bool, selected: Bool, mark: Components.Schemas.MarkView.StatePayload?,
    hasEdit: Bool?, rendersLook: Bool = false, rating: Int?, sourceKind: String?,
    overlays: TileOverlaySet
  ) -> [TileBadgeItem] {
    var items: [TileBadgeItem] = []
    // P6 (IMGMGR-116): highest priority — a refused write's compact, tile-local recovery
    // indicator (plan item 3.3, "tile-local in the grid") must never be crowded out by the
    // ordinary two-badge cap.
    if changedElsewhere { items.append(.changedElsewhere) }
    if selected { items.append(.selected) }
    if overlays.marks {
      switch mark {
      case .some(.pick): items.append(.pick)
      case .some(.dislike): items.append(.dislike)
      case .some(.none), .none: break
      }
    }
    if overlays.edited && hasEdit == true { items.append(.edited) }
    if rendersLook && hasEdit != true { items.append(.look) }
    for item in [TileBadgeItem.lightroomRating, .sourceKind] {
      let isOn = item == .lightroomRating ? overlays.lightroomRating : overlays.sourceKind
      if isOn && item.content(rating: rating, sourceKind: sourceKind) != nil {
        items.append(item)
      }
    }
    return items
  }
}

/// IMGMGR-551 (R3-7): clips a centre-cropped (`.fill`) photograph to its frame. Inactive — the
/// justified layout — it is the identity, so a justified cell renders exactly as before.
struct CentreCrop: ViewModifier {
  let isActive: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isActive {
      content.clipped()
    } else {
      content
    }
  }
}

#if canImport(UIKit)
  import UIKit
  typealias PlatformImage = UIImage

  struct PlatformImageView: View {
    let image: PlatformImage
    var body: some View { Image(uiImage: image).resizable() }
  }
#else
  import AppKit
  typealias PlatformImage = NSImage

  struct PlatformImageView: View {
    let image: PlatformImage
    var body: some View { Image(nsImage: image).resizable() }
  }
#endif
