import ImgManagerAPI
import SwiftUI

/// WHICH shoots the pinned "Needs review" section lists — IMGMGR-389, the last piece of the
/// IMGMGR-342 Option B sidebar (the tree-first home itself shipped in IMGMGR-350).
///
/// One pure predicate over `ReadinessSection`, and deliberately nothing more. The vocabulary is
/// the app's ONE readiness string table (`QueueModels.swift`, shared with the folder-tree row
/// badge and with the widget's counts) — there is no second classification here, and nothing in
/// this file re-derives readiness from counts, sync state or dates, which the browse contract
/// names as a spec violation.
///
/// WHY these two values, stated because the ticket's words ("shoots with unresolved review
/// state") are not a server value (premise gate 2026-09-16, IMGMGR-389 comment 6913):
/// ADR-0004 Amendment 1's review-done predicate is server-derived and has not shipped
/// (IMGMGR-391), so membership is a PRESENTATION filter over the six values that have. The four
/// excluded values are excluded for a reason each:
///
/// - `needs_previews` — not reviewable yet; there is nothing to look at.
/// - `historical_unreviewed` — the pre-app history, which would flood a pinned section.
/// - `sync_problem` — a problem to fix, not a review to finish.
/// - `ready_for_editing` — reviewed; done.
///
/// It is one function with a test per value precisely so widening it later — when IMGMGR-391
/// lands a server-side answer — is a one-line change with six red/green oracles beside it.
enum NeedsReview {

  /// The section's own name, in one place: the header renders it and nothing else spells it.
  static let title = "Needs review"

  /// The membership rule. A `ReadinessSection` the client does not know never reaches here —
  /// `members(from:)` drops an unknown wire value rather than guessing, the same
  /// unknown-vocabulary posture `QueueSort.sections(from:)` and `ReadinessEntryBuilder.counts`
  /// already take.
  static func includes(_ section: ReadinessSection) -> Bool {
    switch section {
    case .readyToReview, .reviewInProgress: return true
    case .needsPreviews, .historicalUnreviewed, .syncProblem, .readyForEditing: return false
    }
  }

  /// The section's rows, in the order the summaries arrived.
  ///
  /// That order is the SERVER's, exactly as the tree's is (IMGMGR-264, owner directive:
  /// `/api/folder-summaries` orders folders by name descending — the names are dates, so newest
  /// first — with a `folder_id` tiebreak, one implementation both clients consume). Nothing here
  /// sorts; a client-side re-sort would answer a different question and silently override the
  /// order the server chose.
  ///
  /// An empty result IS the empty state: the view renders nothing at all for it, so "no members"
  /// and "no section" are the same fact rather than two that can drift.
  static func members(
    from summaries: [Components.Schemas.FolderSummary]
  ) -> [Components.Schemas.FolderSummary] {
    summaries.filter { summary in
      guard let section = ReadinessSection(rawValue: summary.readiness.rawValue) else {
        return false
      }
      return includes(section)
    }
  }

  /// What a pinned row calls its shoot.
  ///
  /// `FolderSummary` carries `path` and no name — unlike `FolderNode`, which the tree's own rows
  /// read `name` off — so the shoot leaf's own path segment is the closest available answer.
  /// This is the same derivation `QueueCardRow` has always used for the same field, moved here
  /// rather than written twice; see this phase's Open questions, where the gap is flagged rather
  /// than silently settled.
  static func shootName(for summary: Components.Schemas.FolderSummary) -> String {
    summary.path.split(separator: "/").last.map(String.init) ?? summary.path
  }

  /// The section container's test handle. On the header's TITLE text rather than on the section
  /// itself: an accessibility identifier set on a container OVERRIDES its descendants'
  /// (`GridView.swift:743-747`), which would make the count beside it unaddressable — the same
  /// reason `folderTreeTier-*` sits on the tier row's own `Text` and `folderRow-*` on a folder
  /// row's name.
  static let sectionIdentifier = "needsReviewSection"

  /// The member count's handle, on the count itself.
  static let countIdentifier = "needsReviewCount"

