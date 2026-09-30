import Foundation
import SwiftUI

/// IMGMGR-474 (owner report, iPad, build 19): "on the pick/unpick menu at the bottom there should
/// always be visual feedback that an option is selected". The grid bar's Pick/Dislike/Clear drew
/// from the LOCK state alone, so a photograph that was just picked left the bar looking exactly
/// as it did before the tap. This is what the bar's mark target currently CARRIES — the same
/// target `applyMarkToTarget` writes to (`GridStore.markTargetImageIDs`): the focused photograph
/// in browse, the actionable selection in Select.
enum MarkTargetReadout: Equatable, Sendable {
  /// Nothing to read: no focused photograph, an empty selection, or a target id the actionable
  /// projection no longer holds.
  case noTarget
  /// Every photograph in the target carries this one mark.
  case uniform(MarkStateValue)
  /// The target carries more than one mark; the set names which ones (always two or more).
  case mixed(Set<MarkStateValue>)

  static func of(_ states: [MarkStateValue]) -> MarkTargetReadout {
    let distinct = Set(states)
    guard let only = distinct.first else { return .noTarget }
    return distinct.count == 1 ? .uniform(only) : .mixed(distinct)
  }
}

/// Which of the three visual states a bar mark control draws — each a SYSTEM button style plus a
/// tint, never a custom material. Review round 1 (IMGMGR-474): a glyph and a trait alone were
/// not visible enough; the SELECTED state must differ by FILL, and still never read as a latch.
enum MarkControlEmphasis: Equatable, Sendable {
  /// `.bordered` over a neutral fill — nothing to report.
  case plain
  /// `.bordered` over the control's own colour (the mark colour; accent for Clear) — the target
  /// carries this mark.
  case selected
  /// `.borderedProminent`, solid, plus the mode-row caption — a lock is on. A mode, not a state.
  case latched
}

/// A colour named as DATA so the style outcome is unit-testable; the view maps it to a `Color`.
enum MarkControlTint: Equatable, Sendable {
  case neutral
  case accent
  case mark(MarkRole)
}

extension MarkControlTint {
  var color: Color {
    switch self {
    // A neutral fill that still reads as a button on both appearances.
    case .neutral: return .gray
    case .accent: return .accentColor
    case .mark(let role): return MarkPalette.color(for: role)
    }
  }
}

/// How one bar control relates to the target's marks.
enum MarkControlIndication: Equatable, Sendable {
  /// The target does not carry this control's mark (or there is nothing to read).
  case off
  /// The whole target carries this control's mark: the control is SELECTED.
  case on
  /// Part of a mixed selection carries this control's mark: never blank, never "selected".
  case partial
}

/// One bar mark control's complete presentation, as DATA — the sibling of `LoupeMarkPresentation`
/// for the grid bar, and a superset of `PickButtonPresentation` (the latch half is carried
/// unchanged inside it, so the lock's pins keep their own tests).
///
/// Two signals, deliberately different in kind so a latch can never be read as a state readout:
/// - LATCHED (a mode): `.borderedProminent` fill + the mode-row caption above the bar.
/// - MARK READOUT (a state): the plain `.bordered` style with the FILLED glyph — the loupe's and
///   the tile badge's vocabulary — plus `.isSelected` and a spoken value; a mixed selection adds
///   a badge instead.
/// While a lock is latched the readout is withheld on every control: in a lock, a tap applies the
/// latched verb to whatever tile it lands on, so the focused photograph is not the subject, and
/// the latched control must stay the only lit one (DislikeLockScreenshotUITests' pin).
struct ActionBarMarkPresentation: Equatable {
  var latch: PickButtonPresentation
  var indication: MarkControlIndication
  var systemImage: String
  var accessibilityValue: String

  /// The mixed-selection badge drawn on a `.partial` control's glyph.
  static let mixedBadgeSymbol = "minus.circle.fill"

  /// The colour this control is identified by: its mark colour (the WP16 P1 palette decision,
  /// p3332 decision 5), or the accent for Clear, which is not a verdict and has no mark colour.
  var ownTint: MarkControlTint

