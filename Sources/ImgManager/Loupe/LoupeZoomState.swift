import CoreGraphics
import SwiftUI

/// The loupe's zoom, as a pure value: everything the sharpness check needs to decide is decided
/// here, so it is falsifiable without a render host.
///
/// ## The pixel ceiling, stated in the type
///
/// The largest proxy this backend renders is `preview`, 1600 px on the long edge (deployed edges
/// probed 2026-08-30: `PROXY_GRID_EDGE=400`, `PROXY_PREVIEW_EDGE=1600`). A 60 MP original is
/// 9504x6336, so the preview carries ~17 % of the original's linear resolution. Magnification
/// here is therefore **proxy-limited**: `oneToOneScale` is 1:1 against the PROXY, never against
/// the original, and there is no cap above it — past 1:1 there is no pixel the proxy has, so
/// showing more would be empty magnification that implies a fidelity the app cannot deliver.
///
/// When `oneToOneScale <= 1` the proxy is already upscaled just to fill the fitted extent; zoom
/// is then **unavailable** (`isZoomAvailable == false`), the chrome control renders disabled and
/// the gestures are inert. That is a legitimate outcome, not a bug.
///
/// ## Why the ceiling is derived from the FITTED extent, never the viewport
///
/// The image renders `.aspectRatio(contentMode: .fit)` inside a viewport-sized frame, so the
/// pixels on screen occupy the FITTED rect, not the viewport. A 1600x1067 landscape proxy in a
/// 400x800 pt @2x portrait viewport fits to 400x267 pt = 800 device px for 1600 proxy px, so 1:1
/// is scale **2.0** — while `proxyLongEdge / (viewportLongEdge * displayScale)` computes
/// `1600 / (800 * 2) = 1.0` and disables zoom outright. The cross-orientation case is the common
/// one on a phone, which is exactly why the viewport formula is wrong.
struct LoupeZoomState: Equatable, Sendable {
  /// Magnification against the fitted extent. `1` is fit; `oneToOneScale` is 1:1 on the proxy.
  private(set) var scale: CGFloat = 1
  /// Pan, in points, of the scaled image relative to its centred fitted position.
  private(set) var offset: CGSize = .zero
  /// The photograph this zoom belongs to. `focus(on:)` resets whenever it changes.
  private(set) var focusedImageID: Int?
  /// Real pixel dimensions of the decoded proxy (not points).
  private(set) var proxyPixels: CGSize = .zero
  /// The image area the proxy is fitted into, in points.
  private(set) var viewport: CGSize = .zero
  /// Device pixels per point.
  private(set) var displayScale: CGFloat = 1

  /// Gesture anchors: the value a continuous gesture started from. Separate per gesture so a
  /// simultaneous pinch and drag cannot consume each other's baseline.
  private var pinchAnchorScale: CGFloat?
  private var panAnchorOffset: CGSize?

  // MARK: - Pure geometry

  /// The rect a uniform `.fit` actually renders into — NOT the viewport.
  static func fittedExtent(proxy: CGSize, viewport: CGSize) -> CGSize {
    guard proxy.width > 0, proxy.height > 0, viewport.width > 0, viewport.height > 0 else {
      return .zero
    }
    let factor = min(viewport.width / proxy.width, viewport.height / proxy.height)
    return CGSize(width: proxy.width * factor, height: proxy.height * factor)
  }

  /// The magnification at which one proxy pixel covers exactly one device pixel. Equal on both
  /// axes under a uniform fit, so either axis answers; `theTwoAxesAgreeUnderAUniformFit` pins it.
  static func oneToOneScale(proxyPixels: CGSize, fitted: CGSize, displayScale: CGFloat)
    -> CGFloat
  {
    guard proxyPixels.width > 0, fitted.width > 0, displayScale > 0 else { return 1 }
    return proxyPixels.width / (fitted.width * displayScale)
  }

  /// Clamps pan so the scaled image never detaches from the viewport: along an axis where the
  /// scaled image is larger than the viewport it may travel only until its own edge reaches the
  /// viewport edge; along an axis where it is smaller it stays centred (no free-floating image).
  static func clampedOffset(_ offset: CGSize, fitted: CGSize, viewport: CGSize, scale: CGFloat)
    -> CGSize
  {
    let scaledWidth = fitted.width * scale
    let scaledHeight = fitted.height * scale
    let limitX = max(0, (scaledWidth - viewport.width) / 2)
    let limitY = max(0, (scaledHeight - viewport.height) / 2)
    return CGSize(
      width: min(max(offset.width, -limitX), limitX),
      height: min(max(offset.height, -limitY), limitY))
  }

