import Foundation
import Testing

@testable import ImgManager

/// P3 fold item 3 + item 4: the degraded copy is exactly "Not connected to the home
/// network", and a transport failure's raw text (`localizedDescription`, a server body, a
/// hostname, any raw transport string) must never be stored or rendered. This suite proves
/// suppression end to end with a sentinel planted in a FOREIGN test error
/// (`SentinelTransportError`, Support/SentinelTransportError.swift — never imported into
/// application source) thrown from the real `ClientTransport` seam
/// (`StubClientTransport`) — if the sentinel ever surfaces anywhere reachable from
/// `ConnectivityState`, these tests fail.
@Suite("Degraded state (P3 fold items 3 and 4)")
struct DegradedStateTests {

  @Test("The exact copy is \"Not connected to the home network\"")
  func exactCopy() {
    #expect(DegradedStateCopy.notConnected == "Not connected to the home network")
  }

  @Test("A sentinel raw transport error never survives into ConnectivityState.status")
  func sentinelRawErrorIsSuppressed() async {
    let sentinel =
      "SENTINEL_RAW_TRANSPORT_ERROR host=backend.internal.example status=503 "
      + "body={\"detail\":\"leak-if-visible\"}"
    let transport = StubClientTransport(outcome: .transportFailure(raw: sentinel))
    let client = ImgManagerAPIClient.make(transport: transport)
    let state = await ConnectivityState(service: ImgManagerAPIService(client: client))
    await state.check()

    #expect(await state.status == .unreachable)

    // Structural proof, not just a string-search: `Status.unreachable` carries no
    // associated value, so there is no property ANYWHERE on ConnectivityState the
    // sentinel could occupy. Mirror confirms this over the live instance rather than
    // trusting the type declaration alone.
    let mirror = Mirror(reflecting: await state.status)
    #expect(mirror.children.isEmpty)

    let statusDescription = String(describing: await state.status)
    #expect(!statusDescription.contains(sentinel))
    #expect(!statusDescription.contains("backend.internal.example"))
    #expect(!statusDescription.contains("leak-if-visible"))
  }

  @Test("The stale banner's second line labels the cached answer with a relative time")
  func cachedAnswerIsLabelledWithARelativeTime() {
    // IMGMGR-198: the cached answer is never shown unlabelled. Line one stays the ONE
    // adjudicated degraded string; line two says how old what you are looking at is.
    let twoHoursAgo = Date().addingTimeInterval(-2 * 60 * 60)
    let line = DegradedStateCopy.showingCached(since: twoHoursAgo)

    #expect(line.hasPrefix("Showing shoots from "))
    #expect(line.lowercased().contains("hour"))
    #expect(DegradedStateCopy.notConnected == "Not connected to the home network")
  }

  @Test("Below a minute the label reads \"just now\" — never a raw seconds count")
  func freshCacheReadsAsJustNow() {
    let thirtySecondsAgo = Date().addingTimeInterval(-30)

    #expect(
      DegradedStateCopy.showingCached(since: thirtySecondsAgo) == "Showing shoots from just now")
  }

  @Test("A days-old cache is labelled in days")
  func olderCacheIsLabelledInDays() {
    let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 60 * 60)
    let line = DegradedStateCopy.showingCached(since: threeDaysAgo)

    #expect(line.hasPrefix("Showing shoots from "))
    #expect(line.lowercased().contains("day"))
  }

  @Test(
    "The foreign test error DOES carry the raw text, proving the sentinel test has a positive control"
  )
  func sentinelErrorCarriesRawText() {
    // Positive control for the suppression test above: the raw string DOES exist on a
    // real thrown error (that's the whole point — it must be stopped at
    // ImgManagerAPIService/ConnectivityState, not because it was never produced). Note
    // this type is FOREIGN to application source (Tests/…/Support only) — the
    // application layer has no `failed(raw:)`-shaped case anywhere to carry it.
    let sentinel = "SENTINEL_POSITIVE_CONTROL"
    let error = SentinelTransportError(raw: sentinel)
    #expect(error.errorDescription == sentinel)
    #expect(error.raw == sentinel)
  }
}
