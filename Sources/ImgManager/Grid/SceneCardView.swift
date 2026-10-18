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
/// scene — `✓n` from `picked_count` first, then `✎n` from `edited_count` (WP21 P2; the pencil
/// was glyph-only, over the cover's own `has_edit`, until v0.20.0 gave it a number to state).
/// Pick before edited is the order the reader judges in.
///
/// Three badges became two questions, deliberately. `has_pick` was a FLAG, and a flag makes a
/// scene with one pick and a scene with nine look identical — exactly the question a reader
/// culling a burst asks of a closed scene, and one the client cannot answer itself because a
/// collapsed scene's members are never loaded. The match badge is GONE (same directive): it
/// answered a third question in a corner where the owner wants two.
///
/// **Both questions are now numbers** (WP21 P2, IMGMGR-339). The pencil carried no digit because
/// there was nothing to count with: it read the COVER's own `has_edit`, a boolean about one
/// photograph standing in for a fact about the scene. img-manager v0.20.0 answers the real
/// question — `StackBrowseStackRow.edited_count`, required on every row — so the pencil states
/// how many of the scene's photographs have an edit, for the same reason ✓N replaced `has_pick`.
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
    SceneVerdictBadges.spokenLabel(
      memberCount: row.memberCount, pickedCount: row.pickedCount, editedCount: row.editedCount,
      isExpanded: isExpanded)
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
    // R3-15: the same local proxy identity as `TileView`, so an adopted cover reloads.
    .task(id: TileLoadKey.make(image: cover, tier: tier)) {
      let key = TileLoadKey.make(image: cover, tier: tier)
      if let data = await store.proxyData(identity: key),
        let decoded = PlatformImage(data: data),
        !Task.isCancelled
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

  /// What has been said about the scene: the pick COUNT, then the edited COUNT.
  ///
  /// Nothing at zero on either — a badge that is always there states nothing. Both digits are the
  /// SERVER's own per-scene counts (`picked_count`, `edited_count`); neither is derived from the
  /// cover or from members a collapsed scene never loads.
  @ViewBuilder
  private var verdictBadges: some View {
    // Nothing said, nothing drawn: an empty capsule in the corner of every unjudged scene would
    // be the "badge that is always there" this cluster exists to avoid. Asked of the same pure
    // functions the two labels come from, so the cluster cannot appear empty or hide a digit.
    if !SceneVerdictBadges.isSilent(pickedCount: row.pickedCount, editedCount: row.editedCount) {
      HStack(spacing: 3) {
        if let picks = SceneVerdictBadges.pickText(row.pickedCount) {
          Label(picks, systemImage: "checkmark")
            .accessibilityIdentifier("scenePickCount")
            // WP16 P1 (p3332 decision 5). The enclosing `.foregroundStyle(.white)` below still
            // answers for anything without its own — `countBadge` is a separate view and stays
            // white, because how big a scene is says nothing about its verdict.
            .foregroundStyle(MarkPalette.color(for: .pick))
        }
        // ONE source for the digit and for the sentence that reports it (diff-gate B2): the
        // string this `Label` RENDERS is the same `editsText` value `spokenLabel` embeds, so the
        // card cannot announce "2 edited" while the pencil draws something else — or nothing.
        if let edits = SceneVerdictBadges.editsText(count: row.editedCount) {
          Label(edits, systemImage: "pencil")
            .accessibilityIdentifier("sceneEdited")
            // The SAME `edits` binding the Label renders, so the badge's own spoken name cannot
            // drift from its glyph either. (`children: .combine` swallows it on this card; it is
            // what a future non-combined card would read out.)
            .accessibilityLabel("\(edits) edited")
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

/// What the collapsed card's verdict cluster SAYS, as values rather than as a view (WP21 P2,
/// IMGMGR-339). The same posture `TileView.plateText` and `ArrangeModel.groupTitle(for:)` take:
/// "the pencil states the number, and states nothing at zero" is then a test that reads strings
/// instead of a screenshot somebody has to look at.
///
/// `spokenLabel` composes the card's sentence rather than replacing it: the size/state/picked
/// half stays `SceneCardAccessibility.label` — one sentence, still assembled in one place — and
/// this adds the edited clause the shipped function does not know about. It is what an assertion
/// on the badge has to read, because `SceneCardView.cell` ends in
/// `.accessibilityElement(children: .combine)`: the cluster's own identifiers are merged away
/// (`SceneExpandHandle`'s doc comment says so in as many words — "a handle drawn inside it would
/// be swallowed whole"), so `sceneEdited` names the pencil for a future non-combined card and for
/// the palette that colours it, while the card's LABEL is the surface a UI test can observe.
enum SceneVerdictBadges {

  /// The ✓ badge's digit, or nil for "draw nothing".
  static func pickText(_ pickedCount: Int) -> String? {
    pickedCount >= 1 ? "\(pickedCount)" : nil
  }

  /// **The one source of the pencil's digit** (diff-gate B2), read by BOTH the rendered `Label`
  /// and the spoken sentence below. Nil means "draw nothing" — `edited_count` is a REQUIRED
  /// non-negative integer on every `StackBrowseStackRow`, so zero is a real answer and not an
  /// absence.
  ///
  /// Why one function rather than two agreeing ones: the card combines its children into a single
  /// accessibility element, so a UI test can only read the card's LABEL. If that label were
  /// composed from `editedCount` independently of what the pencil renders, the assertion would
  /// witness the sentence and not the badge — a pencil drawing the wrong digit, or none, would
  /// still pass. Both call sites going through this function is what makes the label a proof
  /// about the pixels.
  static func editsText(count: Int) -> String? {
    count >= 1 ? "\(count)" : nil
  }

  /// The edited half of the card's sentence, and the pencil's own accessibility label: exactly
  /// `editsText` plus the word it is read with, or the empty string when nothing is drawn.
  static func spokenEditsClause(count: Int) -> String {
    guard let edits = editsText(count: count) else { return "" }
    return ", \(edits) edited"
  }

  /// Nothing said, nothing drawn. Derived from the two digit functions so the capsule and the
  /// digits inside it can never disagree about whether there is anything to show.
  static func isSilent(pickedCount: Int, editedCount: Int) -> Bool {
    pickText(pickedCount) == nil && editsText(count: editedCount) == nil
  }

  static func spokenLabel(
    memberCount: Int, pickedCount: Int, editedCount: Int, isExpanded: Bool
  ) -> String {
    SceneCardAccessibility.label(
      memberCount: memberCount, pickedCount: pickedCount, isExpanded: isExpanded)
      + spokenEditsClause(count: editedCount)
  }
}
