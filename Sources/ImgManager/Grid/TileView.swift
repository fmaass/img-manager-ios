import ImgManagerAPI
import SwiftUI

/// One grid cell: resolves its tier/size via `GridTierResolver` (never upscaling), fetches
/// proxy bytes through `GridStore` (cached), and shows the badge priority the plan pins:
/// tick (Select) → mark (Pick/Dislike) → Edited → Good, at most two.
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
  let store: GridStore
  /// WP13 P11 (IMGMGR-220): the pointer-hover seam, injectable in the shape of
  /// `GridView.pointerGestureInstaller` so a spy can prove this cell really installs the effect.
  /// Pointer presence is a RUNTIME fact — nothing here branches on the device idiom.
  var hoverEffectInstaller: HoverEffectInstaller = .live

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
    // shared: one tile surfaces as SEVERAL accessibility elements, so a shared identifier makes
    // "tap element 0, then element 1" tap the same photograph twice — selecting it and then
    // deselecting it, which is exactly how the first version of that test read "0 selected".
    .accessibilityIdentifier("gridTile-\(image.id)")
    // ≥44×44pt hit region (fold item 4) even for a tile whose rendered/reflowed size is
    // smaller — the tap target is never shrunk along with a capped/placeholder tile.
    .frame(minWidth: 44, minHeight: 44)
  }

  @ViewBuilder
  private func content(tier: ProxyTier, size: CGSize) -> some View {
    Group {
      if let proxyImage {
        PlatformImageView(image: proxyImage)
          .aspectRatio(contentMode: .fit)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(width: size.width, height: size.height)
    .task(id: "\(image.id)|\(tier.rawValue)") {
      let token = ProxyIdentity.token(from: image.proxies.additionalProperties[tier.rawValue]?.url)
      if let data = await store.proxyData(imageID: image.id, tier: tier, identityToken: token),
        let decoded = PlatformImage(data: data)
      {
        proxyImage = decoded
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
  /// testable without a render host — the same posture `GridGroupControl.title(for:)` uses.
  static func plateText(
    for image: Components.Schemas.ImageSummary, showsPlate: Bool
  ) -> String? {
    guard showsPlate else { return nil }
    return image.filename
  }

  @ViewBuilder
  private var badges: some View {
    // Priority order: tick (Select) → mark → Edited → Good, at most two shown.
    let items = badgeItems()
    HStack(spacing: 2) {
      ForEach(items.prefix(2), id: \.self) { item in
        Image(systemName: item.systemImage)
          .font(.caption2)
          .padding(3)
          .background(.black.opacity(0.55), in: Circle())
          .foregroundStyle(.white)
      }
    }
    .padding(3)
  }

  private enum BadgeItem: Hashable {
    case selected, pick, dislike, edited, good, changedElsewhere
    var systemImage: String {
      switch self {
      case .selected: return "checkmark.circle.fill"
      case .pick: return "hand.thumbsup.fill"
      case .dislike: return "hand.thumbsdown.fill"
      case .edited: return "pencil.circle.fill"
      case .good: return "star.fill"
      case .changedElsewhere: return "arrow.triangle.2.circlepath"
      }
    }
  }

  private func badgeItems() -> [BadgeItem] {
    var items: [BadgeItem] = []
    // P6 (IMGMGR-116): highest priority — a refused write's compact, tile-local recovery
    // indicator (plan item 3.3, "tile-local in the grid") must never be crowded out by the
    // ordinary two-badge cap.
    if store.changedElsewhereImageIDs.contains(image.id) { items.append(.changedElsewhere) }
    if isSelectMode && isSelected { items.append(.selected) }
    switch image.mark.state {
    case .some(.pick): items.append(.pick)
    case .some(.dislike): items.append(.dislike)
    case .some(.none), .none: break
    }
    if image.hasEdit == true { items.append(.edited) }
    if image.lightroom.good == true { items.append(.good) }
    return items
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
