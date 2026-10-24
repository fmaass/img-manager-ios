import SwiftUI

/// WP28 P3 (IMGMGR-450), plan Decisions 1 and 2: the Shoot Summary sheet, opened from the
/// grid's title menu (never automatically). It shows the server's shoot-wide counts for the
/// selected folder, the "Nothing left unmarked" banner only when the server says so, the
/// write-back tally, and "Done".
///
/// It reads `queueStore.summaries` in its body, so a queue refresh after marking re-renders it
/// with the new counts while it is open — `QueueStore` is `@Observable`. The plan's Lightroom
/// action is deliberately absent: the one existing Lightroom command copies the WHOLE library's
/// marked set, not this shoot's picks (orchestrator ruling on IMGMGR-450).
struct ShootSummarySheet: View {
  let queueStore: QueueStore
  let folderID: Int?
  let title: String?
  let layoutMode: LayoutMode
  /// IMGMGR-545: the sync routes for the Regular-only sync block; nil shows no block.
  let syncService: SyncService?
  @Environment(\.dismiss) private var dismiss
  /// IMGMGR-545: the sync block's model. The sheet owns and starts it: a `.task` inside the
  /// List (on the block's section, then on its row) never delivered the status on iPad.
  @State private var syncModel: SyncSheetModel?
  @State private var detent: PresentationDetent = .medium

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(Self.sheetTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("shootSummaryDone")
          }
        }
    }
    // First load, if nothing has asked for the queue yet on this shell. `loadIfNeeded` is the
    // queue's own idempotent entry point; it never refetches over a loaded list.
    .task { await queueStore.loadIfNeeded() }
    .modifier(ShootSummarySizing(isCompact: layoutMode == .compact, detent: $detent))
    // IMGMGR-545: one status read per presentation of a Regular Summary; no polling here.
    .task(id: syncBlockFolderID) {
      guard let syncService, let folderID = syncBlockFolderID else {
        syncModel = nil
        return
      }
      let model = SyncSheetModel(service: syncService, folderID: folderID)
      syncModel = model
      await model.start()
    }
  }

  /// The folder the sync block reads, or nil where the block is not shown (Compact, no folder).
  private var syncBlockFolderID: Int? {
    guard syncService != nil, SyncPlacement.showsSummaryBlock(layoutMode: layoutMode) else {
      return nil
    }
    return folderID
  }

  static let sheetTitle = "Shoot Summary"

  private var summary: ShootSummary {
    ShootSummary.forFolder(folderID, in: queueStore.summaries)
  }

  private var content: some View {
    List {
      if let title {
        Section {
          Text(title)
            .font(.headline)
            .accessibilityIdentifier("shootSummaryFolderName")
        }
      }
      if summary.showsNothingLeftUnmarkedBanner {
        Section {
          Label("Nothing left unmarked", systemImage: "checkmark.seal")
            .accessibilityIdentifier("shootSummaryBanner")
        }
      }
      if let counts = summary.counts {
        Section("Photos") {
          countRow("Total", counts.total, id: "total")
          countRow("Picked", counts.picked, id: "picked")
          countRow("Disliked", counts.disliked, id: "disliked")
          countRow("Unmarked", counts.unmarked, id: "unmarked")
        }
      } else {
        Section {
          Text("Counts unavailable")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("shootSummaryCountsUnavailable")
        }
      }
      if let sync = summary.sync {
        Section("Sync") {
          countRow("Synced", sync.synced, id: "sync.synced")
          countRow("Stale", sync.stale, id: "sync.stale")
          countRow("Never", sync.never, id: "sync.never")
          countRow("Refused", sync.refused, id: "sync.refused")
        }
      }
      // IMGMGR-545 (R3-14): the sync block, Regular layouts only; the tally above is unchanged.
      if let syncService, let syncModel, let folderID = syncBlockFolderID {
        SyncSummaryBlock(model: syncModel, service: syncService, folderID: folderID)
      }
    }
  }

  /// The identifier sits on the VALUE text, never on the row: an identifier on a container
  /// overrides its descendants' (`SidebarSectionHeader`), and the value is what a test reads. Two
  /// plain `Text`s rather than `LabeledContent`, which may merge them into one element.
  private func countRow(_ label: String, _ value: Int, id: String) -> some View {
    HStack {
      Text(label)
      Spacer(minLength: 8)
      Text(value.formatted())
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("shootSummary.\(id)")
    }
  }
}

/// Form sizing at Regular, a medium detent at Compact (plan Phase 3). Neither request has a
/// flag-taking form, so the branch is here; it flips only if the window crosses Compact/Regular
/// while the sheet is open, which rebuilds the sheet's own content and nothing outside it.
/// WP31 P2 (IMGMGR-461): internal, so the Pass Summary sheet sizes exactly the same way.
struct ShootSummarySizing: ViewModifier {
  let isCompact: Bool
  @Binding var detent: PresentationDetent

  func body(content: Content) -> some View {
    if isCompact {
      content.presentationDetents([.medium, .large], selection: $detent)
    } else {
      content.presentationSizing(.form)
    }
  }
}
