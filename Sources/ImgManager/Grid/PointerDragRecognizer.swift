import CoreGraphics
import SwiftUI

#if canImport(UIKit)
  import UIKit

  /// Pure predicate: would this set of touch types be accepted as a genuine PRIMARY pointer
  /// (trackpad/mouse) click-and-drag? Diff-gate round 2, blocker 3: pin (d) requires touch and
  /// Pencil drags to NEVER paint, and two-finger trackpad scrolling to remain scrolling. Every
  /// one of those is excluded here: `.direct` (finger) and `.pencil` fail; a two-finger
  /// trackpad scroll is delivered as a scroll EVENT rather than `.indirectPointer` touches at
  /// all (`allowedScrollTypesMask = []` on the recognizer additionally refuses to treat a
  /// scroll gesture as this one), so it never reaches this predicate carrying
  /// `.indirectPointer` touches either. Pulled out as a free function (rather than inlined in
  /// `touchesBegan`) specifically so it is unit-testable without constructing a real `UITouch`.
  enum PointerTouchFilter {
    static func isPrimaryPointerDrag(_ touchTypes: [UITouch.TouchType]) -> Bool {
      !touchTypes.isEmpty && touchTypes.allSatisfy { $0 == .indirectPointer }
    }
  }

  /// A `UIPanGestureRecognizer` that only ever recognizes a genuine primary-pointer drag — see
  /// `PointerTouchFilter`. `touchesBegan` is a thin, one-line delegation to that pure predicate
  /// so the actual UIKit call site carries no independent logic of its own to drift out of sync
  /// with what the tests prove.
  final class PrimaryPointerDragRecognizer: UIPanGestureRecognizer {
    override init(target: Any?, action: Selector?) {
      super.init(target: target, action: action)
      minimumNumberOfTouches = 1
      maximumNumberOfTouches = 1
      allowedScrollTypesMask = []
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      guard PointerTouchFilter.isPrimaryPointerDrag(touches.map(\.type)) else {
        state = .failed
        return
      }
      super.touchesBegan(touches, with: event)
    }
  }

  /// Pure translation from a recognizer's raw UIKit state into the event this view dispatches —
  /// factored out of `handleUIGestureRecognizerAction` so the mapping itself (not just the
  /// touch-type filter) is unit-testable without a real `UIGestureRecognizer` instance.
  enum PointerDragEvent: Equatable {
    case changed(CGPoint)
    case ended
  }

  enum PointerDragEventMapper {
    static func map(state: UIGestureRecognizer.State, location: CGPoint) -> PointerDragEvent? {
      switch state {
      case .began, .changed: return .changed(location)
      case .ended, .cancelled, .failed: return .ended
      default: return nil
      }
    }
  }

  /// SwiftUI bridge (`UIGestureRecognizerRepresentable`). Wired at the grid container level
  /// (not per-tile — a UIKit gesture recognizer tracks the touch that STARTED it, so a single
  /// continuous drag across sibling tile views needs ONE recognizer plus geometry hit-testing,
  /// never one recognizer per tile).
  struct PrimaryPointerDragGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> PrimaryPointerDragRecognizer {
      PrimaryPointerDragRecognizer()
    }

    func handleUIGestureRecognizerAction(
      _ recognizer: PrimaryPointerDragRecognizer, context: Context
    ) {
      guard
        let event = PointerDragEventMapper.map(
          state: recognizer.state, location: recognizer.location(in: recognizer.view))
      else { return }
      switch event {
      case .changed(let point): onChanged(point)
      case .ended: onEnded()
      }
    }
  }
#endif

/// Pure geometry hit-test: which tile (by image id) contains `point`, from the frames each tile
/// reports via `TileFramePreferenceKey`. Independently testable without SwiftUI or UIKit.
enum GridHitTest {
  static func imageID(at point: CGPoint, in frames: [Int: CGRect]) -> Int? {
    frames.first(where: { $0.value.contains(point) })?.key
  }
}

/// Each tile reports its own on-screen frame (in the grid's named coordinate space) here, so the
/// container-level pointer-drag recognizer can hit-test its current point against every tile
/// without any tile needing its own gesture recognizer.
struct TileFramePreferenceKey: PreferenceKey {
  // A computed property (never a stored static var) — sidesteps Swift 6 strict-concurrency's
  // "static stored property is not concurrency-safe" diagnostic entirely, since there is no
  // shared mutable state to race on: every access just builds a fresh empty dictionary.
  static var defaultValue: [Int: CGRect] { [:] }
  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
