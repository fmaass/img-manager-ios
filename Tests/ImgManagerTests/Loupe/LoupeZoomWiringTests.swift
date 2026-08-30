import CoreGraphics
import Foundation
import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// Shared fixtures for the loupe-zoom view-layer suites below.
@MainActor
enum LoupeZoomFixtures {
  static func image(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "arw", filename: "img\(id).arw", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  static func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  static func makeShare(_ transport: GridStubTransport) -> ShareExportStore {
    ShareExportStore(service: GridService(client: ImgManagerAPIClient.make(transport: transport)))
  }

  /// A loaded shoot with `count` photographs, with the loupe open on the first.
  static func loadedStore(count: Int = 2) async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: (1...count).map { image(id: $0) }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    return (store, transport)
  }

  /// Phone geometry with real headroom against a 1600x1067 preview (the phase's probe measured
  /// every deployed preview at exactly that size).
  static func phoneGeometry(_ model: LoupeZoomModel) {
    model.state.updateGeometry(
      proxyPixels: CGSize(width: 1600, height: 1067),
      viewport: CGSize(width: 400, height: 800), displayScale: 2)
  }
}

/// Records every id `LoupeView` routes through the reset seam, and still performs the real reset
/// so the view under test behaves normally.
@MainActor
final class FrameChangeSpy {
  var seenIDs: [Int?] = []

  var installer: LoupeZoomInstaller {
    LoupeZoomInstaller { state, imageID in
      MainActor.assumeIsolated { self.seenIDs.append(imageID) }
      state.focus(on: imageID)
    }
  }
}

/// Captures what each zoom SURFACE was handed by `body`.
@MainActor
final class LoupeZoomControlsSpy {
  var controlToggle: (() -> Void)?
  var handlers: LoupeZoomGestureHandlers?
  var controlModels: [LoupeZoomControlModel] = []

  var controls: LoupeZoomControls {
    LoupeZoomControls(
      makeToggleControl: { model, onToggle in
        self.controlModels.append(model)
        self.controlToggle = onToggle
        return AnyView(EmptyView())
      },
      attachGestures: { content, handlers in
        self.handlers = handlers
        return content
      })
  }
}

/// Reset gate, leg 3 (the call site). Leg 1 pins the semantics and leg 2 pins the production
/// `.live`; neither notices a `LoupeView` that simply never asks. Following
/// `GridViewPointerGestureWiringTests`' causal doctrine, the call site was commented out on the
/// remote mirror and this test observed RED, then restored and observed green — both runs are
/// recorded in `.phase-ledger.md`.
@MainActor
@Suite("LoupeView — body routes the focused frame through the zoom installer")
struct LoupeZoomWiringTests {
  @Test("body routes a focus change into the installer")
  func bodyRoutesAFocusChangeIntoTheInstaller() async {
    let (store, transport) = await LoupeZoomFixtures.loadedStore()
    let spy = FrameChangeSpy()
    var view = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport))
    view.zoomInstaller = spy.installer

    _ = view.body

    #expect(spy.seenIDs.isEmpty == false)
    #expect(spy.seenIDs.allSatisfy { $0 == 1 })

    // ... and the id it routes is the CURRENTLY focused one, not a captured constant.
    store.loupeFocus(on: 2)
    spy.seenIDs.removeAll()
    _ = view.body
    #expect(spy.seenIDs.isEmpty == false)
    #expect(spy.seenIDs.allSatisfy { $0 == 2 })
  }

  @Test("a frame change resets a zoomed loupe back to fit")
  func aFrameChangeResetsAZoomedLoupeBackToFit() async {
    let (store, transport) = await LoupeZoomFixtures.loadedStore()
    let model = LoupeZoomModel()
    LoupeZoomFixtures.phoneGeometry(model)
    var view = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport),
      zoomModel: model)
    let spy = LoupeZoomControlsSpy()
    view.zoomControls = spy.controls

    _ = view.body
    spy.controlToggle?()
    #expect(model.state.scale > 1)

    store.loupeFocus(on: 2)
    #expect(view.resolvedZoom.scale == 1)
    #expect(view.resolvedZoom.offset == .zero)
  }
}

