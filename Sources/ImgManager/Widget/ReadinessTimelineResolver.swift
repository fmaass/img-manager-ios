import Foundation
import ImgManagerAPI

/// Everything the widget's `TimelineProvider` DECIDES, pulled out of WidgetKit so it can be
/// tested — the same posture `ForegroundRefresh`/`RootRouting`/`QueueCardDestination` already
/// take in this codebase ("pulled out as a pure function... so a test proves the PRODUCTION
/// decision, not a re-implementation of it"). The WidgetKit type in the extension target is a
/// thin adapter that owns nothing but the framework call shape.
///
/// The state table, in full — one row per way a refresh can end:
///
/// | credential                        | fetch    | snapshot | entry        | next refresh |
/// |-----------------------------------|----------|----------|--------------|--------------|
/// | `.absent`                         | not made | cleared  | `.signedOut` | retry        |
/// | `.present`, `expiresAt <= now`    | not made | kept     | `.signedOut` | retry        |
/// | `.error` (locked / unreadable)    | not made | kept     | `.lastKnown` | retry        |
/// | `.error`, no snapshot             | not made | kept     | `.noData`    | retry        |
/// | `.present`, valid                 | ok       | replaced | `.live`      | live         |
/// | `.present`, valid                 | failed   | kept     | `.lastKnown` | retry        |
/// | `.present`, valid, failed, none   | failed   | kept     | `.noData`    | retry        |
///
/// Two rows carry the decisions this lane was gated on:
///
/// - `.error` is NOT signed out. The credential's accessibility class is
///   `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` (owner decision: unchanged), so the item
///   is genuinely unreadable while the device is locked — rendering "Open the app to sign in"
///   there would be a lie, and would also contradict `CredentialStore`'s own rule that an
///   unreadable Keychain item is an error and never absence. A locked device shows the last
///   successful counts with their real "as of" time.
/// - Expiry is checked HERE. `CredentialStore.load()` returns any decodable credential as
///   `.present` without comparing `expiresAt`, and `AuthenticatedClientTransport` sends whatever
///   it is handed — only `AuthSession` renews, and an extension must never renew. So the
///   provider validates the expiry itself instead of spending a request to be told 401.
struct ReadinessTimelineResolver: Sendable {
  /// The interval requested after a SUCCESSFUL fetch. WidgetKit treats a reload policy as the
  /// earliest moment it should ask again, not a guarantee — actual cadence is budgeted by the
  /// system — which is precisely why "live" in this file means "these counts came back from a
  /// successful fetch", never "the deadline has not passed yet".
  static let liveRefreshInterval: TimeInterval = 30 * 60
  /// The shorter interval requested when the attempt did not produce fresh counts.
  static let retryRefreshInterval: TimeInterval = 15 * 60

  struct Resolution: Sendable, Equatable {
    let entry: ReadinessEntry
    /// The `.after(_:)` date the timeline asks WidgetKit for.
    let nextRefresh: Date
  }

  let loadCredential: @Sendable () async -> CredentialLoadResult
  let fetchSummaries: @Sendable () async throws -> [Components.Schemas.FolderSummary]
  let readSnapshot: @Sendable () -> ReadinessEntry?
  let writeSnapshot: @Sendable (ReadinessEntry) -> Void
  let clearSnapshot: @Sendable () -> Void

  func resolve(now: Date) async -> Resolution {
    switch await loadCredential() {
    case .absent:
      clearSnapshot()
      return retry(ReadinessEntryBuilder.signedOut(at: now), now: now)
    case .error:
      return retry(fallback(at: now), now: now)
    case .present(let credential):
      guard credential.expiresAt > now else {
        return retry(ReadinessEntryBuilder.signedOut(at: now), now: now)
      }
      guard let summaries = try? await fetchSummaries() else {
        return retry(fallback(at: now), now: now)
      }
      let entry = ReadinessEntryBuilder.live(from: summaries, fetchedAt: now)
      writeSnapshot(entry)
      return Resolution(entry: entry, nextRefresh: now.addingTimeInterval(Self.liveRefreshInterval))
    }
  }

  /// What to show when this attempt produced no fresh counts: the last successful reading if
  /// there is one, otherwise the explicit never-fetched state — never a zeroed-out entry
  /// wearing a fresh timestamp.
  private func fallback(at now: Date) -> ReadinessEntry {
    guard let previous = readSnapshot() else { return ReadinessEntryBuilder.noData(at: now) }
    return ReadinessEntryBuilder.lastKnown(carrying: previous, at: now)
  }

  private func retry(_ entry: ReadinessEntry, now: Date) -> Resolution {
    Resolution(entry: entry, nextRefresh: now.addingTimeInterval(Self.retryRefreshInterval))
  }
}
