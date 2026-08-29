import Foundation

/// The widget kind string, in ONE place: `StaticConfiguration(kind:)` in the extension registers
/// it and `WidgetCenter.reloadTimelines(ofKind:)` in the app names it. A literal duplicated at
/// those two ends silently stops reloading anything the moment one of them is edited, and
/// nothing fails — the widget just goes stale — which is exactly the class of bug a shared
/// constant removes. This file is compiled into BOTH targets (project.yml lists it in the
/// widget target's `sources:`), so the two ends cannot drift.
enum ReadinessWidgetKind {
  static let value = "ReadinessWidget"
}

/// WHY the counts in a `ReadinessEntry` say what they say. Rendering copy hangs off this, and so
/// does the one invariant the entry has: a timestamp is shown only when a real fetch produced
/// the numbers.
///
/// The distinction between `.signedOut` and `.noData` is the same one `CredentialStore` already
/// draws and this app treats as load-bearing (`CredentialStore.swift`'s own doc comment: "A
/// missing entitlement, corrupted JSON or an unreadable Keychain item is an ERROR — never
/// 'signed out'"). A locked device — the credential's accessibility class is
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, so between unlocks the item is genuinely
/// unreadable — must therefore never render "Open the app to sign in": it renders the last
/// successful counts with their real "as of" time (`.lastKnown`), or, if there has never been a
/// successful fetch, `.noData`.
enum ReadinessEntryState: String, Codable, Sendable, Equatable {
  /// The counts in this entry came from the fetch that produced it.
  case live
  /// The latest attempt did not succeed; the counts are the last successful fetch's, and
  /// `fetchedAt` is when THAT fetch happened — never now.
  case lastKnown
  /// There is definitively no credential on this device (`CredentialLoadResult.absent`), or the
  /// stored one is past its expiry and only the app can renew it. No counts, no timestamp.
  case signedOut
  /// Nothing has ever been fetched successfully AND the current attempt could not run or
  /// failed. No counts, no timestamp — the never-fetched state, stated explicitly rather than
  /// rendered as a zeroed-out "live" reading.
  case noData
}

/// One WidgetKit timeline entry's whole payload — deliberately SwiftUI-free and WidgetKit-free
/// (the `TimelineEntry` conformance is declared in the extension target, which is the only
/// target that needs it) so the app target and `ImgManagerTests` can build and exercise it.
///
/// Counts are keyed by `ReadinessSection.rawValue` rather than by the enum itself: the section
/// enum lives in `QueueModels.swift`, which this lane must not edit, and it is not `Codable`.
/// A `[String: Int]` needs no conformance added to somebody else's type, and an absent key is
/// simply zero — the same "zero-item sections are not rendered" posture the queue home takes.
struct ReadinessEntry: Codable, Sendable, Equatable {
  /// The moment this entry is FOR — WidgetKit's own timeline clock. Always "now" at build time;
  /// it is not the data's age (that is `fetchedAt`).
  let date: Date
  let state: ReadinessEntryState
  /// Keyed by `ReadinessSection.rawValue`; an absent key means zero.
  let countsBySection: [String: Int]
  /// When the counts were actually fetched from the server. `nil` for `.signedOut`/`.noData` —
  /// there is no honest "as of" for numbers that were never fetched, and inventing `date` here
  /// would be exactly the fabricated timestamp this entry is designed not to have.
  let fetchedAt: Date?

  /// The one invariant every construction path must satisfy, asserted by
  /// `ReadinessEntryBuilderTests` rather than trusted: a timestamp exists if and only if real
  /// fetched counts are being shown.
  var hasFetchedCounts: Bool {
    state == .live || state == .lastKnown
  }

  func count(for section: ReadinessSection) -> Int {
    countsBySection[section.rawValue] ?? 0
  }

  /// One section and its number. A named struct rather than a labelled tuple because key paths
  /// (`\.section`, `\.count`) do not reach into tuple elements, and reading these back by name is
  /// what the tests do.
  struct SectionCount: Equatable, Sendable {
    let section: ReadinessSection
    let count: Int
  }

  /// Presentation order is `ReadinessSection.displayOrder` — the queue home's ONE ordering
  /// authority (QueueModels.swift), never a second order invented here.
  var orderedCounts: [SectionCount] {
    ReadinessSection.displayOrder.map { SectionCount(section: $0, count: count(for: $0)) }
  }

  /// Q2 note, pinned: the queue home's only rollup number is a readiness SECTION's item count
  /// (`QueueView.swift`'s section header), so "shoots with a sync problem" is the
  /// `sync_problem` section's count — never a sum over `FolderSyncCounts`, which
  /// `SyncSignal.compute` deliberately never sums either.
  var syncProblemCount: Int {
    count(for: .syncProblem)
  }

  var totalShoots: Int {
    ReadinessSection.displayOrder.reduce(0) { $0 + count(for: $1) }
  }
}
