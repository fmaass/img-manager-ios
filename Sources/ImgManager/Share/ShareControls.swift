import ImgManagerAPI
import SwiftUI
import UIKit

/// The share entry. WP30 P1 (IMGMGR-456): it is the Share row of the loupe's More menu — the
/// header became a system toolbar (p4128 D4) and Share moved off it into More, so it keeps its
/// one home in persistent chrome, in BOTH idioms — the chrome rule carried from the web unchanged
/// ("every action is reachable from persistent chrome; gestures and pointer affordances are
/// additions", functional spec p3231).
///
/// A menu row lives only while its menu is open, so the prepare, the presented sheet and their
/// lifetime cannot sit on the row the way they sat on the old header control: they live in a
/// `ShareLauncher` the LOUPE owns, whose sheet and cancel-on-disappear hang off the loupe's root
/// (`ShareLauncherPresentation`). Closing the loupe mid-prepare still cancels the prepare.
///
/// AND NOWHERE ELSE, deliberately. There is no context menu on a grid tile: a tile's touch
/// long-press ALREADY means "enter Select mode" (`Grid/GridView.swift:97-100` →
/// `GridStore.longPressTile`, `Grid/GridStore.swift:536`), and SwiftUI's `.contextMenu` cannot
/// be restricted to the pointer's secondary click — it binds long-press on touch as well — so a
/// tile-level menu would either fight that gesture or add exactly the touch binding this lane is
/// forbidden to add. The iPad pointer-only secondary-click entry therefore stays unbuilt until
/// SwiftUI offers a pointer-only affordance; the chrome control here is the complete, reachable
/// surface in the meantime, which is what the chrome rule actually requires.
///
/// RE-PROBED 2026-08-31 (WP13 P11, IMGMGR-220) against the iOS 26.5 simulator SDK's own SwiftUI
/// swiftinterface, because the rationale above was dated and inheriting it unchecked would have
/// been a guess. `secondaryClick`, `pointerOnly` and `rightClick` return no hits; the only
/// near-matches are `ToolbarItemPlacement.secondaryAction` (unrelated) and
/// `contextMenu(forSelectionType:menu:primaryAction:)`, which is a List/Table SELECTION menu still
/// bound to the standard context-menu interaction — long press on touch. Positive control in the
/// same invocation: all seven `func contextMenu` overloads were listed, so the interface really
/// was read. The constraint STANDS and the entry stays unbuilt, now on evidence rather than on
/// inheritance.
@MainActor
@Observable
final class ShareLauncher {
  /// The export the presented sheet was made from; ended with `finish` when the sheet goes.
  private(set) var presentedToken: ShareExportToken?
  var isSharePresented = false
  @ObservationIgnored private var prepareTask: Task<Void, Never>?

  func start(share: ShareExportStore, image: Components.Schemas.ImageSummary) {
    prepareTask?.cancel()
    prepareTask = Task { await self.present(share: share, image: image) }
  }

  /// The loupe is gone: a prepare still running must never present anything. Cancelling here is
  /// what makes the store's cancellation path run at all, so no prepared bytes outlive a share
  /// that can no longer be presented.
  func cancel() {
    prepareTask?.cancel()
    prepareTask = nil
  }

  /// ONE TAP (IMGMGR-348). Owner device pass on 0.11.0 (14), verbatim: "the sharing is weird: on
  /// a single picture screen, the sharing button should immediatly open the native share
  /// functionality and share that picture". So the menu, the inline "Preparing…"/filename row and
  /// the second tap are gone: this prepares and then presents, in one gesture.
  ///
  /// PREPARE-THEN-PRESENT, not a lazily-resolving `NSItemProvider`, and the reason is the
  /// contract rather than convenience: the item is registered under the EXPORT's own `UTType`
  /// (see `ShareSheet`), and a master's type is the SERVER's — the download `200` declares seven
  /// content types and `ShareExportPlan.contentType(for:)` maps whichever one arrives. A provider
  /// registered before the response exists would have to declare a type it does not yet know,
  /// i.e. tell the receiving app something that may be false. The measured cost of preparing
  /// first is in the phase's evidence (`LoupeShareOneTapUITests` logs it per destination).
  ///
  /// A refusal is NOT presented: nothing is on disk, so there is nothing to hand to a sheet, and
  /// `ShareStatusBar` renders the refusal inline exactly as it always did.
  private func present(share: ShareExportStore, image: Components.Schemas.ImageSummary) async {
    await share.prepare(ShareExportPlan.variant(hasEdit: image.hasEdit), for: image)
    // A prepare that finishes AFTER the loupe is gone must not present anything. The store has
    // already ended that export (its cancellation path), so `.ready` is not reachable here
    // either — this is the second half of the same statement, said where the presentation
    // actually happens rather than inferred from the store's state.
    guard !Task.isCancelled else { return }
    guard case .ready = share.state else { return }
    presentedToken = share.currentToken
    isSharePresented = true
  }
}

