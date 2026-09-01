import Foundation
import ImgManagerAPI

/// WP14 P4 (IMGMGR-277): scene EDITING, as the derivations it rests on — kept pure and
/// free-standing beside `SceneRowBuilder`, and for the same reason: what a topology action acts
/// on, what it may be offered over, what its request carries and where the reader is put
/// afterwards are all decidable from values, so they are decided here rather than inside a store
/// method a test can only reach through a network stub.
///
/// The boundary ADR-0008 draws is what these types encode. A topology action is an EXTENSION over
/// VISIBLE subjects: its subject is the focused member's scene, its extraction set is the
/// selection intersected with that scene's LOADED membership, and neither can name a photograph
/// the reader cannot see. Nothing here mutates membership — the server owns that (ADR-0005) — and
/// nothing here can produce an id that `actionableImages` did not already contain.

/// WHAT a scene-edit action acts on: the scene holding the focused photograph, and that
/// photograph. One value, so "the control is enabled" and "the action runs" read the SAME
/// derivation rather than two checks that can drift (the P11 `openInNewWindow` pattern).
struct SceneEditSubject: Equatable, Sendable {
  let stackID: Int
  let focusedImageID: Int
}

/// One scene the subject may be merged INTO: a scene of the same folder that is currently loaded
/// in the window. Carries what the sheet draws — cover, count, when the scene sits in capture
/// order — and nothing else.
struct SceneMergeTarget: Identifiable, Equatable, Sendable {
  let stackID: Int
  let representative: Components.Schemas.ImageSummary
  let memberCount: Int
  let anchorTakenAt: Date?

  var id: Int { stackID }
}

/// A scene edit exactly as it was asked for, FROZEN.
///
/// The 503 retry replays this value and never recomputes it (plan §Phase 4, the gate's
/// most-serious-unasked finding; web parity — `runExtraction` closes over `chosen` so a selection
/// changed while the folder was busy cannot silently become a different edit). Being a value with
/// no reference to the store is what makes that structural: there is nothing here to re-read.
enum SceneEditRequest: Equatable, Sendable {
  /// `stackIDs` goes on the wire verbatim, in this order: the subject first, the picked target
  /// second. The SURVIVOR is the server's choice (the lowest id), never named here.
  case merge(stackIDs: [Int], focusedImageID: Int)
  case split(stackID: Int, atImageID: Int)
  case extract(stackID: Int, imageIDs: [Int], focusedImageID: Int)

  /// The photograph the reader was on when they asked — where the coordinator tries to put focus
  /// back. For a split it is the cut itself, which is the first member of the new scene.
  var anchorImageID: Int {
    switch self {
    case .merge(_, let focused): return focused
    case .split(_, let atImageID): return atImageID
    case .extract(_, _, let focused): return focused
    }
  }
}

/// Why a scene edit did not happen. Opaque by construction, exactly like `GridServiceError`: every
/// case carries a typed CODE or an integer, never the server's own sentence, hostname or body. The
/// reader's words are this app's (`SceneEditCopy`), keyed off the code the contract declares.
enum SceneEditFailure: Equatable, Sendable {
  /// 503 `stack_edit_busy` — a maintenance lane holds the folder's lock; nothing was changed. The
  /// only failure that offers a Retry, because it is the only one whose frozen payload is still
  /// the right question to ask.
  case busy(retryAfterSeconds: Int?)
  /// 409 on an extraction — the scene is not in the state the request was written against.
  case conflict(SceneEditConflictReason)
  /// 422: the edit is refused by the contract itself (`not_a_member`, `empty_split_side`,
  /// `cross_folder_merge`, …). The coded detail arrives as an object where the declared schema
  /// says array, so the generated client cannot decode WHICH — see `GridService`.
  case refused
  case unreachable
}

/// The two codes `StackExtractConflict` declares. Named here so the alert renders a reason rather
/// than a status code, and so a third code arriving in the contract is a compile error in the
/// mapping rather than a silent fallthrough.
enum SceneEditConflictReason: Equatable, Sendable {
  case foreignFolderMember
  case membershipChanged
}

/// What the reader is told, as a pure function of the failure — so the words are unit-testable and
/// the view holds no second copy of them.
enum SceneEditCopy {
  static let title = "The scene was not changed"

  static func message(for failure: SceneEditFailure) -> String {
    switch failure {
    case .busy(let seconds):
      let wait =
        seconds.map { " Try again in about \($0) second\($0 == 1 ? "" : "s")." } ?? ""
      return "The library is reorganising this folder, so the edit could not start."
        + " Nothing was changed." + wait
    case .conflict(.foreignFolderMember):
      return "One of the chosen photographs is no longer in this folder. Nothing was changed."
    case .conflict(.membershipChanged):
      return "This scene changed while the edit was being prepared. Nothing was changed."
    case .refused:
      return "This edit cannot be made to this scene. Nothing was changed."
    case .unreachable:
      return "The edit could not be sent. Nothing was changed."
    }
  }

