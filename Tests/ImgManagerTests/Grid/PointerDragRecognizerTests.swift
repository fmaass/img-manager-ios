import CoreGraphics
import Testing

@testable import ImgManager

#if canImport(UIKit)
  import UIKit

  /// Diff-gate round 2, blocker 3: "prove touch/Pencil/two-finger-scroll never paint" at the
  /// recognizer level. `PointerTouchFilter.isPrimaryPointerDrag` is the exact predicate
  /// `PrimaryPointerDragRecognizer.touchesBegan` delegates to (a one-line call, see its own
  /// doc comment) — a real `UITouch` cannot be constructed with an arbitrary `.type` in a unit
  /// test, so this proves the FILTER LOGIC directly rather than not at all.
  @Suite("Pointer touch filter (diff-gate round 2, blocker 3)")
  struct PointerTouchFilterTests {

    @Test("A genuine single-touch indirect pointer (trackpad/mouse) IS accepted")
    func indirectPointerAccepted() {
      #expect(PointerTouchFilter.isPrimaryPointerDrag([.indirectPointer]))
    }

    @Test("A finger touch is REJECTED — touch/Pencil drags never paint")
    func directTouchRejected() {
      #expect(!PointerTouchFilter.isPrimaryPointerDrag([.direct]))
    }

    @Test("A Pencil touch is REJECTED — touch/Pencil drags never paint")
    func pencilRejected() {
      #expect(!PointerTouchFilter.isPrimaryPointerDrag([.pencil]))
    }

    @Test("A mixed touch set (any non-pointer touch present) is REJECTED")
    func mixedTouchSetRejected() {
      #expect(!PointerTouchFilter.isPrimaryPointerDrag([.indirectPointer, .direct]))
    }

    @Test("An empty touch set is REJECTED — nothing to recognize")
    func emptyRejected() {
      #expect(!PointerTouchFilter.isPrimaryPointerDrag([]))
    }
  }

  @Suite("Pointer drag event mapping")
  struct PointerDragEventMapperTests {
    @Test("began/changed map to .changed with the location")
    func beganAndChangedMapToChanged() {
      let point = CGPoint(x: 10, y: 20)
      #expect(PointerDragEventMapper.map(state: .began, location: point) == .changed(point))
      #expect(PointerDragEventMapper.map(state: .changed, location: point) == .changed(point))
    }

    @Test("ended/cancelled/failed all map to .ended")
    func terminalStatesMapToEnded() {
      let point = CGPoint(x: 0, y: 0)
      #expect(PointerDragEventMapper.map(state: .ended, location: point) == .ended)
      #expect(PointerDragEventMapper.map(state: .cancelled, location: point) == .ended)
      #expect(PointerDragEventMapper.map(state: .failed, location: point) == .ended)
    }

    @Test("possible maps to nil — no event yet")
    func possibleMapsToNil() {
      #expect(PointerDragEventMapper.map(state: .possible, location: .zero) == nil)
    }
  }
#endif

@Suite("Grid hit-test (pure geometry)")
struct GridHitTestTests {
  @Test("A point inside exactly one tile's frame resolves to that tile")
  func pointInsideOneFrame() {
    let frames: [Int: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 100, height: 100),
      2: CGRect(x: 100, y: 0, width: 100, height: 100),
    ]
    #expect(GridHitTest.imageID(at: CGPoint(x: 50, y: 50), in: frames) == 1)
    #expect(GridHitTest.imageID(at: CGPoint(x: 150, y: 50), in: frames) == 2)
  }

  @Test("A point outside every frame resolves to nil")
  func pointOutsideEveryFrame() {
    let frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100)]
    #expect(GridHitTest.imageID(at: CGPoint(x: 500, y: 500), in: frames) == nil)
  }

  @Test("An empty frame set always resolves to nil")
  func emptyFramesResolveToNil() {
    #expect(GridHitTest.imageID(at: .zero, in: [:]) == nil)
  }
}
