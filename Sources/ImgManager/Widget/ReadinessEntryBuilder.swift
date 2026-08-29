import Foundation
import ImgManagerAPI

/// The pure mapping from what the server returned to what the widget shows. Every
/// `ReadinessEntry` in the app is built here — there is no second construction site — so the
/// "a timestamp only ever accompanies really-fetched counts" invariant is a property of ONE
/// file, and `ReadinessEntryBuilderTests` proves it over every state.
///
/// Section identity comes straight off `FolderSummary.readiness`, exactly as
/// `QueueSort.sections(from:)` does it: a summary whose wire string is outside this app's
/// vocabulary is EXCLUDED from every count (never bucketed into a default), so a schema drift
/// shows up as a shrinking total rather than as a wrong-but-plausible number. Nothing here
/// classifies — the client renders the server's own readiness identifier (spec :224-226).
enum ReadinessEntryBuilder {

  /// Counts per `ReadinessSection.rawValue`. Sections with no shoots are simply absent; the
  /// entry reads an absent key as zero.
  static func counts(from summaries: [Components.Schemas.FolderSummary]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for summary in summaries {
      guard let section = ReadinessSection(rawValue: summary.readiness.rawValue) else { continue }
      counts[section.rawValue, default: 0] += 1
    }
    return counts
  }

  /// A successful fetch. `fetchedAt` is the fetch's own moment and is also the entry's timeline
  /// date — this is the only path that may produce an "as of" time, because it is the only path
  /// where one is true.
  static func live(
    from summaries: [Components.Schemas.FolderSummary], fetchedAt: Date
  ) -> ReadinessEntry {
    ReadinessEntry(
      date: fetchedAt, state: .live, countsBySection: counts(from: summaries),
      fetchedAt: fetchedAt)
  }

  /// The last successful fetch, re-dated to now because the CURRENT attempt did not succeed.
  /// The counts and `fetchedAt` are carried over verbatim — "live" means "came from a
  /// successful fetch", never "the refresh deadline passed", so the age shown stays the real
  /// age of the data (this is the state a locked device renders between unlocks).
  ///
  /// A previous entry that itself carries no fetched counts (`.signedOut`/`.noData`) cannot
  /// become a last-known reading: there is nothing known. It degrades to `.noData`.
  static func lastKnown(carrying previous: ReadinessEntry, at date: Date) -> ReadinessEntry {
    guard previous.hasFetchedCounts, let fetchedAt = previous.fetchedAt else {
      return noData(at: date)
    }
    return ReadinessEntry(
      date: date, state: .lastKnown, countsBySection: previous.countsBySection,
      fetchedAt: fetchedAt)
  }

  /// No usable credential. No counts and no timestamp — a signed-out device must not keep
  /// showing this account's shoot counts, and there is no honest "as of" for numbers not shown.
  static func signedOut(at date: Date) -> ReadinessEntry {
    ReadinessEntry(date: date, state: .signedOut, countsBySection: [:], fetchedAt: nil)
  }

  /// Nothing has ever been fetched successfully. Distinct from `.live` with all-zero counts —
  /// a real fetch that returns no shoots is a zeroed LIVE reading with a real timestamp, and
  /// this is the absence of any reading at all.
  static func noData(at date: Date) -> ReadinessEntry {
    ReadinessEntry(date: date, state: .noData, countsBySection: [:], fetchedAt: nil)
  }
}
