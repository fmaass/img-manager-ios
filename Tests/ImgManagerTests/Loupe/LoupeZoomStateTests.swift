import CoreGraphics
import Testing

@testable import ImgManager

/// The pure half of WP13 P3 (IMGMGR-213). Everything the sharpness check decides — the ceiling,
/// its availability, pan clamping, the toggle and the frame-change reset — is decided in
/// `LoupeZoomState`, so it is falsifiable here without a render host.
///
/// The ceiling numbers below are not invented: the deployed backend renders `preview` at 1600 px
/// on the long edge (probed 2026-08-30 through the running container), and the phase's own live
/// probe measured 16 real deployed previews at exactly 1600x1067 px.
@Suite("LoupeZoomState — proxy-limited ceiling, pan clamping, frame-change reset")
struct LoupeZoomStateTests {
  private static let proxy = CGSize(width: 1600, height: 1067)
  /// Portrait phone viewport, @2x — the cross-orientation case the viewport formula gets wrong.
  private static let phoneViewport = CGSize(width: 400, height: 800)

  private func phoneState() -> LoupeZoomState {
    var state = LoupeZoomState()
    state.updateGeometry(
      proxyPixels: Self.proxy, viewport: Self.phoneViewport, displayScale: 2)
    return state
  }

  @Test("1:1 is derived from the aspect-FITTED extent, never from the viewport")
  func oneToOneScaleIsDerivedFromTheAspectFittedExtentNotTheViewport() {
    let fitted = LoupeZoomState.fittedExtent(proxy: Self.proxy, viewport: Self.phoneViewport)
    #expect(abs(fitted.width - 400) < 0.001)
    #expect(abs(fitted.height - 266.75) < 0.01)

    let oneToOne = LoupeZoomState.oneToOneScale(
      proxyPixels: Self.proxy, fitted: fitted, displayScale: 2)
    #expect(abs(oneToOne - 2.0) < 0.001)

    // The formula this replaced, computed here so the test states what it is NOT: long edge over
    // viewport long edge x displayScale = 1600 / (800 x 2) = 1.0, which would disable zoom on the
    // commonest phone case outright.
    let viewportFormula =
      max(Self.proxy.width, Self.proxy.height)
      / (max(Self.phoneViewport.width, Self.phoneViewport.height) * 2)
    #expect(abs(viewportFormula - 1.0) < 0.001)
    #expect(abs(oneToOne - viewportFormula) > 0.5)
  }

  @Test("the two axes agree under a uniform fit")
  func theTwoAxesAgreeUnderAUniformFit() {
    let fitted = LoupeZoomState.fittedExtent(proxy: Self.proxy, viewport: Self.phoneViewport)
    let byWidth = LoupeZoomState.oneToOneScale(
      proxyPixels: Self.proxy, fitted: fitted, displayScale: 2)
    // The same function answers for the OTHER axis when both inputs are transposed.
    let byHeight = LoupeZoomState.oneToOneScale(
      proxyPixels: CGSize(width: Self.proxy.height, height: Self.proxy.width),
      fitted: CGSize(width: fitted.height, height: fitted.width), displayScale: 2)
    #expect(abs(byWidth - byHeight) < 0.0001)
    #expect(byWidth > 1)
  }

  @Test("zoom is unavailable and its control disabled when 1:1 is at or below fit")
  func zoomIsUnavailableAndTheControlDisabledWhenOneToOneIsAtOrBelowFit() {
    // A 13-inch iPad's full-screen loupe: 1032x1376 pt @2x fits the same proxy to 1032x688 pt =
    // 2064 device px for 1600 proxy px, so the proxy is ALREADY upscaled at fit.
    var upscaled = LoupeZoomState()
    upscaled.updateGeometry(
      proxyPixels: Self.proxy, viewport: CGSize(width: 1032, height: 1376), displayScale: 2)
    #expect(upscaled.oneToOneScale < 1)
    #expect(upscaled.isZoomAvailable == false)
    #expect(LoupeZoomControlModel(upscaled).isAvailable == false)

    upscaled.toggle()
    #expect(upscaled.scale == 1)
    upscaled.magnify(to: 3)
    #expect(upscaled.scale == 1)
    upscaled.pan(to: CGSize(width: 200, height: 200))
    #expect(upscaled.offset == .zero)

    // Positive control: the SAME proxy on the phone geometry does have headroom, so this test is
    // not passing because every state reports unavailable.
    let phone = phoneState()
    #expect(phone.isZoomAvailable)
    #expect(LoupeZoomControlModel(phone).isAvailable)
  }