  var isProminent: Bool { latch.isProminent }
  var isSelected: Bool { latch.accessibilitySelected || indication == .on }
  var showsMixedBadge: Bool { indication == .partial }

  var emphasis: MarkControlEmphasis {
    if latch.isProminent { return .latched }
    return indication == .on ? .selected : .plain
  }

  /// The `.tint` the button STYLE draws its fill with: neutral until the control is selected or
  /// latched, then the control's own colour.
  var fillTint: MarkControlTint { emphasis == .plain ? .neutral : ownTint }

  /// The glyph's own colour, overriding the style's: the control's own colour in both bordered
  /// states, so Pick and Dislike stay mark-coloured whatever the fill. `nil` while latched — the
  /// prominent style draws its own contrasting foreground on the solid fill.
  var glyphTint: MarkControlTint? { emphasis == .latched ? nil : ownTint }

  static func `for`(
    _ control: ActionBarMarkControl, lockState: PickLockState.LockState,
    readout: MarkTargetReadout
  ) -> ActionBarMarkPresentation {
    let latch =
      control.latchVerb.map { PickButtonPresentation.for(lockState, control: $0) }
      ?? PickButtonPresentation(
        isProminent: false, accessibilitySelected: false, modeRowCaption: nil)
    let isIdle = lockState == .idle
    let shown: MarkControlIndication =
      isIdle ? Self.indication(of: control.state, in: readout) : .off
    let hasTarget = isIdle && readout != .noTarget
    return ActionBarMarkPresentation(
      latch: latch, indication: shown,
      systemImage: shown == .on ? "\(control.systemImage).fill" : control.systemImage,
      accessibilityValue: hasTarget ? spokenValue(control, shown) : "",
      ownTint: control.latchVerb.map { .mark($0.markRole) } ?? .accent)
  }

  static func indication(of state: MarkStateValue, in readout: MarkTargetReadout)
    -> MarkControlIndication
  {
    switch readout {
    case .noTarget: return .off
    case .uniform(let carried): return carried == state ? .on : .off
    case .mixed(let carried): return carried.contains(state) ? .partial : .off
    }
  }

  private static func spokenValue(
    _ control: ActionBarMarkControl, _ indication: MarkControlIndication
  ) -> String {
    switch (control, indication) {
    case (.pick, .on): return "Picked"
    case (.pick, .off): return "Not picked"
    case (.pick, .partial): return "Some picked"
    case (.dislike, .on): return "Disliked"
    case (.dislike, .off): return "Not disliked"
    case (.dislike, .partial): return "Some disliked"
    case (.clear, .on): return "Unmarked"
    case (.clear, .off): return "Marked"
    case (.clear, .partial): return "Some unmarked"
    }
  }
}

extension ActionBarMarkControl {
  /// The latch verb this control owns, if any — Clear owns none.
  var latchVerb: LatchVerb? {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    case .clear: return nil
    }
  }
}

extension GridMoreMenu {
  /// The folded Clear row's readout (IMGMGR-474 review round 1): when the bar gives Clear up to
  /// the More menu, that row is the only Clear there is, so it must say what the bar's Clear
  /// would. Unfolded, the bar's own Clear says it, and the menu row stays a plain command.
  static func markPresentation(
    for entry: GridMoreMenuEntry, foldsClearIntoMore: Bool,
    lockState: PickLockState.LockState, readout: MarkTargetReadout
  ) -> ActionBarMarkPresentation? {
    guard foldsClearIntoMore, entry.id == clearMark.id else { return nil }
    return ActionBarMarkPresentation.for(.clear, lockState: lockState, readout: readout)
  }
}

extension GridStore {
  /// The bar's readout, read from the SAME target the bar writes to and from the actionable
  /// projection itself — no cached copy, so it moves in the same frame as the optimistic write,
  /// the rollback, undo and the post-commit scene refresh, whichever last wrote the rows.
  var markTargetReadout: MarkTargetReadout {
    let targets = Set(markTargetImageIDs)
    guard !targets.isEmpty else { return .noTarget }
    return .of(
      actionableImages.filter { targets.contains($0.id) }.map { MarkStateValue($0.mark.state) })
  }
}
