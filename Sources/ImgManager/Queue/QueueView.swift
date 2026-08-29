import ImgManagerAPI
import SwiftUI

/// P7 (WP8, IMGMGR-116): the work-queue home. Six server-derived readiness sections, rendered
/// straight from `FolderSummary.readiness`/`nothingLeftUnmarked` — NEVER classified client-side
/// (Q4 drift hazards: this view recomputes nothing). Compact: this IS the launch surface, a
/// full-screen list. Regular: this IS the sidebar column, with the folder/tier tree collapsed
/// below it (D13) via `treeSection`.
///
/// 396-item strategy (Q4): `List` gives lazy off-screen row instantiation for free — a collapsed
/// section's rows, and any section's off-screen rows, are simply never built. There is no
/// client-defined "active" subset anywhere here; every summary the server returned is reachable
/// by expanding its section.
struct QueueView: View {
  @Bindable var queueStore: QueueStore
  let heroLoader: HeroThumbnailLoader
  @Binding var selectedFolderID: Int?
  let onSelect: (Int, GridSourceTier?) -> Void
  /// nil on Compact (Q's iPad-only "Folders" disclosure never appears there).
  let treeSection: FolderTreeSection?

  @State private var expandedSections: Set<ReadinessSection> = Set(
    ReadinessSection.allCases.filter(\.isDefaultExpanded))

  var body: some View {
    Group {
      switch queueStore.phase {
      case .initialLoading:
        // Q3: "first load, no cache -> centered 'Loading shoots…' (never a flash of empty
        // queue)" — this branch is the ONLY place that copy renders.
        ProgressView("Loading shoots…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .unreachableNoCache:
        unreachableFullSurface
      case .reachable, .unreachableStale:
        listContent
      }
    }
    .navigationTitle("img-manager")
    .task { await queueStore.loadIfNeeded() }
  }

  private var listContent: some View {
    let sections = QueueSort.sections(from: queueStore.summaries)
    return List(selection: $selectedFolderID) {
      if case .unreachableStale = queueStore.phase {
        Section {
          unreachableBanner
        }
      }
      if sections.isEmpty {
        Section {
          ContentUnavailableView("No shoots", systemImage: "photo.stack")
        }
      } else {
        ForEach(sections, id: \.section) { group in
          Section {
            if expandedSections.contains(group.section) {
              ForEach(group.items, id: \.folderId) { summary in
                QueueCardRow(summary: summary, heroLoader: heroLoader)
                  .tag(summary.folderId)
                  .contentShape(Rectangle())
                  .simultaneousGesture(
                    TapGesture().onEnded {
                      // Diff-gate round-3 closure, B1: route through the ONE production
                      // function that decides a queue card's destination — never re-derive the
                      // tier here (that regressed to `summary.sourceTier`, defeating the
                      // atomic-clear contract; see `QueueCardDestination`'s own doc comment).
                      let destination = QueueCardDestination.route(for: summary)
                      selectedFolderID = destination.folderID
                      onSelect(destination.folderID, destination.sourceTier)
                    }
                  )
              }
            }
          } header: {
            sectionHeader(group)
          }
        }
      }
      if let treeSection {
        // Q5: "One collapsed 'Folders' disclosure" — `FolderTreeSection` IS that one
        // disclosure (its own DisclosureGroup titled "Folders"), so this Section carries no
        // header of its own (avoiding a redundant second "Folders" label).
        Section { treeSection }
      }
    }
    .refreshable { await queueStore.refresh() }
    .overlay(alignment: .top) {
      // Q3 "refresh over data": a small activity indicator, cards/expansion/scroll/selection
      // all retained underneath — never the centered first-load spinner.
      if queueStore.isRefreshing {
        ProgressView()
          .padding(6)
          .background(.thinMaterial, in: Capsule())
          .padding(.top, 4)
      }
    }
  }

  private func sectionHeader(_ group: QueueSort.Section) -> some View {
    Button {
      if expandedSections.contains(group.section) {
        expandedSections.remove(group.section)
      } else {
        expandedSections.insert(group.section)
      }
    } label: {
      HStack {
        Text(group.section.title)
        Spacer()
        Text("\(group.items.count)")
          .foregroundStyle(.secondary)
        Image(
          systemName: expandedSections.contains(group.section) ? "chevron.down" : "chevron.right"
        )
        .font(.caption)
      }
    }
    .buttonStyle(.plain)
  }

  private var unreachableFullSurface: some View {
    VStack(spacing: 12) {
      Text(DegradedStateCopy.notConnected)
        .font(.headline)
        .multilineTextAlignment(.center)
      Button("Try Again") { Task { await queueStore.refresh() } }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var unreachableBanner: some View {
    HStack {
      Text(DegradedStateCopy.notConnected)
        .font(.footnote)
      Spacer()
      Button("Try Again") { Task { await queueStore.refresh() } }
        .font(.footnote)
    }
  }
}

/// One queue card: hero thumbnail, shoot name, last-touched date (omitted when null), counts,
/// fidelity badge, sync signal, and the derived review signal — every field read straight off
/// `Components.Schemas.FolderSummary`, never a client-side recomputation.
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
  private var displayName: String {
    summary.path.split(separator: "/").last.map(String.init) ?? summary.path
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
