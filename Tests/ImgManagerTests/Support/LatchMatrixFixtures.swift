import Foundation
import ImgManagerAPI

@testable import ImgManager

/// IMGMGR-552 (R3 P18): the nine grid states the latch matrix runs every mark entry point in,
/// each built through the store's own entry points over a `GridStubTransport`. The builders are
/// copies of the private ones in `ScenePushTests`, `PeekBandStateTests` and
/// `GridStoreMarkGroupTests` (copied, not refactored, so no existing suite moves).
enum LatchState: String, CaseIterable, Sendable, CustomStringConvertible {
  case ungrouped, mark, rating, camera, band, scene, remainder, square, loupe

  var description: String {
    switch self {
    case .ungrouped: "S1 ungrouped"
    case .mark: "S2 Mark"
    case .rating: "S3 Rating"
    case .camera: "S4 Camera"
    case .band: "S5 band"
    case .scene: "S6 drilled scene"
    case .remainder: "S7 drilled remainder"
    case .square: "S8 square"
    case .loupe: "S9 loupe"
    }
  }
}

/// The six ways to mark a photograph the matrix crosses with every state.
enum LatchEntry: String, CaseIterable, Sendable, CustomStringConvertible {
  case latchPick, latchDislike, tapToPick, corner, keys, clear

  var description: String {
    switch self {
    case .latchPick: "E1 latch Pick"
    case .latchDislike: "E2 latch Dislike"
    case .tapToPick: "E3 Tap to Pick"
    case .corner: "E4 corner"
    case .keys: "E5 P/X"
    case .clear: "E6 Clear"
    }
  }
}

/// A built state and the photographs its entries aim at: `focus` is focused before a latch
/// button or a key, `tap` receives the latched tap, `corner` the quick-pick corner. Every id is
/// in the state's actionable pool, so a write to it is never dropped as unloaded.
struct LatchFixture {
  let store: GridStore
  let transport: GridStubTransport
  let focus: Int
  let tap: Int
  let corner: Int
  /// What the corner's one-shot writes on `corner`: Pick, or None when it is already picked.
  let cornerWrites: String
}

@MainActor
enum LatchMatrixFixtures {
  typealias Item = Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  typealias MarkPayload = Components.Schemas.MarkView.StatePayload

  static let markOp = Operations.SetMarkStateApiMarksStatePost.id