  /// Only the busy answer gets a Retry: it is the one refusal that means "ask again, unchanged".
  /// A 409 or a 422 asks for a DIFFERENT edit, and replaying the frozen payload would replay the
  /// refusal.
  static func offersRetry(_ failure: SceneEditFailure) -> Bool {
    if case .busy = failure { return true }
    return false
  }
}

/// One button on the refusal alert, declared AS DATA — the same discipline `GridMoreMenuEntry`
/// applies to the More menu, and here it is load-bearing rather than tidy.
///
/// SwiftUI dismisses an alert when a button is tapped: the `isPresented` binding's setter runs
/// FIRST and the button's own action runs after it. The setter is what clears the refusal, so an
/// action that read the frozen payload off the store when it RAN would read what the dismissal had
/// just cleared and send nothing. The payload is therefore captured into the action's closure when
/// the alert is BUILT, which is before any of that can happen — and because the buttons are data,
/// a test can fire them in SwiftUI's own order instead of hoping.
struct SceneEditAlertAction: Identifiable, Sendable {
  let id: String
  let title: String
  /// `.cancel` in SwiftUI terms — the row that only dismisses.
  let isCancel: Bool
  let run: @MainActor @Sendable (GridStore) -> Void
}

enum SceneEditAlert {
  /// The alert's buttons for one refusal, with the replay payload already captured.
  ///
  /// `pending` is read by the CALLER at render time and handed in, so this function cannot reach
  /// store state at all — which is precisely the property that makes the dismissal ordering
  /// irrelevant.
  static func actions(for failure: SceneEditFailure, replaying pending: SceneEditRequest?)
    -> [SceneEditAlertAction]
  {
    var actions: [SceneEditAlertAction] = []
    if SceneEditCopy.offersRetry(failure), pending != nil {
      actions.append(
        SceneEditAlertAction(id: "sceneEditAlert.retry", title: "Retry", isCancel: false) {
          store in
          // WP14 P4 STAGED PRE-FIX — reads the payload off the store when it RUNS.
          Task { await store.retrySceneEdit() }
        })
    }
    actions.append(
      SceneEditAlertAction(id: "sceneEditAlert.dismiss", title: "OK", isCancel: true) { store in
        store.dismissSceneEditError()
      })
    return actions
  }
}

/// The decisions a scene edit is made of, over values only.
enum SceneEditPlanner {

  /// The ONE enablement predicate (plan Decision 2): a focused photograph that is a member of an
  /// OPEN scene. Everything else — no focus, focus on a loose photograph, focus inside a scene the
  /// reader has closed — has no subject, so every action is disabled.
  ///
  /// `expanded` is asked FIRST and separately from `members`: membership survives a collapse (so
  /// reopening costs no request), and a scene nobody has open is not a subject.
  static func subject(
    expanded: Set<Int>,
    members: [Int: [Components.Schemas.ImageSummary]],
    focusedImageID: Int?
  ) -> SceneEditSubject? {
    guard let focused = focusedImageID else { return nil }
    for stackID in expanded.sorted() {
      guard let loaded = members[stackID] else { continue }
      guard loaded.contains(where: { $0.id == focused }) else { continue }
      return SceneEditSubject(stackID: stackID, focusedImageID: focused)
    }
    return nil
  }

  /// The scenes offered as merge targets: every OTHER scene of the SAME folder currently loaded in
  /// the window, in capture order.
  ///
  /// Same folder is decided from the cover's `folder_id`, which is sound because scenes are
  /// folder-scoped by construction (backend Decision 2: every member, the cover included, is in
  /// the scene's own folder) — so a cross-folder merge is refused before a request rather than by
  /// the 422, exactly as the web decides it.
  ///
  /// **v1 limitation, declared in the sheet:** only LOADED scenes are offered. The window pages
  /// forward on its own cursor and this list is what has arrived; a scene further down the stream
  /// is not a target until the reader has paged to it.
  static func mergeTargets(rows: [SceneBrowseRow], subjectStackID: Int) -> [SceneMergeTarget] {
    var subjectFolderID: Int?
    var candidates: [SceneMergeTarget] = []
    for row in rows {
      guard case .stack(let stack) = row else { continue }
      if stack.stackId == subjectStackID {
        subjectFolderID = stack.representative.folderId
        continue
      }
      candidates.append(
        SceneMergeTarget(
          stackID: stack.stackId, representative: stack.representative,
          memberCount: stack.memberCount, anchorTakenAt: stack.anchorTakenAt))
    }
    guard let folderID = subjectFolderID else { return [] }
    return
      candidates
      .filter { $0.representative.folderId == folderID }
      .sorted { left, right in
        switch (left.anchorTakenAt, right.anchorTakenAt) {
        case (let a?, let b?): return a == b ? left.stackID < right.stackID : a < b
        // A scene with no stored anchor has no place in capture order, so it goes last rather
        // than to the top, where a nil would sort under any comparison that treated it as zero.
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return left.stackID < right.stackID
        }
      }
  }

