import ImgManagerAPI
import SwiftUI

/// WP28 P1 (IMGMGR-448), IMGMGR-549 (R3-14): the Compact Shoots tab — Untouched (the newest eight,
/// then "N more ›") above Recent (the shoots last opened on this device, narrowed to the tier
/// the title menu's "Recent from" picker names). No Pinned section here (ruling c): Pinned is the
/// Regular sidebar's. Each section follows its Settings toggle and renders only with members.
///
/// Rows keep the home's row-navigation discipline — a selection-bound `List` whose rows carry
/// `.simultaneousGesture`, never a bare `Button` and never `onChange` — because both sections
/// render through `ShootRowsSection`, and every tap goes through `onSelectShoot`, the ONE path
/// into the grid (and the one that records the open into Recent).
struct ShootsHomeView: View {
  let queueStore: QueueStore
  @Binding var selectedFolderID: Int?
  let onSelectShoot: (Int, GridSourceTier?) -> Void
  let settings: SettingsPreferences
  let shortcuts: ShootShortcutsStore
  let heroLoader: HeroThumbnailLoader
  /// The Recent section's tier, chosen from the navigation title's menu. Session-scoped, like
  /// the tree's own expansion.
  @State private var tier: FolderTreeTier = .incoming
  /// The overflow sheet and the tile picked in it, opened once the sheet has gone.
  @State private var overflow = UntouchedOverflow()

  var body: some View {
    let summaries = queueStore.summaries
    let untouched = Untouched.members(from: summaries, since: settings.untouchedSince)
    let recent = ShootsHome.recent(entries: shortcuts.recent, summaries: summaries, tier: tier)
    let visible = SidebarSections.visible(
      toggles: SidebarToggles(settings),
      membership: .init(untouched: untouched.count, recent: recent.count), in: .compactShoots)
    List(selection: $selectedFolderID) {
      if visible.contains(.untouched) {
        Section {
          ShootRowsSection(
            kind: .untouched, members: Untouched.visible(untouched),
            selectedFolderID: $selectedFolderID, onSelect: onSelectShoot, shortcuts: shortcuts)
          if let more = Untouched.overflowLabel(count: Untouched.overflowCount(untouched)) {
            UntouchedMoreRow(label: more) { overflow.open() }
          }
        } header: {
          SidebarSectionHeader.untouched.label
        }
      }
      if visible.contains(.recent) {
        Section {
          ShootRowsSection(
            kind: .recent, members: recent, selectedFolderID: $selectedFolderID,
            onSelect: onSelectShoot, shortcuts: shortcuts)
        } header: {
          Text("\(ShootsHome.recentTitle) · \(tier.label)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(ShootsHome.recentSectionIdentifier)
        }
      }
    }
    .sheet(
      isPresented: $overflow.isPresented,
      onDismiss: {
        overflow.handOff { folderID, tier in
          selectedFolderID = folderID
          onSelectShoot(folderID, tier)
        }
      }
    ) {
      UntouchedAllView(
        members: Untouched.members(from: queueStore.summaries, since: settings.untouchedSince),
        heroLoader: heroLoader,
        onPick: { overflow.pick($0) },
        onClose: { overflow.close() })
    }
    .refreshable { await queueStore.refresh() }
    .navigationTitle(CompactTab.shoots.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarTitleMenu {
      Picker(ShootsHome.recentPickerTitle, selection: $tier) {
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
