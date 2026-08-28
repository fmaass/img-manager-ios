import Foundation

/// The defined renewal window (p1-spec-rev2.md §3: "automatic renewal on foreground when
/// entering a defined renewal window"). Pure and separately testable, so the boundary itself
/// — not just "some renewal happens" — is what a test pins down.
///
/// The native PAT lives 365 days (p1-spec-rev2.md §2 "Native PAT lifetime: 365 days"); renewing
/// with a week left is generous against a device that might not foreground again for a while,
/// while never renewing on every single foreground (a token minted seconds ago is nowhere near
/// its window).
enum RenewalWindow {
  static let defaultWindow: TimeInterval = 7 * 24 * 60 * 60

  /// Whether `expiresAt` is close enough to `now` (within `window`) to renew, or already past.
  /// An already-expired token is also `true`: a renewal attempt is the one thing that can still
  /// recover it if the server has not yet reaped it, and if it has, the renewal's own 401
  /// handling routes to sign-in — never silently left alone to keep failing every other request.
  static func shouldRenew(
    expiresAt: Date, now: Date = Date(), window: TimeInterval = defaultWindow
  ) -> Bool {
    expiresAt.timeIntervalSince(now) <= window
  }
}
