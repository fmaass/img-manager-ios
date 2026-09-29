import ImgManagerAPI
import SwiftUI

/// WP28 P1 (IMGMGR-448): the Compact Shoots tab (plan Decision 3) — the pinned "Needs review"
/// section (IMGMGR-389, the same component and predicate the split's sidebar shows), then Recent:
/// the remaining queue summaries of the tier the title menu names, newest first
/// (`ShootsHome.recent(from:tier:)`).
///
/// Rows keep the home's row-navigation discipline — a selection-bound `List` whose rows carry
/// `.simultaneousGesture`, never a bare `Button` and never `onChange` — because both sections
/// render through `NeedsReviewSection`, and every tap goes through `onSelectShoot`, the ONE path
/// into `GridStore.selectShoot(folderID:sourceTier:)`.
struct ShootsHomeView: View {
  let queueStore: QueueStore
  @Binding var selectedFolderID: Int?
  let onSelectShoot: (Int, GridSourceTier?) -> Void
  /// The Recent section's tier, chosen from the navigation title's menu. Session-scoped, like
  /// the tree's own expansion.
  @State private var tier: FolderTreeTier = .incoming

  var body: some View {
    let summaries = queueStore.summaries
    let needsReview = NeedsReview.members(from: summaries)
    let recent = ShootsHome.recent(from: summaries, tier: tier)
    List(selection: $selectedFolderID) {
      if !needsReview.isEmpty {
        Section {
          NeedsReviewSection(
            members: needsReview, selectedFolderID: $selectedFolderID, onSelect: onSelectShoot)
        } header: {
          NeedsReviewHeader(count: needsReview.count)
        }
      }
      Section {
        NeedsReviewSection(
          members: recent, selectedFolderID: $selectedFolderID, onSelect: onSelectShoot,
          rowIdentifier: ShootsHome.recentRowIdentifier(for:))
      } header: {
        Text("\(ShootsHome.recentTitle) · \(tier.label)")
          .accessibilityIdentifier(ShootsHome.recentSectionIdentifier)
      }
    }
    .refreshable { await queueStore.refresh() }
    .navigationTitle(CompactTab.shoots.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarTitleMenu {
      Picker("Tier", selection: $tier) {
        ForEach(FolderTreeTier.allCases, id: \.self) { option in
          Text(option.label).tag(option)
        }
      }
      .accessibilityIdentifier(ShootsHome.tierMenuIdentifier)
      // Final audit F2: the visible twin of the pull-to-refresh above — the same call, so a
      // reader who never discovers the gesture can still re-read the queue.
      Button {
        Task { await queueStore.refresh() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .accessibilityIdentifier(ShootsHome.refreshMenuRowIdentifier)
    }
    .overlay(alignment: .topLeading) { debugProbeElement }
    .task { await queueStore.loadIfNeeded() }
  }

  /// DEBUG-ONLY, under the fixture launch argument, exactly like `GridView`'s probe: the served
  /// summaries-request count, so a UI test sees the Refresh row's re-fetch. No hit testing, so it
  /// cannot take a tap meant for a row; in Release it is an `EmptyView`.
  #if DEBUG
    @ViewBuilder private var debugProbeElement: some View {
      if DebugStubLaunch.isActive {
        Text("debugProbeSummaries")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.summaries")
          .accessibilityValue("summariesRequests=\(DebugProbe.shared.summariesRequests)")
      }
    }
  #else
    private var debugProbeElement: some View { EmptyView() }
  #endif
}
