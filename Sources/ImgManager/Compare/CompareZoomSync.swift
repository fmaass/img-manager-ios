import CoreGraphics

/// WP30 P3 (IMGMGR-458): zoom for Compare's two panes. NOT one `LoupeZoomModel` shared by both:
/// that model is keyed to one image and resets on every id change (`LoupeZoomState.focus(on:)`),
/// and two panes show two images of different geometry.
///
/// What is shared is RELATIVE: magnification as a multiple of each pane's own fit scale (the
/// same unit `LoupeZoomState.scale` uses, 1 = fit), and pan as a fraction of each pane's own
/// pannable range (-1…1 per axis). Each pane then clamps to its OWN ceiling (its 1:1 scale,
/// `LoupeZoomState.maxScale`) and its own pan limits (`LoupeZoomState.clampedOffset`), so a
/// small proxy beside a large one stops at its own 100 % while the other keeps going.
///
/// Synced by default. With sync off each pane zooms alone; turning sync back on starts both at
/// fit. Either pane's image changing resets both to fit.
struct CompareZoomSync: Equatable, Sendable {
  enum Pane: CaseIterable, Hashable, Sendable {
    case left
    case right
  }

  /// One pane's geometry, as `LoupeZoomState.updateGeometry` takes it.
  struct Geometry: Equatable, Sendable {
    var proxyPixels: CGSize = .zero
    var viewport: CGSize = .zero
    var displayScale: CGFloat = 1

    var fitted: CGSize { LoupeZoomState.fittedExtent(proxy: proxyPixels, viewport: viewport) }

    /// This pane's own ceiling: its 1:1 scale, never below fit.
    var maxScale: CGFloat {
      let oneToOne = LoupeZoomState.oneToOneScale(
        proxyPixels: proxyPixels, fitted: fitted, displayScale: displayScale)
      return max(1, oneToOne)
    }

    /// Half the overflow per axis at `scale`: the most an offset can move either way.
    func panLimit(at scale: CGFloat) -> CGSize {
      let fitted = self.fitted
      let width = max(0, (fitted.width * scale - viewport.width) / 2)
      let height = max(0, (fitted.height * scale - viewport.height) / 2)
      return CGSize(width: width, height: height)
    }
  }

  /// A relative zoom: scale as a multiple of fit, pan as a fraction of the pannable range.
  struct Relative: Equatable, Sendable {
    var scale: CGFloat = 1
    var pan: CGSize = .zero
  }

  /// What one pane draws.
  struct Rendered: Equatable, Sendable {
    let scale: CGFloat
    let offset: CGSize

    var isZoomed: Bool { scale > 1 }
  }

  var isSynced = true {
    didSet {
      guard isSynced != oldValue else { return }
      if isSynced {
        resetToFit()
      } else {
        // Each pane keeps what it was drawing: the shared value, until it is moved alone.
        for pane in Pane.allCases { own[pane] = shared }
      }
    }
  }

  private(set) var images: [Pane: Int] = [:]
  private(set) var geometries: [Pane: Geometry] = [:]
  private var shared = Relative()
  private var own: [Pane: Relative] = [:]
  private var pinchAnchor: CGFloat?
  private var panAnchor: CGSize?

  // MARK: - Inputs

  /// The panes' images. A change on either side resets BOTH to fit.
  mutating func show(left: Int?, right: Int?) {
    let pairs: [Pane: Int?] = [.left: left, .right: right]
    let next = pairs.compactMapValues { $0 }
    guard next != images else { return }
    images = next
    resetToFit()
  }

  mutating func updateGeometry(_ pane: Pane, _ newGeometry: Geometry) {
    geometries[pane] = newGeometry
  }

  // MARK: - Gestures and commands