/// The view-layer contract: one toggle behind two surfaces, the drag arbitration, and the tier
/// the loupe asks for at any magnification.
@MainActor
@Suite("LoupeView — zoom surfaces, drag arbitration and the preview-only tier")
struct LoupeViewTests {
  @Test("the double-tap and the chrome control invoke the same toggle")
  func doubleTapAndTheChromeControlInvokeTheSameToggle() async {
    let (store, transport) = await LoupeZoomFixtures.loadedStore()
    let model = LoupeZoomModel()
    LoupeZoomFixtures.phoneGeometry(model)
    var view = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport),
      zoomModel: model)
    let spy = LoupeZoomControlsSpy()
    view.zoomControls = spy.controls

    _ = view.body
    #expect(spy.controlToggle != nil)
    #expect(spy.handlers != nil)
    // The chrome twin is built in every layout mode, Compact included.
    #expect(spy.controlModels.isEmpty == false)
    #expect(spy.controlModels.allSatisfy { $0.isAvailable })

    let start = model.state
    spy.controlToggle?()
    let afterControl = model.state

    model.state = start
    spy.handlers?.onToggle()
    let afterDoubleTap = model.state

    #expect(afterControl == afterDoubleTap)
    // Positive control: they are not two no-ops agreeing with each other.
    #expect(afterControl != start)
    #expect(afterControl.scale > 1)
    #expect(abs(afterControl.scale - afterControl.oneToOneScale) < 0.001)
  }

  @Test("a horizontal drag advances at fit and pans when zoomed")
  func aHorizontalDragAdvancesAtFitAndPansWhenZoomed() async {
    let (store, transport) = await LoupeZoomFixtures.loadedStore()
    let model = LoupeZoomModel()
    LoupeZoomFixtures.phoneGeometry(model)
    var view = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport),
      zoomModel: model)
    let spy = LoupeZoomControlsSpy()
    view.zoomControls = spy.controls
    _ = view.body
    #expect(spy.handlers != nil)

    // At fit: the shipped advance, unchanged (-100 pt crosses the same +/-30 pt threshold).
    #expect(store.focusedImageID == 1)
    spy.handlers?.onDragEnded(CGSize(width: -100, height: 0))
    var advanced = false
    for _ in 0..<500 where !advanced {
      if store.focusedImageID == 2 { advanced = true } else { await Task.yield() }
    }
    #expect(advanced)
    #expect(model.state.offset == .zero)

    // Zoomed: the same drag PANS and must not move the frame.
    spy.controlToggle?()
    #expect(model.state.scale > 1)
    spy.handlers?.onDragEnded(CGSize(width: -100, height: 0))
    #expect(model.state.offset.width < 0)
    #expect(store.focusedImageID == 2)
  }

  @Test("the loupe never requests anything but the preview tier, at any zoom")
  func theLoupeNeverRequestsAnythingButThePreviewTier() async {
    let (store, transport) = await LoupeZoomFixtures.loadedStore()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    let model = LoupeZoomModel()
    LoupeZoomFixtures.phoneGeometry(model)
    var view = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport),
      zoomModel: model)
    let spy = LoupeZoomControlsSpy()
    view.zoomControls = spy.controls
    _ = view.body

    await view.loadMainImage()
    spy.controlToggle?()
    #expect(model.state.scale > 1)
    store.loupeFocus(on: 2)
    await view.loadMainImage()
    spy.handlers?.onMagnify(1.4)

    let tiers = await transport.recordedProxyTiers
    // Positive control: the recorder really saw the loupe's own request — a 0-hit "no grid tier"
    // claim over an empty list would prove nothing.
    #expect(tiers.isEmpty == false)
    #expect(tiers.allSatisfy { $0 == ProxyTier.preview.rawValue })
    #expect(tiers.contains(ProxyTier.grid.rawValue) == false)
    let downloads = await transport.callCount(
      Operations.DownloadImageApiImagesImageIdDownloadGet.id)
    #expect(downloads == 0)
  }
}
