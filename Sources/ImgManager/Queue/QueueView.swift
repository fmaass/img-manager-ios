import ImgManagerAPI
import SwiftUI

/// The home. IMGMGR-350: the tier-grouped FOLDER TREE — Incoming / Edits / Archive, each folding
/// into the server's own taxonomy — is what this surface renders, on both idioms. Compact: this
/// IS the launch surface, a full-screen list. Regular: this IS the sidebar column.
///
/// What it stopped being (owner decision, 2026-09-02: "i think i would prefer the same folder
/// view on the ios app as on web - incoming, edits and archive"): six server-derived readiness
/// sections with the tree as a collapsed "Folders" disclosure below them. Since IMGMGR-549 the
/// client stops surfacing readiness on the home altogether (it stays decoded and stays the
/// widget's): the tree's rows carry the hollow "untouched" ring instead, and the sidebar's
/// sections are Untouched · Pinned · Recent above the tree (design R3-1/R3-2).
///
/// `QueueStore` stays mounted and stays the phase machine: the first-load spinner, the
/// refresh-in-progress indicator, the degraded banner with its cached-answer timestamp and the
/// "Try Again" recovery are all IMGMGR-198's, unchanged, and the summaries they carry are what
/// the rows' rings and the sidebar's sections read. The tree's own load is
/// `FolderTreeSection`'s (`FolderTreeLoad`).
struct QueueView: View {
  @Bindable var queueStore: QueueStore
  @Binding var selectedFolderID: Int?
  /// What a pull-to-refresh runs: `QueueHomeRefresh.run(summaries:tree:)`, composed ONCE in
  /// `RootView.refreshQueueHome()`. IMGMGR-499: the tree's View menu carries the gesture's visible
  /// twin, and both run this same closure, so the gesture and the menu row cannot diverge. The
  /// tree's load is view state inside `FolderTreeSection`, so the refresh reaches it by advancing
  /// the token that section's `.task(id:)` keys on rather than by calling into it.
  let onRefresh: @MainActor () async -> Void
  /// How a SECTION row (Untouched, Pinned, Recent, an overflow tile) enters the grid — the very
  /// closure `RootView` hands the tree, so every row of this home shares one routing path, and
  /// that path is the one that records the open into Recent (`ShootOpenRecorder`). The tier is
  /// optional because a summary carries `source_tier` as a wire string and an unrecognised one
  /// must clear the grid's tier filter rather than resolve to an invented tier.
  let onSelectShoot: (Int, GridSourceTier?) -> Void
  /// IMGMGR-549: whether the sidebar's sections and their headers render — Untouched · Pinned ·
  /// Recent above the tree, and "Library" over it (design R3-2). The split's sidebar passes true;
  /// the Compact Library tab passes false, because there the tree is the whole tab and the
  /// Shoots tab is Untouched's and Recent's home.
  var showsSidebarSections = false
  /// The three section toggles and the Untouched horizon (IMGMGR-548's Settings).
  let settings: SettingsPreferences
  /// The Pinned and Recent entries, and the rows' Pin/Unpin menus.
  let shortcuts: ShootShortcutsStore
  /// The overflow grid's covers come through the app's one loader.
  let heroLoader: HeroThumbnailLoader
  /// On BOTH idioms since P6 (IMGMGR-216), and non-optional on purpose: the `nil`-on-Compact
  /// branch that left the phone without a browse surface cannot return without a type change.
  /// Since IMGMGR-350 it is not a section of this view but its whole content.
  let treeSection: FolderTreeSection

  /// The overflow sheet and the tile picked in it, opened once the sheet has gone.
  @State private var overflow = UntouchedOverflow()

  var body: some View {
    Group {
      if QueueHomePresentation.rendersTree(for: queueStore.phase) {
        listContent
      }
    }
    .navigationTitle("img-manager")
    .task { await queueStore.loadIfNeeded() }
  }