  // MARK: - Derived

  var fittedExtent: CGSize { Self.fittedExtent(proxy: proxyPixels, viewport: viewport) }

  var oneToOneScale: CGFloat {
    Self.oneToOneScale(
      proxyPixels: proxyPixels, fitted: fittedExtent, displayScale: displayScale)
  }

  /// The ceiling. Exactly 1:1 against the proxy, never an arbitrary multiple.
  var maxScale: CGFloat { max(1, oneToOneScale) }

  var isZoomAvailable: Bool { oneToOneScale > 1 }

  var isZoomed: Bool { scale > 1 }

  // MARK: - Mutations

  /// Re-states the geometry after a layout or image change and re-clamps whatever was already
  /// applied — a viewport that grew can put the current scale above the new ceiling.
  mutating func updateGeometry(proxyPixels: CGSize, viewport: CGSize, displayScale: CGFloat) {
    self.proxyPixels = proxyPixels
    self.viewport = viewport
    self.displayScale = displayScale
    scale = min(max(scale, 1), maxScale)
    offset = Self.clampedOffset(offset, fitted: fittedExtent, viewport: viewport, scale: scale)
  }

  /// THE zoom action: fit if zoomed, 1:1 if not. The double-tap and the chrome control both call
  /// exactly this — there is no second target value anywhere, so "100 %" cannot come to mean two
  /// different things in the two places.
  mutating func toggle() {
    guard isZoomAvailable else { return }
    scale = isZoomed ? 1 : oneToOneScale
    offset = .zero
    pinchAnchorScale = nil
    panAnchorOffset = nil
  }

  /// Continuous pinch. `magnification` is the gesture's cumulative factor since it began, so the
  /// anchor is captured on the first change and the scale is always anchor x magnification.
  mutating func magnify(to magnification: CGFloat) {
    guard isZoomAvailable else { return }
    let anchor = pinchAnchorScale ?? scale
    pinchAnchorScale = anchor
    scale = min(max(anchor * magnification, 1), maxScale)
    offset = Self.clampedOffset(offset, fitted: fittedExtent, viewport: viewport, scale: scale)
  }

  mutating func endMagnify() { pinchAnchorScale = nil }

  /// Continuous pan, cumulative translation since the drag began. Inert at fit — at fit a
  /// horizontal drag is the shipped prev/next advance, and `dragOutcome` is where that is decided.
  mutating func pan(to translation: CGSize) {
    guard isZoomed else { return }
    let anchor = panAnchorOffset ?? offset
    panAnchorOffset = anchor
    offset = Self.clampedOffset(
      CGSize(width: anchor.width + translation.width, height: anchor.height + translation.height),
      fitted: fittedExtent, viewport: viewport, scale: scale)
  }

  mutating func endPan() { panAnchorOffset = nil }

  /// Reset on frame change, owned in the pure type so a unit test can drive it: any id other than
  /// the one this state holds returns it to fit with no pan. Deleting the reset turns
  /// `focusOnADifferentImageIdResetsScaleAndOffset` RED.
  mutating func focus(on imageID: Int?) {
    guard imageID != focusedImageID else { return }
    focusedImageID = imageID
    scale = 1
    offset = .zero
    pinchAnchorScale = nil
    panAnchorOffset = nil
  }

  // MARK: - Gesture arbitration

  /// What a horizontal drag on the loupe image means. While zoomed it PANS; at fit it advances
  /// the frame exactly as the shipped loupe does (the same +/-30 pt threshold as
  /// `LoupeView.swift:144-153` before this phase). Stated as a pure function because gesture
  /// priority is not something a test can observe, and this is the invariant that would silently
  /// break the shipped app.
  enum DragOutcome: Equatable, Sendable {
    case pan(CGSize)
    case advanceNext
    case advancePrevious
    case ignored
  }

  static func dragOutcome(translation: CGSize, isZoomed: Bool, advanceThreshold: CGFloat = 30)
    -> DragOutcome
  {
    if isZoomed { return .pan(translation) }
    if translation.width < -advanceThreshold { return .advanceNext }
    if translation.width > advanceThreshold { return .advancePrevious }
    return .ignored
  }
}

