import ImgManagerAPI
import SwiftUI

/// One collapsed scene, as a card.
///
/// A bespoke cell rather than a `TileView` with extra flags, and that is the point rather than a
/// styling preference. A collapsed card is not a write target, and `TileView` carries the entire
/// write surface — the selection ring, the mark badges, the focus ring, the `.task` that pages the
/// flat grid. A card built from it would have to REMOVE that surface flag by flag, leaving the
/// boundary one forgotten default away from failing. Built separately, there is no write surface
/// to remove: nothing here reads `store.selection`, nothing reads `mark`, and the only thing this
/// cell can produce is "open me".
///
/// What it DOES share is the visual language and the proxy path: the cover is fetched through the
/// same `GridStore.proxyData` cache at the same tier as any other cell, so a card takes its turn
/// with every other tile rather than opening a second lane.
///
/// Three badges, because they are three different questions and merging them would answer none of
/// them: `member_count` is how big the scene is, `has_pick` is whether the reader has already
/// judged something in it, and `matched_count` is how many members the ACTIVE filters match. The
/// matched badge is omitted when it equals the member count — a number that always agrees with
/// the one beside it states nothing.
struct SceneCardView: View {
  let row: Components.Schemas.StackBrowseStackRow
  let plan: TileRenderPlan
  let isExpanded: Bool
  let store: GridStore
  @State private var coverImage: PlatformImage?
  /// WP13 P11 (IMGMGR-220): the same pointer-hover seam every other cell takes. A card is not a
  /// write target (ADR-0005) — hovering it says "this is a thing you can open", nothing more.
  var hoverEffectInstaller: HoverEffectInstaller = .live

  private var cover: Components.Schemas.ImageSummary { row.representative }

  /// True while the filters match FEWER members than the scene holds — the only case where saying
  /// both numbers tells the reader anything.
  private var isPartiallyMatched: Bool { row.matchedCount < row.memberCount }

  private var accessibilityName: String {
    let photos = "\(row.memberCount) \(row.memberCount == 1 ? "photo" : "photos")"
    let state = isExpanded ? "open" : "closed"
    return "Scene of \(photos), \(state)\(row.hasPick ? ", has a pick" : "")"
  }

  var body: some View {
    // RED (gate r1): the installer is not called. The GREEN commit wraps `cell`.
    cell
  }

  private var cell: some View {
    ZStack(alignment: .topLeading) {
      Group {
        // The same rule every other cell follows (`TilePresentation`): a tombstoned cover is
        // drawn as gone, whatever the proxy cache still holds.
        switch TilePresentation.resolve(missing: cover.missing, plan: plan) {
        case .tombstone:
          coverPlaceholder(systemImage: "questionmark.square.dashed")
        case .display(let tier, let size):
          coverContent(tier: tier, size: size)
        case .placeholder(let reason):
          coverPlaceholder(systemImage: placeholderSymbol(reason))
        }
      }
      badges
    }
    .overlay(
      RoundedRectangle(cornerRadius: 2)
        .stroke(isExpanded ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 2)
    )
    .contentShape(Rectangle())
    // ≥44×44pt hit region, the same floor every other cell gets.
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityName)
    // The no-gesture-only rule, stated in the UI and not only in the code: a long press does
    // nothing on a card, so the card says out loud what its ONE gesture is.
    .accessibilityHint(
      isExpanded ? "Double tap to close this scene" : "Double tap to open this scene"
    )
    .accessibilityIdentifier("sceneCard")
  }

  @ViewBuilder
  private func coverContent(tier: ProxyTier, size: CGSize) -> some View {
    Group {
      if let coverImage {
        PlatformImageView(image: coverImage)
          .aspectRatio(contentMode: .fit)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(width: size.width, height: size.height)
    .task(id: "\(cover.id)|\(tier.rawValue)") {
      let token = ProxyIdentity.token(from: cover.proxies.additionalProperties[tier.rawValue]?.url)
      if let data = await store.proxyData(imageID: cover.id, tier: tier, identityToken: token),
        let decoded = PlatformImage(data: data)
      {
        coverImage = decoded
      }
    }
  }

  private func placeholderSymbol(_ reason: TilePlaceholderReason) -> String {
    switch reason {
    case .pending: return "clock"
    case .permanentFail: return "exclamationmark.triangle"
    case .missing: return "photo"
    }
  }

  @ViewBuilder
  private func coverPlaceholder(systemImage: String) -> some View {
    ZStack {
      Rectangle().fill(.tertiary)
      Image(systemName: systemImage)
    }
    .frame(minWidth: 44, minHeight: 44)
  }

  @ViewBuilder
  private var badges: some View {
    HStack(spacing: 3) {
      Label("\(row.memberCount)", systemImage: "square.stack")
        .accessibilityIdentifier("sceneMemberCount")
      if row.hasPick {
        Image(systemName: "hand.thumbsup.fill")
          .accessibilityIdentifier("sceneHasPick")
      }
      if isPartiallyMatched {
        Text("\(row.matchedCount) match")
          .accessibilityIdentifier("sceneMatchedCount")
      }
      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
    }
    .font(.caption2)
    .labelStyle(.titleAndIcon)
    .padding(.horizontal, 5)
    .padding(.vertical, 3)
    .background(.black.opacity(0.55), in: Capsule())
    .foregroundStyle(.white)
    .padding(3)
  }
}