  private var listContent: some View {
    List(selection: $selectedFolderID) {
      if QueueHomePresentation.showsDegradedBanner(for: queueStore.phase) {
        Section {
          unreachableBanner
        }
      }
      // IMGMGR-549 (design R3-2): Untouched · Pinned · Recent above the tree, inside the SAME
      // list — one container, one scroll, one selection binding. Each renders only when its
      // Settings toggle is on and it has members (`SidebarSections.visible`); no members means no
      // Section at all, which is also what an unreachable summaries endpoint produces, so the
      // tree's own degraded banner stays the only message on that screen.
      //
      // Derived ONCE per body and handed to both halves of each section.
      let summaries = queueStore.summaries
      let untouched = Untouched.members(from: summaries, since: settings.untouchedSince)
      let pinned = ShootRowPresentation.summaries(for: shortcuts.pinned, in: summaries)
      let recent = ShootRowPresentation.summaries(for: shortcuts.recent, in: summaries)
      let visible =
        showsSidebarSections
        ? SidebarSections.visible(
          toggles: SidebarToggles(settings),
          membership: .init(
            untouched: untouched.count, pinned: pinned.count, recent: recent.count))
        : []
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
      if visible.contains(.pinned) {
        Section {
          ShootRowsSection(
            kind: .pinned, members: pinned, selectedFolderID: $selectedFolderID,
            onSelect: onSelectShoot, shortcuts: shortcuts)
        } header: {
          SidebarSectionHeader.pinned.label
        }
      }
      if visible.contains(.recent) {
        Section {
          ShootRowsSection(
            kind: .recent, members: recent, selectedFolderID: $selectedFolderID,
            onSelect: onSelectShoot, shortcuts: shortcuts)
        } header: {
          SidebarSectionHeader.recent.label
        }
      }
      // The tree IS the home (IMGMGR-350). At Regular the section is named "Library"; at Compact
      // the Library tab already names it.
      if showsSidebarSections {
        Section {
          treeSection
        } header: {
          SidebarSectionHeader.library.label
        }
      } else {
        Section { treeSection }
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
        heroLoader: heroLoader, listFetchedAt: queueStore.lastFetchedAt,
        onPick: { overflow.pick($0) },
        onClose: { overflow.close() })
    }
    .refreshable { await onRefresh() }
    .overlay(alignment: .top) {
      // Q3 "refresh over data": a small activity indicator, rows/expansion/scroll/selection all
      // retained underneath — never the centered first-load spinner.
      if queueStore.isRefreshing {
        ProgressView()
          .padding(6)
          // WP28 P4 (IMGMGR-451): at Regular this list IS the glass sidebar, so the capsule is
          // never a material there (glass on glass) — MaterialPolicy's `insideSystemGlass`.
          .chromeFill(.insideSystemGlass, in: Capsule())
          .padding(.top, 4)
      }
    }
    .overlay(alignment: .topLeading) { debugProbeElement }
  }

  /// DEBUG-ONLY, under the fixture launch argument, exactly like `ShootsHomeView`'s probe
  /// (IMGMGR-499): the served summaries-request AND folder-tree-request counts, so a UI test sees
  /// BOTH halves of a home refresh re-run. Its own identifier, because at Compact the Shoots
  /// root's `debugProbe.summaries` can sit in the same hierarchy. No hit testing, so it cannot
  /// take a tap meant for a row; in Release it is an `EmptyView`.
  #if DEBUG
    @ViewBuilder private var debugProbeElement: some View {
      if DebugStubLaunch.isActive {
        Text("debugProbeHomeRefresh")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier(QueueHomeRefresh.probeIdentifier)
          .accessibilityValue(debugProbeValue)
      }
    }

    private var debugProbeValue: String {
      let probe = DebugProbe.shared
      return "summariesRequests=\(probe.summariesRequests) "
        + "folderTreeRequests=\(probe.folderTreeRequests) "
        + "homeRefreshSummaries=\(probe.homeRefreshSummaries) "
        + "homeRefreshTreeToken=\(probe.homeRefreshTreeToken) "
        + "treeLoadCompletedToken=\(probe.treeLoadCompletedToken)"
    }
  #else
    private var debugProbeElement: some View { EmptyView() }
  #endif

  /// Two lines, never one: the adjudicated degraded copy, and — whenever the list underneath is
  /// a replayed answer rather than a live one — how old that answer is (IMGMGR-198). Rows stay
  /// tappable in this phase exactly as before; the grid has its own unreachable state.
  private var unreachableBanner: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(DegradedStateCopy.notConnected)
          .font(.footnote)
        if let lastFetchedAt = queueStore.lastFetchedAt {
          Text(DegradedStateCopy.showingCached(since: lastFetchedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Try Again") { Task { await queueStore.refresh() } }
        .font(.footnote)
    }
  }
}

/// The home's section names — IMGMGR-549 (R3-2): Untouched · Pinned · Recent · Library, the
/// four headings the sidebar has (the standing "Shoots" header of WP28 P2 is gone, ruling a). The
/// identifier sits on the `Text` itself, never on a container around it — a container's
/// identifier overrides its descendants' (`GridView.swift:743-747`).
enum SidebarSectionHeader: CaseIterable, Sendable {
  case untouched
  case pinned
  case recent
  case library

