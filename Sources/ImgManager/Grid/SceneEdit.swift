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

/// WHAT an absorb acts on (IMGMGR-347): a LOOSE photograph — one the browse stream serves as a row
/// of its own rather than inside a scene — and the folder it sits in.
///
/// Deliberately NOT a `SceneEditSubject`: that value IS a membership (a scene and a member of it),
/// and the absorb is the one editor whose subject is a photograph that belongs to no scene, which
/// is exactly why `sceneEditSubject` is nil for it and why the other three rows are dead while a
/// loose photograph is focused. Its folder is what decides which scenes may take it — the server
/// refuses a cross-folder absorb, so the client offers only the folder's own scenes rather than
/// arranging a guaranteed refusal.
struct SceneAbsorbSubject: Equatable, Sendable {
  let imageID: Int
  let folderID: Int
}

/// One scene the subject may be merged INTO: a scene of the same folder that is currently loaded
/// in the window. Carries what the sheet draws — cover, count, when the scene sits in capture
/// order — and nothing else.
///
/// The absorb's targets are the same value (IMGMGR-347): a loose photograph is choosing among the
/// same scenes, drawn by the same sheet, so a second type would only be this one renamed.
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
  /// IMGMGR-347. `stackID` is the scene the photographs JOIN — the one the reader picked, not a
  /// subject they were already inside — and `imageIDs` are loose photographs. Frozen like its
  /// siblings, so the busy retry asks the same question.
  case absorb(stackID: Int, imageIDs: [Int], focusedImageID: Int)

  /// WHICH edit this is, as a value the refusal copy can be keyed on — the same 409 code means a
  /// different thing depending on the edit that got it, and the reader is owed the difference
  /// (codex gate, blocker: the absorb's `membership_changed` is about the PHOTOGRAPH, not the
  /// target scene). Derived from the request rather than stored beside it, so it cannot drift.
  var kind: SceneEditKind {
    switch self {
    case .merge: return .merge
    case .split: return .split
    case .extract: return .extract
    case .absorb: return .absorb
    }
  }

  /// The photograph the reader was on when they asked — where the coordinator tries to put focus
  /// back. For a split it is the cut itself, which is the first member of the new scene.
  var anchorImageID: Int {
    switch self {
    case .merge(_, let focused): return focused
    case .split(_, let atImageID): return atImageID
    case .extract(_, _, let focused): return focused
    case .absorb(_, _, let focused): return focused
    }
  }
}

/// The four edits, named so a refusal can say what was refused. Not a second copy of
/// `SceneEditRequest` — it is that value's own `kind`, carried past the point where the payload
/// has been dropped (the alert stands after the request is gone).
enum SceneEditKind: Equatable, Sendable {
  case merge
  case split
  case extract
  case absorb
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
  /// 404 on an absorb (IMGMGR-347): the scene, or a photograph this request named, is not in the
  /// library any more. Its own case rather than a `.refused`, because it says something different
  /// to the reader — nothing about this edit was wrong, the thing it acted on left — and because
  /// the absorb is the only editor that declares a 404 with a coded detail at all.
  case vanished
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

