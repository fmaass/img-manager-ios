import SwiftUI

/// The funnel in the grid's chrome, and the popover it opens. WP16 P3 (IMGMGR-295), design record
/// [/link/3332] decision 1: "a funnel control in the grid nav bar — with the active-filter dot
/// whenever filters are active — opening a popover … EACH row showing its LIVE result count
/// before applying".
///
/// Rendered in the two places every other grid view-option control already is: a Regular
/// `.primaryAction` toolbar item and Compact's persistent options row (`GridView`). One
/// definition, so the two cannot drift.
///
/// The dot reads `InspectorFacetFilters.activeCount` — the SAME predicate the Info button uses
/// (`RootView.inspectorChromeButton`), so the two indicators cannot disagree about whether this
/// grid is filtered.
struct GridFilterControl: View {
  let store: GridStore
  @State private var isPresented = false

  private var activeCount: Int {
    InspectorFacetFilters.activeCount(store.currentQuery)
  }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Label("Filters", systemImage: symbolName)
    }
    // Icon-only: the funnel carries no value to read at rest, and the dot below is what states
    // "filters are on".
    .labelStyle(.iconOnly)
    // The dot itself. An overlay rather than a second glyph, so the control's own size is
    // identical filtered and unfiltered — a control that grows when a filter lands would reflow
    // Compact's options row underneath the reader's finger.
    .overlay(alignment: .topTrailing) {
      if activeCount > 0 {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 8, height: 8)
          .offset(x: 3, y: -2)
          .allowsHitTesting(false)
      }
    }
    .accessibilityIdentifier("gridFilterControl")
    .accessibilityLabel(Self.spokenLabel(activeCount: activeCount))
    // Machine-readable state, the convention `gridGroupControl` already established: the dot is
    // pixels, this is the same fact in words — and what a UI test can assert without reading one.
    .accessibilityValue(activeCount > 0 ? "Active" : "Off")
    .popover(isPresented: $isPresented) {
      // Deliberately NO `.presentationCompactAdaptation`: on Compact the system adapts a popover
      // to a sheet, which is the phone's existing filter idiom (the Info/Stats sheet), so the
      // adaptation is accepted rather than forced back into a popover the phone has no room for.
      FilterPopoverView(store: store)
    }
    // IMGMGR-542: Esc belongs to the popover while it is up, not to the peek bands under it.
    .onChange(of: isPresented) { _, now in
      store.notePopover("gridFilterControl", isPresented: now)
    }
  }

  /// The same shape `InspectorFacetFilters.infoButtonAccessibilityLabel` gives the Info button,
  /// under this control's own noun: "Filters" is what a reader is reaching for here, not "Info".
  private static func spokenLabel(activeCount: Int) -> String {
    switch activeCount {
    case 0: return "Filters"
    case 1: return "Filters, 1 filter active"
    default: return "Filters, \(activeCount) filters active"
    }
  }

  /// The filled variant is the shipped "filters are on" glyph — `RootView.inspectorChromeButton`
  /// already switches to exactly this symbol at exactly this threshold.
  private var symbolName: String {
    activeCount > 0
      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
  }
}

/// The popover's body: the declared rows, each stating the count it would deliver.
///
/// Every tap calls `GridStore.applyFacetFilter(_:value:)` and Clear calls
/// `GridStore.clearFacetFilters()` — the two shipped mutations the Stats tab already routes
/// through. This surface adds no mutation path and no facets fetch of its own: WP16 P2 moved the
/// refresh trigger onto `RootView.workspace`, so the counts are already loading on a screen the
/// inspector was never on.
struct FilterPopoverView: View {
  let store: GridStore
  @Environment(\.dismiss) private var dismiss

  private var activeCount: Int {
    InspectorFacetFilters.activeCount(store.currentQuery)
  }