  var title: String {
    switch self {
    case .untouched: Untouched.title
    case .pinned: "Pinned"
    case .recent: ShootsHome.recentTitle
    case .library: "Library"
    }
  }

  var identifier: String {
    switch self {
    case .untouched: Untouched.sectionIdentifier
    case .pinned: "pinnedSection"
    case .recent: ShootsHome.recentSectionIdentifier
    case .library: "sidebarSectionLibrary"
    }
  }

  @MainActor var label: some View {
    Text(title)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier(identifier)
  }
}

/// What the tree home renders for one SUMMARIES phase — and, since checkpoint-2 finding B1, what
/// it does NOT let that phase decide.
///
/// The summaries stopped being the home's primary data in IMGMGR-350: the folder tree is, and it
/// has its own load, its own failure state and its own retry (`FolderTreeLoad`). Letting
/// `QueueStore.phase` choose the whole surface meant a `/api/folder-summaries` outage blanked a
/// tree whose own fetch had succeeded — a healthy library, unreachable because a DIFFERENT
/// endpoint was down. The rule here is the fix, and it is a value so a test reads it rather than
/// a rendered view.
enum QueueHomePresentation {
  /// Whether the tree renders. It always does — including while the summaries are loading, and
  /// including when they failed outright, which degrades what summaries feed (the P3 badge, the
  /// widget) and nothing else.
  ///
  /// Checkpoint-3 finding F1 is why this takes the phase and ignores it rather than not existing:
  /// `QueueStore.performLoad` returns to `.initialLoading` whenever it has nothing of its own on
  /// screen, which a "Try Again" tap after a summaries-only outage does — and a phase-gated home
  /// replaced a loaded tree with the summaries' centered spinner. The coupling is gone, and this
  /// is where a future one would be written and where the test would catch it. The home's only
  /// placeholder is the TREE's own, decided by `FolderTreeLoad.phase` inside `FolderTreeSection`.
  static func rendersTree(for phase: QueueStore.Phase) -> Bool {
    _ = phase
    return true
  }

  /// Whether the degraded notice sits above the tree: whenever the summaries are unreachable,
  /// cached answer or not. `unreachableBanner` states the cached-since line only when there IS a
  /// cached fetch time, so one banner covers both.
  static func showsDegradedBanner(for phase: QueueStore.Phase) -> Bool {
    phase == .unreachableStale || phase == .unreachableNoCache
  }
}

/// What ONE pull-to-refresh on the home runs: the summaries AND the tree.
///
/// A value rather than two statements inside `.refreshable`, because the second half is the part
/// that used to be missing and nothing could say so. Before IMGMGR-350 the gesture refreshed the
/// summaries only; the tree had no refresh path at all beyond its own "Retry" button
/// (`FolderTreeSection`), which was survivable while it was a collapsed secondary disclosure and
/// is the HOME's staleness now.
///
/// What it can and cannot pin, stated plainly: the tree's load is SwiftUI view state, so this
/// hands the gesture on as a token bump (`FolderTreeSection.reloadToken`) and returns without
/// awaiting the fetch — the tree renders its own progress. The wiring itself (that `QueueView`
/// calls this at all) is not reachable from a unit test; `TierHomeUITests` walks the surface.
///
/// IMGMGR-499: the gesture's visible twin is the tree View menu's "Refresh" row
/// (`RootView.folderTreeViewMenuItem`, on the Compact Library tab and the Regular sidebar). It
/// and the gesture both run `RootView.refreshQueueHome()`, the one place this is called with
/// its two closures; `QueueHomeRefreshUITests` taps the row and reads both halves re-run.
@MainActor
enum QueueHomeRefresh {
  /// The View menu's Refresh row (IMGMGR-499).
  static let menuRowIdentifier = "queueHomeRefreshMenuRow"
  /// The DEBUG fixture probe `QueueView` publishes both request counts on (IMGMGR-499).
  static let probeIdentifier = "debugProbe.homeRefresh"

  static func run(summaries: () async -> Void, tree: () -> Void) async {
    await summaries()
    tree()
  }
}

/// One queue card: hero thumbnail, shoot name, last-touched date (omitted when null), counts,
/// fidelity badge, sync signal, and the derived review signal — every field read straight off
/// `Components.Schemas.FolderSummary`, never a client-side recomputation.
///
/// IMGMGR-350 removed the surface that rendered it: the home is the folder tree, and readiness
/// becomes a per-row badge on the tree's own shoot rows (P3). The type is left standing for this
/// package rather than deleted with the sections, because deleting it also orphans
/// `QueueCardDestination` — which `RootView`'s restore path, `ShootSceneValue` and
/// `GridSourceTier`'s own file-boundary note all cite — and that disposal is its own decision,
/// not a side effect of moving the home. Nothing instantiates it today.
struct QueueCardRow: View {
  let summary: Components.Schemas.FolderSummary
  let heroLoader: HeroThumbnailLoader

