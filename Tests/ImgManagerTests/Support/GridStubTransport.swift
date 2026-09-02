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
  var facetsShouldFail = false
  /// WP13 P5a: `GET /api/marks/export`'s answer. Default mirrors the live probe's SHAPE
  /// (bare stems, `state: ["pick"]`, untruncated), not its 211-row size.
  var marksExport = Components.Schemas.MarksExport(
    count: 0, state: ["pick"], stems: [], truncated: false)
  var marksExportShouldFail = false
  /// WP13 P5a: `GET /api/status`'s answer.
  var statusResponse = Components.Schemas.StatusResponse(
    coverage: .init(imagesActive: 0, imagesMissing: 0, tiers: []),
    maintenance: .init(enabled: false), runs: [])
  var statusShouldFail = false
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
  /// IMGMGR-174: `GET /api/folders` answers PER TIER — the sidebar asks for local and archive
  /// separately, and "one tier is unreachable while the other answers" is a state the disclosure
  /// has to render distinctly, so the stub has to be able to produce it.
  private var folderTrees: [String: [Components.Schemas.FolderNode]] = [:]
  private var foldersFailingTiers: Set<String> = []

  /// P5: always what a `GET /api/images/{id}/neighbours` call receives.
  var neighboursPage = Components.Schemas.ImagePage(items: [], limit: 5, nextCursor: nil)

  /// WP13 P5b: `GET /api/image-groups`'s answer — the ONLY truthful section source. The default
  /// mirrors the live probe's SHAPE (2026-08-30, `group_by=camera`): headers whose counts sum to
  /// `total`, a `timezone` that is nil for a non-time key.
  var imageGroupsResult = Components.Schemas.ImageGroups(
    costHint: .standard, groupBy: .camera, headers: [], timezone: nil, total: 0)
  /// Self-disarming one-shot, same discipline as `facetsShouldFail`.
  var imageGroupsShouldFail = false

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

  // MARK: - WP12 facets reentrancy (compact filter surface)

  /// The same hold/release pattern as `listImages`/`neighbours` above, for
  /// `GET /api/facets`: lets a test keep ONE facets request genuinely in flight while a second
  /// `refreshFacets()` for the same query runs, which is the only way to prove the store's
  /// single-flight coalescing rather than to assume it.
  ///
  /// The release side holds a LIST of continuations, unlike the single-slot holds above: the
  /// whole point of the coalescing test is that a SECOND request must not arrive, and a
  /// single slot would let a regression overwrite the first request's continuation and hang the
  /// suite instead of failing it. With a list, a regression releases both and the test fails on
  /// its call-count assertion, which is a verdict rather than a timeout.
  private var facetsHoldEnabled = false
  private var facetsHasStarted = false
  private var facetsStartedContinuation: CheckedContinuation<Void, Never>?
  private var facetsReleaseContinuations: [CheckedContinuation<Void, Never>] = []

  func holdFacetsRequests(_ hold: Bool) { facetsHoldEnabled = hold }

  /// Suspends until a held facets call has genuinely entered `send(...)` — deterministic, not a
  /// sleep.
  func waitUntilFacetsStarted() async {
    if facetsHasStarted { return }
    await withCheckedContinuation { continuation in
      self.facetsStartedContinuation = continuation
    }
  }

  func releaseFacets() {
    let waiting = facetsReleaseContinuations
    facetsReleaseContinuations = []
    facetsHasStarted = false
    for continuation in waiting {
      continuation.resume()
    }
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

  // MARK: - WP12 Scene browse (stacks as display rows)

  /// Always what a `cursor == nil` (first-page / restart) `GET /api/browse/stacks` receives.
  private var browseStacksPage = Components.Schemas.StackBrowsePage(items: [], limit: 100)
  /// A SECOND (and beyond) page, keyed by the exact cursor value a request carries — the same
  /// shape `listImagesPagesByCursor` uses for flat paging.
  private var browseStacksPagesByCursor: [String: Components.Schemas.StackBrowsePage] = [:]
  /// The stack-mode twin of `listImagesRejectNonNilCursor`: models `cursor_scope_mismatch`, the
  /// undocumented 400 the endpoint answers a stale or foreign cursor with.
  private var browseStacksRejectNonNilCursor = false
  /// Each stack's FIRST membership page (`cursor == nil`), by stack id.
  private var stackMemberPages: [Int: Components.Schemas.StackMemberPage] = [:]
  /// Further membership pages, by the exact cursor value carried.
  private var stackMemberPagesByCursor: [String: Components.Schemas.StackMemberPage] = [:]
  /// What `GET /api/stacks/{id}` answers — the cover-refresh read, by stack id.
  private var stackRows: [Int: Components.Schemas.StackBrowseStackRow] = [:]

  func setBrowseStacksPage(_ page: Components.Schemas.StackBrowsePage) { browseStacksPage = page }
  func setBrowseStacksPage(
    _ page: Components.Schemas.StackBrowsePage, forCursor cursor: String
  ) {
    browseStacksPagesByCursor[cursor] = page
  }
  func setBrowseStacksRejectNonNilCursor(_ reject: Bool) { browseStacksRejectNonNilCursor = reject }
  func setStackMemberPage(_ page: Components.Schemas.StackMemberPage, forStack stackID: Int) {
    stackMemberPages[stackID] = page
  }
  func setStackMemberPage(
    _ page: Components.Schemas.StackMemberPage, forCursor cursor: String
  ) {
    stackMemberPagesByCursor[cursor] = page
  }
  func setStackRow(_ row: Components.Schemas.StackBrowseStackRow, forStack stackID: Int) {
    stackRows[stackID] = row
  }

  /// The same hold/release pattern as the other operations, for
  /// `GET /api/stacks/{id}/members` — what makes the single-flight guard testable
  /// deterministically: a second expand of the same scene lands while the first page is
  /// genuinely still on the wire, not after a sleep and a hope.
  private var membersHoldEnabled = false
  private var membersHasStarted = false
  private var membersStartedContinuation: CheckedContinuation<Void, Never>?
  private var membersReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdStackMembersRequests(_ hold: Bool) { membersHoldEnabled = hold }

  func waitUntilStackMembersStarted() async {
    if membersHasStarted { return }
    await withCheckedContinuation { continuation in
      self.membersStartedContinuation = continuation
    }
  }

  func releaseStackMembers() {
    membersReleaseContinuation?.resume()
    membersReleaseContinuation = nil
    membersHasStarted = false
  }

  // MARK: - WP14 P4 (IMGMGR-277): the three scene-edit writes

  /// What one scene edit answers. Modelled at the WIRE level, like `DownloadOutcome`: the 409 and
  /// 503 bodies are the ones the contract declares, so the tests decode them through the REAL
  /// generated client rather than through a hand-written model of it.
  enum StackEditOutcome: Sendable {
    case success(Components.Schemas.StackEditResult)
    /// 409 — extraction only; the only editor that declares one.
    case conflict(Components.Schemas.StackExtractConflict.CodePayload)
    /// 422 in the shape the operation DECLARES (`HTTPValidationError`: `detail` is an ARRAY).
    case refused
    /// 422 in the shape the server actually emits for a coded refusal — an OBJECT detail
    /// (`{"detail": {"code", "message"}}`), which the declared array schema cannot decode. Kept as
    /// its own case so the consequence is pinned by a test instead of assumed.
    case refusedCodedDetail(code: String)
    /// 503 `stack_edit_busy`, with the `Retry-After` the contract declares beside it.
    case busy(retryAfterSeconds: Int?)
    /// 404 with the absorb's own coded detail (IMGMGR-347): the scene, or a photograph the
    /// request named, is not there. Declared with NO content schema in the contract, so the body
    /// here is the server's real one and the client may not decode it — which is exactly the
    /// point of pinning the mapping with a test.
    case vanished(code: String)
  }

  /// One recorded scene-edit request, with its body EXACTLY as it went on the wire — which is what
  /// makes "the retry replayed the frozen payload" a byte comparison rather than a re-derivation.
  struct RecordedStackEdit: Sendable, Equatable {
    let operationID: String
    let path: String
    let body: Data
  }

  private(set) var recordedStackEdits: [RecordedStackEdit] = []

  /// Consumed in order, one per edit call; when it runs out, `stackEditOutcome` answers. A queue
  /// rather than a single slot because the 503 retry is precisely a SECOND call that must be able
  /// to answer differently from the first.
  private var stackEditOutcomes: [StackEditOutcome] = []
  private var stackEditOutcome: StackEditOutcome = .success(
    Components.Schemas.StackEditResult(
      dissolvedStackIds: [], loosenedImageIds: [], stackIds: []))

  func setStackEditOutcome(_ outcome: StackEditOutcome) { stackEditOutcome = outcome }
  func enqueueStackEditOutcomes(_ outcomes: [StackEditOutcome]) {
    stackEditOutcomes.append(contentsOf: outcomes)
  }

  private func nextStackEditOutcome() -> StackEditOutcome {
    stackEditOutcomes.isEmpty ? stackEditOutcome : stackEditOutcomes.removeFirst()
  }

  /// The same hold/release pattern the other operations carry, for the three edits — what makes
  /// "one edit at a time" provable deterministically: a second action lands while the first is
  /// genuinely still on the wire, not after a sleep and a hope.
  private var stackEditHoldEnabled = false
  private var stackEditHasStarted = false
  private var stackEditStartedContinuation: CheckedContinuation<Void, Never>?
  private var stackEditReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdStackEditRequests(_ hold: Bool) { stackEditHoldEnabled = hold }

  func waitUntilStackEditStarted() async {
    if stackEditHasStarted { return }
    await withCheckedContinuation { continuation in
      self.stackEditStartedContinuation = continuation
    }
  }

  func releaseStackEdit() {
    stackEditReleaseContinuation?.resume()
    stackEditReleaseContinuation = nil
    stackEditHasStarted = false
  }

  private func holdStackEditIfArmed() async {
    guard stackEditHoldEnabled else { return }
    stackEditHasStarted = true
    stackEditStartedContinuation?.resume()
    stackEditStartedContinuation = nil
    await withCheckedContinuation { continuation in
      self.stackEditReleaseContinuation = continuation
    }
  }

  private func recordStackEdit(_ request: HTTPRequest, _ body: HTTPBody?, _ operationID: String)
    async throws
  {
    let data: Data
    if let body {
      data = try await Data(collecting: body, upTo: 1024 * 1024)
    } else {
      data = Data()
    }
    recordedStackEdits.append(
      RecordedStackEdit(operationID: operationID, path: request.path ?? "", body: data))
  }

  private func stackEditResponse(_ outcome: StackEditOutcome) throws -> (HTTPResponse, HTTPBody?) {
    switch outcome {
    case .success(let result):
      return try jsonResponse(.ok, result)
    case .conflict(let code):
      return try jsonResponse(
        .conflict,
        Components.Schemas.StackExtractConflictError(
          detail: .init(code: code, message: "the scene is not in the state you asked about")))
    case .refused:
      // Written as raw JSON rather than through the generated `HTTPValidationError`: this is the
      // DECLARED shape and the point is that it is on the wire byte for byte, not that a Swift
      // value can be built for it (`ValidationError.loc` is a generated anyOf union whose spelling
      // is an implementation detail of the generator).
      return jsonBytes(
        .unprocessableContent,
        #"{"detail": [{"loc": ["body"], "msg": "refused", "type": "value_error"}]}"#)
    case .refusedCodedDetail(let code):
      return jsonBytes(
        .unprocessableContent, #"{"detail": {"code": "\#(code)", "message": "refused"}}"#)
    case .vanished(let code):
      return jsonBytes(.notFound, #"{"detail": {"code": "\#(code)", "message": "not here"}}"#)
    case .busy(let seconds):
      var response = HTTPResponse(status: .serviceUnavailable)
      response.headerFields[.contentType] = "application/json"
      if let seconds, let name = HTTPField.Name("Retry-After") {
        response.headerFields[name] = String(seconds)
      }
      let data = try JSONEncoder.grid.encode(
        Components.Schemas.StackEditBusyError(
          detail: .init(
            code: .stackEditBusy, message: "a maintenance lane holds this folder's lock")))
      return (response, HTTPBody(data))
    }
  }

  enum ProxyOutcome: Sendable {
    case ok(Data)
    case notModified
    case notFound
  }

  /// A `SentinelTransportError` for the NEXT proxy call (self-disarming, single-slot — same
  /// discipline as `listImagesShouldFail`): the fetch itself cannot reach the server, which
  /// `GridService.proxy` turns into `GridServiceError.unreachable`. Deliberately DISTINCT from
  /// `.notFound`, which is the tier simply not holding that proxy — the share lane must tell
  /// those two apart to choose between the offline copy and "no preview yet".
  var proxyShouldFail = false
  func setProxyShouldFail(_ fail: Bool) { proxyShouldFail = fail }

  /// The same hold/release pattern as `listImages`/`neighbours`/`markState`: lets a test land a
  /// focus change while a proxy fetch is genuinely in flight, so the share lane's stale-result
  /// discard is proven deterministically rather than by sleeping.
  private var proxyHoldEnabled = false
  private var proxyHasStarted = false
  private var proxyStartedContinuation: CheckedContinuation<Void, Never>?
  private var proxyReleaseContinuation: CheckedContinuation<Void, Never>?

  func holdProxyRequests(_ hold: Bool) { proxyHoldEnabled = hold }

  func waitUntilProxyStarted() async {
    if proxyHasStarted { return }
    await withCheckedContinuation { continuation in
      self.proxyStartedContinuation = continuation
    }
  }

  func releaseProxy() {
    proxyReleaseContinuation?.resume()
    proxyReleaseContinuation = nil
    proxyHasStarted = false
  }

  // MARK: - WP12 (IMGMGR-196): GET /api/images/{id}/download

  /// The download endpoint's outcomes, modelled at the WIRE level so the contract probe decodes
  /// them through the real generated `Client`. `.ok` carries bytes and a `Content-Disposition`
  /// the stub genuinely sends — which is the point: the probe proves the generated `Output.Ok`
  /// cannot reach either of them at this contract version.
  enum DownloadOutcome: Sendable {
    case ok(Data, contentDisposition: String?)
    /// 403 WITH `X-Img-Policy: raw-original` — the application's own policy answer.
    case rawOriginalPolicy
    /// 403 WITHOUT the header — a proxy/session refusal, which is a different thing entirely.
    case sessionForbidden
    case notFound
  }

  var downloadOutcome: DownloadOutcome = .notFound
  func setDownloadOutcome(_ outcome: DownloadOutcome) { downloadOutcome = outcome }

  private(set) var lastMarkStateRequest: Components.Schemas.MarkStateRequest?
  private(set) var lastTagsRequest: Components.Schemas.MarkTagsRequest?
  private(set) var callCounts: [String: Int] = [:]

  // MARK: - Recorded browse-request query parameters (WP12 compact filter surface)

  /// Every `GET /api/images` and `GET /api/facets` request's query parameters, in order, read
  /// off the URL the REAL generated `Client` built — so a test can prove a Stats-row tap
  /// actually reaches the server as a filter, rather than only that a Swift property changed.
  /// Names are the wire's own (`folder_id`, `rating_min`, `source_tier`, …), never the Swift
  /// property names, which is exactly what makes this a contract check.
  private(set) var recordedListImagesQueries: [[String: String]] = []
  /// Every proxy request path this transport saw, in order — WP13 P3 asserts the loupe asks for
  /// the `preview` tier and nothing else at any magnification, which needs the TIER, not just an
  /// operation-level call count.
  private(set) var recordedProxyRequests: [String] = []

  /// The `{tier}` path component of each recorded proxy request.
  var recordedProxyTiers: [String] {
    recordedProxyRequests.compactMap {
      URLComponents(string: $0)?.path.split(separator: "/").last.map(String.init)
    }
  }

  private(set) var recordedFacetsQueries: [[String: String]] = []
  /// WP13 P5b: the three query surfaces the sort/group contract has to agree across. The
  /// loupe-divergence guard is exactly "are the recorded `/api/images` and neighbours queries
  /// equal on sort/direction/group_by", and the stack Do-NOT is "does the recorded stacks query
  /// carry either" — neither is answerable without the wire query itself.
  private(set) var recordedNeighboursQueries: [[String: String]] = []
  private(set) var recordedBrowseStacksQueries: [[String: String]] = []
  private(set) var recordedImageGroupsQueries: [[String: String]] = []
  /// WP13 P5a: every `GET /api/marks/export` query, so a test can prove `format=txt` was never
  /// requested (the vendored document declares only `application/json` for its 200).
  private(set) var recordedMarksExportQueries: [[String: String]] = []

  var lastListImagesQuery: [String: String]? { recordedListImagesQueries.last }
  var lastFacetsQuery: [String: String]? { recordedFacetsQueries.last }
  var lastNeighboursQuery: [String: String]? { recordedNeighboursQueries.last }
  var lastBrowseStacksQuery: [String: String]? { recordedBrowseStacksQueries.last }
  var lastImageGroupsQuery: [String: String]? { recordedImageGroupsQueries.last }

  private func queryParameters(of request: HTTPRequest) -> [String: String] {
    guard let path = request.path, let items = URLComponents(string: path)?.queryItems else {
      return [:]
    }
    var parameters: [String: String] = [:]
    for item in items {
      guard let value = item.value else { continue }
      parameters[item.name] = value
    }
    return parameters
  }

  func setListImagesPage(_ page: Components.Schemas.ImagePage) { listImagesPage = page }
  func setListImagesRejectNonNilCursor(_ reject: Bool) { listImagesRejectNonNilCursor = reject }
  func setFacetsResult(_ result: Components.Schemas.ImageFacets) { facetsResult = result }
  /// A `GET /api/facets` failure for the NEXT call only (self-disarming single slot, same
  /// discipline as `detailShouldFail`) — models the Stats counts being unreachable while a
  /// filter tap still lands, which is what the "last good counts stand" rule is about.
  func setFacetsShouldFail(_ fail: Bool) { facetsShouldFail = fail }
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
  /// IMGMGR-174: one tier's `GET /api/folders` answer, and its reachability. The tier is the
  /// WIRE string, not the app's `GridSourceTier` — this file deliberately imports only the
  /// generated API and the transport types (never `ImgManager`), the same way it keys every other
  /// operation off the generated `operationID` rather than off an app-level vocabulary. Callers
  /// pass `GridSourceTier.<case>.rawValue`, which is that wire string.
  func setFolderTree(_ items: [Components.Schemas.FolderNode], tier: String) {
    folderTrees[tier] = items
  }
  func setFoldersShouldFail(_ fail: Bool, tier: String) {
    if fail {
      foldersFailingTiers.insert(tier)
    } else {
      foldersFailingTiers.remove(tier)
    }
  }
  // WP13 P5b (IMGMGR-221 part 2): the group-header endpoint.
  func setImageGroupsResult(_ result: Components.Schemas.ImageGroups) { imageGroupsResult = result }
  func setImageGroupsShouldFail(_ fail: Bool) { imageGroupsShouldFail = fail }
  func callCount(_ operationID: String) -> Int { callCounts[operationID] ?? 0 }

  // WP13 P5a (IMGMGR-221): the More menu's two read-only endpoints.
  func setMarksExport(_ export: Components.Schemas.MarksExport) { marksExport = export }
  func setMarksExportShouldFail(_ fail: Bool) { marksExportShouldFail = fail }
  func setStatusResponse(_ status: Components.Schemas.StatusResponse) { statusResponse = status }
  func setStatusShouldFail(_ fail: Bool) { statusShouldFail = fail }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCounts[operationID, default: 0] += 1

    switch operationID {
    case Operations.FolderTreeApiFoldersGet.id:
      let tier = queryParameters(of: request)["source_tier"] ?? "local"
      if foldersFailingTiers.contains(tier) {
        return (HTTPResponse(status: .internalServerError), nil)
      }
      return try jsonResponse(
        .ok, Components.Schemas.FolderTree(items: folderTrees[tier] ?? []))

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
      recordedListImagesQueries.append(queryParameters(of: request))
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

    case Operations.BrowseStacksApiBrowseStacksGet.id:
      recordedBrowseStacksQueries.append(queryParameters(of: request))
      let cursorValue = request.path.flatMap(URLComponents.init(string:))?
        .queryItems?.first(where: { $0.name == "cursor" })?.value
      if browseStacksRejectNonNilCursor, let cursorValue, !cursorValue.isEmpty {
        // No declared content for 400 on this operation either (the vendored document declares
        // 200 and 422 only), so the status code alone is what `.undocumented` exposes.
        return (HTTPResponse(status: .badRequest), nil)
      }
      if let cursorValue, !cursorValue.isEmpty, let page = browseStacksPagesByCursor[cursorValue] {
        return try jsonResponse(.ok, page)
      }
      return try jsonResponse(.ok, browseStacksPage)

    case Operations.ListStackMembersApiStacksStackIdMembersGet.id:
      let components = request.path.flatMap(URLComponents.init(string:))
      let cursorValue = components?.queryItems?.first(where: { $0.name == "cursor" })?.value
      // `/api/stacks/{id}/members` — the id is the second-to-last path component.
      let stackID = (components?.path.split(separator: "/").dropLast().last).flatMap { Int($0) }
      if membersHoldEnabled {
        membersHasStarted = true
        membersStartedContinuation?.resume()
        membersStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.membersReleaseContinuation = continuation
        }
      }
      if let cursorValue, !cursorValue.isEmpty, let page = stackMemberPagesByCursor[cursorValue] {
        return try jsonResponse(.ok, page)
      }
      guard let stackID, let page = stackMemberPages[stackID] else {
        let named = stackID.map { String($0) } ?? "?"
        throw SentinelTransportError(
          raw: "GridStubTransport: no stackMemberPage configured for \(named)")
      }
      return try jsonResponse(.ok, page)

    case Operations.GetStackApiStacksStackIdGet.id:
      let stackID = request.path.flatMap(URLComponents.init(string:))?
        .path.split(separator: "/").last.flatMap { Int($0) }
      guard let stackID, let row = stackRows[stackID] else {
        let named = stackID.map { String($0) } ?? "?"
        throw SentinelTransportError(
          raw: "GridStubTransport: no stackRow configured for \(named)")
      }
      return try jsonResponse(.ok, row)

    case Operations.ImageGroupsApiImageGroupsGet.id:
      recordedImageGroupsQueries.append(queryParameters(of: request))
      let resolvedGroups = imageGroupsResult
      if imageGroupsShouldFail {
        imageGroupsShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced imageGroups failure")
      }
      return try jsonResponse(.ok, resolvedGroups)

    case Operations.ImageFacetsApiFacetsGet.id:
      recordedFacetsQueries.append(queryParameters(of: request))
      // Resolved BEFORE any hold-suspend, same discipline as `listImages`: a held call returns
      // what was configured at REQUEST time, not what the stub drifted to while it sat held.
      let resolvedFacets = facetsResult
      if facetsHoldEnabled {
        facetsHasStarted = true
        facetsStartedContinuation?.resume()
        facetsStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.facetsReleaseContinuations.append(continuation)
        }
      }
      if facetsShouldFail {
        facetsShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced facets failure")
      }
      return try jsonResponse(.ok, resolvedFacets)

    case Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id:
      recordedNeighboursQueries.append(queryParameters(of: request))
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
      recordedProxyRequests.append(request.path ?? "")
      if proxyHoldEnabled {
        proxyHasStarted = true
        proxyStartedContinuation?.resume()
        proxyStartedContinuation = nil
        await withCheckedContinuation { continuation in
          self.proxyReleaseContinuation = continuation
        }
      }
      if proxyShouldFail {
        proxyShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced proxy failure")
      }
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

    case Operations.DownloadImageApiImagesImageIdDownloadGet.id:
      switch downloadOutcome {
      case .ok(let data, let contentDisposition):
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/octet-stream"
        if let contentDisposition, let name = HTTPField.Name("Content-Disposition") {
          response.headerFields[name] = contentDisposition
        }
        return (response, HTTPBody(data))
      case .rawOriginalPolicy:
        var response = HTTPResponse(status: .forbidden)
        // The exact header the backend sets (app/api/images.py) and the schema declares.
        if let name = HTTPField.Name("X-Img-Policy") {
          response.headerFields[name] = "raw-original"
        }
        return (response, nil)
      case .sessionForbidden:
        return (HTTPResponse(status: .forbidden), nil)
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
      case .conflict: return try staleRevisionConflict(for: lastMarkStateRequest?.imageIds ?? [])
      }

    // WP14 P4 (IMGMGR-277). All three take the SAME shape: record the request exactly as it went
    // on the wire, then answer with the next configured outcome. The body is captured BEFORE any
    // outcome is resolved, so a test can compare two attempts' bodies whatever either answered.
    case Operations.MergeStacksApiStacksMergePost.id,
      Operations.SplitStackApiStacksStackIdSplitPost.id,
      Operations.ExtractFromStackApiStacksStackIdExtractPost.id,
      // IMGMGR-347: the absorb takes the SAME shape, so it joins the same case rather than a
      // second copy of it — and its body is recorded on the wire like its siblings'.
      Operations.AbsorbIntoStackApiStacksStackIdAbsorbPost.id:
      try await recordStackEdit(request, body, operationID)
      await holdStackEditIfArmed()
      return try stackEditResponse(nextStackEditOutcome())

    case Operations.ExportMarksApiMarksExportGet.id:
      recordedMarksExportQueries.append(queryParameters(of: request))
      if marksExportShouldFail {
        marksExportShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced marksExport failure")
      }
      return try jsonResponse(.ok, marksExport)

    case Operations.StatusApiStatusGet.id:
      if statusShouldFail {
        statusShouldFail = false
        throw SentinelTransportError(raw: "GridStubTransport: forced status failure")
      }
      return try jsonResponse(.ok, statusResponse)

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
      case .conflict: return try staleRevisionConflict(for: lastTagsRequest?.imageIds ?? [])
      }

    default:
      throw SentinelTransportError(raw: "GridStubTransport: unexpected operationID: \(operationID)")
    }
  }

  /// The 409 the server actually sends since the WP14 re-vendor (IMGMGR-177's
  /// `StaleMarkRevisionError`, now DECLARED on both mark writes). A bodyless 409 no longer
  /// decodes through the generated client at all, so it surfaces as `.unreachable` and every
  /// conflict test would be measuring a decode failure instead of a refusal. The submitted ids
  /// are echoed as the stale set, which is the shape `_refuse_if_stale` produces: the whole
  /// request is refused, so every id named in it is one the caller has to re-read.
  private func staleRevisionConflict(for imageIDs: [Int]) throws -> (HTTPResponse, HTTPBody?) {
    try jsonResponse(
      .conflict,
      Components.Schemas.StaleMarkRevisionError(
        detail: .init(code: .staleMarkRevision, staleImageIds: imageIDs)))
  }

  /// A JSON response whose body is written LITERALLY — for shapes the generated types cannot
  /// express (a coded object where the declared schema says array) or where the wire bytes
  /// themselves are the subject.
  private func jsonBytes(_ status: HTTPResponse.Status, _ json: String) -> (
    HTTPResponse, HTTPBody?
  ) {
    var response = HTTPResponse(status: status)
    response.headerFields[.contentType] = "application/json"
    return (response, HTTPBody(Data(json.utf8)))
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