  /// A `ScrollView` over an EAGER `VStack`, deliberately, and never a `List` (nor a `LazyVStack`).
  ///
  /// The gate's iPhone leg proved why. `List` is UICollectionView-backed and lazy: on the compact
  /// sheet this popover adapts to, it realised only the four rows that fit the viewport —
  /// `rating-3/4/5` and `mark-pick`, each with a correct identifier, label and count — and simply
  /// never built `mark-none`, `mark-dislike`, `hasMaster-true` or the Type rows. They were absent
  /// from the accessibility tree, not merely off screen ("Vertical scroll bar, 3 pages", 0%).
  ///
  /// That is a B2 violation on the real surface, not a test problem. Decision 1 NAMES these rows,
  /// and the whole point of rendering an absent dimension as a live 0 is that the reader can see
  /// the row is there and empty. A row that does not exist until it is scrolled into being is, for
  /// every purpose the decision cares about, omitted — and no identifier can fix a view that was
  /// never built. Virtualisation buys nothing here anyway: the row set is FIXED and small (three
  /// rating, three mark, one Edited, plus however many file types the response holds), so building
  /// all of it costs one pass and makes "every declared row is addressable" structurally true.
  /// R3-18 (IMGMGR-550) adds the Keyword section last, bounded at thirty rows
  /// (`FilterPopoverModel.keywordValueLimit`), which keeps the eager pass small.
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Outside the sections, and present only while something is filtered — the same rule the
        // Stats tab's own Clear row follows.
        if activeCount > 0 {
          clearFiltersRow
          Divider()
        }

        ForEach(FilterPopoverModel.rows(store.facets, store.currentQuery)) { section in
          sectionHeader(section.title)
          ForEach(section.rows) { row in
            rowView(row)
          }
        }
      }
      .padding(.vertical, 8)
    }
    .frame(idealWidth: 340, idealHeight: 460)
  }

  @ViewBuilder
  private var clearFiltersRow: some View {
    Button {
      Task { await store.clearFacetFilters() }
      dismiss()
    } label: {
      HStack {
        Label("Clear filters", systemImage: "xmark.circle")
        Spacer()
        Text("\(activeCount)").foregroundStyle(.secondary).monospacedDigit()
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("filterPopoverClearFilters")
  }

  /// The section caption, in the inspector's own idiom (`InspectorView.section`): uppercased
  /// caption2 in secondary. Carries no identifier — an identifier on a container OVERRIDES its
  /// descendants', which is how a sibling lane lost a row's own name.
  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func rowView(_ row: FilterPopoverRow) -> some View {
    Button {
      Task { await store.applyFacetFilter(row.field, value: row.value) }
      dismiss()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: row.isActive ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(row.isActive ? .primary : .tertiary)
        if let role = row.markRole {
          // Decision 5's fifth surface: the mark rows take the palette, so a Pick reads the same
          // green here as on the tile badge that means the same thing. The glyph SHAPE is
          // unchanged — colour augments the shape channel, it never replaces it.
          Image(systemName: Self.symbolName(for: role))
            .foregroundStyle(MarkPalette.color(for: role))
        }
        Text(row.title).fontWeight(row.isActive ? .semibold : .regular)
        Spacer()
        if row.isCounted {
          Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      // The whole row takes the tap, not just the glyph and the words in it.
      .contentShape(Rectangle())
    }
    // Plain, so the row keeps its own layout and its disabled state reads as dimmed text rather
    // than a tinted control — and so `.disabled` still reports through to `isEnabled`.
    .buttonStyle(.plain)
    // A 0-count row is not reachable — applying it would empty the grid — unless it is the value
    // in force, which `FilterPopoverRow.isEnabled` keeps enabled so it can always be cleared.
    .disabled(!row.isEnabled)
    .accessibilityIdentifier(row.accessibilityIdentifier)
    // The label is the row's own name and the value is its count, separately: a combined string
    // would make the count unreadable to anything but a person, including this phase's own tests.
    .accessibilityLabel(row.title)
    .accessibilityValue(row.isCounted ? "\(row.count)" : "")
    .accessibilityAddTraits(row.isActive ? [.isSelected] : [])
  }

  /// The tile badges' own vocabulary (`TileView`'s badge table), reused verbatim so one mark never
  /// wears two glyphs across the app.
  private static func symbolName(for role: MarkRole) -> String {
    switch role {
    case .pick: return "hand.thumbsup.fill"
    case .dislike: return "hand.thumbsdown.fill"
    case .edited: return "pencil.circle.fill"
    }
  }
}