  @State private var heroImage: PlatformImage?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      hero
      VStack(alignment: .leading, spacing: 4) {
        Text(displayName)
          .font(.headline)
          .lineLimit(1)
        if let lastTouched = summary.lastTouched {
          Text(lastTouched, style: .date)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("\(summary.total) photos · \(summary.picked) picked")
          .font(.subheadline)
          .lineLimit(1)
        // Stacked, not packed into one HStack (fixed after the Regular-2 screenshot exposed
        // it): a narrow sidebar column left three side-by-side Labels so little width each
        // that "Lightroom preview" wrapped character-by-character. Each badge gets its own
        // line and `.lineLimit(1)` (truncating with an ellipsis is always legible; wrapping a
        // single word one glyph per line never is).
        VStack(alignment: .leading, spacing: 2) {
          if let fidelity {
            Label(fidelity, systemImage: "camera.aperture")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          if let sync = SyncSignal.compute(from: summary.sync) {
            syncBadge(sync)
          }
          if summary.nothingLeftUnmarked {
            Label("No unmarked photos", systemImage: "checkmark.circle")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 44)
    .task(id: heroTaskID) {
      switch await heroLoader.hero(
        folderID: summary.folderId, sourceTier: GridSourceTier(rawValue: summary.sourceTier))
      {
      case .image(let data):
        if let decoded = PlatformImage(data: data), !Task.isCancelled {
          heroImage = decoded
        }
      case .empty, .failure:
        break
      }
    }
  }

  private var heroTaskID: String { "\(summary.folderId)|\(summary.sourceTier)" }

  /// `FolderSummary` carries `path`, never a separate display name (unlike `FolderNode`, which
  /// has both) — the shoot leaf's own path segment is the closest available "shoot name". See
  /// this phase's Open questions: flagged as a premise gap, not silently settled.
  ///
  /// The derivation itself lives in `ShootName.of(_:)`, which the sidebar's section rows need for
  /// the same reason and on the same data. Same expression, one owner — two surfaces naming one
  /// shoot differently is exactly what a duplicated one-liner drifts into.
  private var displayName: String {
    ShootName.of(summary)
  }

  /// Q's fidelity badge, derived from `camera_preview_only`/`with_masters` (Ready does NOT wait
  /// for Lightroom coverage — this badge is informational, never gating). Live data shows these
  /// two counts complementary within a folder's `total`; `with_masters > 0` is read as "at least
  /// partial Lightroom-fidelity coverage exists", shown in preference to the camera-only label.
  private var fidelity: String? {
    if summary.withMasters > 0 { return "Lightroom preview" }
    if summary.cameraPreviewOnly > 0 { return "Camera preview" }
    return nil
  }

  @ViewBuilder
  private var hero: some View {
    Group {
      if let heroImage {
        PlatformImageView(image: heroImage).aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(width: 64, height: 64)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func syncBadge(_ signal: SyncSignal) -> some View {
    let presentation = SyncBadgePresentation.for(signal.kind)
    Label("\(signal.count) \(presentation.word)", systemImage: presentation.systemImage)
      .font(.caption2)
      .foregroundStyle(presentation.tint)
      .lineLimit(1)
  }
}

/// Q2's "warning/neutral/success iconography" — three visual buckets over the four precedence
/// kinds (refused and stale both read as warning-severity; never is neutral; synced is success).
private struct SyncBadgePresentation {
  let word: String
  let systemImage: String
  let tint: Color

  static func `for`(_ kind: SyncSignal.Kind) -> SyncBadgePresentation {
    switch kind {
    case .refused:
      return SyncBadgePresentation(
        word: "refused", systemImage: "exclamationmark.triangle.fill", tint: .orange)
    case .stale:
      return SyncBadgePresentation(
        word: "stale", systemImage: "clock.badge.exclamationmark", tint: .orange)
    case .never:
      return SyncBadgePresentation(word: "never", systemImage: "circle.dashed", tint: .secondary)
    case .synced:
      return SyncBadgePresentation(
        word: "synced", systemImage: "checkmark.circle.fill", tint: .green)
    }
  }
}