  @Test("pan is clamped so the image never detaches from the viewport")
  func panIsClampedSoTheImageNeverDetachesFromTheViewport() {
    var state = phoneState()
    state.toggle()
    #expect(abs(state.scale - 2) < 0.001)

    let scaledWidth = state.fittedExtent.width * state.scale
    let limitX = (scaledWidth - Self.phoneViewport.width) / 2
    #expect(abs(limitX - 200) < 0.001)

    state.pan(to: CGSize(width: 10_000, height: 10_000))
    #expect(abs(state.offset.width - limitX) < 0.001)
    // The short axis is still smaller than the viewport even at 1:1 (533.5 pt < 800 pt), so it
    // stays centred rather than floating.
    #expect(state.offset.height == 0)

    state.endPan()
    state.pan(to: CGSize(width: -10_000, height: 0))
    #expect(abs(state.offset.width + limitX) < 0.001)
  }

  @Test("toggle goes fit -> 1:1 and back")
  func toggleGoesFitToOneToOneAndBack() {
    var state = phoneState()
    #expect(state.scale == 1)
    state.toggle()
    #expect(abs(state.scale - state.oneToOneScale) < 0.001)
    #expect(abs(state.scale - 2) < 0.001)
    state.pan(to: CGSize(width: 100, height: 0))
    #expect(state.offset != .zero)
    state.toggle()
    #expect(state.scale == 1)
    #expect(state.offset == .zero)
  }

  @Test("a continuous pinch is clamped to the fit..1:1 band")
  func magnifyIsClampedToTheBandBetweenFitAndOneToOne() {
    var state = phoneState()
    state.magnify(to: 1.5)
    #expect(abs(state.scale - 1.5) < 0.001)
    state.magnify(to: 8)
    #expect(abs(state.scale - state.oneToOneScale) < 0.001)
    state.magnify(to: 0.1)
    #expect(state.scale == 1)
    state.endMagnify()
  }

  @Test("focus on a different image id resets scale and offset")
  func focusOnADifferentImageIdResetsScaleAndOffset() {
    var state = phoneState()
    state.focus(on: 7)
    state.toggle()
    state.pan(to: CGSize(width: 120, height: 0))
    #expect(state.scale > 1)
    #expect(state.offset != .zero)

    // The SAME photograph is not a frame change — the reader's zoom survives a re-render.
    state.focus(on: 7)
    #expect(state.scale > 1)
    #expect(state.offset != .zero)

    state.focus(on: 8)
    #expect(state.scale == 1)
    #expect(state.offset == .zero)
    #expect(state.focusedImageID == 8)
  }

  @Test("a horizontal drag advances at fit and pans when zoomed (the pure decision)")
  func dragOutcomeSwitchesOnZoom() {
    #expect(
      LoupeZoomState.dragOutcome(translation: CGSize(width: -100, height: 0), isZoomed: false)
        == .advanceNext)
    #expect(
      LoupeZoomState.dragOutcome(translation: CGSize(width: 100, height: 0), isZoomed: false)
        == .advancePrevious)
    #expect(
      LoupeZoomState.dragOutcome(translation: CGSize(width: 10, height: 0), isZoomed: false)
        == .ignored)
    #expect(
      LoupeZoomState.dragOutcome(translation: CGSize(width: -100, height: 5), isZoomed: true)
        == .pan(CGSize(width: -100, height: 5)))
  }
}

/// Reset gate, leg 2 (plan amendment, diff-gate round 2): the PRODUCTION `.live` value, never a
/// spy. The repo already learned one layer down that a spy-observed seam leaves a hollow `.live`
/// green (`GridViewPointerGestureWiringTests.swift:107-137`); a `LoupeZoomInstaller.live` that
/// forgot `focus(on:)` — or mutated nothing — fails here.
@Suite("LoupeZoomInstaller — the production .live really resets a real zoom state")
struct LoupeZoomInstallerTests {
  @Test("live.applyFrameChange resets a real, zoomed-and-panned LoupeZoomState")
  func liveApplyFrameChangeResetsARealZoomState() {
    var state = LoupeZoomState()
    state.updateGeometry(
      proxyPixels: CGSize(width: 1600, height: 1067),
      viewport: CGSize(width: 400, height: 800), displayScale: 2)

    LoupeZoomInstaller.live.applyFrameChange(&state, 11)
    state.toggle()
    state.pan(to: CGSize(width: 150, height: 0))
    // Preconditions: this state really is zoomed to 1:1 and really is panned off centre, so the
    // assertions below cannot pass on a state that was never zoomed in the first place.
    #expect(abs(state.scale - state.oneToOneScale) < 0.001)
    #expect(state.scale > 1)
    #expect(state.offset != .zero)
    #expect(state.focusedImageID == 11)

    LoupeZoomInstaller.live.applyFrameChange(&state, 12)

    #expect(state.scale == 1)
    #expect(state.offset == .zero)
    #expect(state.focusedImageID == 12)
  }
}
