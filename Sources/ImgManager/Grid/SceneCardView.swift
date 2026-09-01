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
/// **The badges follow the web (IMGMGR-241, owner directive 2026-08-31).** LEFT: `member_count`,
/// how big the scene is — where a photo tile's own state row sits, so the eye finds the same kind
/// of fact in the same place on either kind of cell. TOP-RIGHT: what has been SAID about the
/// scene — `✓n` from `picked_count` first, then the cover's own `has_edit` pencil, glyph-only.
/// Pick before edited is the order the reader judges in.
///
/// Three badges became two questions, deliberately. `has_pick` was a FLAG, and a flag makes a
/// scene with one pick and a scene with nine look identical — exactly the question a reader
/// culling a burst asks of a closed scene, and one the client cannot answer itself because a
/// collapsed scene's members are never loaded. The match badge is GONE (same directive): it
/// answered a third question in a corner where the owner wants two.
///
/// The expand chevron is gone from here too, and that is IMGMGR-240: it was a decoration inside
/// a combined accessibility element, looking like the control it was not. The real control is
/// `SceneExpandHandle`, drawn beside this card by `GridView`.
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

  private var accessibilityName: String {
    SceneCardAccessibility.label(
      memberCount: row.memberCount, pickedCount: row.pickedCount, isExpanded: isExpanded)
  }

  var body: some View {
    hoverEffectInstaller.apply(cell)
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
      countBadge
    }
    .overlay(alignment: .topTrailing) { verdictBadges }
    .overlay(alignment: .bottomLeading) { openingIndicator }
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
    // nothing on a card, so the card says out loud what its ONE gesture is — and since
    // IMGMGR-240 there is a named control beside it that does the same thing without a gesture.
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

  /// How big the scene is, and nothing else.
  private var countBadge: some View {
    Label("\(row.memberCount)", systemImage: "square.stack")
      .font(.caption2)
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 5)
      .padding(.vertical, 3)
      .background(.black.opacity(0.55), in: Capsule())
      .foregroundStyle(.white)
      .padding(3)
      .accessibilityIdentifier("sceneMemberCount")
  }

  /// What has been said about the scene: the pick COUNT, then the cover's edited state.
  ///
  /// Nothing at zero on either — a badge that is always there states nothing. The pencil carries
  /// no digit, and that is the SAME deviation the web shipped: `has_edit` is the cover's own
  /// field, and there is no server-side `edited_count` to count with until IMGMGR-263 adds one.
  @ViewBuilder
  private var verdictBadges: some View {
    // Nothing said, nothing drawn: an empty capsule in the corner of every unjudged scene would
    // be the "badge that is always there" this cluster exists to avoid.
    if row.pickedCount >= 1 || cover.hasEdit == true {
      HStack(spacing: 3) {
        if row.pickedCount >= 1 {
          Label("\(row.pickedCount)", systemImage: "checkmark")
            .accessibilityIdentifier("scenePickCount")
            // WP16 P1 (p3332 decision 5). The enclosing `.foregroundStyle(.white)` below still
            // answers for anything without its own — `countBadge` is a separate view and stays
            // white, because how big a scene is says nothing about its verdict.
            .foregroundStyle(MarkPalette.color(for: .pick))
        }
        if cover.hasEdit == true {
          Image(systemName: "pencil")
            .accessibilityIdentifier("sceneEdited")
            .accessibilityLabel("Edited")
            .foregroundStyle(MarkPalette.color(for: .edited))
        }
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

  /// The one thing the card alone can say once IMGMGR-240 swapped it out of an OPEN scene: the
  /// reader's own "open" is in flight, and this is why the band has not replaced it yet. A card
  /// rendered `isExpanded` can only BE that state — an open scene whose members have arrived is
  /// drawn as its members.
  @ViewBuilder
  private var openingIndicator: some View {
    if isExpanded {
      ProgressView()
        .controlSize(.mini)
        .padding(4)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(3)
        .accessibilityHidden(true)
    }
  }
}
