import SwiftUI

/// WP29 P2 (IMGMGR-453): what one Arrange row chooses — a sort key, a direction, a grouping or a
/// thumbnail size. Each case carries a value of a type the store already owns, so a row can only
/// name a state the shipped setters accept.
enum ArrangeChoice: Hashable, Sendable {
  case sortKey(SortKey)
  case direction(SortDirection)
  case grouping(GroupingChoice)
  case size(GridRowHeight)
  /// IMGMGR-551 (R3-7): Justified or Square.
  case layout(GridLayoutStyle)
}

/// One row of the Arrange popover. A row has no children: every choice is ONE tap inside the
/// popover, so the popover is depth 1 and each choice depth 2 (the ticket's "every row depth ≤ 2").
/// The row type has no field that could hold a nested row, which `ArrangeModelTests` checks by
/// reflection rather than by a count.
struct ArrangeRow: Identifiable, Hashable, Sendable {
  /// Also the row's accessibility identifier: `arrange.<section>.<value>`.
  let id: String
  let title: String
  let choice: ArrangeChoice
}

/// One labelled run of rows.
struct ArrangeSection: Identifiable, Sendable {
  let id: String
  let title: String
  let rows: [ArrangeRow]
}

/// WP29 P2 (IMGMGR-453): the Arrange popover's rows, stated as data over the store.
///
/// There is no second state. `isChecked` reads the store's own getters (`activeSortKey`,
/// `activeDirection`, `activeGrouping`, `rowHeight`) and `apply` calls the store's own setters
/// (`setSortKey`, `setSortDirection`, `selectGrouping`, `setRowHeight`), the same calls the
/// removed Sort, Group and Zoom menus and the More menu's Density row made. So a choice made here
/// is the choice the menu-bar commands (⌘1…⌘6, ⌥⌘R, the View menu's sort and group rows) read
/// back, and nothing new is persisted: `GridPreferences.persistedKeys` is unchanged (plan
/// Decision 7, "round-trips to the shipped owners").
///
/// The rules the store owns stay the store's: a sort key or direction chosen in Scene leaves
/// Scene (`GridStore.applyFlatPresentation`), and Scene and a `group_by` dimension are one
/// single-select list (`GridStore.selectGrouping`).
@MainActor
struct ArrangeModel {
  let store: GridStore

  /// The five sections, in the order the popover renders them: 6 + 2 + 8 + 2 + 6 = 24 rows.
  /// IMGMGR-551 (R3-7): Layout sits before Thumbnail size, whose steps then read as the cell edge
  /// in Square.
  static let sections: [ArrangeSection] = [
    ArrangeSection(
      id: "arrange.section.sort", title: "Sort by",
      rows: SortGroupOptions.sortKeys.map {
        ArrangeRow(id: "arrange.sort.\($0.rawValue)", title: $0.title, choice: .sortKey($0))
      }),
    ArrangeSection(
      id: "arrange.section.direction", title: "Direction",
      rows: SortGroupOptions.directions.map {
        ArrangeRow(
          id: "arrange.direction.\($0.rawValue)", title: $0.title, choice: .direction($0))
      }),
    ArrangeSection(
      id: "arrange.section.group", title: "Group",
      rows: SortGroupOptions.groupingChoices.map {
        ArrangeRow(
          id: "arrange.group.\(groupIdentifierSuffix(for: $0))", title: groupTitle(for: $0),
          choice: .grouping($0))
      }),
    ArrangeSection(
      id: "arrange.section.layout", title: "Layout",
      rows: GridLayoutStyle.allCases.map {
        ArrangeRow(id: "arrange.layout.\($0.rawValue)", title: $0.title, choice: .layout($0))
      }),
    ArrangeSection(
      id: "arrange.section.size", title: "Thumbnail size",
      rows: GridRowHeight.allCases.map {
        ArrangeRow(
          id: "arrange.size.\(Int($0.rawValue))", title: "\(Int($0.rawValue)) pt",
          choice: .size($0))
      }),
  ]

  /// Every row, flattened in rendered order.
  static var rows: [ArrangeRow] { sections.flatMap(\.rows) }

  /// Whether `row` names the state in force, read from the store's own getter.
  func isChecked(_ row: ArrangeRow) -> Bool {
    switch row.choice {
    case .sortKey(let key): store.activeSortKey == key
    case .direction(let direction): store.activeDirection == direction
    case .grouping(let choice): store.activeGrouping == choice
    case .size(let step): store.rowHeight == step
    case .layout(let style): store.layoutStyle == style
    }
  }

