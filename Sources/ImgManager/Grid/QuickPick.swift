import SwiftUI

/// IMGMGR-475 (owner, 2026-09-29, options 1 + 2): "a quick option to pick a photo would be nice,
/// e.g. tap on a photo — unfortunately that is reserved for opening the picture in detail mode."
///
/// Where a tap on a tile's MARK CORNER goes. The corner is the badge area (top trailing), a
/// 44-pt target laid over a tile; the rest of the tile keeps focus/open (`GridStore.tapTile`).
enum MarkCornerRoute: Equatable, Sendable {
  /// Focus that photograph (never the loupe), then a one-shot Pick toggle on it, no latch. The
  /// focus move is what makes the bar's Pick readout (IMGMGR-474) name the SAME photograph the
  /// badge just changed on, in the same pass; a following tap on the tile body then opens the
  /// loupe, as for any focused tile (review round 1, AC 3).
  case focusAndQuickPick
  /// The tile's own tap, unchanged — Select keeps selecting, a latched lock applies its verb.
  case tile
}

/// The corner's rules as pure functions, so "browse quick-picks, Select selects, a lock applies
/// its own verb" is a unit test rather than a gesture only a device can exercise. Its chrome twin
/// (every gesture keeps a visible twin) is the action bar's Pick.
enum QuickPickCorner {
  /// Fold item 4's floor: the corner is a full 44 × 44 pt target.
  static let side: CGFloat = 44

  /// Browse with no lock on is the ONLY state in which the corner is its own gesture. In Select
  /// a tap anywhere on the tile selects; while a lock is latched a tap anywhere applies the
  /// latched verb (`GridStore.tapTile`) — a second, different write from the corner would make
  /// one tile answer two ways.
  static func route(mode: GridInteractionMode, latchedVerb: LatchVerb?) -> MarkCornerRoute {
    guard latchedVerb == nil, mode == .browse else { return .tile }
    return .focusAndQuickPick
  }

  /// Pick <-> none: a picked photograph clears, anything else becomes picked.
  static func toggledMark(from current: MarkStateValue) -> MarkStateValue {
    current == .pick ? MarkStateValue.none : .pick
  }

  /// The corner is laid over a tile only when it takes LESS than a quarter-ish of it: both sides
  /// strictly longer than two targets, so the tile's centre — where a tap focuses or opens, and
  /// where a UI test's element tap lands — is never inside the corner. A placeholder has no
  /// known size and a tombstone has nothing to mark, so neither gets one: the whole cell stays
  /// the tile's.
  static func isInstalled(plan: TileRenderPlan, missing: Bool?) -> Bool {
    guard missing != true, case .display(_, let size) = plan else { return false }
    return size.width > 2 * side && size.height > 2 * side
  }

  /// What the corner says to VoiceOver — every status the tile's badges draw, because the badges
  /// step out of the tree wherever a corner sits over them: the mark first, then Edited, Good and
  /// Changed elsewhere when they apply. The Select tick is not repeated here: the tile itself
  /// carries the selected trait.
  static func accessibilityValue(
    mark: MarkStateValue, isEdited: Bool = false, isGood: Bool = false,
    isChangedElsewhere: Bool = false
  ) -> String {
    var words: [String]
    switch mark {
    case .pick: words = ["Picked"]
    case .dislike: words = ["Disliked"]
    case .none: words = ["Not picked"]
    }
    if isEdited { words.append("Edited") }
    if isGood { words.append("Good") }
    if isChangedElsewhere { words.append("Changed elsewhere") }
    return words.joined(separator: ", ")
  }

  static let accessibilityLabel = "Quick Pick"

  static func accessibilityIdentifier(imageID: Int) -> String { "tileMarkCorner-\(imageID)" }
}

/// IMGMGR-475 option 1: a VISIBLE "Tap to Pick" control on the action bar, beside Pick, that
/// surfaces Pick Lock. The mechanics are Pick Lock's, unchanged — it latches through the same
/// `forceLatch` path as the long-press "Lock Pick" and leaves through the same exit as the mode
/// row's Done. It is the discoverable twin of the double-tap latch.
enum TapToPickToggle {
  enum Action: Equatable, Sendable {
    case latchPick
    case exitLock
    /// Inert: in Select (lock entry is disabled there, pin e) or under a Dislike lock (whose own
    /// Done exits it — the toggle never silently swaps the latched verb).
    case inert
  }

  static let title = "Tap to Pick"
  static let accessibilityIdentifier = "gridTapToPickToggle"
  static let systemImage = "hand.tap"

  static func action(lockState: PickLockState.LockState, mode: GridInteractionMode) -> Action {
    switch lockState {
    case .latched(.pick): return .exitLock
    case .latched(.dislike): return .inert
    case .idle: return mode == .browse ? .latchPick : .inert
    }
  }

  /// On exactly while the Pick lock is latched.
  static func isOn(_ lockState: PickLockState.LockState) -> Bool {
    lockState == .latched(.pick)
  }
}

extension GridStore {
  /// IMGMGR-475 option 2: a tap on a tile's mark corner. In browse with no lock on it focuses
  /// THAT photograph (never opening the loupe) and toggles Pick on it through the shipped mark
  /// path (`applyMark`: optimistic, undoable, one mutation lane — a second corner tap while the
  /// first is in flight is refused, never a flip back). Focus moves BEFORE the write's first
  /// suspension, so the badge and the bar's readout change together. Everywhere else it is the
  /// tile's own tap.
  func tapMarkCorner(_ imageID: Int) async {
    switch QuickPickCorner.route(mode: selection.mode, latchedVerb: pickLock.latchedVerb) {
    case .tile:
      await tapTile(imageID)
    case .focusAndQuickPick:
      guard let image = actionableImages.first(where: { $0.id == imageID }) else { return }
      focusedImageID = imageID
      let next = QuickPickCorner.toggledMark(from: MarkStateValue(image.mark.state))
      await applyMark(next, to: [imageID])
    }
  }

  /// IMGMGR-475 option 1: the bar's "Tap to Pick" toggle.
  func toggleTapToPick() {
    switch TapToPickToggle.action(lockState: pickLock.state, mode: selection.mode) {
    case .latchPick: lockFromMenu(.pick)
    case .exitLock: done()
    case .inert: return
    }
  }
}

/// IMGMGR-475 option 2's target: an invisible 44 × 44 pt square over a tile's badge corner. A
/// SIBLING of the tile laid on by `GridView`, never a child of `TileView`, so it answers to its
/// own identifier and not to the tile's (the `SceneExpandHandle` precedent). The long-press is
/// forwarded so pressing on the corner still enters Select, exactly as anywhere else on the tile.
struct MarkCornerTarget: View {
  let imageID: Int
  /// `QuickPickCorner.accessibilityValue(...)`, resolved by `GridView` where the tile is built.
  let spokenValue: String
  let store: GridStore

  var body: some View {
    Color.clear
      .frame(width: QuickPickCorner.side, height: QuickPickCorner.side)
      .contentShape(Rectangle())
      .onTapGesture { Task { await store.tapMarkCorner(imageID) } }
      .onLongPressGesture(minimumDuration: 0.5) { store.longPressCell(.image(imageID)) }
      .accessibilityElement()
      .accessibilityLabel(QuickPickCorner.accessibilityLabel)
      .accessibilityValue(spokenValue)
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier(QuickPickCorner.accessibilityIdentifier(imageID: imageID))
  }
}
