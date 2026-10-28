import ImgManagerAPI
import SwiftUI

/// IMGMGR-543 (R3-10): the Looks strip — in the filmstrip's place while Looks is open on the
/// focused photograph. None, Favourites, Film · Camera · Mono (`LookStripSections`), each tile the
/// photograph's `.grid` proxy through that look; the strength slider (0…200 %, detents at 0, 100
/// and 200); Cancel, and Apply, which saves the draft (IMGMGR-544, `GridStore.applyLook`).
///
/// Every control is `.focusable(false)`: a tapped or dragged control must never become the focus
/// target that takes ←→↑↓ before the key commands do (`GridStore.handleArrowShortcut`). The
/// strength control is its own track for the same reason: after a drag on the system `Slider`
/// the iPad delivered ↑ and ← to nothing (gate runs 2026-10-23 18:49 and 19:12), which
/// `.focusable(false)` on the `Slider` did not prevent. An EAGER
/// `HStack`, never a lazy stack, so every tile has an accessibility element (the
/// `ArrangePopoverView` rule).
struct LooksStripView: View {
  let store: GridStore
  let image: Components.Schemas.ImageSummary
  /// The slider's value while a finger is on it; committed (snapped) when it lets go.
  @State private var dragValue: Double?

  private var looks: LookModel { store.looks }

  nonisolated static func tileIdentifier(for lookID: String?) -> String {
    "loupeLookTile-\(lookID ?? "none")"
  }

  var body: some View {
    let draft = looks.draft
    VStack(spacing: 6) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .bottom, spacing: 10) {
            tile(lookID: nil, name: "None", selected: draft?.lookID == nil)
            ForEach(
              LookStripSections.sections(
                catalogue: looks.catalogue, favourites: looks.favourites.ids),
              id: \.group
            ) { section in
              VStack(alignment: .leading, spacing: 2) {
                Text(section.group.title)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                  ForEach(section.looks, id: \.id) { look in
                    tile(lookID: look.id, name: look.name, selected: draft?.lookID == look.id)
                  }
                }
              }
            }
          }
          .padding(.horizontal, 12)
        }
        .onChange(of: draft?.lookID) { _, lookID in
          withAnimation { proxy.scrollTo(Self.tileIdentifier(for: lookID)) }
        }
      }
      controls(draft: draft)
      // IMGMGR-544: a failed save, for THIS strip session only.
      if let failure = looks.visibleSaveFailure(for: image.id) {
        Text(failure.copy)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("loupeLooksSaveFailure")
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("loupeLooksStrip")
  }

  private func tile(lookID: String?, name: String, selected: Bool) -> some View {
    Button {
      looks.select(lookID)
    } label: {
      VStack(spacing: 2) {
        LookTileImage(store: store, image: image, lookID: lookID, session: looks.stripSession)
          .frame(width: 64, height: 48)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
          }
        Text(name)
          .font(.caption2)
          .lineLimit(1)
          .frame(width: 72)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    // IMGMGR-544: the draft is frozen while its save is on the wire.
    .disabled(looks.isSaving(image.id))
    .id(Self.tileIdentifier(for: lookID))
    .accessibilityIdentifier(Self.tileIdentifier(for: lookID))
    .accessibilityLabel(name)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      if let lookID {
        Button(favouriteTitle(lookID), systemImage: "star") { looks.favourites.toggle(lookID) }
      }
    }
    .accessibilityActions {
      if let lookID {
        Button(favouriteTitle(lookID)) { looks.favourites.toggle(lookID) }
      }
    }
  }

  private func favouriteTitle(_ lookID: String) -> String {
    looks.favourites.contains(lookID) ? "Remove from Favourites" : "Add to Favourites"
  }

  @ViewBuilder
  private func controls(draft: LookModel.Draft?) -> some View {
    let strength = draft?.strength ?? LookStrength.standard
    let shown = dragValue.map(LookStrength.snapped) ?? strength
    HStack(spacing: 12) {
      Button("Cancel") { looks.cancel() }
        .focusable(false)
        .accessibilityIdentifier("loupeLooksCancel")
      LookStrengthTrack(
        strength: strength, dragValue: $dragValue,
        commit: { looks.setStrength($0) },
        nudge: { looks.nudgeStrength(by: $0) }
      )
      .disabled(draft?.lookID == nil || looks.isSaving(image.id))
      Text(LookStrength.label(shown))
        .font(.caption.monospacedDigit())
        .frame(minWidth: 48, alignment: .trailing)
        .accessibilityHidden(true)
      // IMGMGR-544: Apply saves the draft on the server (`GridStore.applyLook`); disabled while
      // that save is on the wire. Cancel stays live: it closes the strip, it cannot recall it.
      Button("Apply") { Task { await store.applyLook() } }
        .disabled(draft == nil || looks.isSaving(image.id))
        .focusable(false)
        .accessibilityIdentifier("loupeLooksApply")
    }
    .padding(.horizontal, 12)
  }
}