  /// Applies `row` through the store's own setter.
  func apply(_ row: ArrangeRow) async {
    switch row.choice {
    case .sortKey(let key): await store.setSortKey(key)
    case .direction(let direction): await store.setSortDirection(direction)
    case .grouping(let choice): await store.selectGrouping(choice)
    case .size(let step): store.setRowHeight(step)
    case .layout(let style): store.setLayoutStyle(style)
    }
  }

  /// IMGMGR-256, carried over from the removed Group control: the Arrange control is the "you are
  /// in an arrangement" signal. It is highlighted whenever ANY grouping is in force, Scene or one
  /// of the six dimensions, and plain under None. A pure function, so the state is a value test.
  nonisolated static func isHighlighted(for choice: GroupingChoice) -> Bool {
    choice != .none
  }

  /// A grouping row's own words: "None", "Scene", or the dimension's title.
  nonisolated static func groupTitle(for choice: GroupingChoice) -> String {
    switch choice {
    case .none: "None"
    case .scene: "Scene"
    case .key(let key): key.title
    }
  }

  nonisolated private static func groupIdentifierSuffix(for choice: GroupingChoice) -> String {
    switch choice {
    case .none: "none"
    case .scene: "scene"
    case .key(let key): key.rawValue
    }
  }
}

/// WP29 P2 (IMGMGR-453): the Arrange control. It replaces the Sort, Group and Zoom controls on the
/// Regular grid bar and on Compact's options row, and the More menu's Density row.
///
/// A `Button` that presents a popover, the shape `GridFilterControl` already ships. There is no
/// `.presentationCompactAdaptation`: at Compact the system adapts the popover to a sheet, as it
/// does for Filter.
///
/// It takes over the Group control's IMGMGR-256 signal: highlighted while an arrangement is in
/// force, with the same fact in words as its accessibility value ("Active"/"Off").
struct GridArrangeControl: View {
  static let accessibilityIdentifier = "gridArrangeControl"

  let store: GridStore
  @State private var isPresented = false

  private var isHighlighted: Bool {
    ArrangeModel.isHighlighted(for: store.activeGrouping)
  }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Label("Arrange", systemImage: "arrow.up.arrow.down")
    }
    // A value-driven modifier on one view type, never an `if/else` over two (IMGMGR-256): the
    // control keeps its size and identity whether or not an arrangement is in force.
    .modifier(GroupControlHighlight(isHighlighted: isHighlighted))
    // The word stays visible beside the icon: an icon-only control is what the owner could not
    // find (gap audit /link/3282, owner feedback (c)).
    .labelStyle(.titleAndIcon)
    .accessibilityIdentifier(Self.accessibilityIdentifier)
    .accessibilityValue(isHighlighted ? "Active" : "Off")
    .popover(isPresented: $isPresented) {
      ArrangePopoverView(store: store)
    }
  }
}

/// The popover's body: the five sections of `ArrangeModel`, each row one tap.
///
/// A `ScrollView` over an EAGER `VStack`, never a `List`, for the reason `FilterPopoverView`
/// records: a `List` is lazy, and on the Compact sheet it built only the rows that fit the
/// viewport, so the rest had no accessibility element until scrolled into being. All 24 rows are
/// built on open; the scroll view only moves them.
///
/// No `NavigationLink`, `Menu` or `.menu` picker is inside: nothing here opens a further level. A
/// row does not close the popover, so a sort and a size can be chosen in one visit. "Done" closes
/// it; at Compact, where the popover is a sheet, it is the visible twin of the swipe down.
struct ArrangePopoverView: View {
  let store: GridStore
  @Environment(\.dismiss) private var dismiss

  private var model: ArrangeModel { ArrangeModel(store: store) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Spacer()
          Button("Done") { dismiss() }
            .accessibilityIdentifier("arrangeDone")
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)

        ForEach(ArrangeModel.sections) { section in
          sectionHeader(section.title)
          ForEach(section.rows) { row in
            rowView(row)
          }
        }
      }
      .padding(.vertical, 8)
    }
    .frame(idealWidth: 320, idealHeight: 560)
  }

  /// The section caption in the inspector's idiom, as `FilterPopoverView` draws it. No
  /// identifier: an identifier on a container overrides its descendants'.
  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func rowView(_ row: ArrangeRow) -> some View {
    let checked = model.isChecked(row)
    return Button {
      Task { await model.apply(row) }
    } label: {
      HStack(spacing: 8) {
        Text(row.title)
        Spacer(minLength: 8)
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .opacity(checked ? 1 : 0)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(row.id)
    // The checkmark in words, for VoiceOver and for a UI test that cannot read pixels.
    .accessibilityValue(checked ? "Checked" : "Unchecked")
    .accessibilityAddTraits(checked ? .isSelected : [])
  }
}
