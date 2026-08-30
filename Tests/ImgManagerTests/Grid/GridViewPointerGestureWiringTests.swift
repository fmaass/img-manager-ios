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
/// This suite closes that gap in two layers: it substitutes a spy for
/// `GridView.pointerGestureInstaller`, evaluates `body`, and asserts the spy was actually invoked
/// with the REAL production callbacks (the call-site layer); and it exercises the production
/// `.live` factory itself, reflectively asserting the real gesture lands in the returned tree
/// with the given callbacks forwarded (the installer layer — round-4 delta blocker).
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
    var view = GridView(store: store, layoutMode: .compact)

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

    var view = GridView(store: store, layoutMode: .compact)
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
    // first crossing of id 1 in this drag session -- applies
    await store.pointerDragCrossed(.image(1))
    let callsAfterFirstCross = await transport.callCount(
      Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterFirstCross == callsBefore + 1)

    await store.pointerDragCrossed(.image(1))  // re-crossing the SAME id, SAME session -- deduped
    let callsAfterReCross = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterReCross == callsAfterFirstCross)  // no new call: dedup is still in effect

    capturedOnEnded?()  // must be the real store.beginPointerDrag(), starting a FRESH session
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])))
    // same id, but a NEW session -- not deduped this time
    await store.pointerDragCrossed(.image(1))
    let callsAfterReset = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterReset == callsAfterReCross + 1)
  }

  #if canImport(UIKit)
    /// Diff-gate round 4, the surviving blocker: the spy-based tests above prove `body` invokes
    /// AN installer with working callbacks, but nothing ever exercised `.live`'s own body —
    /// gutting the real `.gesture(...)` attachment inside `.live` (returning the view
    /// unmodified) left every test green, the round-2 fake-test failure mode reintroduced one
    /// layer down. This test closes that gap at the only seam a unit test can reach without a
    /// render host: it invokes the production `.live` factory directly and reflects over the
    /// view tree it returns. If `.live` stops attaching `PrimaryPointerDragGesture`, the walk
    /// finds nothing; if it stops forwarding the exact closures it was handed, invoking the
    /// found gesture's callbacks no longer reaches ours.
    @Test(".live attaches the real PrimaryPointerDragGesture and forwards the exact callbacks")
    func liveInstallerAttachesTheRealGesture() {
      var changedPoints: [CGPoint] = []
      var endedCount = 0
      let attached = PointerGestureInstaller.live.attach(
        AnyView(Color.clear), { changedPoints.append($0) }, { endedCount += 1 })

      let gesture = firstPrimaryPointerDragGesture(in: attached)
      #expect(gesture != nil)

      // Two probe points with no coordinate value in common (round-5 delta blocker): a single
      // fixed point cannot distinguish exact forwarding from a transform that happens to fix
      // one coordinate at the probed value — with distinct x AND y across both probes, any
      // hardcoded or partial coordinate mapping inside `.live` fails the sequence equality.
      gesture?.onChanged(CGPoint(x: 3, y: 4))
      gesture?.onChanged(CGPoint(x: -7.5, y: 12.25))
      #expect(changedPoints == [CGPoint(x: 3, y: 4), CGPoint(x: -7.5, y: 12.25)])
      #expect(endedCount == 0)
      gesture?.onEnded()
      #expect(endedCount == 1)
    }

    /// Depth-capped reflective search for the gesture value inside an `AnyView`-erased SwiftUI
    /// view tree. Reflection is the only way to see through `AnyView` without rendering; the
    /// cap bounds the walk in case SwiftUI's internal shape ever grows a cycle.
    private func firstPrimaryPointerDragGesture(
      in value: Any, depth: Int = 0
    ) -> PrimaryPointerDragGesture? {
      if let gesture = value as? PrimaryPointerDragGesture { return gesture }
      guard depth < 16 else { return nil }
      for child in Mirror(reflecting: value).children {
        if let found = firstPrimaryPointerDragGesture(in: child.value, depth: depth + 1) {
          return found
        }
      }
      return nil
    }
  #endif
}
