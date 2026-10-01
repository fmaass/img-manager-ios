import SwiftUI

/// WP31 P2 (IMGMGR-461): the Pass Summary sheet — presented over the grid when a Triage pass
/// ends with at least one action (plan decision 4), a medium detent at Compact and a form at
/// Regular through the Shoot Summary's own `ShootSummarySizing` (design D9: same content).
///
/// It shows the pass's OWN counts — picks, dislikes, skipped — and the "Continue on iPad" row,
/// which explains Handoff rather than pretending to send anything (decision 5): while the sheet
/// is up it keeps the pass's `TriageActivity` current through `.userActivity`, so the iPad
/// offers the app in its Dock. The whole-shoot Shoot Summary sheet is a different surface and
/// is unchanged.
struct PassSummarySheet: View {
  let presentation: PassSummaryPresentation
  let layoutMode: LayoutMode
  @Environment(\.dismiss) private var dismiss
  @State private var detent: PresentationDetent = .medium

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(PassSummaryCopy.title(completed: presentation.completed))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("passSummaryDone")
          }
        }
    }
    .overlay(alignment: .topLeading) { debugProbeElement }
    .modifier(ShootSummarySizing(isCompact: layoutMode == .compact, detent: $detent))
    .userActivity(TriageActivity.activityType, isActive: isAdvertising) { activity in
      presentation.handoff?.configure(activity)
      TriageActivityProbe.record(activity, source: "passSummary")
    }
  }

  private var summary: PassSummary { presentation.summary }

  /// Decision 5: the sheet keeps the pass's activity current while it is up.
  private var isAdvertising: Bool { presentation.handoff != nil }

  private var content: some View {
    List {
      Section {
        if !presentation.folderTitle.isEmpty {
          Text(presentation.folderTitle)
            .font(.headline)
            .accessibilityIdentifier("passSummaryFolderName")
        }
        Text(PassSummaryCopy.marked(summary.marked))
          .accessibilityIdentifier("passSummary.marked")
      }
      Section {
        HStack(spacing: 0) {
          stat("Picks", summary.picks, id: "picks")
          stat("Dislikes", summary.dislikes, id: "dislikes")
          stat("Skipped", summary.skipped, id: "skipped")
        }
      }
      if presentation.handoff != nil {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            Label(PassSummaryCopy.handoffTitle, systemImage: "ipad.and.iphone")
              .font(.body.weight(.semibold))
            Text(PassSummaryCopy.handoffDetail)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("passSummary.handoff")
        }
      }
    }
  }

  /// One column of the stat grid. The identifier sits on the VALUE text, never on the column —
  /// the Shoot Summary's rule: an identifier on a container overrides its descendants'.
  private func stat(_ label: String, _ value: Int, id: String) -> some View {
    VStack(spacing: 2) {
      Text(value.formatted())
        .font(.title2.weight(.semibold))
        .monospacedDigit()
        .accessibilityIdentifier("passSummary.\(id)")
      Text(label)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  /// EVIDENCE, fixture-only (`GridView.debugProbeElement`'s pattern): what this sheet's
  /// `.userActivity` closure configured, recorded from inside it.
  #if DEBUG
    @ViewBuilder private var debugProbeElement: some View {
      if DebugStubLaunch.isActive {
        Text("debugProbeActivity")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.activity")
          .accessibilityValue(DebugProbe.shared.activity)
      }
    }
  #else
    private var debugProbeElement: some View { EmptyView() }
  #endif
}