  /// A pinch on `pane`, anchored on the scale that pane showed when the pinch began.
  mutating func magnify(_ pane: Pane, to magnification: CGFloat) {
    let anchor = pinchAnchor ?? rendered(pane).scale
    pinchAnchor = anchor
    let ceiling = geometry(of: pane).maxScale
    let scale = min(max(anchor * magnification, 1), ceiling)
    write(pane) { $0.scale = scale }
  }

  mutating func endMagnify() { pinchAnchor = nil }

  /// A drag on a zoomed `pane`: the translation in that pane's points, converted to a fraction
  /// of that pane's pannable range, so the other pane moves by the same FRACTION of its own.
  mutating func pan(_ pane: Pane, by translation: CGSize) {
    let current = relative(of: pane)
    let anchor = panAnchor ?? current.pan
    panAnchor = anchor
    let limit = geometry(of: pane).panLimit(at: rendered(pane).scale)
    let dx = limit.width > 0 ? translation.width / limit.width : 0
    let dy = limit.height > 0 ? translation.height / limit.height : 0
    let x = min(max(anchor.width + dx, -1), 1)
    let y = min(max(anchor.height + dy, -1), 1)
    let pan = CGSize(width: x, height: y)
    write(pane) { $0.pan = pan }
  }

  mutating func endPan() { panAnchor = nil }

  /// More › Fit: both panes at fit.
  mutating func resetToFit() {
    shared = Relative()
    own = [:]
    pinchAnchor = nil
    panAnchor = nil
  }

  /// More › 100%: each pane at its OWN 1:1 (the shared relative scale is the larger ceiling, and
  /// each pane clamps it to its own).
  mutating func zoomToOneToOne() {
    pinchAnchor = nil
    panAnchor = nil
    if isSynced {
      let ceilings = Pane.allCases.map { geometry(of: $0).maxScale }
      shared = Relative(scale: ceilings.max() ?? 1)
    } else {
      for pane in Pane.allCases { own[pane] = Relative(scale: geometry(of: pane).maxScale) }
    }
  }

  /// Double-tap on `pane`: back to fit when anything is zoomed, else 100 %.
  mutating func toggle(_ pane: Pane) {
    if isSynced {
      if Pane.allCases.contains(where: { rendered($0).isZoomed }) {
        resetToFit()
      } else {
        zoomToOneToOne()
      }
    } else if rendered(pane).isZoomed {
      own[pane] = Relative()
    } else {
      own[pane] = Relative(scale: geometry(of: pane).maxScale)
    }
  }

  // MARK: - Output

  /// What `pane` draws: the relative zoom clamped to that pane's own ceiling and pan limits.
  func rendered(_ pane: Pane) -> Rendered {
    let paneGeometry = geometry(of: pane)
    let zoom = relative(of: pane)
    let scale = min(max(zoom.scale, 1), paneGeometry.maxScale)
    let limit = paneGeometry.panLimit(at: scale)
    let offset = CGSize(width: zoom.pan.width * limit.width, height: zoom.pan.height * limit.height)
    return Rendered(scale: scale, offset: offset)
  }

  /// Whether any pane is zoomed (the right pane's swipe steps only at fit).
  func isZoomed(_ pane: Pane) -> Bool { rendered(pane).isZoomed }

  /// "fit" or "N %" of that pane's own 1:1, for the pane's accessibility value.
  func magnificationDescription(_ pane: Pane) -> String {
    let drawn = rendered(pane)
    guard drawn.isZoomed else { return "fit" }
    let percent = Int((drawn.scale / geometry(of: pane).maxScale * 100).rounded())
    return "\(percent) %"
  }

  // MARK: - Private

  private func geometry(of pane: Pane) -> Geometry { geometries[pane] ?? Geometry() }

  private func relative(of pane: Pane) -> Relative {
    isSynced ? shared : (own[pane] ?? Relative())
  }

  private mutating func write(_ pane: Pane, _ change: (inout Relative) -> Void) {
    if isSynced {
      change(&shared)
    } else {
      var value = own[pane] ?? Relative()
      change(&value)
      own[pane] = value
    }
  }
}