  /// `kind` is optional because most of these sentences are the family's, not one edit's: only
  /// `membership_changed` describes a DIFFERENT cause per edit, and a nil kind (a caller that has
  /// no edit in hand) gets the wording the three membership-based edits share.
  static func message(for failure: SceneEditFailure, of kind: SceneEditKind? = nil) -> String {
    switch failure {
    case .busy(let seconds):
      let wait =
        seconds.map { " Try again in about \($0) second\($0 == 1 ? "" : "s")." } ?? ""
      return "The library is reorganising this folder, so the edit could not start."
        + " Nothing was changed." + wait
    case .conflict(.foreignFolderMember):
      return "One of the chosen photographs is no longer in this folder. Nothing was changed."
    case .conflict(.membershipChanged):
      // The contract gives this code two different causes. For merge, split and extract the
      // SCENE moved under the request. For an absorb the target scene may be untouched: the
      // photograph "stopped being loose between the check and the write" (openapi.json,
      // StackExtractConflict), i.e. something else put it in a scene first — so naming the scene
      // here would tell the reader to look at the wrong thing. Neither offers a Retry: both mean
      // the reader must ask a different question, which is `offersRetry`'s existing rule.
      if kind == .absorb {
        return "That photograph stopped being loose while the edit was being prepared —"
          + " something else put it in a scene. Nothing was changed."
      }
      return "This scene changed while the edit was being prepared. Nothing was changed."
    case .refused:
      return "This edit cannot be made to this scene. Nothing was changed."
    case .vanished:
      return "That photograph or scene is no longer in the library. Nothing was changed."
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

/// Why the absorb cannot run right now (IMGMGR-347 AC2). One value, ordered by what the reader
/// would have to change FIRST, so the row can name a single missing thing rather than a list.
enum SceneAbsorbUnavailability: Equatable, Sendable {
  /// Nothing focused, the focus is on a scene MEMBER, or the grid is not in Scene mode at all —
  /// in every one of those there is no loose photograph for the absorb to act on.
  case noLoosePhotographFocused
  /// A loose photograph, but no scene of its folder has been paged into the window yet, so there
  /// is nothing to offer as a target.
  case noSceneInTheSameFolderLoaded
  /// One edit at a time (`isSceneEditInFlight`), the same answer every other topology row gives.
  case anotherEditIsRunning
}

/// The absorb row's own words, as a pure function of why it cannot act.
///
/// The words matter here more than on the other rows, and the ticket is why: the owner's device
/// pass (TestFlight 0.11.0 (14)) hit "'merge into..' is not doing anything" — a row that greys out
/// says nothing about WHAT is missing, so a reader who cannot make it enabled has no way to learn
/// what would. The menu idiom in this app is present-and-disabled (`GridMoreMenuItem` applies
/// `.disabled`), and a menu row's only visible surface is its title, so the reason goes in the
/// title. Kept beside the failure copy because it is the same kind of thing: the reader's words,
/// unit-testable, held in exactly one place.
enum SceneAbsorbCopy {
  static let offered = "Add to scene…"

  static func title(for unavailability: SceneAbsorbUnavailability?) -> String {
    guard let unavailability else { return offered }
    switch unavailability {
    case .noLoosePhotographFocused: return "Add to scene — focus a loose photograph"
    case .noSceneInTheSameFolderLoaded: return "Add to scene — no scene in view yet"
    case .anotherEditIsRunning: return "Add to scene — an edit is running"
    }
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
    if SceneEditCopy.offersRetry(failure), let pending {
      actions.append(
        SceneEditAlertAction(id: "sceneEditAlert.retry", title: "Retry", isCancel: false) {
          store in
          // CAPTURED, not read: `pending` is bound here, when the alert is built, so the
          // dismissal SwiftUI runs before this action cannot take the payload away from it.
          Task { await store.replaySceneEdit(pending) }
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
    return candidates.filter { $0.representative.folderId == folderID }.sorted(by: inCaptureOrder)
  }

  /// The order both target lists are offered in — the stream's own, so the sheet reads like the
  /// grid behind it. Shared rather than copied because "which scenes may take these photographs,
  /// in what order" is one question asked from two directions (IMGMGR-347).
  ///
  /// A scene with no stored anchor has no place in capture order, so it goes LAST rather than to
  /// the top, where a nil would sort under any comparison that treated it as zero.
  private static func inCaptureOrder(_ left: SceneMergeTarget, _ right: SceneMergeTarget) -> Bool {
    switch (left.anchorTakenAt, right.anchorTakenAt) {
    case (let a?, let b?): return a == b ? left.stackID < right.stackID : a < b
    case (nil, _?): return false
    case (_?, nil): return true
    case (nil, nil): return left.stackID < right.stackID
    }
  }

  /// The absorb's subject: the focused photograph, if the stream is serving it as a LOOSE row.
  ///
  /// Read off `sceneRows` rather than off `sceneMembers`, and that is the whole difference from
  /// `subject(expanded:members:focusedImageID:)`: a photograph is loose exactly when the server
  /// put it in the stream as its own row, which is a fact the client is told rather than one it
  /// derives (ADR-0005 — the server owns membership). A member of a scene, open or closed, never
  /// appears as an `.image` row, so this is nil for it without a second membership check.
  static func absorbSubject(rows: [SceneBrowseRow], focusedImageID: Int?) -> SceneAbsorbSubject? {
    guard let focused = focusedImageID else { return nil }
    for row in rows {
      guard case .image(let image) = row, image.id == focused else { continue }
      return SceneAbsorbSubject(imageID: image.id, folderID: image.folderId)
    }
    return nil
  }

  /// The scenes a loose photograph may join: every scene of ITS folder currently loaded in the
  /// window, in capture order.
  ///
  /// Same folder for the same reason a merge is folder-scoped — the server refuses a cross-folder
  /// absorb (`foreign_folder_member`), so offering one would be arranging a guaranteed refusal —
  /// and decided from the cover's `folder_id`, which is sound because every member of a scene,
  /// the cover included, is in the scene's own folder.
  ///
  /// **Same v1 limitation as the merge sheet, declared in the same place:** only LOADED scenes
  /// are offered, because the window pages forward on its own cursor and this list is what has
  /// arrived.
  static func absorbTargets(rows: [SceneBrowseRow], folderID: Int) -> [SceneMergeTarget] {
    rows.compactMap { row -> SceneMergeTarget? in
      guard case .stack(let stack) = row, stack.representative.folderId == folderID else {
        return nil
      }
      return SceneMergeTarget(
        stackID: stack.stackId, representative: stack.representative,
        memberCount: stack.memberCount, anchorTakenAt: stack.anchorTakenAt)
    }
    .sorted(by: inCaptureOrder)
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

  /// Where a row belongs in the loaded window — the ONE comparator both the topology coordinator's
  /// splice and the scene pager's append go through.
  ///
  /// Chronological ascending, which is the only order `GET /api/browse/stacks` serves (ADR-0005
  /// decision 1) and the order every page was fetched in. An incoming row with no time sorts to
  /// the END, for the same reason a scene with no anchor is offered last as a merge target: it has
  /// no place in capture order, and inventing one at the front would put it where the reader is
  /// looking.
  ///
  /// An UNDATED row already in the window is stepped over rather than treated as a boundary, and
  /// that single `continue` is what makes this degenerate to a plain append for ordinary paging:
  /// a page whose rows are at or after everything loaded finds no later row and lands at the end,
  /// whatever undated rows the server chose to put there and wherever it put them. Stopping at one
  /// instead would silently re-order normal pages around it, which is a real behaviour change to
  /// pay for a placement the server, not this client, decides.
  static func insertionIndex(for anchor: Date?, in rows: [SceneBrowseRow]) -> Int {
    guard let anchor else { return rows.count }
    for (index, row) in rows.enumerated() {
      guard let time = streamTime(of: row) else { continue }
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
