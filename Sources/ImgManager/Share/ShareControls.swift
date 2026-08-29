import ImgManagerAPI
import SwiftUI

/// The share entry, in the loupe's persistent header chrome, in BOTH idioms — the chrome rule
/// carried from the web unchanged ("every action is reachable from persistent chrome; gestures
/// and pointer affordances are additions", functional spec p3231) — with the same 44-pt
/// treatment every other header control has (`Loupe/LoupeView.swift:63-73`).
///
/// AND NOWHERE ELSE, deliberately. There is no context menu on a grid tile: a tile's touch
/// long-press ALREADY means "enter Select mode" (`Grid/GridView.swift:97-100` →
/// `GridStore.longPressTile`, `Grid/GridStore.swift:536`), and SwiftUI's `.contextMenu` cannot
/// be restricted to the pointer's secondary click — it binds long-press on touch as well — so a
/// tile-level menu would either fight that gesture or add exactly the touch binding this lane is
/// forbidden to add. The iPad pointer-only secondary-click entry therefore stays unbuilt until
/// SwiftUI offers a pointer-only affordance; the chrome control here is the complete, reachable
/// surface in the meantime, which is what the chrome rule actually requires.
struct ShareControl: View {
  @Bindable var share: ShareExportStore
  let image: Components.Schemas.ImageSummary?

  var body: some View {
    Group {
      if share.isPreparing {
        ProgressView()
          .controlSize(.small)
      } else {
        Menu {
          Button("Share preview") {
            guard let image else { return }
            Task { await share.prepare(.preview, for: image) }
          }
          // The rule itself lives in `ShareExportPlan.offersMaster` — see its doc comment — so
          // it is one testable decision rather than a condition restated in a view.
          if ShareExportPlan.offersMaster(hasEdit: image?.hasEdit) {
            Button("Share edited master") {
              guard let image else { return }
              Task { await share.prepare(.master, for: image) }
            }
          }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(image == nil)
      }
    }
    .labelStyle(.iconOnly)
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityIdentifier("loupeShare")
  }
}

/// The share lane's inline, non-modal status row, directly under the loupe header — the same
/// posture `ConflictRecoveryBanner` already uses for the 409 lane: no alerts, no server text, no
/// modality anywhere in this flow.
///
/// The `ShareLink` lives HERE rather than in the header because it exists only once the file
/// does: reaching `.ready` means the bytes are already on disk under their final name, so the
/// system sheet this link opens is handed a file URL that resolves instantly and cannot fail
/// half-presented (gate correction 3).
struct ShareStatusBar: View {
  @Bindable var share: ShareExportStore

  var body: some View {
    switch share.state {
    case .idle:
      EmptyView()
    case .preparing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Preparing the export…")
          .font(.footnote)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial)
      .accessibilityIdentifier("sharePreparing")
    case .ready(let file):
      HStack(spacing: 12) {
        ShareLink(item: file.url) {
          Label(file.filename, systemImage: "square.and.arrow.up")
        }
        .font(.footnote)
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .accessibilityIdentifier("shareReadyLink")
        Spacer()
        Button("Done") { share.finish() }
          .font(.footnote)
          .frame(minHeight: 44)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.thinMaterial)
      .accessibilityIdentifier("shareReady")
    case .refused(let refusal):
      HStack(spacing: 12) {
        Label(refusal.copy, systemImage: "exclamationmark.triangle")
          .font(.footnote)
        Spacer()
        Button("Dismiss") { share.finish() }
          .font(.footnote)
          .frame(minHeight: 44)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.orange.opacity(0.15))
      .accessibilityIdentifier("shareRefusal")
    }
  }
}
