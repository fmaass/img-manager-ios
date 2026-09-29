import SwiftUI

/// WP29 P4 (IMGMGR-455): one control of the grid's action bar. The bar renders a LIST of these,
/// so which controls it shows, and in what order, is data a test reads rather than a view body it
/// cannot see.
enum SelectBarControl: String, CaseIterable, Sendable {
  case pick, dislike, clear, undo, tag, scene, more
  /// The gap that puts Undo at the trailing edge in Select ("… ‖ Undo"). Not a control: it takes
  /// no hit region and no 44-pt slot.
  case spacer
}

/// WP29 P4 (IMGMGR-455): the action bar's order, per state and width class.
///
/// - At rest, unchanged: Regular `Pick · Dislike · Clear · Undo · Tag`, Compact `… · More`.
/// - Select at Regular: `Pick · Dislike · Clear · Tag · Scene ‖ Undo`.
/// - Select at Compact: `Pick · Dislike · Clear · Tag · Scene · More ‖ Undo` — More keeps its only
///   Compact home, and the narrow tier still folds Clear into More under the same identifier.
///
/// Pure and nonisolated: `ActionBarMetrics`, whose width arithmetic reads it, is nonisolated too.
/// `carriesMore` is the width-derived placement (`WorkspaceChromePlacement.actionBarCarriesMore`),
/// never a device idiom.
enum SelectBarLayout {
  static func controls(
    selecting: Bool, carriesMore: Bool, foldsClearIntoMore: Bool = false
  ) -> [SelectBarControl] {
    var marks: [SelectBarControl] = [.pick, .dislike]
    if !foldsClearIntoMore { marks.append(.clear) }
    let more: [SelectBarControl] = carriesMore ? [.more] : []
    guard selecting else { return marks + [.undo, .tag] + more }
    return marks + [.tag, .scene] + more + [.spacer, .undo]
  }
}

/// WP29 P4 (IMGMGR-455, plan Decision 5): when the SELECTION agrees with the focused subject of a
/// shipped scene edit.
///
/// Scene ▸ runs the SHIPPED focus-derived actions unchanged (ADR-0008: "explicit chrome actions
/// whose subject is always the FOCUSED member's OPEN scene"). The selection never picks a
/// different subject; it only narrows when a row is enabled. `f` is the focused photograph, `X`
/// the focused member's open scene, `S` the selection — non-empty in every row.
///
/// | row     | agrees iff                                   |
/// |---------|----------------------------------------------|
/// | merge   | S ⊆ loaded members of X and f ∈ S            |
/// | split   | S == {f}                                     |
/// | extract | S ⊆ loaded members of X and f ∈ S            |
/// | absorb  | S == {f}, f the focused loose photograph     |
@MainActor
enum SceneSelectionAgreement {
  enum Row: String, CaseIterable, Sendable {
    case merge, split, extract, absorb
  }

  static func merge(selection: Set<Int>, subject: SceneEditSubject?, members: [Int]) -> Bool {
    selectionIsInsideTheFocusedScene(selection, subject: subject, members: members)
  }

  static func split(selection: Set<Int>, subject: SceneEditSubject?) -> Bool {
    guard let subject else { return false }
    return selection == [subject.focusedImageID]
  }

  static func extract(selection: Set<Int>, subject: SceneEditSubject?, members: [Int]) -> Bool {
    selectionIsInsideTheFocusedScene(selection, subject: subject, members: members)
  }

  static func absorb(selection: Set<Int>, subject: SceneAbsorbSubject?) -> Bool {
    guard let subject else { return false }
    return selection == [subject.imageID]
  }

  private static func selectionIsInsideTheFocusedScene(
    _ selection: Set<Int>, subject: SceneEditSubject?, members: [Int]
  ) -> Bool {
    guard let subject, !selection.isEmpty, selection.contains(subject.focusedImageID) else {
      return false
    }
    return selection.isSubset(of: Set(members))
  }

