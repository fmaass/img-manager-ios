#if DEBUG
  import Foundation
  import HTTPTypes
  import ImgManagerAPI
  import OpenAPIRuntime

  /// DEBUG-ONLY screenshot/UI-fixture transport (diff-gate round 2, item 9(a)). Compiled ONLY
  /// into Debug builds — a Release/TestFlight archive strips every `#if DEBUG` block entirely,
  /// so this type does not exist in shipped binaries, and production composition
  /// (`ImgManagerApp`, absent the launch argument below) never constructs or references it.
  /// Routes the same operations `GridService`/`ImgManagerAPIService` use, by the real generated
  /// `operationID`, exactly like the test-target `GridStubTransport` — this is its Debug-build
  /// sibling, for retained SCREENSHOT evidence rather than `swift test`.
  actor DebugStubTransport: ClientTransport {
    /// A minimal valid 1×1 JPEG — the last-resort fallback where no drawing API exists.
    private static let tinyJPEG = Data(
      base64Encoded:
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k="
    )!

    func send(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
      switch operationID {
      case Operations.ApiHealthApiHealthGet.id:
        return try jsonResponse(
          .ok, Components.Schemas.ApiHealthResponse(db: "ok", status: "ok", version: "stub"))
      case Operations.StatusApiStatusGet.id:
        return try jsonResponse(
          .ok,
          Components.Schemas.StatusResponse(
            coverage: .init(imagesActive: 0, imagesMissing: 0, tiers: []),
            maintenance: .init(enabled: false), runs: []))
      case Operations.FolderTreeApiFoldersGet.id:
        return try jsonResponse(.ok, Components.Schemas.FolderTree(items: Self.fixtureFolders()))
      case Operations.FolderSummariesApiFolderSummariesGet.id:
        return try jsonResponse(
          .ok, Components.Schemas.FolderSummaryList(items: Self.fixtureSummaries()))
      case Operations.ListImagesApiImagesGet.id:
        return try jsonResponse(
          .ok,
          Components.Schemas.ImagePage(items: Self.fixtureImages(), limit: 100, nextCursor: nil))
      case Operations.ImageFacetsApiFacetsGet.id:
        return try jsonResponse(
          .ok,
          Components.Schemas.ImageFacets(mark: [.init(count: 3, value: "pick")], total: 12))
      case Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id:
        // P5: no more stub images beyond the fixed dozen `fixtureImages()` already returns —
        // an empty page is the truthful "nothing further" answer, keeping the loupe's own
        // exhaustion path exercisable from the screenshot fixture instead of silently 404ing.
        return try jsonResponse(
          .ok, Components.Schemas.ImagePage(items: [], limit: 5, nextCursor: nil))
      case Operations.GetImageApiImagesImageIdGet.id:
        return try jsonResponse(.ok, Self.fixtureDetail())
      case Operations.GetProxyApiImagesImageIdProxyTierGet.id:
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        let tier = request.path.flatMap { URLComponents(string: $0)?.path }?
          .split(separator: "/").last.map(String.init)
        return (response, HTTPBody(Self.fixtureProxy(tier: tier)))
      case Operations.SetMarkStateApiMarksStatePost.id:
        return try jsonResponse(
          .ok, Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
      case Operations.EditMarkTagsApiMarksTagsPost.id:
        return try jsonResponse(
          .ok, Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
      default:
        return (HTTPResponse(status: .notFound), nil)
      }
    }

    private func jsonResponse<T: Encodable>(
      _ status: HTTPResponse.Status, _ body: T
    ) throws -> (HTTPResponse, HTTPBody?) {
      var response = HTTPResponse(status: status)
      response.headerFields[.contentType] = "application/json"
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(body)
      return (response, HTTPBody(data))
    }

    /// WP13 P3 (IMGMGR-213): the retained zoom screenshots need a fixture proxy with REAL
    /// production geometry — the deployed backend renders `preview` at 1600 px on the long edge
    /// and `grid` at 400 px (probed 2026-08-30), and the phase's own probe measured 16 deployed
    /// previews at exactly 1600x1067. A 1x1 placeholder makes the fitted extent square and the
    /// 1:1 ceiling meaningless, so "fit versus 100 %" could not be photographed at all. The
    /// pattern is a resolution wedge: hairlines whose pitch widens across the frame, so the
    /// difference between fit and 1:1 is visible in a screenshot rather than asserted.
    private static func fixtureProxy(tier: String?) -> Data {
      tier == ProxyTier.grid.rawValue ? gridFixture : previewFixture
    }

    private static let previewFixture: Data = renderFixture(width: 1600, height: 1067)
    private static let gridFixture: Data = renderFixture(width: 400, height: 267)

    private static func renderFixture(width: Int, height: Int) -> Data {
      #if canImport(UIKit)
        return DebugStubProxyRenderer.jpeg(width: width, height: height) ?? tinyJPEG
      #else
        return tinyJPEG
      #endif
    }

    /// A dozen fixture images spanning several aspect ratios — including a panorama (index 3)
    /// — so the three retained screenshots actually exercise justified reflow, not just a
    /// uniform grid of squares.
    private static func fixtureImages() -> [Components.Schemas.ImageSummary] {
      let aspects: [Double] = [1.5, 1.0, 0.75, 3.5, 1.5, 1.5, 1.0, 1.5, 2.0, 1.0, 1.5, 0.75]
      return aspects.enumerated().map { index, aspect in
        Components.Schemas.ImageSummary(
          aspectRatio: aspect, capturedAt: Date(), ext: "jpg",
          filename: "STUB_\(String(format: "%04d", index + 1)).jpg", folderId: 1,
          hasEdit: index % 3 == 0, id: index + 1,
          lightroom: .init(
            good: index % 4 == 0, rating: index % 5, sidecarPresent: index % 2 == 0),
          mark: .init(
            revision: "r\(index)",
            state: index % 5 == 0 ? .pick : (index % 7 == 0 ? .dislike : .none)),
          missing: false,
          proxies: .init(additionalProperties: [
            "grid": .init(height: 400, url: nil, verdict: .ok, width: Int(400 * aspect)),
            "preview": .init(height: 1600, url: nil, verdict: .ok, width: Int(1600 * aspect)),
          ]),
          sourceKind: "camera_original", sourceLabel: "STUB_\(index + 1).ARW", sourceTier: "local")
      }
    }

    /// WP8 P7 (Q9, advisory 4, IMGMGR-173 discipline): six rows, one per readiness value —
    /// every STRING vocabulary value here (`kind`, `source_tier`, `readiness`) is proven live
    /// or schema-valid per `wp7native-live-vocabulary.txt`/`wp7native-schema-enums.txt`, never
    /// invented; `readiness` is built via `.init(rawValue:)!` from the schema's own snake_case
    /// wire string so this fixture never has to spell (and risk mis-guessing) the generated
    /// enum's camelCased Swift case name. Sync-count MIXES are not a closed vocabulary (plain
    /// integers) so combining them freely to exercise Q2's worst-present precedence is not a
    /// vocabulary invention. Covers: all 6 readiness values, a genuine multi-field sync mix
    /// (row 1), each precedence kind isolated alone (rows 2-5), an all-zero sync rollup (row 6,
    /// proving "no sync signal"), `nothingLeftUnmarked` both true and false, and exactly one
    /// null `lastTouched` (row 3).
    /// The folder tree the fixture browses. Kinds are the LIVE vocabulary (IMGMGR-173) — a
    /// fixture kind the API never emits is how the empty-sidebar defect stayed green — and since
    /// P7 (IMGMGR-217) the SHAPE is live too: a shoot at the tier root (`folderRow-1`, the row
    /// P6's browse test drives, still exactly where it was), plus a container whose child shoot
    /// carries a `template` subfolder of its own. Two levels, so the hierarchy P7 renders is
    /// something a UI test can actually walk instead of a single flat leaf.
    ///
    /// The counts are deliberately NOT self-consistent sums: `2026` reports 12 descendants while
    /// its visible child reports 9 of its own. A client that rolled the numbers up itself would
    /// show a different figure here, which is the point.
    private static func fixtureFolders() -> [Components.Schemas.FolderNode] {
      [
        .init(
          descendantImageCount: 12, id: 1, imageCount: 12, kind: "dated",
          name: "2026-08-27 — Stub Shoot", path: "stub"),
        .init(
          descendantImageCount: 12, id: 2, imageCount: 0, kind: "other", name: "2026",
          path: "2026"),
        .init(
          descendantImageCount: 12, id: 3, imageCount: 9, kind: "dated",
          name: "2026-09-14 — Wandern", parentId: 2, path: "2026/2026-09-14-wandern"),
        .init(
          descendantImageCount: 3, id: 4, imageCount: 3, kind: "template", name: "template",
          parentId: 3, path: "2026/2026-09-14-wandern/template"),
      ]
    }

    private static func fixtureSummaries() -> [Components.Schemas.FolderSummary] {
      [
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 25, decided: 12, disliked: 2, edited: 5, folderId: 101,
          kind: "dated", lastTouched: Date(timeIntervalSince1970: 1_755_421_712),
          nothingLeftUnmarked: false, path: "photo_edits/2026/2026-08-13-1", picked: 10,
          previewOutstanding: 0, readiness: .init(rawValue: "review_in_progress")!,
          sourceTier: "local", sync: .init(never: 3, refused: 1, stale: 2, synced: 5), total: 40,
          unmarked: 28, withMasters: 15),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 60, decided: 0, disliked: 0, edited: 0, folderId: 102,
          kind: "dated_split", lastTouched: Date(timeIntervalSince1970: 1_755_508_112),
          nothingLeftUnmarked: false, path: "photo_edits/2026/2026-08-14-1", picked: 0,
          previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!,
          sourceTier: "archive", sync: .init(never: 0, refused: 3, stale: 0, synced: 0),
          total: 60, unmarked: 60, withMasters: 0),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 12, decided: 5, disliked: 1, edited: 3, folderId: 103, kind: "dated",
          lastTouched: nil, nothingLeftUnmarked: true, path: "photo_edits/2026/2026-08-15-1",
          picked: 4, previewOutstanding: 8, readiness: .init(rawValue: "sync_problem")!,
          sourceTier: "local", sync: .init(never: 0, refused: 0, stale: 7, synced: 0), total: 12,
          unmarked: 7, withMasters: 4),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 0, decided: 32, disliked: 4, edited: 20, folderId: 104,
          kind: "dated", lastTouched: Date(timeIntervalSince1970: 1_755_594_512),
          nothingLeftUnmarked: true, path: "photo_edits/2026/2026-08-16-1", picked: 28,
          previewOutstanding: 0, readiness: .init(rawValue: "ready_for_editing")!,
          sourceTier: "local", sync: .init(never: 32, refused: 0, stale: 0, synced: 0), total: 32,
          unmarked: 0, withMasters: 32),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 255, decided: 0, disliked: 0, edited: 0, folderId: 105,
          kind: "dated_split", lastTouched: Date(timeIntervalSince1970: 1_755_680_912),
          nothingLeftUnmarked: false, path: "photo_edits/2026/2026-08-17-1", picked: 0,
          previewOutstanding: 255, readiness: .init(rawValue: "needs_previews")!,
          sourceTier: "archive", sync: .init(never: 0, refused: 0, stale: 0, synced: 12),
          total: 255, unmarked: 255, withMasters: 0),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 18, decided: 18, disliked: 3, edited: 10, folderId: 106,
          kind: "dated", lastTouched: Date(timeIntervalSince1970: 1_755_767_312),
          nothingLeftUnmarked: true, path: "photo_edits/2025/2025-12-24-1", picked: 15,
          previewOutstanding: 0, readiness: .init(rawValue: "historical_unreviewed")!,
          sourceTier: "local", sync: .init(never: 0, refused: 0, stale: 0, synced: 0), total: 18,
          unmarked: 0, withMasters: 18),
      ]
    }

    private static func fixtureDetail() -> Components.Schemas.ImageDetail {
      let exif = Components.Schemas.ImageDetail.ExifPayload(additionalProperties: [
        "Make": .init(value1: "Stub Camera Co.", value2: nil, value3: nil),
        "Model": .init(value1: "Fixture X100", value2: nil, value3: nil),
        "ISO": .init(value1: nil, value2: 400, value3: nil),
        "FNumber": .init(value1: nil, value2: nil, value3: 2.8),
      ])
      return Components.Schemas.ImageDetail(
        exif: exif, ext: "jpg", fileSize: 12_345_678, filename: "STUB_0001.jpg", folderId: 1, id: 1,
        lightroom: .init(good: true, rating: 4, sidecarPresent: true),
        mark: .init(revision: "r0", state: .pick),
        proxies: .init(additionalProperties: [:]), sourceTier: "local")
    }
  }

  /// The ONE launch argument that activates the fixture — `ImgManagerApp.swift` checks this,
  /// never anything idiom-shaped.
  enum DebugStubLaunch {
    static let argument = "-UITestStubGrid"
    static var isActive: Bool {
      ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// A SECOND, independent launch argument (screenshot-capture convenience only) requesting
    /// the scene rotate to landscape via the SUPPORTED, public
    /// `UIWindowScene.requestGeometryUpdate` API (iOS 16+) — never a private API, never
    /// idiom-based. This is what lets the retained Regular-3 screenshot be captured from a
    /// script without a full XCUITest target.
    static var forceLandscape: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestForceLandscape")
    }

    /// WP8 P7: a THIRD, independent launch argument. P4's own auto-select convenience (below)
    /// pre-selects the fixture shoot so the grid is already populated for ITS screenshots —
    /// correct and still needed for those. P7's launch surface change means that SAME auto-
    /// select now immediately navigates PAST the queue (the new Compact/Regular-2 sidebar) into
    /// the grid detail pane before a queue screenshot can ever be taken. This flag lets the
    /// queue's own screenshot capture skip the auto-select and see the sidebar/queue as a real
    /// launch actually would — `RegularThreeScreenshotUITests` passes no such argument, so its
    /// own grid-focused screenshot is completely unaffected.
    static var skipAutoSelect: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestStubSkipAutoSelect")
    }
  }

  #if canImport(UIKit)
    import UIKit

    /// Draws the DEBUG fixture proxy. Offscreen only, never on a shipping path — this whole
    /// file sits inside `#if DEBUG`, so a Release/TestFlight archive contains none of it.
    enum DebugStubProxyRenderer {
      static func jpeg(width: Int, height: Int) -> Data? {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
          UIColor(white: 0.10, alpha: 1).setFill()
          context.fill(CGRect(origin: .zero, size: size))
          UIColor(white: 0.90, alpha: 1).setStroke()
          let wedge = UIBezierPath()
          wedge.lineWidth = 1
          var x = size.width * 0.04
          var pitch: CGFloat = 2
          while x < size.width * 0.96 {
            wedge.move(to: CGPoint(x: x.rounded() + 0.5, y: size.height * 0.06))
            wedge.addLine(to: CGPoint(x: x.rounded() + 0.5, y: size.height * 0.94))
            x += pitch
            pitch = min(24, pitch * 1.012)
          }
          wedge.stroke()
          UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1).setFill()
          let bar = CGRect(
            x: size.width * 0.04, y: size.height * 0.46,
            width: size.width * 0.92, height: max(1, size.height * 0.01))
          context.fill(bar)
        }
        // The deployed render profile encodes at quality 85 (`PROXY_JPEG_QUALITY`, probed
        // 2026-08-30), so the fixture carries the same compression character.
        return image.jpegData(compressionQuality: 0.85)
      }
    }
  #endif
#endif
