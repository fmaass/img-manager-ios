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
    /// A minimal valid 1×1 JPEG — screenshots need SOME decodable image, not a photorealistic
    /// one, to prove tiles render rather than show placeholders.
    private let tinyJPEG = Data(
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
        // "dated" is the LIVE vocabulary (IMGMGR-173) — a fixture kind the API never emits
        // is how the empty-sidebar defect stayed green.
        let node = Components.Schemas.FolderNode(
          id: 1, kind: "dated", name: "2026-08-27 — Stub Shoot", path: "stub")
        return try jsonResponse(.ok, Components.Schemas.FolderTree(items: [node]))
      case Operations.ListImagesApiImagesGet.id:
        return try jsonResponse(
          .ok,
          Components.Schemas.ImagePage(items: Self.fixtureImages(), limit: 100, nextCursor: nil))
      case Operations.ImageFacetsApiFacetsGet.id:
        return try jsonResponse(
          .ok,
          Components.Schemas.ImageFacets(mark: [.init(count: 3, value: "pick")], total: 12))
      case Operations.GetImageApiImagesImageIdGet.id:
        return try jsonResponse(.ok, Self.fixtureDetail())
      case Operations.GetProxyApiImagesImageIdProxyTierGet.id:
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        return (response, HTTPBody(tinyJPEG))
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

    private static func fixtureDetail() -> Components.Schemas.ImageDetail {
      let exif = Components.Schemas.ImageDetail.ExifPayload(additionalProperties: [
        "Make": .init(value1: "Stub Camera Co.", value2: nil, value3: nil),
        "Model": .init(value1: "Fixture X100", value2: nil, value3: nil),
        "ISO": .init(value1: nil, value2: 400, value3: nil),
        "FNumber": .init(value1: nil, value2: nil, value3: 2.8),
      ])
      return Components.Schemas.ImageDetail(
        exif: exif, ext: "jpg", filename: "STUB_0001.jpg", folderId: 1, id: 1,
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
  }
#endif