/// The launcher's sheet and lifetime, attached to the loupe's root — the one view that outlives
/// the More menu the Share row sits in.
struct ShareLauncherPresentation: ViewModifier {
  @Bindable var launcher: ShareLauncher
  let share: ShareExportStore

  func body(content: Content) -> some View {
    content
      .onDisappear { launcher.cancel() }
      .sheet(
        isPresented: $launcher.isSharePresented,
        onDismiss: {
          if let token = launcher.presentedToken { share.finish(token) }
        },
        content: {
          // Re-read from state rather than capturing: by presentation time this is still the
          // same `.ready` file, and if anything superseded it there is nothing to present.
          if case .ready(let file) = share.state, let token = launcher.presentedToken {
            ShareSheet(file: file, share: share, token: token)
          }
        })
  }
}

/// The More menu's Share row (identifier `loupeShare`, kept from the header control): one tap on
/// the row prepares and presents, as the header control did (IMGMGR-348).
struct ShareMenuRow: View {
  let launcher: ShareLauncher
  @Bindable var share: ShareExportStore
  let image: Components.Schemas.ImageSummary?

  var body: some View {
    Button {
      guard let image else { return }
      launcher.start(share: share, image: image)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .disabled(image == nil || share.isPreparing)
    .accessibilityIdentifier("loupeShare")
  }
}

/// The share lane's inline, non-modal REFUSAL row, directly under the loupe header — the same
/// posture `ConflictRecoveryBanner` already uses for the 409 lane: no alerts, no server text, no
/// modality anywhere in this flow.
///
/// It renders one state and one only (IMGMGR-348). The "Preparing the export…" row and the
/// ready-filename button it used to draw were the second and third interactions the owner did
/// not want, and both are gone: preparation shows on the loupe itself (`loupeSharePreparing`),
/// and a prepared export presents its sheet without being asked again. What remains is the one
/// thing a share can still need to say — that it could not happen, and why — which no system
/// sheet can say for this app.
struct ShareStatusBar: View {
  @Bindable var share: ShareExportStore

  var body: some View {
    if case .refused(let refusal) = share.state {
      HStack(spacing: 12) {
        Label(refusal.copy, systemImage: "exclamationmark.triangle")
          .font(.footnote)
        Spacer()
        Button("Dismiss") { share.finish(share.currentToken) }
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
///    swipe-down. Both end at `ShareExportStore.finish(_:)` carrying this sheet's own token, so
///    the temp file's life is tied to the sheet's — and a callback that arrives after the user
///    moved on ends nothing at all.
/// 2. **The type is declared, not inferred.** The item is registered under the EXPORT's own
///    `UTType` — the proxy's image type today, the master's server-declared type once
///    `ShareMasterSeam` opens — instead of letting the receiving app guess from a file
///    extension. `suggestedName` carries the filename the plan derived.
struct ShareSheet: UIViewControllerRepresentable {
  let file: ShareExportFile
  let share: ShareExportStore
  /// The export this sheet is showing. Carried so a completion arriving from an out-of-process
  /// target — which can be minutes later, after the user prepared something else entirely — ends
  /// THIS export and not whatever happens to be current when it lands.
  let token: ShareExportToken

  /// The identifier a UI test waits for. A presented `UIActivityViewController` draws its
  /// contents out of process, so its rows are not reliably in this app's accessibility tree —
  /// but the container view it presents IS ours, and naming it is what lets
  /// `LoupeShareOneTapUITests` prove the sheet actually opened rather than that a tap happened.
  static let presentedIdentifier = "loupeShareSheet"

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = Self.makeController(file: file, share: share, token: token)
    controller.view.accessibilityIdentifier = Self.presentedIdentifier
    return controller
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

  /// Split out of `makeUIViewController` because a `Context` cannot be constructed in a test:
  /// this is the SAME code path the view uses, callable directly, so the dismissal wiring and
  /// the declared type are provable rather than asserted in a comment.
  static func makeController(
    file: ShareExportFile, share: ShareExportStore, token: ShareExportToken
  ) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: [makeItemProvider(for: file)], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, _, _, _ in
      // UIKit calls this on the main thread; `assumeIsolated` states that requirement instead
      // of hopping through a `Task`, which would make cleanup arrive an unpredictable moment
      // later — including after a new export had already started.
      MainActor.assumeIsolated { share.finish(token) }
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
