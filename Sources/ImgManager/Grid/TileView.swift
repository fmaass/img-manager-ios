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
  @State private var proxyImage: PlatformImage?
  let store: GridStore

  var body: some View {
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
    .overlay(
      RoundedRectangle(cornerRadius: 2)
        .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
    )
    .contentShape(Rectangle())
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