/// The production adapter for "reset on frame change", as a plain VALUE rather than a
/// view-wrapping closure: a spy-only wiring test proves `body` invokes *an* installer, and a
/// no-op `.live` would leave that green while zoom survived every frame change. The repo learned
/// this one layer down already — see
/// `Tests/ImgManagerTests/Grid/GridViewPointerGestureWiringTests.swift:107-137`. So `.live` is
/// itself exercised by `LoupeZoomInstallerTests.liveApplyFrameChangeResetsARealZoomState`.
struct LoupeZoomInstaller: Sendable {
  var applyFrameChange: @Sendable (inout LoupeZoomState, Int?) -> Void

  static let live = LoupeZoomInstaller { state, imageID in state.focus(on: imageID) }
}

/// What the chrome twin needs to render itself, derived from the zoom state — never from a device
/// idiom and never from a second, independent geometry computation.
struct LoupeZoomControlModel: Equatable, Sendable {
  var isAvailable: Bool
  var isZoomed: Bool

  /// "Fit" when zoomed (what tapping does next), "100 %" when at fit. Both are 1:1 against the
  /// PROXY — no string here claims original-resolution fidelity.
  var title: String { isZoomed ? "Fit" : "100 %" }

  var accessibilityHint: String {
    isAvailable
      ? "Toggles between fitting the photograph and viewing it at 100 % of the preview proxy."
      : "Unavailable: the preview proxy is already enlarged to fill this view, so there is no "
        + "further detail to show."
  }
}

extension LoupeZoomControlModel {
  init(_ zoom: LoupeZoomState) {
    self.init(isAvailable: zoom.isZoomAvailable, isZoomed: zoom.isZoomed)
  }
}

/// The handlers the loupe's image-area gestures route into. One `onToggle` value is built once in
/// `LoupeView.body` and handed to BOTH surfaces — this struct and the chrome control — which is
/// what makes "double-tap and the chrome control are the same action" true by construction rather
/// than by convention.
@MainActor
struct LoupeZoomGestureHandlers {
  var onToggle: () -> Void
  var onMagnify: (CGFloat) -> Void
  var onMagnifyEnded: () -> Void
  var onDrag: (CGSize) -> Void
  var onDragEnded: (CGSize) -> Void
}

/// Injectable factory for the loupe's zoom SURFACES, in the shape of
/// `GridView.pointerGestureInstaller` (`GridView.swift:18-24`): `.live` is the only one the
/// running app uses; a test substitutes a spy, evaluates `body`, and captures the closures each
/// surface was actually handed.
@MainActor
struct LoupeZoomControls {
  /// The chrome twin: a >=44x44 Fit / 100 % button. Zoom is never gesture-only.
  var makeToggleControl: (LoupeZoomControlModel, @escaping () -> Void) -> AnyView
  /// Pinch + double-tap + the dual-purpose drag, attached to the image area.
  var attachGestures: (AnyView, LoupeZoomGestureHandlers) -> AnyView

  static let live = LoupeZoomControls(
    makeToggleControl: { model, onToggle in
      AnyView(
        Button(action: onToggle) {
          Text(model.title)
            .font(.caption)
            .monospacedDigit()
        }
        .disabled(!model.isAvailable)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("loupeZoomToggle")
        .accessibilityLabel("Zoom")
        .accessibilityValue(model.title)
        .accessibilityHint(model.accessibilityHint)
      )
    },
    attachGestures: { content, handlers in
      AnyView(
        content
          .onTapGesture(count: 2) { handlers.onToggle() }
          .gesture(
            DragGesture(minimumDistance: 10)
              .onChanged { handlers.onDrag($0.translation) }
              .onEnded { handlers.onDragEnded($0.translation) }
          )
          .simultaneousGesture(
            MagnifyGesture()
              .onChanged { handlers.onMagnify($0.magnification) }
              .onEnded { _ in handlers.onMagnifyEnded() }
          )
      )
    })
}

/// Reference-typed owner of the zoom value so `LoupeView` can hold it in `@State` (a plain
/// stored property would be replaced — and the zoom lost — on every parent re-evaluation) while
/// tests can inject one instance and observe what the view's own call sites did to it.
@MainActor
@Observable
final class LoupeZoomModel {
  var state = LoupeZoomState()
  init() {}
}
