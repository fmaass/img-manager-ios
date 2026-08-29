import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// P4's own test-only stub transport — a sibling of `StubClientTransport` (P3's own, confined
/// to its three read-only operations by design), routing P4's seven operations by the real
/// generated `operationID` strings, so every test decodes through the REAL generated `Client`
/// exactly as production does (same discipline as `StubClientTransport`'s own doc comment).
actor GridStubTransport: ClientTransport {
  enum MarkMutationOutcome: Sendable {
    case success(Components.Schemas.MarksApplied)
    case conflict
  }

  /// Always what a `cursor == nil` (first-page / restart) request receives.
  var listImagesPage = Components.Schemas.ImagePage(items: [], limit: 100, nextCursor: nil)
  /// When true, a request that DOES carry a non-empty `cursor` gets the undocumented
  /// cursor-fingerprint 400 instead of `listImagesPage` — modeling the real backend
  /// (`app/api/cursor.py`): a fresh page-one request always succeeds; only a stale/mismatched
  /// cursor is refused. This lets a single test prove both the refusal AND that the restart
  /// (which resends with `cursor == nil`) actually lands on real data again.
  var listImagesRejectNonNilCursor = false
  var facetsResult = Components.Schemas.ImageFacets(total: 0)
  var detailResult: Components.Schemas.ImageDetail?
  /// Diff-gate round 3, B6: a `GET /api/images/{id}` failure for the NEXT call (self-disarming
  /// one-shot, same discipline as `listImagesShouldFail`) — models the per-id detail() fallback
  /// itself being unreachable, distinct from `detailResult` simply not being configured.
  var detailShouldFail = false
  var proxyOutcome: ProxyOutcome = .ok(Data([0xFF, 0xD8, 0xFF, 0xD9]))
  var markStateOutcome: MarkMutationOutcome = .success(
    Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
  private var markStateOutcomeByState:
    [Components.Schemas.MarkStateRequest.StatePayload: MarkMutationOutcome] = [:]
  var tagsOutcome: MarkMutationOutcome = .success(
    Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
  /// P5: always what a `GET /api/images/{id}/neighbours` call receives.
  var neighboursPage = Components.Schemas.ImagePage(items: [], limit: 5, nextCursor: nil)

  // MARK: - P7 folder-summaries (QueueService/QueueStore tests)

  var folderSummariesResult: [Components.Schemas.FolderSummary] = []
  /// Self-disarming, single-slot — same discipline as `listImagesShouldFail`/`detailShouldFail`.
  var folderSummariesShouldFail = false
  func setFolderSummariesResult(_ items: [Components.Schemas.FolderSummary]) {
    folderSummariesResult = items
  }
  func setFolderSummariesShouldFail(_ fail: Bool) { folderSummariesShouldFail = fail }

  /// Same hold/release pattern as `listImages`/`neighbours`/`markState` above — lets a
  /// `QueueStore` test prove `isRefreshing`/debounce-coalescing behaviour deterministically
  /// rather than by sleeping.
  private var folderSummariesHoldEnabled = false
  private var folderSummariesHasStarted = false
  private var folderSummariesStartedContinuation: CheckedContinuation<Void, Never>?
  private var folderSummariesReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdFolderSummariesRequests(_ hold: Bool) { folderSummariesHoldEnabled = hold }

  func waitUntilFolderSummariesStarted() async {
    if folderSummariesHasStarted { return }
    await withCheckedContinuation { continuation in
      self.folderSummariesStartedContinuation = continuation
    }
  }

  func releaseFolderSummaries() {
    folderSummariesReleaseContinuation?.resume()
    folderSummariesReleaseContinuation = nil
    folderSummariesHasStarted = false
  }

  // MARK: - P5 rapid-double-mutation race (BINDING fold addendum)

  /// When armed, a `SetMarkStateApiMarksStatePost` call suspends inside `send(...)` — same
  /// pattern as `JoinableRenewalStubTransport` — until `releaseMarkState()` is called, so a
  /// test can prove a SECOND mutation attempted while the first is genuinely in flight is
  /// refused rather than racing it.
  private var markStateHoldEnabled = false
  private var markStateHasStarted = false
  private var markStateStartedContinuation: CheckedContinuation<Void, Never>?
  private var markStateReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdMarkStateRequests(_ hold: Bool) { markStateHoldEnabled = hold }

  /// Suspends until a held `SetMarkStateApiMarksStatePost` call has genuinely entered
  /// `send(...)` — deterministic, not a sleep.
  func waitUntilMarkStateStarted() async {
    if markStateHasStarted { return }
    await withCheckedContinuation { continuation in
      self.markStateStartedContinuation = continuation
    }
  }

  /// Lets a held `send(...)` proceed to return its configured outcome.
  func releaseMarkState() {
    markStateReleaseContinuation?.resume()
    markStateReleaseContinuation = nil
    markStateHasStarted = false
  }

  // MARK: - WP8 P7 round-2 closure, B2: in-flight tag-mutation race (diff-gate round 3)

  /// Same hold/release pattern as `markState` above, for `EditMarkTagsApiMarksTagsPost` — lets a
  /// test prove `addTag`'s own commit-signal fix (mutationCommitCount increments regardless of a
  /// racing generation change) deterministically rather than by sleeping.
  private var tagsHoldEnabled = false
  private var tagsHasStarted = false
  private var tagsStartedContinuation: CheckedContinuation<Void, Never>?
  private var tagsReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdTagsRequests(_ hold: Bool) { tagsHoldEnabled = hold }

  func waitUntilTagsStarted() async {
    if tagsHasStarted { return }
    await withCheckedContinuation { continuation in
      self.tagsStartedContinuation = continuation
    }
  }

  func releaseTags() {
    tagsReleaseContinuation?.resume()
    tagsReleaseContinuation = nil
    tagsHasStarted = false
  }

  // MARK: - P5 stale-neighbours race (diff-gate round, 2026-08-28)

  /// The same hold pattern for `GET /api/images/{id}/neighbours`: lets a test land a
  /// shoot/filter switch (or a concurrent grid merge) while a neighbours response is
  /// genuinely in flight, proving stale-response discard and dedup-vs-exhaustion behaviour
  /// deterministically rather than by sleeping.
  private var neighboursHoldEnabled = false
  private var neighboursHasStarted = false
  private var neighboursStartedContinuation: CheckedContinuation<Void, Never>?
  private var neighboursReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdNeighboursRequests(_ hold: Bool) { neighboursHoldEnabled = hold }

  /// Suspends until a held neighbours call has genuinely entered `send(...)`.
  func waitUntilNeighboursStarted() async {
    if neighboursHasStarted { return }
    await withCheckedContinuation { continuation in
      self.neighboursStartedContinuation = continuation
    }
  }

  func releaseNeighbours() {
    neighboursReleaseContinuation?.resume()
    neighboursReleaseContinuation = nil
    neighboursHasStarted = false
  }

  /// P6: a `GET /api/images/{id}/neighbours` failure (a non-.ok, non-404 status), so
  /// `GridService.neighbours` throws `.unreachable` — models the "neighbours-catch guard" fix
  /// (the FAILURE path needs the same generation guard the success path already had).
  var neighboursShouldFail = false
  func setNeighboursShouldFail(_ fail: Bool) { neighboursShouldFail = fail }

  // MARK: - P6 authoritative refresh: multi-page-by-cursor, generation-fence hold, failures

  /// A SECOND (and beyond) page, keyed by the exact cursor value a request carries — lets a
  /// test model a real multi-page shoot (`listImagesPage` is always page 1, cursor==nil) without
  /// needing the blanket `listImagesRejectNonNilCursor` refusal for every non-nil cursor.
  private var listImagesPagesByCursor: [String: Components.Schemas.ImagePage] = [:]
  func setListImagesPage(_ page: Components.Schemas.ImagePage, forCursor cursor: String) {
    listImagesPagesByCursor[cursor] = page
  }

  /// Rejects EXACTLY the next non-nil-cursor request with the same undocumented 400
  /// `listImagesRejectNonNilCursor` models, then self-disarms — so a SECOND attempt at the same
  /// cursor value (e.g. `performAuthoritativeRefresh`'s own restart-from-page-one-then-retry
  /// loop) succeeds normally. Distinct from `listImagesRejectNonNilCursor`, which stays on
  /// indefinitely until explicitly turned off.
  private var listImagesRejectNonNilCursorOnceArmed = false
  func armListImagesRejectNonNilCursorOnce() { listImagesRejectNonNilCursorOnceArmed = true }

  /// A `SentinelTransportError` (network-level failure, never a declared HTTP status) for the
  /// NEXT `ListImagesApiImagesGet` call — models an authoritative-refresh re-read that itself
  /// cannot reach the server (`GridServiceError.unreachable`), distinct from the 400
  /// cursor-fingerprint refusal above.
  var listImagesShouldFail = false
  func setListImagesShouldFail(_ fail: Bool) { listImagesShouldFail = fail }

  /// Holds exactly the NEXT `ListImagesApiImagesGet` call (self-disarming, single-slot — same
  /// discipline as the neighbours/markState holds above) so a test can let a scope change land
  /// (its OWN, un-held, `ListImagesApiImagesGet` call) while the FIRST call is still suspended,
  /// then release the first to prove its now-stale result is discarded by the generation fence.
  private var listImagesHoldArmed = false
  private var listImagesHasStarted = false
  private var listImagesStartedContinuation: CheckedContinuation<Void, Never>?
  private var listImagesReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdNextListImagesRequest() { listImagesHoldArmed = true }

  func waitUntilListImagesStarted() async {
    if listImagesHasStarted { return }
    await withCheckedContinuation { continuation in
      self.listImagesStartedContinuation = continuation
    }
  }

  func releaseListImages() {
    listImagesReleaseContinuation?.resume()
    listImagesReleaseContinuation = nil
    listImagesHasStarted = false
  }

  enum ProxyOutcome: Sendable {
    case ok(Data)
    case notModified
    case notFound
  }

  private(set) var lastMarkStateRequest: Components.Schemas.MarkStateRequest?
  private(set) var lastTagsRequest: Components.Schemas.MarkTagsRequest?
  private(set) var callCounts: [String: Int] = [:]

  func setListImagesPage(_ page: Components.Schemas.ImagePage) { listImagesPage = page }
  func setListImagesRejectNonNilCursor(_ reject: Bool) { listImagesRejectNonNilCursor = reject }
  func setFacetsResult(_ result: Components.Schemas.ImageFacets) { facetsResult = result }
  func setDetailResult(_ result: Components.Schemas.ImageDetail) { detailResult = result }
  func setDetailShouldFail(_ fail: Bool) { detailShouldFail = fail }
  func setProxyOutcome(_ outcome: ProxyOutcome) { proxyOutcome = outcome }
  func setMarkStateOutcome(_ outcome: MarkMutationOutcome) { markStateOutcome = outcome }
  /// Overrides `markStateOutcome` for requests whose `state` matches — lets a test make ONE
  /// state-group in a mixed-state batch undo succeed while another 409s (diff-gate round 2,
  /// blocker 6's mixed-state test needs exactly this to be deterministic).
  func setMarkStateOutcome(
    _ outcome: MarkMutationOutcome, forState state: Components.Schemas.MarkStateRequest.StatePayload
  ) {
    markStateOutcomeByState[state] = outcome
  }
  func setTagsOutcome(_ outcome: MarkMutationOutcome) { tagsOutcome = outcome }
  func setNeighboursPage(_ page: Components.Schemas.ImagePage) { neighboursPage = page }
  func callCount(_ operationID: String) -> Int { callCounts[operationID] ?? 0 }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCounts[operationID, default: 0] += 1

    switch operationID {
    case Operations.FolderTreeApiFoldersGet.id:
      return try jsonResponse(.ok, Components.Schemas.FolderTree(items: []))

    case Operations.FolderSummariesApiFolderSummariesGet.id:
      // Resolved BEFORE any hold-suspend, same discipline as `listImages` above: a held call
      // truthfully returns what was configured at REQUEST time, so a test can prove a stale
      // (slower) response never clobbers a newer one even after the config changed mid-flight.
      let resolvedItems = folderSummariesResult
      if folderSummariesHoldEnabled {
        folderSummariesHasStarted = true
        folderSummariesStartedContinuation?.resume()
        folderSummariesStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.folderSummariesReleaseContinuation = continuation
        }
      }
      if folderSummariesShouldFail {
        folderSummariesShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced folderSummaries failure")
      }
      return try jsonResponse(.ok, Components.Schemas.FolderSummaryList(items: resolvedItems))

    case Operations.ListImagesApiImagesGet.id:
      let cursorValue = request.path.flatMap(URLComponents.init(string:))?
        .queryItems?.first(where: { $0.name == "cursor" })?.value
      if listImagesShouldFail {
        listImagesShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced listImages failure")
      }
      if listImagesRejectNonNilCursor, let cursorValue, !cursorValue.isEmpty {
        // No declared content for this status in the vendored schema (see GridService's own
        // doc comment) — the real backend's actual 400 body is irrelevant to what the
        // generated client can express; only the STATUS CODE is what `.undocumented` exposes.
        return (HTTPResponse(status: .badRequest), nil)
      }
      if listImagesRejectNonNilCursorOnceArmed, let cursorValue, !cursorValue.isEmpty {
        listImagesRejectNonNilCursorOnceArmed = false
        return (HTTPResponse(status: .badRequest), nil)
      }
      // Resolved BEFORE any hold-suspend below — a held call returns what was configured at
      // REQUEST time, not whatever the stub's config drifted to while it sat suspended (matches
      // a real server, which computes its response from state at request time; it is also what
      // makes the generation-fence test meaningful: the stale call must carry OLD-scope data
      // for "was it discarded" to be a real question, not `setListImagesPage` called again
      // afterward silently making the stale and fresh responses identical).
      let resolvedPage: Components.Schemas.ImagePage
      if let cursorValue, !cursorValue.isEmpty, let page = listImagesPagesByCursor[cursorValue] {
        resolvedPage = page
      } else {
        resolvedPage = listImagesPage
      }
      if listImagesHoldArmed {
        listImagesHoldArmed = false
        listImagesHasStarted = true
        listImagesStartedContinuation?.resume()
        listImagesStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.listImagesReleaseContinuation = continuation
        }
      }
      return try jsonResponse(.ok, resolvedPage)

    case Operations.ImageFacetsApiFacetsGet.id:
      return try jsonResponse(.ok, facetsResult)

    case Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id:
      if neighboursHoldEnabled {
        neighboursHasStarted = true
        neighboursStartedContinuation?.resume()
        neighboursStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.neighboursReleaseContinuation = continuation
        }
      }
      // Checked AFTER the hold/release above (never before) — a test arms this WHILE the call
      // is suspended, so the failure is what the RELEASE reveals, not the arrival.
      if neighboursShouldFail {
        neighboursShouldFail = false
        return (HTTPResponse(status: .internalServerError), nil)
      }
      return try jsonResponse(.ok, neighboursPage)

    case Operations.GetImageApiImagesImageIdGet.id:
      if detailShouldFail {
        detailShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced detail failure")
      }
      guard let detailResult else {
        throw SentinelTransportError(raw: "GridStubTransport: no detailResult configured")
      }
      return try jsonResponse(.ok, detailResult)

    case Operations.GetProxyApiImagesImageIdProxyTierGet.id:
      switch proxyOutcome {
      case .ok(let data):
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        return (response, HTTPBody(data))
      case .notModified:
        return (HTTPResponse(status: .notModified), nil)
      case .notFound:
        return (HTTPResponse(status: .notFound), nil)
      }

    case Operations.SetMarkStateApiMarksStatePost.id:
      if let body {
        let data = try await Data(collecting: body, upTo: 1024 * 1024)
        lastMarkStateRequest = try? JSONDecoder.grid.decode(
          Components.Schemas.MarkStateRequest.self, from: data)
      }
      // P5 rapid-double-mutation race test: the request is already captured above (so a test
      // can inspect it while held), and the hold happens AFTER that capture, mirroring
      // `JoinableRenewalStubTransport`'s own started/release continuation pair.
      if markStateHoldEnabled {
        markStateHasStarted = true
        markStateStartedContinuation?.resume()
        markStateStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.markStateReleaseContinuation = continuation
        }
      }
      let effectiveOutcome =
        lastMarkStateRequest.flatMap { markStateOutcomeByState[$0.state] } ?? markStateOutcome
      switch effectiveOutcome {
      case .success(let applied): return try jsonResponse(.ok, applied)
      case .conflict: return (HTTPResponse(status: .conflict), nil)
      }

    case Operations.EditMarkTagsApiMarksTagsPost.id:
      if let body {
        let data = try await Data(collecting: body, upTo: 1024 * 1024)
        lastTagsRequest = try? JSONDecoder.grid.decode(
          Components.Schemas.MarkTagsRequest.self, from: data)
      }
      if tagsHoldEnabled {
        tagsHasStarted = true
        tagsStartedContinuation?.resume()
        tagsStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.tagsReleaseContinuation = continuation
        }
      }
      switch tagsOutcome {
      case .success(let applied): return try jsonResponse(.ok, applied)
      case .conflict: return (HTTPResponse(status: .conflict), nil)
      }

    default:
      throw SentinelTransportError(raw: "GridStubTransport: unexpected operationID: \(operationID)")
    }
  }

  private func jsonResponse<T: Encodable>(
    _ status: HTTPResponse.Status, _ body: T
  ) throws -> (HTTPResponse, HTTPBody?) {
    var response = HTTPResponse(status: status)
    response.headerFields[.contentType] = "application/json"
    let data = try JSONEncoder.grid.encode(body)
    return (response, HTTPBody(data))
  }
}

extension JSONEncoder {
  /// The generated types decode/encode `Date` fields via ISO-8601 — mirrored here so a
  /// request-body round-trip (`lastMarkStateRequest`, etc.) never mismatches the generated
  /// `Client`'s own encoder configuration.
  fileprivate static let grid: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
}

extension JSONDecoder {
  fileprivate static let grid: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