/// One tile's image: the photograph's `.grid` proxy through `lookID` (or unlooked for None),
/// asked once per strip session (`GridStore.lookTile`).
///
/// IMGMGR-650: while a look's render is pending — waiting for one of the four render slots, or
/// on the wire — the tile shows the photograph's unlooked grid tile
/// (`GridStore.lookTilePlaceholder`) above the look's name, never an empty square. A render that
/// fails leaves the empty square, as before: the placeholder is not a look.
private struct LookTileImage: View {
  let store: GridStore
  let image: Components.Schemas.ImageSummary
  let lookID: String?
  let session: Int
  @State private var rendered: PlatformImage?
  @State private var placeholder: PlatformImage?

  /// What one render answers for: the strip session, the photograph, the look and (IMGMGR-544)
  /// the look's tile generation, so an invalidated tile is asked for again.
  private var renderID: String {
    "\(session)|\(image.id)|\(lookID ?? "none")|\(store.looks.tileToken(for: lookID))"
  }

  var body: some View {
    ZStack {
      Rectangle().fill(.quaternary)
      if let shown = rendered ?? placeholder {
        PlatformImageView(image: shown)
          .scaledToFill()
      }
    }
    .task(id: renderID) {
      rendered = nil
      placeholder = nil
      let token = ProxyIdentity.token(
        from: image.proxies.additionalProperties[ProxyTier.grid.rawValue]?.url)
      if lookID != nil {
        let unlooked = await store.lookTilePlaceholder(imageID: image.id, identityToken: token)
        guard !Task.isCancelled else { return }
        placeholder = unlooked.flatMap { PlatformImage(data: $0) }
      }
      let data = await store.lookTile(imageID: image.id, lookID: lookID, identityToken: token)
      guard !Task.isCancelled else { return }
      placeholder = nil
      rendered = data.flatMap { PlatformImage(data: $0) }
    }
  }
}

/// The strength track, 0…200 % with ticks at the detents: a drag shows the value under the
/// finger and commits it snapped (`LookStrength.snapped`) on release. Built from shapes and a
/// `DragGesture`, so there is no focusable control to keep the arrow keys after a drag; to
/// VoiceOver it is one adjustable element (±10 %) with the strength as its value.
private struct LookStrengthTrack: View {
  let strength: Int
  @Binding var dragValue: Double?
  let commit: (Int) -> Void
  let nudge: (Int) -> Void
  @Environment(\.isEnabled) private var isEnabled

  private static let lower = Double(LookStrength.range.lowerBound)
  private static let upper = Double(LookStrength.range.upperBound)
  private static let thumb: CGFloat = 22

  private static func fraction(_ value: Double) -> CGFloat {
    CGFloat((min(max(value, lower), upper) - lower) / (upper - lower))
  }

  var body: some View {
    GeometryReader { geometry in
      let width = max(geometry.size.width - Self.thumb, 1)
      let shown = Self.fraction(dragValue ?? Double(strength))
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary).frame(height: 4)
        Capsule().fill(.tint).frame(width: Self.thumb / 2 + width * shown, height: 4)
        ForEach(LookStrength.detents, id: \.self) { detent in
          Rectangle()
            .fill(.secondary)
            .frame(width: 1, height: 8)
            .offset(x: Self.thumb / 2 + width * Self.fraction(Double(detent)) - 0.5)
        }
        Circle()
          .fill(.white)
          .shadow(radius: 1)
          .frame(width: Self.thumb, height: Self.thumb)
          .offset(x: width * shown)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in dragValue = value(at: drag.location.x, width: width) }
          .onEnded { drag in
            commit(LookStrength.snapped(value(at: drag.location.x, width: width)))
            dragValue = nil
          })
    }
    .frame(height: 31)
    .opacity(isEnabled ? 1 : 0.4)
    .accessibilityElement()
    .accessibilityLabel("Strength")
    .accessibilityIdentifier("loupeLookStrength")
    .accessibilityValue(LookStrength.label(strength))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: nudge(LookStrength.nudge)
      case .decrement: nudge(-LookStrength.nudge)
      @unknown default: break
      }
    }
  }

  private func value(at x: CGFloat, width: CGFloat) -> Double {
    let fraction = min(max((x - Self.thumb / 2) / width, 0), 1)
    return Self.lower + Double(fraction) * (Self.upper - Self.lower)
  }
}
