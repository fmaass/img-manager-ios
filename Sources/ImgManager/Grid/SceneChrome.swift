import ImgManagerAPI
import SwiftUI

/// What the scene's expand control ANNOUNCES, as values rather than as a rendered view.
///
/// Pure for the same reason `FilmstripThumbnailAccessibility` is: the claim "the control names
/// what it does and says which state it is in" is a contract, and a contract belongs in a test
/// that reads a string, not in a screenshot that has to be looked at.
enum SceneHandleAccessibility {
  static func label(isExpanded: Bool) -> String { isExpanded ? "Close scene" : "Open scene" }
  /// The state half. SwiftUI has no `aria-expanded` trait, so the state travels as the element's
  /// VALUE — which is what VoiceOver reads immediately after the label, and what XCUITest can
  /// assert on.
  static func value(isExpanded: Bool) -> String { isExpanded ? "Open" : "Closed" }
}

/// What a collapsed card announces (IMGMGR-241 changed it): how big the scene is, whether it is
/// open, and — now a COUNT rather than a flag — how many of its members are picked.
enum SceneCardAccessibility {
  static func label(memberCount: Int, pickedCount: Int, isExpanded: Bool) -> String {
    let photos = "\(memberCount) \(memberCount == 1 ? "photo" : "photos")"
    let state = isExpanded ? "open" : "closed"
    let picks = pickedCount >= 1 ? ", \(pickedCount) picked" : ""
    return "Scene of \(photos), \(state)\(picks)"
  }
}

/// The scene's expand control (IMGMGR-240) — the promotion of what used to be a decorative
/// chevron drawn inside the card's badge cluster.
///
/// Until this story the ONLY way to open a scene was to double-tap the picture and discover that
/// the picture was a control; the chevron beside the badges looked like the affordance and was
/// not one. This is a real `Button`: it carries a name, a state, a ≥44×44 pt hit region and — by
/// being a Button at all — the hardware-keyboard reachability the gesture never had.
///
/// It is a SIBLING of the cell rather than a child of it, and that is load-bearing twice over.
/// `SceneCardView` combines its children into ONE accessibility element (it is a picture with
/// badges, not a set of controls), so a handle drawn inside it would be swallowed whole. And
/// the same overlay position has to work over the BAND, where — since IMGMGR-240 — there is no
/// card at all, only the members that replaced it.
struct SceneExpandHandle: View {
  let stackID: Int
  let isExpanded: Bool
  let store: GridStore

  var body: some View {
    Button {
      Task { await store.toggleSceneExpanded(stackID) }
    } label: {
      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.caption2.weight(.semibold))
        .frame(width: 24, height: 24)
        .background(.black.opacity(0.65), in: Circle())
        .foregroundStyle(.white)
        // The ≥44×44 pt floor every other control in this app gets, without growing the drawn
        // glyph: the justified solver owns the cell's pixels, so the target is padded, not the art.
        .frame(minWidth: 44, minHeight: 44, alignment: .center)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sceneHandle-\(stackID)")
    .accessibilityLabel(SceneHandleAccessibility.label(isExpanded: isExpanded))
    .accessibilityValue(SceneHandleAccessibility.value(isExpanded: isExpanded))
    .padding(2)
  }
}

/// The picks a COLLAPSED scene holds, drawn inside the card's own region (IMGMGR-261).
///
/// DISPLAY-ONLY, and structurally so rather than by remembering: these are not `TileView`s (the
/// type that carries the entire write surface), they are not in `actionableImages`, they hold no
/// mark badge and no selection ring, and the whole strip refuses hit testing — so the card stays
/// ONE tap target that opens the group, exactly as ADR-0005 requires. The photographs come from
/// a bespoke capped read (`GridStore.sceneInlinePicks`) that never touches `sceneMembers`, which
/// is the array expansion writes into.
struct SceneInlinePicksStrip: View {
  let stackID: Int
  let picks: [Components.Schemas.ImageSummary]
  let store: GridStore

  /// How many fit before they stop being legible rather than informative. The READ is capped at
  /// the first membership page; this is the second cap, on what is drawn.
  static let visibleLimit = 3

  private var visible: [Components.Schemas.ImageSummary] {
    Array(picks.prefix(Self.visibleLimit))
  }

  var body: some View {
    HStack(spacing: 2) {
      // Keyed by IMAGE ID (IMGMGR-210) — never by position in the strip.
      ForEach(visible, id: \.id) { image in
        SceneInlinePickThumb(image: image, store: store)
      }
      if picks.count > Self.visibleLimit {
        Text("+\(picks.count - Self.visibleLimit)")
          .font(.system(size: 9, weight: .semibold))
          .padding(.horizontal, 3)
      }
    }
    .padding(3)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
    .foregroundStyle(.white)
    .padding(4)
    // Never a gesture target: the card's own tap opens the group, and a member reached through a
    // collapsed card is not addressable at all.
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("sceneInlinePicks-\(stackID)")
    .accessibilityLabel(
      "\(picks.count) picked \(picks.count == 1 ? "photo" : "photos") in this scene")
  }
}

/// One inline pick, at the same tier and through the same cache every other cell uses — a strip
/// of picks takes its turn in the proxy queue rather than opening a second lane.
private struct SceneInlinePickThumb: View {
  let image: Components.Schemas.ImageSummary
  let store: GridStore
  @State private var thumb: PlatformImage?

  var body: some View {
    Group {
      if let thumb {
        PlatformImageView(image: thumb)
          .aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(width: 26, height: 26)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .task(id: image.id) {
      let tier = ProxyTier.grid
      let token = ProxyIdentity.token(from: image.proxies.additionalProperties[tier.rawValue]?.url)
      if let data = await store.proxyData(imageID: image.id, tier: tier, identityToken: token),
        let decoded = PlatformImage(data: data)
      {
        thumb = decoded
      }
    }
  }
}