  /// One row's handle, keyed by the server's folder id like every identifier the tree derives.
  static func rowIdentifier(for folderID: Int) -> String { "needsReviewRow-\(folderID)" }
}

/// The pinned section's ROWS — the content half, on the same terms as `FolderTreeSection`: the
/// enclosing `Section` and its header are composed by `QueueView`, which is the one view that
/// owns the home's list, so the pinned section and the tree sit in one container and one scroll.
///
/// It fetches nothing. The members are derived from the summaries `QueueStore` already holds for
/// the tree's row badges — so the section follows the same reload paths the badges follow (the
/// home's pull-to-refresh, the foreground refresh, the offline snapshot replay) and adds no
/// second request. When the summaries are unreachable with no cached answer there are no members
/// and `QueueView` renders no section at all; the tree's own degraded banner is the only message
/// on that screen, which is the posture `QueueHomePresentation` already fixed once.
struct NeedsReviewSection: View {
  /// Already filtered by `NeedsReview.members(from:)`, in the order the server sent them: the
  /// caller needs the COUNT for the header and the rows here, and deriving it twice would be two
  /// answers to one question.
  let members: [Components.Schemas.FolderSummary]
  @Binding var selectedFolderID: Int?
  /// The SAME closure `RootView` hands the folder tree, hoisted there into one value: a pinned
  /// row and a tree row enter the grid through one `GridStore.selectShoot(folderID:sourceTier:)`
  /// call, and no second navigation path exists.
  let onSelect: (Int, GridSourceTier?) -> Void
  /// WP28 P1 (IMGMGR-448): the row's identifier. The Shoots tab's Recent section renders its rows
  /// through this same view — same row discipline, same routing — under its own identifiers, so a
  /// UI test can tell the two sections apart.
  var rowIdentifier: (Int) -> String = NeedsReview.rowIdentifier(for:)

  var body: some View {
    ForEach(members, id: \.folderId) { summary in
      row(summary)
    }
  }

  /// One pinned row: the shoot's name and the SAME readiness badge the tree's folder row shows,
  /// from the one function that words it (`FolderTreeRowPresentation.readinessBadge`) — a second
  /// wording would be a second vocabulary to the reader.
  ///
  /// The tap is the tree's own mechanism, not a `Button`: `.tag` plus a `.simultaneousGesture`
  /// layered on the enclosing `List`'s selection recognizer. A bare `Button` never pushes
  /// `NavigationSplitView`'s column on Compact (`FolderTreeSection`'s own doc comment records the
  /// device evidence), and this row must reach the grid on the phone exactly as a tree row does.
  private func row(_ summary: Components.Schemas.FolderSummary) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(NeedsReview.shootName(for: summary))
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier(rowIdentifier(summary.folderId))
        if let readiness = FolderTreeRowPresentation.readinessBadge(for: summary) {
          Text(readiness)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
    }
    // The same minimum target the tree's rows carry, so the row's empty trailing half is as
    // tappable as its name.
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .tag(summary.folderId)
    .simultaneousGesture(
      TapGesture().onEnded {
        // Exactly what a tree folder row does on a tap (`FolderTreeRowView.perform`): the
        // selection and the grid's scope, set in that order. The tier is the server's own
        // `source_tier` for this shoot; an unknown value resolves to `nil`, which clears the
        // grid's tier filter rather than inventing a tier the server never named.
        selectedFolderID = summary.folderId
        onSelect(summary.folderId, GridSourceTier(rawValue: summary.sourceTier))
      })
  }
}

/// The pinned section's header: its name and how many shoots are in it.
///
/// The two identifiers sit on the two `Text`s and never on the `HStack` around them — an
/// accessibility identifier on a container overrides its descendants' (`GridView.swift:743-747`),
/// which is exactly how a count beside a title becomes unaddressable from a UI test.
struct NeedsReviewHeader: View {
  let count: Int

  var body: some View {
    HStack(spacing: 6) {
      Text(NeedsReview.title)
        .accessibilityIdentifier(NeedsReview.sectionIdentifier)
      Text(count.formatted())
        .monospacedDigit()
        .accessibilityIdentifier(NeedsReview.countIdentifier)
      Spacer(minLength: 0)
    }
  }
}
