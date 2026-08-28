import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// Diff-gate round 3, blocker 2: the recognizer's touch-type filter, the state-to-event mapper,
/// the geometry hit-test, and the store's own drag-routing/dedup are each independently tested
/// elsewhere (`PointerDragRecognizerTests`, `GridStoreTests`) — but none of those tests depended
/// on `GridView` actually ATTACHING the live gesture bridge to its view hierarchy. Deleting the
/// old bare `.gesture(PrimaryPointerDragGesture(...))` block left every one of those tests green.
///
/// This suite closes that gap: it substitutes a spy for `GridView.pointerGestureInstaller`,
/// evaluates `body`, and asserts the spy was actually invoked with the REAL production callbacks
/// — the one thing a unit test can prove about a SwiftUI gesture modifier without a live device.
/// Verified causally on the remote mirror per this phase's own doctrine: commenting out the
/// `pointerGestureInstaller.attach(...)` call site in `GridView.scrollArea` turned
/// `installerWasInvokedByBody` RED (installCount == 0); restoring it went green again.
@MainActor
@Suite(
  "GridView — live pointer-drag gesture is actually wired into body, not just present in source")
struct GridViewPointerGestureWiringTests {

  private func makeImage(id: Int, revision: String = "r0")
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = GridService(client: client)
    return (GridStore(service: service), transport)
  }

  @Test("body attaches the pointer-drag gesture through pointerGestureInstaller exactly once")
  func installerWasInvokedByBody() async {
    let (store, _) = makeStore()
    var view = GridView(store: store)

    var installCount = 0
    var capturedOnChanged: ((CGPoint) -> Void)?
    var capturedOnEnded: (() -> Void)?
    view.pointerGestureInstaller = PointerGestureInstaller { content, onChanged, onEnded in
      installCount += 1
      capturedOnChanged = onChanged
      capturedOnEnded = onEnded
      return content
    }

    _ = view.body

    #expect(installCount == 1)
    #expect(capturedOnChanged != nil)
    #expect(capturedOnEnded != nil)
  }

  @Test(
    "The installed onEnded callback is the REAL store.beginPointerDrag() -- it actually resets the drag session, not a no-op"
  )
  func installedOnEndedDrivesTheRealStore() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    var view = GridView(store: store)
    var capturedOnEnded: (() -> Void)?
    view.pointerGestureInstaller = PointerGestureInstaller { content, _, onEnded in
      capturedOnEnded = onEnded
      return content
    }
    _ = view.body
    #expect(capturedOnEnded != nil)

    store.pickLock.forceLatch()
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    let callsBefore = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    await store.pointerDragCrossed(1)  // first crossing of id 1 in this drag session -- applies
    let callsAfterFirstCross = await transport.callCount(
      Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterFirstCross == callsBefore + 1)

    await store.pointerDragCrossed(1)  // re-crossing the SAME id, SAME session -- deduped
    let callsAfterReCross = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterReCross == callsAfterFirstCross)  // no new call: dedup is still in effect

    capturedOnEnded?()  // must be the real store.beginPointerDrag(), starting a FRESH session
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])))
    await store.pointerDragCrossed(1)  // same id, but a NEW session -- not deduped this time
    let callsAfterReset = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterReset == callsAfterReCross + 1)
  }
}
