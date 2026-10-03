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
    /// WP16 P2 (IMGMGR-298): the fixture counter this transport reports facet requests to. Held
    /// as a stored reference rather than reached for at each call site so the object incremented
    /// is unambiguously the object `ImgManagerApp` handed over and `GridView` observes.
    ///
    /// Optional-with-nil rather than the `= .shared` default argument the phase's plan sketched:
    /// `DebugProbe` is `@MainActor`, so `.shared` is a MainActor-isolated expression, and an
    /// actor's initializer is nonisolated — a MainActor default argument on it is rejected at the
    /// declaration (SE-0411 evaluates default arguments in the caller's isolation). Resolving
    /// `?? .shared` inside the `MainActor.run` hop below is the same singleton, on the isolation
    /// domain that can name it.
    private let probe: DebugProbe?

    init(probe: DebugProbe? = nil) {
      self.probe = probe
    }

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
        return try jsonResponse(.ok, Self.fixtureStatus())
      case Operations.ExportMarksApiMarksExportGet.id:
        return try jsonResponse(.ok, Self.fixtureMarksExport())
      case Operations.FolderTreeApiFoldersGet.id
      where DebugStubLaunch.failArchiveFolders
        && Self.queryParameters(of: request)["source_tier"] == GridSourceTier.archive.rawValue:
        // IMGMGR-350 checkpoint-2 (B3): ONE tier unreachable while the others answer — the state
        // a partial folder-load failure has to render, and the one a fixture that always answers
        // could never produce.
        return (HTTPResponse(status: .internalServerError), nil)
      case Operations.FolderTreeApiFoldersGet.id:
        // IMGMGR-350 P2: the fixture answers PER `(source_tier, tree)`, parsed off the request
        // the real generated client built — the same way the proxy branch below reads its tier
        // out of `request.path`. Until this phase it returned ONE taxonomy whatever was asked,
        // so the three tier branches would have repeated each other and a tier walk could have
        // passed against a shape the API never returns.
        let folderQuery = Self.queryParameters(of: request)
        // IMGMGR-499: counted like the summaries below, so the home Refresh row's TREE reload is
        // observable. The failing-archive branch above is not counted; no refresh test uses it.
        let folderTreeProbe = self.probe
        await MainActor.run { (folderTreeProbe ?? .shared).folderTreeRequests += 1 }
        return try jsonResponse(
          .ok,
          Components.Schemas.FolderTree(
            items: Self.fixtureFolders(
              sourceTier: folderQuery["source_tier"], tree: folderQuery["tree"])))
      case Operations.FolderSummariesApiFolderSummariesGet.id where DebugStubLaunch.hangSummaries:
        // IMGMGR-350 checkpoint-3 (F1): the summaries never answer, so `QueueStore` STAYS in its
        // first-load phase. That is the state that used to hold the whole home behind a spinner
        // while the folder tree beside it was loaded and ready.
        try? await Task.sleep(nanoseconds: 600_000_000_000)
        return (HTTPResponse(status: .internalServerError), nil)
      case Operations.FolderSummariesApiFolderSummariesGet.id where DebugStubLaunch.failSummaries:
        // IMGMGR-350 checkpoint-2 (B1): the summaries endpoint down while `/api/folders` is
        // healthy — the exact split that used to blank the tree home.
        return (HTTPResponse(status: .internalServerError), nil)
      case Operations.FolderSummariesApiFolderSummariesGet.id:
        // Final audit F2: counted BEFORE the answer goes back, through the same probe as the
        // facets and absorb requests, so the Shoots Refresh row's re-fetch is observable.
        let summariesProbe = self.probe
        await MainActor.run { (summariesProbe ?? .shared).summariesRequests += 1 }
        return try jsonResponse(
          .ok, Components.Schemas.FolderSummaryList(items: Self.servedFixtureSummaries()))
      case Operations.ListImagesApiImagesGet.id
      where Self.queryParameters(of: request)["folder_id"] == String(Self.pagedFolderID):
        // WP31 P2 (IMGMGR-461): the one fixture shoot whose photographs span two pages, so a
        // Handoff continuation can target a photograph the first page does not carry.
        return try jsonResponse(
          .ok, Self.pagedFolderPage(cursor: Self.queryParameters(of: request)["cursor"]))
      case Operations.ListImagesApiImagesGet.id:
        return try jsonResponse(
          .ok,
          Components.Schemas.ImagePage(
            items: Self.fixtureImages(scopedTo: Self.perFolderScope(of: request)), limit: 100,
            nextCursor: nil))
      case Operations.ImageGroupsApiImageGroupsGet.id:
        // WP13 P5b: the fixture's `group_key` values are CAMERA names, so this is the dimension
        // it models; the counts are the live probe's own (2026-08-30), deliberately far larger
        // than the twelve rows on the page — a section header that showed 4 would be a
        // client-side tally, and the screenshot evidence is where that shows up.
        return try jsonResponse(.ok, Self.fixtureImageGroups())
      case Operations.ImageFacetsApiFacetsGet.id:
        // WP16 P2 (IMGMGR-298): counted BEFORE the response goes back, so a UI test can observe
        // that the facets fetch ran at all without the inspector ever having been on screen —
        // the one observation showing the inspector cannot make, because showing it is what
        // starts the fetch. Copied into a local first: the closure is `@Sendable`, so reading
        // `self.probe` inside it would capture this actor's isolated state.
        let probe = self.probe
        await MainActor.run { (probe ?? .shared).facetsRequests += 1 }
        return try jsonResponse(.ok, Self.fixtureFacets())
      case Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id:
        // P5: no more stub images beyond the fixed dozen `fixtureImages()` already returns —
        // an empty page is the truthful "nothing further" answer, keeping the loupe's own
        // exhaustion path exercisable from the screenshot fixture instead of silently 404ing.
        return try jsonResponse(
          .ok, Components.Schemas.ImagePage(items: [], limit: 5, nextCursor: nil))
      case Operations.GetImageApiImagesImageIdGet.id:
        return try jsonResponse(.ok, Self.fixtureDetail())
      case Operations.GetProxyApiImagesImageIdProxyTierGet.id
      where DebugStubLaunch.noPreviews
        && Self.proxyTier(of: request) == ProxyTier.preview.rawValue:
        // IMGMGR-502: no photograph has a preview — the server's 404 for a proxy it does not
        // have, which Triage renders as its "No preview" placeholder.
        return (HTTPResponse(status: .notFound), nil)
      case Operations.GetProxyApiImagesImageIdProxyTierGet.id:
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        let tier = Self.proxyTier(of: request)
        // IMGMGR-502: ONE named photograph's preview is held back until the UI test releases
        // it (`DebugPreviewHold`, never a timer); every other request answers at once. Gate
        // flake: holding "every preview after the first" counted globally, so the grid's and
        // the loupe's preview loads used up "the first" and Triage's own start got held.
        if tier == ProxyTier.preview.rawValue,
          let heldID = DebugStubLaunch.heldPreviewImageID,
          Self.proxyImageID(of: request) == heldID
        {
          await DebugPreviewHold.shared.hold()
        }
        return (response, HTTPBody(Self.fixtureProxy(tier: tier)))
      // IMGMGR-382: the look catalogue and the looked proxy, so the loupe's Looks control has
      // something to choose under `-UITestStubGrid`. The looked render is the same fixture with a
      // visible warm cast; an id outside the catalogue answers the server's coded 422.
      case Operations.ListLooksApiLooksGet.id:
        return try jsonResponse(.ok, Components.Schemas.LookList(looks: Self.fixtureLooks))
      case Operations.GetLookedProxyApiImagesImageIdProxyTierLookLookIdGet.id:
        // `/api/images/{id}/proxy/{tier}/look/{look_id}`: the look is the last component, the
        // tier the third from last.
        let path = request.path.flatMap { URLComponents(string: $0)?.path } ?? ""
        let components = path.split(separator: "/").map(String.init)
        guard let lookID = components.last, Self.fixtureLooks.contains(where: { $0.id == lookID })
        else {
          return try jsonResponse(
            .unprocessableContent,
            Components.Schemas.LookRefusalError(
              detail: .init(code: .unknownLook, message: "unknown look")))
        }
        let tier = components.count >= 3 ? components[components.count - 3] : nil
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        return (response, HTTPBody(Self.fixtureLookedProxy(tier: tier)))
      // WP14 lane B (IMGMGR-240/-241/-261): Scene mode's own fixture. Without these three the
      // Debug composition could not enter Scene mode with data at all, so the band, the ✓N badge
      // and the inline picks had no rendered evidence — only unit assertions.
      case Operations.BrowseStacksApiBrowseStacksGet.id:
        return try jsonResponse(.ok, Self.fixtureStackPage())
      case Operations.ListStackMembersApiStacksStackIdMembersGet.id:
        let memberCursor = request.path.flatMap { URLComponents(string: $0)?.queryItems }?
          .first(where: { $0.name == "cursor" })?.value
        return try jsonResponse(.ok, Self.fixtureStackMemberPage(cursor: memberCursor))
      case Operations.GetStackApiStacksStackIdGet.id:
        return try jsonResponse(.ok, Self.fixtureStackRow())
      // IMGMGR-347: the absorb the More menu's new row drives. Counted BEFORE the answer goes
      // back, through the same probe the facets fetch uses, so a UI test observes the REQUEST
      // rather than the sheet closing. The result names the fixture's own scene, which is what
      // the topology coordinator then reopens and completes.
      case Operations.AbsorbIntoStackApiStacksStackIdAbsorbPost.id:
        let absorbProbe = self.probe
        await MainActor.run { (absorbProbe ?? .shared).absorbRequests += 1 }
        return try jsonResponse(
          .ok,
          Components.Schemas.StackEditResult(
            dissolvedStackIds: [], loosenedImageIds: [], stackIds: [Self.fixtureStackID]))
      // WP29 P4 (IMGMGR-455): the split and extract Scene ▸ drives. Recorded as the WIRE call —
      // the stack id off the path, the payload off the body — BEFORE the answer goes back, so a
      // UI test reads what was sent. The result names the fixture's own scene, which the topology
      // coordinator then reopens exactly as it does after an absorb.
      case Operations.SplitStackApiStacksStackIdSplitPost.id,
        Operations.ExtractFromStackApiStacksStackIdExtractPost.id:
        let record = await Self.sceneEditRecord(
          isSplit: operationID == Operations.SplitStackApiStacksStackIdSplitPost.id,
          path: request.path, body: body)
        let sceneEditProbe = self.probe
        await MainActor.run { (sceneEditProbe ?? .shared).sceneEdits.append(record) }
        return try jsonResponse(
          .ok,
          Components.Schemas.StackEditResult(
            dissolvedStackIds: [], loosenedImageIds: [], stackIds: [Self.fixtureStackID]))
      // IMGMGR-348: the one-tap share's master lane needs bytes in the fixture composition —
      // `fixtureImages()` marks every third stub image `hasEdit`, and those are exactly the ones
      // whose share takes the master path, so without this the UI test would be measuring a
      // refusal. Served as the preview proxy's own bytes under a server-authored name, which is
      // the shape the real endpoint answers with.
      case Operations.DownloadImageApiImagesImageIdDownloadGet.id:
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        if let name = HTTPField.Name("Content-Disposition") {
          response.headerFields[name] = "attachment; filename=\"STUB-master.jpg\""
        }
        return (response, HTTPBody(Self.fixtureProxy(tier: "preview")))
      case Operations.SetMarkStateApiMarksStatePost.id:
        // WP31 P1 (IMGMGR-460): counted BEFORE the answer goes back, through the same probe as the
        // absorb request, so a UI test reads how many mark writes really reached the wire.
        let markProbe = self.probe
        await MainActor.run { (markProbe ?? .shared).markWrites += 1 }
        return try jsonResponse(
          .ok, Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
      case Operations.EditMarkTagsApiMarksTagsPost.id:
        // IMGMGR-485: recorded as the WIRE call BEFORE the answer goes back, the same way the
        // scene edits above are, so a UI test reads which photographs the tag sheet wrote.
        let record = await Self.tagEditRecord(body: body)
        let tagProbe = self.probe
        await MainActor.run { (tagProbe ?? .shared).tagEdits.append(record) }
        return try jsonResponse(
          .ok, Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
      default:
        return (HTTPResponse(status: .notFound), nil)
      }
    }

    /// The tier a `/api/images/{id}/proxy/{tier}` request names: the path's last component, read
    /// exactly as the proxy branch always read it.
    private static func proxyTier(of request: HTTPRequest) -> String? {
      request.path.flatMap { URLComponents(string: $0)?.path }?
        .split(separator: "/").last.map(String.init)
    }

    /// The image id a `/api/images/{id}/proxy/{tier}` request names: the path's third-from-last
    /// component.
    private static func proxyImageID(of request: HTTPRequest) -> Int? {
      let components = (request.path.flatMap { URLComponents(string: $0)?.path } ?? "")
        .split(separator: "/").map(String.init)
      guard components.count >= 3 else { return nil }
      return Int(components[components.count - 3])
    }

    /// The request's query as name → value. `request.path` carries the path AND the query (the
    /// proxy branch reads the path half of the same string), so one parse answers both.
    private static func queryParameters(of request: HTTPRequest) -> [String: String] {
      guard let path = request.path, let items = URLComponents(string: path)?.queryItems else {
        return [:]
      }
      return Dictionary(
        items.compactMap { item in item.value.map { (item.name, $0) } },
        uniquingKeysWith: { first, _ in first })
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

    /// IMGMGR-382: the looked twin of the fixture proxy, at the same geometry per tier.
    private static func fixtureLookedProxy(tier: String?) -> Data {
      tier == ProxyTier.grid.rawValue ? lookedGridFixture : lookedPreviewFixture
    }

    private static let lookedPreviewFixture = renderFixture(width: 1600, height: 1067, looked: true)
    private static let lookedGridFixture = renderFixture(width: 400, height: 267, looked: true)

    private static func renderFixture(width: Int, height: Int, looked: Bool = false) -> Data {
      #if canImport(UIKit)
        return DebugStubProxyRenderer.jpeg(width: width, height: height, looked: looked) ?? tinyJPEG
      #else
        return tinyJPEG
      #endif
    }

    /// IMGMGR-382: a three-look catalogue in manifest order. The names avoid the zoom pill's
    /// vocabulary (`LoupeScopeScan.pillPattern`), so the no-zoom scan stays meaningful.
    static let fixtureLooks: [Components.Schemas.LookSummary] = [
      fixtureLook(id: "warm-film", name: "Warm Film", category: "Film"),
      fixtureLook(id: "cool-matte", name: "Cool Matte", category: "Creative"),
      fixtureLook(id: "classic-mono", name: "Classic Mono", category: "Black and white"),
    ]

    private static func fixtureLook(id: String, name: String, category: String)
      -> Components.Schemas.LookSummary
    {
      Components.Schemas.LookSummary(
        category: category, id: id, licence: "Debug fixture, no colour table", name: name,
        source: "img-manager-ios debug stub", sourceUrl: "https://example.invalid/looks/\(id)")
    }

    /// A dozen fixture images spanning several aspect ratios — including a panorama (index 3)
    /// — so the three retained screenshots actually exercise justified reflow, not just a
    /// uniform grid of squares.
    /// WP13 P5a (IMGMGR-221): the Status sheet's screenshot fixture. Shaped from the live
    /// 2026-08-30 probe of the deployed backend (two mounted stores, two proxy tiers, an idle
    /// loop, a finished run) with FIXED timestamps so a screenshot is reproducible.
    private static func fixtureStatus() -> Components.Schemas.StatusResponse {
      Components.Schemas.StatusResponse(
        coverage: .init(
          imagesActive: 202_572, imagesMissing: 7_154,
          tiers: [
            .init(coveragePercent: 97.825, failed: 4_406, ok: 198_166, pending: 0, tier: "grid"),
            .init(
              coveragePercent: 97.544, failed: 4_976, ok: 197_596, pending: 0, tier: "preview"),
          ]),
        lastIndexedAt: Date(timeIntervalSince1970: 1_788_119_492),
        maintenance: .init(
          enabled: true, executorLock: .free,
          nextRunAt: Date(timeIntervalSince1970: 1_788_120_392), note: "idle",
          tierDetail: "the photo library is mounted and verified", tierMounted: true),
        runs: [
          .init(
            finishedAt: Date(timeIntervalSince1970: 1_788_119_492), id: 1_985,
            startedAt: Date(timeIntervalSince1970: 1_788_119_480), state: "succeeded",
            trigger: "interval")
        ],
        stores: [
          .init(
            detail: "the photo library is mounted and verified", health: .mounted, indexed: true,
            mounted: true, store: "local"),
          .init(
            detail: "the archive is mounted and verified", health: .mounted, indexed: true,
            mounted: true, store: "archive"),
        ])
    }

    /// WP13 P5a: bare STEMS, exactly the shape the live endpoint returned on 2026-08-30 — no
    /// extension, no directory component.
    private static func fixtureMarksExport() -> Components.Schemas.MarksExport {
      Components.Schemas.MarksExport(
        count: 3, state: ["pick"], stems: ["STUB_0001", "STUB_0006", "STUB_0011"],
        truncated: false)
    }

    /// WP13 P5b: the three camera buckets the fixture's `group_key` values fall into, with the
    /// live endpoint's own counts (`group_by=camera` on 2026-08-30) and its explicit Unknown
    /// bucket (`key: nil`, the server's own label). `sum(count) == total`, as the schema
    /// guarantees.
    private static func fixtureImageGroups() -> Components.Schemas.ImageGroups {
      Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: .camera,
        headers: [
          .init(count: 36568, key: "SONY ILCE-7RM5", label: "SONY ILCE-7RM5"),
          .init(count: 280, key: "FUJIFILM X-T2", label: "FUJIFILM X-T2"),
          .init(count: 213, key: nil, label: "Unknown"),
        ], timezone: nil, total: 37061)
    }

    /// The three buckets a fixture image belongs to, in the order a grouped page serves them
    /// (known keys ascending, Unknown last) — so the twelve rows really do arrive already
    /// grouped, the way `/api/images?group_by=camera` serves them.
    private static func fixtureGroupKey(index: Int) -> String? {
      switch index {
      case 0...3: return "SONY ILCE-7RM5"
      case 4...7: return "FUJIFILM X-T2"
      default: return nil
      }
    }

    /// `split(stackID: S, atImageID: I)` / `extract(stackID: S, imageIDs: [I, …])` — the wire
    /// fields in the order the request carried them. A body that does not decode records its
    /// absence (`?`) rather than a plausible value.
    private static func sceneEditRecord(isSplit: Bool, path: String?, body: HTTPBody?) async
      -> String
    {
      let stackID = sceneEditStackID(path: path) ?? "?"
      var object: [String: Any] = [:]
      if let body, let data = try? await Data(collecting: body, upTo: 1 << 16) {
        object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      }
      if isSplit {
        let at = (object["at_image_id"] as? Int).map(String.init) ?? "?"
        return "split(stackID: \(stackID), atImageID: \(at))"
      }
      let ids = (object["image_ids"] as? [Int]).map { $0.map(String.init).joined(separator: ", ") }
      return "extract(stackID: \(stackID), imageIDs: [\(ids ?? "?")])"
    }

    /// `add(tag: T, imageIDs: [I, …])` — the wire fields of a tag edit. A body that does not
    /// decode records its absence (`?`) rather than a plausible value.
    private static func tagEditRecord(body: HTTPBody?) async -> String {
      var object: [String: Any] = [:]
      if let body, let data = try? await Data(collecting: body, upTo: 1 << 16) {
        object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      }
      let operation = object["operation"] as? String ?? "?"
      let tag = object["tag"] as? String ?? "?"
      let ids = (object["image_ids"] as? [Int]).map { $0.map(String.init).joined(separator: ", ") }
      return "\(operation)(tag: \(tag), imageIDs: [\(ids ?? "?")])"
    }

    /// The `stacks/{id}` segment of a scene-edit request path, or `nil` when the path names none.
    private static func sceneEditStackID(path: String?) -> String? {
      guard let requestPath = path.flatMap({ URLComponents(string: $0)?.path }) else {
        return nil
      }
      let parts = requestPath.split(separator: "/")
      guard let index = parts.firstIndex(of: "stacks"), index + 1 < parts.count else {
        return nil
      }
      return String(parts[index + 1])
    }

    /// The fixture scene's id. One scene is enough and two would only make the screenshot
    /// ambiguous about which card an assertion is talking about.
    static let fixtureStackID = 5000

    /// The fixture scene's members: the five named ones (ids 3…7, TWO of them picked — so
    /// `picked_count` is a number a screenshot can disagree with, and the inline strip has more
    /// than one thumbnail to lay out), then a long tail of plain ones.
    ///
    /// IMGMGR-406: the tail is what makes a band LONGER than any gate destination's grid
    /// viewport, so the grid never renders the band's last member and therefore never pages the
    /// membership itself (`GridView` pages from rendered cells only). That is the one arrangement
    /// in which the loupe's own paging trigger is observable end to end: the strip can be
    /// scrolled to the loaded tail while the grid behind it cannot. The tail carries no picks and
    /// no edits, so `picked_count` (2) and `edited_count` (2) are exactly what they were.
    private static func fixtureStackMemberImages() -> [Components.Schemas.ImageSummary] {
      let named = fixtureImages().dropFirst(2).prefix(5).enumerated().map { index, image in
        var member = image
        member.mark = .init(
          revision: image.mark.revision, state: (index == 0 || index == 2) ? .pick : .none)
        return member
      }
      return named + (601...635).map { plainMember(id: $0) }
    }

    /// The last member of the loaded band — the frame a UI test focuses to make the loupe ask for
    /// the next membership page. Named here so the fixture, not a test, owns the number.
    static let fixtureBandTailMemberID = 635
    /// The member only the SECOND membership page carries: it can appear in a strip only after
    /// something asked for that page.
    static let fixtureSecondPageMemberID = 700

    /// A member with no verdict, no edit and no group key: tail material, deliberately inert so
    /// growing the band cannot move any count a shipped screenshot test asserts on.
    private static func plainMember(id: Int) -> Components.Schemas.ImageSummary {
      Components.Schemas.ImageSummary(
        aspectRatio: 1.5, capturedAt: Date(), ext: "jpg",
        filename: "STUB_\(String(format: "%04d", id)).jpg", folderId: 1, hasEdit: false, id: id,
        lightroom: .init(good: false, rating: 0, sidecarPresent: false),
        mark: .init(revision: "r\(id)", state: .none), missing: false,
        proxies: .init(additionalProperties: [
          "grid": .init(height: 400, url: nil, verdict: .ok, width: 600),
          "preview": .init(height: 1600, url: nil, verdict: .ok, width: 2400),
        ]),
        sourceKind: "camera_original", sourceLabel: "STUB_\(id).ARW", sourceTier: "local")
    }

    /// The card's own row. `representative` is a member whose `has_edit` is true, so the card
    /// draws the ✎ badge beside the ✓N one — the two-badge cluster the owner decided on.
    ///
    /// WP21 P2 (IMGMGR-339): `editedCount` is COUNTED from the members rather than written down,
    /// so it cannot drift from the photographs the fixture actually holds — two of the five carry
    /// `has_edit` (`fixtureImages()` marks every third), which is the digit the pencil now
    /// states. Phase 1 landed the field at a placeholder 0; a zero here would draw no pencil at
    /// all and make the badge's UI leg vacuous.
    private static func fixtureStackRow() -> Components.Schemas.StackBrowseStackRow {
      let members = fixtureStackMemberImages()
      // IMGMGR-406 (Codex round 4): the counts advertise the WHOLE scene, not the first page of
      // it — the band serves `members.count` now and one more on the second membership page, and
      // a card that promised 40 while its band ends at 41 would be the fixture lying about the
      // very thing this scene exists to page.
      let advertised = members.count + 1
      return Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_788_000_000),
        editedCount: members.filter { $0.hasEdit == true }.count, hasPick: true,
        kind: .stack,
        matchedCount: advertised, memberCount: advertised,
        pickedCount: members.filter { $0.mark.state == .pick }.count,
        representative: members[1], stackId: fixtureStackID)
    }

    /// Loose photographs either side of the scene, so the band's POSITION in the stream is part
    /// of the rendered evidence rather than something to take on trust.
    private static func fixtureStackPage() -> Components.Schemas.StackBrowsePage {
      let loose = fixtureImages()
      return Components.Schemas.StackBrowsePage(
        items: [
          .init(value1: .init(image: loose[0], kind: .image), value2: nil),
          .init(value1: .init(image: loose[1], kind: .image), value2: nil),
          .init(value1: nil, value2: fixtureStackRow()),
          .init(value1: .init(image: loose[7], kind: .image), value2: nil),
          .init(value1: .init(image: loose[8], kind: .image), value2: nil),
        ], limit: 100, nextCursor: nil)
    }

    /// Two membership pages (IMGMGR-406). Page one is the loaded band and names its successor;
    /// the second page is served only to a request that carries that cursor, which is what makes
    /// its one member evidence that somebody asked.
    private static func fixtureStackMemberPage(cursor: String?)
      -> Components.Schemas.StackMemberPage
    {
      guard cursor == memberPageTwoCursor else {
        return Components.Schemas.StackMemberPage(
          items: fixtureStackMemberImages(), limit: 100, nextCursor: memberPageTwoCursor,
          stackId: fixtureStackID)
      }
      return Components.Schemas.StackMemberPage(
        items: [plainMember(id: fixtureSecondPageMemberID)], limit: 100, nextCursor: nil,
        stackId: fixtureStackID)
    }

    private static let memberPageTwoCursor = "members-2"

    /// WP16 P3 (IMGMGR-295), the named fixture work item (gate round 1, B9). Until this phase the
    /// stub answered `/api/facets` with ONE mark row (`pick`, 3) and no `rating`, `ext` or
    /// `has_master` at all, so the filter popover's assertions could not be written against it:
    /// every declared row would have read 0 and the difference between "the fixture is thin" and
    /// "the popover is broken" would have been unobservable.
    ///
    /// Shaped like the live probe of 2026-09-01 (`GET /api/facets`, HTTP 200), which is what makes
    /// the numbers meaningful rather than invented: `rating` in EXACT-value buckets plus `unset`
    /// (so the `>= N` rows exercise the suffix sum instead of echoing a bucket), `mark` in all
    /// three states INCLUDING a zero, `has_master` both ways, and two `ext` values. Chosen so ONE
    /// response drives both paths the popover has: rows with results (enabled, non-zero) and a row
    /// with none (`dislike`, rendered at 0 and disabled — B2's rule, on the real surface).
    ///
    /// `total` stays 12, consistent with `fixtureImages()`'s twelve rows. The per-dimension counts
    /// sum to twelve as well, so nothing here reads as a page-derived tally.
    ///
    /// WP21 P2 (IMGMGR-376) adds `camera`, which img-manager v0.20.0 serves. Its buckets are NOT
    /// invented either: they are `fixtureGroupKey`'s own three, so the response and the grouped
    /// page describe the same twelve photographs — four Sonys, four Fujis and four with no
    /// `exif_camera` at all. That last bucket arrives as `"unset"` because that is what the
    /// server emits for a NULL (`app/api/images.py`'s `_count_by`: "A NULL is reported as
    /// 'unset' rather than dropped"), which is what makes the popover's non-filterable-value
    /// rule testable against a real wire shape rather than a hypothetical one.
    ///
    /// Internal rather than private, unlike its siblings: `FilterPopoverModelTests` runs the MODEL
    /// over this exact response, so a later edit that quietly drops the zero-count row — and with
    /// it the popover's zero-disabled UI coverage — fails a named unit test instead of silently
    /// making a UI leg vacuous.
    static func fixtureFacets() -> Components.Schemas.ImageFacets {
      Components.Schemas.ImageFacets(
        camera: [
          .init(count: 4, value: "SONY ILCE-7RM5"), .init(count: 4, value: "FUJIFILM X-T2"),
          .init(count: 4, value: "unset"),
        ],
        ext: [.init(count: 9, value: "jpg"), .init(count: 3, value: "arw")],
        hasMaster: [.init(count: 5, value: "true"), .init(count: 7, value: "false")],
        mark: [
          .init(count: 4, value: "pick"), .init(count: 0, value: "dislike"),
          .init(count: 8, value: "none"),
        ],
        rating: [
          .init(count: 4, value: "unset"), .init(count: 1, value: "2"),
          .init(count: 2, value: "3"), .init(count: 3, value: "4"), .init(count: 2, value: "5"),
        ],
        total: 12)
    }

    /// IMGMGR-405: the `folder_id` this request asked for, and ONLY while `-UITestPerFolderGrid`
    /// is set — `nil` otherwise, which is every shipped suite and the whole of Release.
    private static func perFolderScope(of request: HTTPRequest) -> Int? {
      guard DebugStubLaunch.perFolderGrid else { return nil }
      return queryParameters(of: request)["folder_id"].flatMap(Int.init)
    }

    /// WP31 P2 (IMGMGR-461): a fixture shoot whose photographs span TWO `/api/images` pages —
    /// twelve on the first, eight more behind `pagedSecondPageCursor` — so the Handoff route's
    /// paging has a photograph to reach beyond page one. Not in the folder tree (no shipped suite
    /// counts it) and requested only by folder id, so no other suite ever sees it.
    static let pagedFolderID = 7
    static let pagedFirstPageCount = 12
    static let pagedTotalCount = 20
    private static let pagedSecondPageCursor = "paged-2"

    /// The paged shoot's photograph ids, `7001…7020`, in display order.
    static func pagedFolderImageIDs() -> [Int] {
      (1...pagedTotalCount).map { pagedFolderID * 1000 + $0 }
    }

    private static func pagedFolderPage(cursor: String?) -> Components.Schemas.ImagePage {
      let ids = pagedFolderImageIDs()
      guard cursor == pagedSecondPageCursor else {
        return Components.Schemas.ImagePage(
          items: ids.prefix(pagedFirstPageCount).map { pagedImage(id: $0) }, limit: 100,
          nextCursor: pagedSecondPageCursor)
      }
      return Components.Schemas.ImagePage(
        items: ids.dropFirst(pagedFirstPageCount).map { pagedImage(id: $0) }, limit: 100,
        nextCursor: nil)
    }

    /// One unmarked photograph of the paged shoot, built like `plainMember`.
    private static func pagedImage(id: Int) -> Components.Schemas.ImageSummary {
      var image = plainMember(id: id)
      image.folderId = pagedFolderID
      return image
    }

    /// The same twelve photographs, re-identified per folder: `folderID * 1000 + n`, so a tile's
    /// identifier (`gridTile-<id>`) names the folder its grid was loaded for. `nil` returns the
    /// fixture untouched, which is what keeps this invisible to every suite that does not ask.
    private static func fixtureImages(scopedTo folderID: Int?) -> [Components.Schemas.ImageSummary]
    {
      guard let folderID else { return fixtureImages() }
      return fixtureImages().map { image in
        var scoped = image
        scoped.id = folderID * 1000 + image.id
        scoped.folderId = folderID
        return scoped
      }
    }

    private static func fixtureImages() -> [Components.Schemas.ImageSummary] {
      let aspects: [Double] = [1.5, 1.0, 0.75, 3.5, 1.5, 1.5, 1.0, 1.5, 2.0, 1.0, 1.5, 0.75]
      return aspects.enumerated().map { index, aspect in
        Components.Schemas.ImageSummary(
          aspectRatio: aspect, capturedAt: Date(), ext: "jpg",
          filename: "STUB_\(String(format: "%04d", index + 1)).jpg", folderId: 1,
          groupKey: fixtureGroupKey(index: index),
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
    /// IMGMGR-350 P2: SCOPED like the real endpoint. `/api/folders` answers per
    /// `(source_tier, tree)` (img-manager `app/api/folders.py:33-59`), and the three browse tiers
    /// are `(local, photo_incoming)`, `(local, photo_edits)` and `(archive, —)`. Internal rather
    /// than private so `DebugStubFolderFixtureTests` can read the same three answers the app does.
    static func fixtureFolders(sourceTier: String?, tree: String?)
      -> [Components.Schemas.FolderNode]
    {
      if sourceTier == GridSourceTier.archive.rawValue { return archiveFixtureFolders }
      if tree == FolderTreeTier.edits.treePrefix { return editsFixtureFolders }
      return incomingFixtureFolders
    }

    /// The incoming tier, live-shaped: ONE indexed root row (`photo_incoming`, which the tier-root
    /// hoist then drops, so the rows on screen are unchanged) over the shape the shipped tree
    /// tests walk — a root-level shoot (`folderRow-1`) beside the `2026` container whose child
    /// shoot carries a `template` subfolder. IMGMGR-350 adds the SECOND dated child, so the year
    /// has two shoots in one month for the fold to fold.
    private static let incomingFixtureFolders: [Components.Schemas.FolderNode] = [
      .init(
        descendantImageCount: 12, id: 9, imageCount: 0, kind: "other", name: "photo_incoming",
        path: "photo_incoming"),
      .init(
        descendantImageCount: 12, id: 1, imageCount: 12, kind: "dated",
        name: "2026-08-27 — Stub Shoot", parentId: 9, path: "photo_incoming/stub"),
      .init(
        descendantImageCount: 12, id: 2, imageCount: 0, kind: "other", name: "2026", parentId: 9,
        path: "photo_incoming/2026"),
      .init(
        descendantImageCount: 12, id: 3, imageCount: 9, kind: "dated",
        name: "2026-09-14 — Wandern", parentId: 2, path: "photo_incoming/2026/2026-09-14-wandern"),
      .init(
        descendantImageCount: 3, id: 4, imageCount: 3, kind: "template", name: "template",
        parentId: 3, path: "photo_incoming/2026/2026-09-14-wandern/template"),
      .init(
        descendantImageCount: 6, id: 5, imageCount: 6, kind: "dated", name: "2026-09-27 — Ufer",
        parentId: 2, path: "photo_incoming/2026/2026-09-27-ufer"),
    ]

    /// The edits tier: its own root row and its own shoot, no id shared with any other tier —
    /// `edits` is the SAME store as incoming, told apart only by the `tree` prefix, so a fixture
    /// that answered one taxonomy for both would have hidden exactly that.
    private static let editsFixtureFolders: [Components.Schemas.FolderNode] = [
      .init(
        descendantImageCount: 7, id: 10, imageCount: 0, kind: "other", name: "photo_edits",
        path: "photo_edits"),
      .init(
        descendantImageCount: 7, id: 11, imageCount: 7, kind: "dated",
        name: "2026-08-02 — Edits Pass", parentId: 10, path: "photo_edits/2026-08-02-edits-pass"),
    ]

    /// The archive tier: one REAL shoot with a nonzero count, beside one MIRRORED folder counting
    /// zero — the archive's counts drop every image the archive view hides, so a folder fully
    /// mirrored by the incoming library reports 0 (`app/api/folders.py:49-51`). IMGMGR-350 runs no
    /// prune, so that row stays visible; it is the control proving so, and the oracle the
    /// follow-up prune ticket (under IMGMGR-322) will invert.
    private static let archiveFixtureFolders: [Components.Schemas.FolderNode] = [
      .init(
        descendantImageCount: 4, id: 20, imageCount: 0, kind: "other", name: "2025", path: "2025"),
      .init(
        descendantImageCount: 4, id: 21, imageCount: 4, kind: "dated",
        name: "2025-12-24 — Archive Shoot", parentId: 20, path: "2025/2025-12-24-archive-shoot"),
      .init(
        descendantImageCount: 0, id: 22, imageCount: 0, kind: "dated",
        name: "2025-11-01 — Mirrored", parentId: 20, path: "2025/2025-11-01-mirrored"),
    ]

    /// IMGMGR-350 P3: every row's `folderId` is a folder the TREE renders — ids 1/3/5 (incoming),
    /// 11 (edits) and 21/22 (archive) — because the badge is a `folder_id` join and a summary for
    /// a folder that is not on screen renders nothing. They used to be 101-106, which intersected
    /// the tree nowhere, so the join would have been empty on every row. Readiness values, counts
    /// and the deliberate contradictions between them are unchanged; `sourceTier` follows the
    /// folder's own store. Internal, not private, so `DebugStubFolderFixtureTests` can prove the
    /// join lands.
    static func fixtureSummaries() -> [Components.Schemas.FolderSummary] {
      [
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 25, decided: 12, disliked: 2, edited: 5, folderId: 1,
          kind: "dated", lastTouched: Date(timeIntervalSince1970: 1_755_421_712),
          nothingLeftUnmarked: false, path: "photo_incoming/stub", picked: 10,
          previewOutstanding: 0, readiness: .init(rawValue: "review_in_progress")!,
          sourceTier: "local", sync: .init(never: 3, refused: 1, stale: 2, synced: 5), total: 40,
          unmarked: 28, withMasters: 15),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 60, decided: 0, disliked: 0, edited: 0, folderId: 21,
          kind: "dated_split", lastTouched: Date(timeIntervalSince1970: 1_755_508_112),
          nothingLeftUnmarked: false, path: "2025/2025-12-24-archive-shoot", picked: 0,
          previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!,
          sourceTier: "archive", sync: .init(never: 0, refused: 3, stale: 0, synced: 0),
          total: 60, unmarked: 60, withMasters: 0),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 12, decided: 5, disliked: 1, edited: 3, folderId: 3, kind: "dated",
          lastTouched: nil, nothingLeftUnmarked: true,
          path: "photo_incoming/2026/2026-09-14-wandern",
          picked: 4, previewOutstanding: 8, readiness: .init(rawValue: "sync_problem")!,
          sourceTier: "local", sync: .init(never: 0, refused: 0, stale: 7, synced: 0), total: 12,
          unmarked: 7, withMasters: 4),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 0, decided: 32, disliked: 4, edited: 20, folderId: 11,
          kind: "dated", lastTouched: Date(timeIntervalSince1970: 1_755_594_512),
          nothingLeftUnmarked: true, path: "photo_edits/2026-08-02-edits-pass", picked: 28,
          previewOutstanding: 0, readiness: .init(rawValue: "ready_for_editing")!,
          sourceTier: "local", sync: .init(never: 32, refused: 0, stale: 0, synced: 0), total: 32,
          unmarked: 0, withMasters: 32),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 255, decided: 0, disliked: 0, edited: 0, folderId: 22,
          kind: "dated_split", lastTouched: Date(timeIntervalSince1970: 1_755_680_912),
          nothingLeftUnmarked: false, path: "2025/2025-11-01-mirrored", picked: 0,
          previewOutstanding: 255, readiness: .init(rawValue: "needs_previews")!,
          sourceTier: "archive", sync: .init(never: 0, refused: 0, stale: 0, synced: 12),
          total: 255, unmarked: 255, withMasters: 0),
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: 18, decided: 18, disliked: 3, edited: 10, folderId: 5,
          kind: "dated", lastTouched: Date(timeIntervalSince1970: 1_755_767_312),
          nothingLeftUnmarked: true, path: "photo_incoming/2026/2026-09-27-ufer", picked: 15,
          previewOutstanding: 0, readiness: .init(rawValue: "historical_unreviewed")!,
          sourceTier: "local", sync: .init(never: 0, refused: 0, stale: 0, synced: 0), total: 18,
          unmarked: 0, withMasters: 18),
      ]
    }

    /// What `/api/folder-summaries` actually answers for THIS launch — the shipped fixture, or
    /// the all-reviewed variant `-UITestSummariesReviewed` asks for. `fixtureSummaries()` itself
    /// is left exactly as it was, so `DebugStubFolderFixtureTests`' pins (the id set, and one
    /// summary per readiness value) keep reading the same six rows.
    static func servedFixtureSummaries() -> [Components.Schemas.FolderSummary] {
      DebugStubLaunch.summariesReviewed ? reviewedFixtureSummaries() : fixtureSummaries()
    }

    /// IMGMGR-389: the same six shoots with every readiness rewritten to `ready_for_editing`, so
    /// NO shoot is a member of the pinned "Needs review" set and the section's empty state can be
    /// driven through the real UI. No shipped entry point can produce it — the fixture always has
    /// members — and the emptiness has to come from the DATA rather than from a broken load, or
    /// an absent section would prove only that nothing rendered.
    ///
    /// Rebuilt through the generated memberwise initialiser rather than mutated in place, in the
    /// same field order the literals above use: `readiness` is the one field that differs, and it
    /// is spelled as the schema's OWN wire string, exactly as every literal in this file does.
    /// Internal, not private, so a unit test can read the same rows the app is served.
    static func reviewedFixtureSummaries() -> [Components.Schemas.FolderSummary] {
      fixtureSummaries().map { summary in
        Components.Schemas.FolderSummary(
          cameraPreviewOnly: summary.cameraPreviewOnly, decided: summary.decided,
          disliked: summary.disliked, edited: summary.edited, folderId: summary.folderId,
          kind: summary.kind, lastTouched: summary.lastTouched,
          nothingLeftUnmarked: summary.nothingLeftUnmarked, path: summary.path,
          picked: summary.picked, previewOutstanding: summary.previewOutstanding,
          readiness: .init(rawValue: "ready_for_editing")!, sourceTier: summary.sourceTier,
          sync: summary.sync, total: summary.total, unmarked: summary.unmarked,
          withMasters: summary.withMasters)
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

    /// IMGMGR-348: park the advance-on-mark cadence for one launch. The loupe header control
    /// that used to do this from a UI test is gone with the owner's device-pass decision, and
    /// `LoupeAutoAdvanceScreenshotUITests`' mark-bar reading still needs the mark to leave the
    /// loupe on the SAME frame. Debug-only and fixture-only, like every flag here; it writes the
    /// preference through the same property a control would, so nothing about how the cadence is
    /// stored becomes test-special.
    static var noAutoAdvance: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestStubNoAutoAdvance")
    }

    /// WP13 P1: a FOURTH, independent launch argument. The Select mode row's retained
    /// screenshot needs the app to BE in Select mode, and neither shipped entry is drivable
    /// from XCUITest on every destination — Regular-3 never receives the tile long press (the
    /// grid's pointer-drag recognizer claims it) and its More-menu popover items are not
    /// addressable by label or by identifier. This flag enters Select mode after the fixture
    /// shoot loads, through `GridStore.enterSelectExplicitly()` — the SAME entry point the
    /// More menu's own command calls, never a special code path — so the harness gets the
    /// state without the gesture. Debug-only, like every flag here: a Release archive strips
    /// this whole file.
    static var enterSelectMode: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestEnterSelectMode")
    }

    /// WP13 P2 (IMGMGR-222): a FIFTH, independent launch argument, for the same reason the
    /// Select one exists. The Dislike Lock mode row's retained screenshot needs the app to BE
    /// latched on Dislike, and neither shipped entry is drivable from XCUITest on every
    /// destination — a double tap inside the 350 ms window is not a gesture XCUITest can time
    /// reliably against a control, and the context-menu twin is a long press whose popover items
    /// are not addressable by label or identifier on Regular-3 (three P1 gate runs established
    /// the same for the More menu). This flag latches through `GridStore.lockFromMenu(.dislike)`
    /// — the SAME entry point the "Lock Dislike" context-menu command calls, never a special
    /// code path. Debug-only, like every flag here: a Release archive strips this whole file.
    static var latchDislikeLock: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestLatchDislikeLock")
    }

    /// WP14 lane B (IMGMGR-240/-241/-261): a SIXTH, independent launch argument, for the same
    /// reason the two above it exist. Scene mode's retained screenshot needs the app to BE in
    /// Scene mode with the picks-in-groups switch on, and neither entry point is drivable from
    /// XCUITest on every destination — the Group menu's items are not addressable by label or
    /// identifier inside a popover on Regular-3 (three P1 gate runs established that), and ⌘⇧G
    /// never reaches a simulator with no attached hardware keyboard.
    ///
    /// Both effects go through the SHIPPED entry points — `GridStore.setDisplayMode(.scene)` and
    /// the same `GridPreferences` property the More menu's toggle writes — never a special code
    /// path. It therefore PERSISTS the preference in the simulator's own defaults, exactly as a
    /// reader flipping the switch would; nothing outside Scene mode reads it, so no other
    /// fixture's screenshot changes.
    static var enterSceneMode: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestEnterSceneMode")
    }

    /// A SEVENTH, independent launch argument — the INVERSE of the one WP16 P2 (IMGMGR-298)
    /// shipped, which is retired with this story and understood by nothing any more. That one
    /// hid the inspector, because the Regular-3 inspector was up at launch and a test that needed
    /// it away could not tap the chrome control to get there (tapping puts it on screen first,
    /// which is exactly the observation `FacetsWithoutInspectorUITests` proves nothing with). The
    /// owner's decision on IMGMGR-338 makes COLLAPSED the launch state, so hiding is what a plain
    /// launch already does and SHOWING is the state with no other route to it. Hence
    /// `-UITestInspectorShown`: a test wanting the collapsed workspace launches plainly.
    ///
    /// Drives the same `RootView.showInspector` state the shipped control toggles, never a second
    /// code path — and, since WP28 P3 merged the inspector's flags, only on the first resolve to
    /// Regular-3 (`RootView.applyWidth`), the one width this flag has ever governed.
    /// Independent of every flag above and of `-UITestStubGrid`'s own
    /// effects; Debug-only, like all of them, because a Release archive strips this whole file.
    static var startsWithInspectorShown: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestInspectorShown")
    }

    /// WP28 P4 (IMGMGR-451): mounts `MaterialsSettingsProbe`, the element the materials suite
    /// reads the real Reduce Transparency / Increase Contrast settings back from before each
    /// capture. Renders nothing a reader sees; Debug-only like every flag here.
    static var materialsProbe: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestMaterialsProbe")
    }

    /// IMGMGR-478: the Regular sidebar's visibility is REMEMBERED across launches
    /// (`SidebarVisibilityMemory.hiddenKey`, standard `UserDefaults`), and the simulator keeps it
    /// from one test to the next — so a fixture launch forgets it (`ImgManagerApp.init`) and every
    /// suite starts on the shown sidebar it was written against, whatever an earlier or
    /// interrupted test left. `-UITestKeepSidebarMemory` keeps it: the relaunch half of
    /// `RegularSidebarShellUITests` passes it to read back what its previous launch stored, through
    /// the same `@AppStorage` read a shipped launch makes.
    static var keepsSidebarMemory: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestKeepSidebarMemory")
    }

    /// The fixture launch's reset described above; `ImgManagerApp.init` calls it once per process,
    /// before any `RootView` reads the flag.
    static func resetSidebarMemoryUnlessKept(defaults: UserDefaults = .standard) {
      guard isActive, !keepsSidebarMemory else { return }
      defaults.removeObject(forKey: SidebarVisibilityMemory.hiddenKey)
    }

    /// WP31 P2 (IMGMGR-461): the JSON `userInfo` of a Triage Handoff to continue once the
    /// fixture's shoot has loaded — the value after `-UITestContinueActivity`. It feeds the SAME
    /// decode-and-route function `.onContinueUserActivity` calls, so the receiving side is
    /// testable without a second device. Debug-only like every flag here.
    static var continueActivityJSON: String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-UITestContinueActivity"),
        arguments.indices.contains(index + 1)
      else { return nil }
      return arguments[index + 1]
    }

    /// WP28 P3 (IMGMGR-450): which fixture folder the auto-select opens — the id that follows
    /// `-UITestSelectFolder` in the launch arguments, or folder 1 (the shipped default) when the
    /// flag is absent or its value is not an id. The Summary's cases need folders the fixture
    /// already has: 1 (`nothingLeftUnmarked == false`), 3 (`true`) and 4 (`template`, which has
    /// no `FolderSummary` at all). Debug-only like every flag here.
    static var autoSelectFolderID: Int {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-UITestSelectFolder"),
        arguments.indices.contains(index + 1), let id = Int(arguments[index + 1])
      else { return 1 }
      return id
    }

    /// IMGMGR-405: an EIGHTH, independent launch argument. `/api/images` answers the same twelve
    /// fixture photographs whatever `folder_id` is asked for, which is right for every suite that
    /// only needs A grid — and useless for the one assertion that has to tell WHICH folder's grid
    /// is on screen (rule 3: a collapsing tap leaves the other side of the split view alone).
    /// With this set, the fixture's ids are offset by the folder asked for, so `gridTile-2001…`
    /// is the year folder's grid and `gridTile-1001…` the root shoot's, and "the grid did not
    /// change" becomes something a test can read instead of assume.
    ///
    /// OPT-IN precisely so nothing else moves: no shipped suite passes it, so every existing
    /// screenshot, tile and loupe assertion still sees ids 1…12. Debug-only like every flag here.
    ///
    /// Scoped to the image PAGE alone, deliberately: the groups, facets and neighbour fixtures
    /// keep the unscoped dozen, so a suite that passes this flag and then drives Scene mode or the
    /// loupe would be comparing two id spaces. The one test that passes it reads tile identifiers
    /// and nothing else.
    static var perFolderGrid: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestPerFolderGrid")
    }

    /// IMGMGR-350 checkpoint-2 (B1): an EIGHTH, independent launch argument. The tree home must
    /// survive a `/api/folder-summaries` outage, and no shipped entry point can produce one — the
    /// fixture answers everything. Debug-only like every flag here.
    static var failSummaries: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestFailSummaries")
    }

    /// IMGMGR-350 checkpoint-3 (F1): a TENTH, on the same terms — `/api/folder-summaries` that
    /// never answers, holding the summaries in their first-load phase for as long as the test
    /// needs. A failing endpoint could not produce this: it answers, and the phase moves on.
    static var hangSummaries: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestHangSummaries")
    }

    /// IMGMGR-389: another INDEPENDENT launch argument (the ordinals above stopped being a
    /// reliable count some flags ago; what matters is that this one composes with all of them).
    /// Every fixture summary is served as `ready_for_editing`, so the pinned "Needs review"
    /// section has no members and must not render at all. The endpoint still ANSWERS — a healthy
    /// home with nothing awaiting review, a different state from the failing and hanging
    /// summaries above and the only one that proves the empty case. Debug-only like every flag
    /// here.
    ///
    /// WP28 P1 (IMGMGR-448): `-UITestNoNeedsReview` is a second spelling of the same switch, named
    /// for what the Compact shell's badge tests need (no Needs-review member, so no Shoots badge).
    /// One fixture, two names — never a second fixture that could drift from this one.
    static var summariesReviewed: Bool {
      let arguments = ProcessInfo.processInfo.arguments
      return arguments.contains("-UITestSummariesReviewed")
        || arguments.contains(noNeedsReviewArgument)
    }

    static let noNeedsReviewArgument = "-UITestNoNeedsReview"

    /// IMGMGR-350 checkpoint-2 (B3): a NINTH, on the same terms. One tier of `/api/folders`
    /// unreachable while the other two answer — "an unknown tier is not an empty tier" has no
    /// other way to be driven through the real UI.
    static var failArchiveFolders: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestFailArchiveFolders")
    }

    /// IMGMGR-502: `-UITestHoldPreviewOf <image id>` — that ONE photograph's `preview`-tier
    /// proxy is held until the UI test releases it (`DebugPreviewHold`); every other request
    /// answers at once. The delayed preview Triage's photo area must not paper over with the
    /// previous photograph. Independent of every other flag here.
    static let holdPreviewArgument = "-UITestHoldPreviewOf"

    static var heldPreviewImageID: Int? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: holdPreviewArgument),
        arguments.indices.contains(index + 1)
      else { return nil }
      return Int(arguments[index + 1])
    }

    static var holdsAPreview: Bool { heldPreviewImageID != nil }

    /// IMGMGR-502: every `preview`-tier proxy answers 404, so Triage shows "No preview".
    static var noPreviews: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestNoPreviews")
    }
  }

  #if canImport(UIKit)
    import UIKit

    /// Draws the DEBUG fixture proxy. Offscreen only, never on a shipping path — this whole
    /// file sits inside `#if DEBUG`, so a Release/TestFlight archive contains none of it.
    enum DebugStubProxyRenderer {
      static func jpeg(width: Int, height: Int, looked: Bool = false) -> Data? {
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
          // IMGMGR-382: the looked fixture is the same frame under a visible warm cast.
          if looked {
            UIColor(red: 0.95, green: 0.62, blue: 0.30, alpha: 0.35).setFill()
            context.fill(CGRect(origin: .zero, size: size))
          }
        }
        // The deployed render profile encodes at quality 85 (`PROXY_JPEG_QUALITY`, probed
        // 2026-08-30), so the fixture carries the same compression character.
        return image.jpegData(compressionQuality: 0.85)
      }
    }
  #endif
#endif
