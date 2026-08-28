import Testing

@testable import ImgManager

/// P7 coexistence, binding adjudication 7a — a pure sequencing/value test (mirrors
/// `RootRoutingTests`'s own posture), never a rendered-view test.
@Suite("ForegroundRefresh — P6/P7 coexistence ordering")
struct ForegroundRefreshTests {

  @Test("Signed in, a shoot selected: renew -> grid refresh -> queue refresh, IN THAT ORDER")
  func fullOrderWithSelection() async {
    var events: [String] = []
    await ForegroundRefresh.run(
      renew: { events.append("renew") },
      isSignedIn: { true },
      hasSelectedShoot: { true },
      refreshGrid: { events.append("grid") },
      refreshQueue: { events.append("queue") }
    )
    #expect(events == ["renew", "grid", "queue"])
  }

  @Test("Signed in, NO shoot selected: the queue still refreshes — grid is skipped, not queue")
  func queueRefreshesEvenWithoutSelection() async {
    var events: [String] = []
    await ForegroundRefresh.run(
      renew: { events.append("renew") },
      isSignedIn: { true },
      hasSelectedShoot: { false },
      refreshGrid: { events.append("grid") },
      refreshQueue: { events.append("queue") }
    )
    #expect(events == ["renew", "queue"])
  }

  @Test("Not signed in after renewal: neither grid nor queue refreshes")
  func signedOutSkipsBoth() async {
    var events: [String] = []
    await ForegroundRefresh.run(
      renew: { events.append("renew") },
      isSignedIn: { false },
      hasSelectedShoot: { true },
      refreshGrid: { events.append("grid") },
      refreshQueue: { events.append("queue") }
    )
    #expect(events == ["renew"])
  }
}