  /// The row's agreement against the store's LIVE state: the shipped subject derivations
  /// (`sceneEditSubject`, `sceneAbsorbSubject`) and the selection, which only exists in Select.
  static func agrees(_ row: Row, in store: GridStore) -> Bool {
    let selection = store.selection.mode == .select ? store.selection.members : []
    let subject = store.sceneEditSubject
    let members = subject.map { store.sceneMembers[$0.stackID]?.map(\.id) ?? [] } ?? []
    switch row {
    case .merge: return merge(selection: selection, subject: subject, members: members)
    case .split: return split(selection: selection, subject: subject)
    case .extract: return extract(selection: selection, subject: subject, members: members)
    case .absorb: return absorb(selection: selection, subject: store.sceneAbsorbSubject)
    }
  }

  /// Plan gate r4, R4-B1: the check a Scene ▸ picker runs immediately before its unchanged
  /// shipped submit. A foreground refresh can move `f` into another scene while the sheet stands
  /// open, and the shipped submit re-derives its subject — so the agreement is re-read LIVE here
  /// rather than trusted from when the row was tapped.
  static func pickerGuard(
    for kind: SceneMergePicker.Kind
  ) -> @MainActor @Sendable (GridStore) -> Bool {
    switch kind {
    case .mergeFocusedScene: return { agrees(.merge, in: $0) }
    case .absorbLoosePhotograph: return { agrees(.absorb, in: $0) }
    }
  }
}

/// WP29 P4 (IMGMGR-455): Scene ▸, the scene edits' ONE touch home. The four rows are the entries
/// the More menu's Scene section declared until this phase, moved rather than copied — one
/// declaration per command — under the Select bar's identifiers. Each runs the SHIPPED action and
/// is enabled only when the shipped predicate holds AND the selection agrees
/// (`SceneSelectionAgreement`). None is destructive (plan Decision 6).
enum SelectBarSceneMenu {
  static let accessibilityIdentifier = "selectBarSceneMenu"
  static let title = "Scene"
  static let systemImage = "square.stack.3d.up"

  static let merge = GridMoreMenuEntry(
    id: "selectBar.scene.merge",
    accessibilityIdentifier: "selectBar.scene.merge",
    foldedAccessibilityIdentifier: nil,
    systemImage: "arrow.triangle.merge",
    title: { _ in "Merge into…" },
    isEnabled: { $0.canMergeFocusedScene && SceneSelectionAgreement.agrees(.merge, in: $0) },
    surface: .action { store in
      guard SceneSelectionAgreement.agrees(.merge, in: store) else { return }
      store.presentSceneMergePicker()
    })

  static let split = GridMoreMenuEntry(
    id: "selectBar.scene.split",
    accessibilityIdentifier: "selectBar.scene.split",
    foldedAccessibilityIdentifier: nil,
    systemImage: "scissors",
    title: { _ in "Split here" },
    isEnabled: { $0.canSplitFocusedScene && SceneSelectionAgreement.agrees(.split, in: $0) },
    surface: .action { store in
      guard SceneSelectionAgreement.agrees(.split, in: store) else { return }
      Task { await store.splitFocusedScene() }
    })

  static let extract = GridMoreMenuEntry(
    id: "selectBar.scene.extract",
    accessibilityIdentifier: "selectBar.scene.extract",
    foldedAccessibilityIdentifier: nil,
    systemImage: "square.on.square.dashed",
    title: { _ in "Extract selected" },
    isEnabled: {
      $0.canExtractSelectionFromScene && SceneSelectionAgreement.agrees(.extract, in: $0)
    },
    surface: .action { store in
      guard SceneSelectionAgreement.agrees(.extract, in: store) else { return }
      Task { await store.extractSelectionFromFocusedScene() }
    })

  /// Keeps its shipped reason-in-title (`SceneAbsorbCopy`). When the shipped predicate holds but
  /// the selection disagrees, the row is disabled and keeps the shipped title.
  static let absorb = GridMoreMenuEntry(
    id: "selectBar.scene.absorb",
    accessibilityIdentifier: "selectBar.scene.absorb",
    foldedAccessibilityIdentifier: nil,
    systemImage: "rectangle.stack.badge.plus",
    title: { SceneAbsorbCopy.title(for: $0.sceneAbsorbUnavailability) },
    isEnabled: { $0.canAbsorbFocusedPhoto && SceneSelectionAgreement.agrees(.absorb, in: $0) },
    surface: .action { store in
      guard SceneSelectionAgreement.agrees(.absorb, in: store) else { return }
      store.presentSceneAbsorbPicker()
    })

  static let entries: [GridMoreMenuEntry] = [merge, split, extract, absorb]
}
