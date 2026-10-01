import CoreGraphics
import Testing

@testable import ImgManager

/// WP30 P3 (IMGMGR-458): Compare's zoom, with two panes of UNEQUAL geometry — a landscape proxy
/// whose 1:1 is 5× fit beside a portrait one whose 1:1 is 2.67× fit, in the same viewport.
@Suite("CompareZoomSync — relative magnification, normalised pan, per-pane clamp (WP30 P3)")
struct CompareZoomSyncTests {
  private typealias Geometry = CompareZoomSync.Geometry

  /// 4000×3000 px in 400×300 pt at @2x: fitted 400×300, 1:1 at 5× fit.
  private let landscape = Geometry(
    proxyPixels: CGSize(width: 4000, height: 3000), viewport: CGSize(width: 400, height: 300),
    displayScale: 2)
  /// 1200×1600 px in the same viewport: fitted 225×300, 1:1 at 1200 / 450 = 2.67× fit.
  private let portrait = Geometry(
    proxyPixels: CGSize(width: 1200, height: 1600), viewport: CGSize(width: 400, height: 300),
    displayScale: 2)

  private func makeSync() -> CompareZoomSync {
    var sync = CompareZoomSync()
    sync.show(left: 1, right: 2)
    sync.updateGeometry(.left, landscape)
    sync.updateGeometry(.right, portrait)
    return sync
  }

  private func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }

  @Test("The two geometries really are unequal")
  func geometriesDiffer() {
    #expect(approx(landscape.maxScale, 5))
    #expect(approx(portrait.maxScale, 1200.0 / 450.0))
  }

  @Test("A pinch is shared as a multiple of fit; each pane clamps to its own ceiling")
  func relativeMagnificationWithPerPaneCeiling() {
    var sync = makeSync()
    sync.magnify(.left, to: 2)
    #expect(approx(sync.rendered(.left).scale, 2))
    #expect(approx(sync.rendered(.right).scale, 2))
    sync.magnify(.left, to: 4)
    sync.endMagnify()
    #expect(approx(sync.rendered(.left).scale, 4))
    #expect(sync.rendered(.right).scale == portrait.maxScale)
    #expect(sync.magnificationDescription(.right) == "100 %")
    #expect(sync.magnificationDescription(.left) == "80 %")
  }

  @Test("100% puts EACH pane at its own 1:1; Fit brings both back")
  func oneToOneAndFit() {
    var sync = makeSync()
    sync.zoomToOneToOne()
    #expect(sync.rendered(.left).scale == landscape.maxScale)
    #expect(sync.rendered(.right).scale == portrait.maxScale)
    sync.resetToFit()
    #expect(sync.rendered(.left) == CompareZoomSync.Rendered(scale: 1, offset: .zero))
    #expect(sync.rendered(.right) == CompareZoomSync.Rendered(scale: 1, offset: .zero))
  }

  @Test("Pan is shared as a fraction of each pane's own range, and clamps per pane")
  func normalisedPanWithPerPaneLimits() {
    var sync = makeSync()
    sync.magnify(.left, to: 2)
    sync.endMagnify()
    // At 2×: left overflows (800−400)/2 = 200 by (600−300)/2 = 150; right (450−400)/2 = 25 by 150.
    sync.pan(.left, by: CGSize(width: 100, height: 75))
    sync.endPan()
    let left = sync.rendered(.left).offset
    let right = sync.rendered(.right).offset
    #expect(approx(left.width, 100) && approx(left.height, 75))
    #expect(approx(right.width, 12.5) && approx(right.height, 75))

    sync.pan(.right, by: CGSize(width: 1000, height: -1000))
    sync.endPan()
    #expect(approx(sync.rendered(.left).offset.width, 200))
    #expect(approx(sync.rendered(.left).offset.height, -150))
    #expect(approx(sync.rendered(.right).offset.width, 25))
    #expect(approx(sync.rendered(.right).offset.height, -150))
  }

  @Test("Either pane's image changing resets both to fit")
  func imageChangeResetsBoth() {
    var sync = makeSync()
    sync.magnify(.left, to: 2)
    sync.endMagnify()
    sync.show(left: 1, right: 2)
    #expect(sync.isZoomed(.left))
    sync.show(left: 1, right: 3)
    #expect(!sync.isZoomed(.left))
    #expect(!sync.isZoomed(.right))
  }

  @Test("With sync off each pane zooms alone; turning it back on starts both at fit")
  func syncOff() {
    var sync = makeSync()
    sync.isSynced = false
    sync.magnify(.left, to: 3)
    sync.endMagnify()
    #expect(approx(sync.rendered(.left).scale, 3))
    #expect(sync.rendered(.right).scale == 1)
    sync.toggle(.right)
    #expect(sync.rendered(.right).scale == portrait.maxScale)
    #expect(approx(sync.rendered(.left).scale, 3))
    sync.isSynced = true
    #expect(!sync.isZoomed(.left))
    #expect(!sync.isZoomed(.right))
  }

  @Test("Double-tap while synced: 100% each, then back to fit")
  func toggleSynced() {
    var sync = makeSync()
    sync.toggle(.right)
    #expect(sync.rendered(.left).scale == landscape.maxScale)
    #expect(sync.rendered(.right).scale == portrait.maxScale)
    sync.toggle(.left)
    #expect(!sync.isZoomed(.left))
    #expect(!sync.isZoomed(.right))
  }
}
