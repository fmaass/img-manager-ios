import ImgManagerAPI
import SwiftUI
import UIKit

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
/// The share control lives HERE rather than in the header because it exists only once the file
/// does: reaching `.ready` means the bytes are already on disk under their final name, so the
/// system sheet resolves instantly and cannot fail half-presented (gate correction 3).
///
/// It presents `ShareSheet` rather than a `ShareLink` for one reason: `ShareLink` never reports
/// its own dismissal. With it, the prepared file and the `.ready` state survived until something
/// unrelated happened to clear them — the user pressing Done, or focus moving — so a cancelled
/// share left bytes on disk indefinitely. `.sheet(onDismiss:)` plus the activity controller's own
/// `completionWithItemsHandler` between them cover every way the sheet can go away, and both end
/// at `finish()`.
struct ShareStatusBar: View {
  @Bindable var share: ShareExportStore
  @State private var isSharePresented = false

  var body: some View {
    content
      .sheet(
        isPresented: $isSharePresented, onDismiss: { share.finish() },
        content: {
          // Re-read from state rather than capturing: by presentation time this is still the
          // same `.ready` file, and if anything superseded it there is nothing to present.
          if case .ready(let file) = share.state {
            ShareSheet(file: file, share: share)
          }
        })
  }

  @ViewBuilder
  private var content: some View {
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
        Button {
          isSharePresented = true
        } label: {
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

/// The system share sheet for an export that is already on disk — and, unlike `ShareLink`, a
/// presentation that says when it is DONE.
///
/// Two things this type exists for:
///
/// 1. **Dismissal is reported.** `completionWithItemsHandler` fires whether the user completed a
///    share or cancelled, and `.sheet`'s own `onDismiss` at the call site covers an interactive
///    swipe-down. Both end at `ShareExportStore.finish()`, so the temp file's life is tied to the
///    sheet's rather than to the user happening to press Done afterwards.
/// 2. **The type is declared, not inferred.** The item is registered under the EXPORT's own
///    `UTType` — the proxy's image type today, the master's server-declared type once
///    `ShareMasterSeam` opens — instead of letting the receiving app guess from a file
///    extension. `suggestedName` carries the filename the plan derived.
struct ShareSheet: UIViewControllerRepresentable {
  let file: ShareExportFile
  let share: ShareExportStore

  func makeUIViewController(context: Context) -> UIActivityViewController {
    Self.makeController(file: file, share: share)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

  /// Split out of `makeUIViewController` because a `Context` cannot be constructed in a test:
  /// this is the SAME code path the view uses, callable directly, so the dismissal wiring and
  /// the declared type are provable rather than asserted in a comment.
  static func makeController(file: ShareExportFile, share: ShareExportStore)
    -> UIActivityViewController
  {
    let controller = UIActivityViewController(
      activityItems: [makeItemProvider(for: file)], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, _, _, _ in
      // UIKit calls this on the main thread; `assumeIsolated` states that requirement instead
      // of hopping through a `Task`, which would make cleanup arrive an unpredictable moment
      // later — including after a new export had already started.
      MainActor.assumeIsolated { share.finish() }
    }
    return controller
  }

  static func makeItemProvider(for file: ShareExportFile) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = file.filename
    provider.registerFileRepresentation(
      forTypeIdentifier: file.contentType.identifier, fileOptions: [], visibility: .all
    ) { completion in
      // The bytes are already on disk (that is what `.ready` means), so this hands the existing
      // file straight over — it never re-fetches, re-encodes, or decodes anything.
      completion(file.url, false, nil)
      return nil
    }
    return provider
  }
}
