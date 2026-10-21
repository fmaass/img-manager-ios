import ImgManagerAPI
import SwiftUI

/// IMGMGR-549: which of the home's summary-backed sections a row belongs to — Untouched, Pinned
/// or Recent. Each names its rows and its rings under its own prefix, so a UI test tells the
/// three apart even when one shoot sits in all of them.
enum ShootRowsKind: String, CaseIterable, Sendable {
  case untouched
  case pinned
  case recent

  func rowIdentifier(for folderID: Int) -> String { "\(rawValue)Row-\(folderID)" }

  /// The ring's handle, scoped to the section it is drawn in (`untouchedRing-recent-5`).
  func ringIdentifier(for folderID: Int) -> String { "untouchedRing-\(rawValue)-\(folderID)" }
}

/// What the home's section rows need that is not a view: the ring rule, the menu's identifiers,
/// and the join from remembered entries to the summaries `QueueStore` holds.
enum ShootRowPresentation {

  static let pinMenuIdentifier = "rowMenuPin"
  static let unpinMenuIdentifier = "rowMenuUnpin"

  /// The ring's accessibility label, on the ring itself.
  static let ringLabel = "Untouched"

  /// "A hollow ring marks untouched rows everywhere" (R3-1): the server's flag, nothing derived.
  static func showsUntouchedRing(_ summary: Components.Schemas.FolderSummary) -> Bool {
    summary.untouched
  }

  /// The entry a summary's row pins or records.
  static func entry(for summary: Components.Schemas.FolderSummary) -> ShootShortcutsStore.Entry {
    .init(folderID: summary.folderId, sourceTier: summary.sourceTier)
  }

  /// The remembered entries as summaries, in the entries' order. The join matches the folder id
  /// AND the tier; an entry with no summary (not served right now, or the summaries are
  /// unreachable) is kept in the store but not drawn.
  static func summaries(
    for entries: [ShootShortcutsStore.Entry], in summaries: [Components.Schemas.FolderSummary]
  ) -> [Components.Schemas.FolderSummary] {
    entries.compactMap { entry in
      summaries.first { $0.folderId == entry.folderID && $0.sourceTier == entry.sourceTier }
    }
  }
}

/// The hollow ring (R3-1). Its identifier and label sit on the image itself — a leaf element —
/// and the row around it never combines its children, so the ring stays addressable inside the
/// row's cell (`FolderTreeRowPresentation`'s leaf-identifier rule).
struct UntouchedRing: View {
  let identifier: String

  var body: some View {
    Image(systemName: "circle")
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityLabel(ShootRowPresentation.ringLabel)
      .accessibilityIdentifier(identifier)
  }
}

extension View {
  /// The row's Pin/Unpin context menu. Its actions call only `togglePin` — never the open
  /// recorder and never the selection. That is all the menu itself guarantees: the enclosing
  /// `List(selection:)` and the row's simultaneous tap gesture still see the press, and that a
  /// long press neither navigates nor enters Recent is what `SidebarPinUITests` checks.
  func shootPinMenu(
    _ entry: ShootShortcutsStore.Entry, isPinned: Bool, shortcuts: ShootShortcutsStore
  ) -> some View {
    contextMenu {
      Button {
        shortcuts.togglePin(entry)
      } label: {
        Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
      }
      .accessibilityIdentifier(
        isPinned ? ShootRowPresentation.unpinMenuIdentifier : ShootRowPresentation.pinMenuIdentifier
      )
    }
  }
}

/// The ROWS of one summary-backed section (Untouched, Pinned or Recent) — the content half, like
/// `FolderTreeSection`: the enclosing `Section` and its header are composed by the view that owns
/// the list, so these rows and the tree share one container, one scroll and one selection.
///
/// It fetches nothing: the members come from the summaries `QueueStore` already holds.
struct ShootRowsSection: View {
  let kind: ShootRowsKind
  let members: [Components.Schemas.FolderSummary]
  @Binding var selectedFolderID: Int?
  /// The SAME closure `RootView` hands the folder tree: a section row and a tree row enter the
  /// grid through one path (`RootView.selectShoot`, which records the open).
  let onSelect: (Int, GridSourceTier?) -> Void
  let shortcuts: ShootShortcutsStore

  var body: some View {
    ForEach(members, id: \.folderId) { summary in
      row(summary)
    }
  }

  /// One row: the shoot's name, then the ring when the server calls it untouched.
  ///
  /// The tap is the tree's own mechanism, not a `Button`: `.tag` plus a `.simultaneousGesture`
  /// layered on the enclosing `List`'s selection recognizer. A bare `Button` never pushes
  /// `NavigationSplitView`'s column on Compact (`FolderTreeSection`'s own doc comment), and this
  /// row must reach the grid on the phone exactly as a tree row does. The context menu is a long
  /// press, which a `TapGesture` never receives.
  private func row(_ summary: Components.Schemas.FolderSummary) -> some View {
    let entry = ShootRowPresentation.entry(for: summary)
    let isPinned = shortcuts.isPinned(entry)
    return HStack(spacing: 8) {
      Text(ShootName.of(summary))
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier(kind.rowIdentifier(for: summary.folderId))
      Spacer(minLength: 8)
      if ShootRowPresentation.showsUntouchedRing(summary) {
        UntouchedRing(identifier: kind.ringIdentifier(for: summary.folderId))
      }
    }
    // The same minimum target the tree's rows carry, so the row's empty trailing half is as
    // tappable as its name.
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .tag(summary.folderId)
    .simultaneousGesture(
      TapGesture().onEnded {
        // Exactly what a tree folder row does on a tap: the selection and the grid's scope, in
        // that order. An unknown wire tier resolves to `nil`, which clears the grid's tier
        // filter rather than inventing a tier the server never named.
        selectedFolderID = summary.folderId
        onSelect(summary.folderId, GridSourceTier(rawValue: summary.sourceTier))
      }
    )
    .shootPinMenu(entry, isPinned: isPinned, shortcuts: shortcuts)
  }
}

/// The "N more ›" row under the Untouched section: a real `Button` (it carries no `.tag`, so the
/// enclosing `List(selection:)` would swallow a gesture-only tap, `FolderTreeRowView`'s note).
struct UntouchedMoreRow: View {
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Text(label)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(Untouched.moreIdentifier)
  }
}
