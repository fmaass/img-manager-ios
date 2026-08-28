import Foundation

/// Where a URL the app was opened with meets the sign-in that is waiting for one.
///
/// The two are far apart: the URL arrives on the scene (`onOpenURL`, `RootView.swift`) and the
/// sign-in waiting for it is a coordinator created by a button several layers down. This is the
/// one seam between them — deliberately dumb: it holds at most one waiter, hands it each URL,
/// and keeps the ones nobody claims out of the flow entirely. Ported (simplified: one lane, one
/// generation counter instead of a dedicated `Attempt` type) from memos-ng-ios's
/// `MemosFeatures/NativeLoginCallbackInbox.swift`.
///
/// The entry is bound to the GENERATION that registered it, so an entry belonging to an ended
/// attempt cannot still be sitting here when the next one starts, and `stopWaiting(generation:)`
/// from a dead attempt cannot unregister the live one's.
@MainActor
final class NativeLoginCallbackInbox {
  static let shared = NativeLoginCallbackInbox()

  private struct Entry {
    let generation: Int
    let claim: (URL) -> Bool
  }

  private var entry: Entry?

  init() {}

  /// Readable so a test can assert a finished sign-in left nothing of itself behind.
  var waitingGeneration: Int? { entry?.generation }

  /// Wait for a callback on behalf of one attempt. At most one waits at a time; a later attempt
  /// replaces an earlier one.
  func waitForCallback(generation: Int, _ claim: @escaping (URL) -> Bool) {
    entry = Entry(generation: generation, claim: claim)
  }

  /// Stop waiting, but only if the entry still belongs to this generation — an attempt that
  /// ends after the next one has already registered must not silently unregister ITS entry.
  func stopWaiting(generation: Int) {
    guard entry?.generation == generation else { return }
    entry = nil
  }

  /// Offer a URL to whatever is waiting. Returns `true` if a waiting sign-in took it.
  @discardableResult
  func deliver(_ url: URL) -> Bool {
    guard let entry else { return false }
    return entry.claim(url)
  }
}