  static func image(_ id: Int, groupKey: String? = nil, mark: MarkStateValue = .none)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, groupKey: groupKey,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: MarkPayload(rawValue: mark.rawValue), tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  static func makeStore(startsWithTapToPick: Bool = false) -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let preferences = GridPreferences(defaults: makeEphemeralDefaults())
    // The loupe's cadence would move the focus after a committed loupe mark, so a P then an X
    // would name two photographs; the matrix asserts the write, not the cadence.
    preferences.autoAdvanceOnMark = false
    let store = GridStore(
      service: GridService(client: client), preferences: preferences,
      startsWithTapToPick: { startsWithTapToPick })
    return (store, transport)
  }

  /// Every mark write the transport has served, decoded, as `"<state>:<ids>"` — the UI probe's
  /// own vocabulary (`debugProbe.markRequests`).
  static func markWrites(_ transport: GridStubTransport) async -> [String] {
    await transport.recordedWire.filter { $0.operationID == markOp }.map { wire in
      guard
        let request = try? JSONDecoder().decode(
          Components.Schemas.MarkStateRequest.self, from: wire.body)
      else { return "undecodable" }
      return "\(request.state.rawValue):"
        + request.imageIds.map(String.init).joined(separator: ",")
    }
  }

  // MARK: - Flat (S1, S8, S9) and the three flat groupings (S2–S4)

  /// Twelve unmarked photographs, one page, no group key.
  private static func flatStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: (1...12).map { image($0) }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  /// Twelve photographs grouped by Mark as the server buckets them: picks 1…3, dislikes 4…5,
  /// then the null bucket 6…12 — which is the remainder row.
  static func markStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    let rows = (1...12).map { id -> Components.Schemas.ImageSummary in
      let mark: MarkStateValue = id <= 3 ? .pick : id <= 5 ? .dislike : .none
      return image(id, groupKey: id <= 5 ? mark.rawValue : nil, mark: mark)
    }
    await transport.setListImagesPage(.init(items: rows, limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: .mark,
        headers: [
          .init(count: 3, key: "pick", label: "Pick"),
          .init(count: 2, key: "dislike", label: "Dislike"),
          .init(count: 7, key: nil, label: "Unknown"),
        ], timezone: nil, total: 12))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    return (store, transport)
  }

  /// Twelve unmarked photographs grouped by Rating: 1…3 rated 5, 4…5 rated 3, 6…12 unrated.
  private static func ratingStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    let rows = (1...12).map { image($0, groupKey: $0 <= 3 ? "5" : $0 <= 5 ? "3" : nil) }
    await transport.setListImagesPage(.init(items: rows, limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: .rating,
        headers: [
          .init(count: 3, key: "5", label: "5"), .init(count: 2, key: "3", label: "3"),
          .init(count: 7, key: nil, label: "Unknown"),
        ], timezone: nil, total: 12))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.rating))
    await store.refreshGroupHeaders()
    return (store, transport)
  }

  /// Twelve unmarked photographs grouped by Camera, two bodies.
  private static func cameraStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    let rows = (1...12).map { image($0, groupKey: $0 <= 6 ? "X-T5" : "X100VI") }
    await transport.setListImagesPage(.init(items: rows, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))
    return (store, transport)
  }

  // MARK: - Scene (S5, S6)

  private static func loose(_ id: Int) -> Item {
    .init(value1: .init(image: image(id), kind: .image), value2: nil)
  }

  private static func scene(_ id: Int, count: Int, cover: Int) -> Item {
    .init(
      value1: nil,
      value2: Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)), editedCount: 0,
        hasPick: false, kind: .stack, matchedCount: count, memberCount: count, pickedCount: 0,
        representative: image(cover), stackId: id))
  }

  private static var streamItems: [Item] {
    [loose(10), scene(5, count: 3, cover: 900), scene(6, count: 2, cover: 901), loose(11)]
  }

  /// The stream is loose 10, scene 5 {1, 2, 3} (cover 900), scene 6 {7, 8} (cover 901), loose
  /// 11 — the `ScenePushTests` fixture. Covers are not members.
  static func sceneStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: streamItems, limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(
      .init(items: [1, 2, 3].map { image($0) }, limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await transport.setStackMemberPage(
      .init(items: [7, 8].map { image($0) }, limit: 100, nextCursor: nil, stackId: 6),
      forStack: 6)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  /// A flat folder of twelve unmarked photographs (1…12) that ALSO has scenes, so the reader can
  /// switch Flat → Scene → Flat: Scene shows the `sceneStore` stream.
  static func flatStoreWithScenes(startsWithTapToPick: Bool = false) async
    -> (GridStore, GridStubTransport)
  {
    let (store, transport) = makeStore(startsWithTapToPick: startsWithTapToPick)
    await transport.setListImagesPage(
      .init(items: (1...12).map { image($0) }, limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: streamItems, limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(
      .init(items: [1, 2, 3].map { image($0) }, limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  // MARK: - The nine states

  static func build(_ state: LatchState) async -> LatchFixture {
    switch state {
    case .ungrouped:
      let (store, transport) = await flatStore()
      return LatchFixture(
        store: store, transport: transport, focus: 3, tap: 2, corner: 4, cornerWrites: "pick")
    case .mark:
      let (store, transport) = await markStore()
      // Only 1…5 are in the stream; 1 is picked, so its corner clears it.
      return LatchFixture(
        store: store, transport: transport, focus: 4, tap: 5, corner: 1, cornerWrites: "none")
    case .rating:
      let (store, transport) = await ratingStore()
      return LatchFixture(
        store: store, transport: transport, focus: 4, tap: 5, corner: 2, cornerWrites: "pick")
    case .camera:
      let (store, transport) = await cameraStore()
      return LatchFixture(
        store: store, transport: transport, focus: 3, tap: 8, corner: 4, cornerWrites: "pick")
    case .band:
      let (store, transport) = await sceneStore()
      await store.togglePeekBand(5)
      return LatchFixture(
        store: store, transport: transport, focus: 1, tap: 2, corner: 3, cornerWrites: "pick")
    case .scene:
      let (store, transport) = await sceneStore()
      await store.enterScene(5)
      return LatchFixture(
        store: store, transport: transport, focus: 1, tap: 2, corner: 3, cornerWrites: "pick")
    case .remainder:
      let (store, transport) = await markStore()
      store.enterRemainder()
      return LatchFixture(
        store: store, transport: transport, focus: 6, tap: 7, corner: 8, cornerWrites: "pick")
    case .square:
      let (store, transport) = await flatStore()
      store.setLayoutStyle(.square)
      return LatchFixture(
        store: store, transport: transport, focus: 3, tap: 2, corner: 4, cornerWrites: "pick")
    case .loupe:
      let (store, transport) = await flatStore()
      // Two separate taps: the first focuses 2, the second opens the loupe on it.
      await store.tapCell(.image(2))
      await store.tapCell(.image(2))
      // In the loupe the focused frame is the target; the latched tap after Back lands on 3.
      return LatchFixture(
        store: store, transport: transport, focus: 2, tap: 3, corner: 2, cornerWrites: "pick")
    }
  }
}
