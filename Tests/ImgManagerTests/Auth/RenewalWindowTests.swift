import Foundation
import Testing

@testable import ImgManager

@Suite("RenewalWindow.shouldRenew")
struct RenewalWindowTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let window: TimeInterval = 7 * 24 * 60 * 60

  @Test("well outside the window (30 days left) — do not renew")
  func farFromExpiry() {
    let expiresAt = now.addingTimeInterval(30 * 24 * 60 * 60)
    #expect(!RenewalWindow.shouldRenew(expiresAt: expiresAt, now: now, window: window))
  }

  @Test("just outside the window (window + 1 second left) — do not renew")
  func justOutsideWindow() {
    let expiresAt = now.addingTimeInterval(window + 1)
    #expect(!RenewalWindow.shouldRenew(expiresAt: expiresAt, now: now, window: window))
  }

  @Test("exactly at the window boundary — renew (inclusive)")
  func exactlyAtBoundary() {
    let expiresAt = now.addingTimeInterval(window)
    #expect(RenewalWindow.shouldRenew(expiresAt: expiresAt, now: now, window: window))
  }

  @Test("inside the window (1 day left) — renew")
  func insideWindow() {
    let expiresAt = now.addingTimeInterval(24 * 60 * 60)
    #expect(RenewalWindow.shouldRenew(expiresAt: expiresAt, now: now, window: window))
  }

  @Test("already expired — renew (the last chance to recover it)")
  func alreadyExpired() {
    let expiresAt = now.addingTimeInterval(-60)
    #expect(RenewalWindow.shouldRenew(expiresAt: expiresAt, now: now, window: window))
  }

  @Test("the default window is 7 days")
  func defaultWindowIsSevenDays() {
    #expect(RenewalWindow.defaultWindow == 7 * 24 * 60 * 60)
  }
}
