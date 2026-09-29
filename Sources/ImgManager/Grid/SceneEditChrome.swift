import ImgManagerAPI
import SwiftUI

/// WP14 P4 (IMGMGR-277): the two surfaces scene editing puts on screen — the merge-target sheet
/// and the refusal alert. Both are CHROME: no gesture is added anywhere by this lane, and no
/// banner (the connectivity/stale-cache banner surface is untouched, owner decision IMGMGR-256).

/// Pick the scene to merge INTO.
///
/// A sheet rather than the web's arm-and-tap grid mode (plan Decision 1): a modal grid state
/// fights Select, which is the one mode this grid already has. The list is the same folder's other
/// LOADED scenes in capture order, and the sheet says so — the window pages forward on its own
/// cursor, so a scene further down the stream is not offered until the reader has paged to it.
struct SceneMergePicker: View {

  /// WHICH edit is choosing a target (IMGMGR-347). One view rather than two, because it is the
  /// same choice made from two directions — a scene of this folder, from the same list, in the
  /// same order — and only the words, the row identifier and the store method the tap runs
  /// differ. A second view would be this one copied, and the copy is where a fix lands on one
  /// surface and not the other.
  enum Kind: Sendable {
    /// The focused member's scene joins the one picked (WP14 P4, IMGMGR-277).
    case mergeFocusedScene
    /// The focused LOOSE photograph joins the one picked (IMGMGR-347).
    case absorbLoosePhotograph
  }

  let store: GridStore
  var kind: Kind = .mergeFocusedScene
  /// WP29 P4 (IMGMGR-455, plan gate r4 R4-B1): read LIVE inside the submission task, immediately
  /// before the unchanged shipped call — false submits nothing. Scene ▸ passes
  /// `SceneSelectionAgreement.pickerGuard(for:)`; the default keeps the shipped behaviour for any
  /// other opener.
  var submissionGuard: @MainActor @Sendable (GridStore) -> Bool = { _ in true }
  @Environment(\.dismiss) private var dismiss

  private var targets: [SceneMergeTarget] {
    switch kind {
    case .mergeFocusedScene: return store.sceneMergeTargets
    case .absorbLoosePhotograph: return store.sceneAbsorbTargets
    }
  }

  private var title: String {
    switch kind {
    case .mergeFocusedScene: return "Merge into…"
    case .absorbLoosePhotograph: return SceneAbsorbCopy.offered
    }
  }

  private func identifier(for target: SceneMergeTarget) -> String {
    switch kind {
    case .mergeFocusedScene: return "sceneMergeTarget-\(target.stackID)"
    case .absorbLoosePhotograph: return "sceneAbsorbTarget-\(target.stackID)"
    }
  }

  private func choose(_ target: SceneMergeTarget) {
    let kind = self.kind
    let store = self.store
    let submissionGuard = self.submissionGuard
    Task {
      await Self.submit(
        kind: kind, targetStackID: target.stackID, store: store, submissionGuard: submissionGuard)
    }
  }

  /// The submission, as one function a test can drive: the guard, then the SHIPPED call,
  /// unchanged.
  static func submit(
    kind: Kind, targetStackID: Int, store: GridStore,
    submissionGuard: @MainActor @Sendable (GridStore) -> Bool
  ) async {
    guard submissionGuard(store) else { return }
    switch kind {
    case .mergeFocusedScene:
      await store.mergeFocusedScene(into: targetStackID)
    case .absorbLoosePhotograph:
      await store.absorbFocusedPhoto(into: targetStackID)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(targets) { target in
            Button {
              dismiss()
              choose(target)
            } label: {
              SceneMergeTargetRow(target: target, store: store)
            }
            .accessibilityIdentifier(identifier(for: target))
          }
        } footer: {
          // The v1 limitation, DECLARED where the choice is made rather than in a release note.
          Text(
            "Only scenes already loaded in this folder are listed. Scroll the grid further to"
              + " reach more.")
        }
      }
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}

/// One target scene: its cover, how many photographs it holds, and where it sits in capture order.
/// The cover comes through the SAME `GridStore.proxyData` cache at the same tier as every other
/// cell (`SceneInlinePickThumb`'s pattern), so the sheet takes its turn in the proxy queue rather
/// than opening a second lane.
private struct SceneMergeTargetRow: View {
  let target: SceneMergeTarget
  let store: GridStore
  @State private var cover: PlatformImage?

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let cover {
          PlatformImageView(image: cover)
            .aspectRatio(contentMode: .fill)
        } else {
          Rectangle().fill(.quaternary)
        }
      }
      .frame(width: 44, height: 44)
      .clipShape(RoundedRectangle(cornerRadius: 4))

      VStack(alignment: .leading, spacing: 2) {
        Text("\(target.memberCount) photo\(target.memberCount == 1 ? "" : "s")")
          .font(.headline)
        if let anchor = target.anchorTakenAt {
          Text(anchor.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 44)
    .task(id: target.stackID) {
      let tier = ProxyTier.grid
      let token = ProxyIdentity.token(
        from: target.representative.proxies.additionalProperties[tier.rawValue]?.url)
      if let data = await store.proxyData(
        imageID: target.representative.id, tier: tier, identityToken: token),
        let decoded = PlatformImage(data: data)
      {
        cover = decoded
      }
    }
  }
}

extension View {
  /// The refusal surface: an ALERT carrying the typed decision, in `AccountSheetView`'s idiom —
  /// the app's ONE `.alert(presenting:)` with per-case buttons. Retry appears for exactly one
  /// failure, the busy folder, and replays the FROZEN payload.
  func sceneEditAlert(store: GridStore) -> some View {
    alert(
      SceneEditCopy.title,
      isPresented: Binding(
        get: { store.sceneEditError != nil },
        set: { presented in
          if !presented { store.dismissSceneEditError() }
        }
      ),
      presenting: store.sceneEditError
    ) { failure in
      // The buttons are DATA (`SceneEditAlert`), rendered here and nowhere else — and the replay
      // payload is read HERE, at render time, because the dismissal that SwiftUI fires before a
      // button's action would otherwise have cleared it first.
      ForEach(SceneEditAlert.actions(for: failure, replaying: store.pendingSceneEdit)) { action in
        Button(action.title, role: action.isCancel ? .cancel : nil) { action.run(store) }
          .accessibilityIdentifier(action.id)
      }
    } message: { failure in
      // Keyed on the edit that was refused: one 409 code means two different things depending on
      // it (`SceneEditCopy.message`), and the reader is owed the one that happened to them.
      Text(SceneEditCopy.message(for: failure, of: store.sceneEditErrorKind))
    }
  }
}