  /// The members of THIS scene that are selected, in the MEMBERSHIP's own order (web parity,
  /// `selectedMembersOf`). Scoped to the one scene rather than reading the whole selection,
  /// because the action's subject defines its scope: a reader with photographs selected in two
  /// open scenes who extracts from one has not asked anything of the other.
  static func selectedMembers(
    of stackID: Int,
    members: [Int: [Components.Schemas.ImageSummary]],
    selected: Set<Int>
  ) -> [Int] {
    (members[stackID] ?? []).filter { selected.contains($0.id) }.map(\.id)
  }

  /// Whether "Extract selected" is offered at all.
  ///
  /// Two refusals, both of them the server's own guards, answered here as DISABLEMENT rather than
  /// as a round trip to a refusal — a control that cannot do anything should not be offered
  /// (native adaptation of the web's two pre-flight notices; this app raises no notice banners).
  /// A selection of nothing names no photographs. A selection of EVERY member would leave a
  /// memberless row — asked only of a membership that is fully loaded, since a scene still paging
  /// in may hold members the client has not seen, and refusing on a partial count would refuse an
  /// extraction the server would allow.
  static func extractionIsOffered(chosen: Int, loaded: Int, membershipComplete: Bool) -> Bool {
    guard chosen > 0 else { return false }
    guard membershipComplete, chosen == loaded else { return true }
    return false
  }

  /// Where focus goes after a confirmed edit.
  ///
  /// The rule, in one sentence: the photograph the reader was on, if the reloaded window can still
  /// show it; otherwise the first member of the first result scene that came back open. That
  /// covers all three edits — a merge keeps every member (so the anchor survives, provided the
  /// merged scene was completed past page one), a split and an extraction move the anchor into a
  /// NEW scene which the coordinator has just reopened — and it degrades to a defined answer
  /// rather than to nothing when the anchor genuinely left the window (a filter it no longer
  /// matches, a page it no longer sits on).
  static func restoredFocus(
    anchorImageID: Int,
    actionable: [Components.Schemas.ImageSummary],
    resultStackIDs: [Int],
    members: [Int: [Components.Schemas.ImageSummary]]
  ) -> Int? {
    if actionable.contains(where: { $0.id == anchorImageID }) { return anchorImageID }
    for stackID in resultStackIDs {
      if let first = members[stackID]?.first { return first.id }
    }
    return nil
  }

  /// The time a browse row sits at in the ONE order this stream has: a scene's STORED anchor, and
  /// a loose photograph's capture time. Nil where the row has neither.
  static func streamTime(of row: SceneBrowseRow) -> Date? {
    switch row {
    case .stack(let stack): return stack.anchorTakenAt
    case .image(let image): return image.capturedAt
    }
  }

  /// Where a row the reloaded page does not contain belongs in the loaded window.
  ///
  /// Chronological ascending, which is the only order `GET /api/browse/stacks` serves (ADR-0005
  /// decision 1) and the order the page was fetched in. A row with no time sorts to the END rather
  /// than to the top, for the same reason a scene with no anchor is offered last as a merge
  /// target: it has no place in capture order, and inventing one at the front would put it where
  /// the reader is looking.
  static func insertionIndex(for anchor: Date?, in rows: [SceneBrowseRow]) -> Int {
    guard let anchor else { return rows.count }
    for (index, row) in rows.enumerated() {
      guard let time = streamTime(of: row) else { return index }
      if time > anchor { return index }
    }
    return rows.count
  }

  /// Which scenes are open after the edit: everything that was open and did not dissolve, plus
  /// every scene the edit produced (web parity, `reloadAfterTopologyEdit`). Sorted so the reopen
  /// order is deterministic and a test can name it.
  static func scenesToReopen(
    previouslyExpanded: Set<Int>, result: Components.Schemas.StackEditResult
  ) -> [Int] {
    var reopen = previouslyExpanded.subtracting(result.dissolvedStackIds)
    reopen.formUnion(result.stackIds)
    return reopen.sorted()
  }
}
