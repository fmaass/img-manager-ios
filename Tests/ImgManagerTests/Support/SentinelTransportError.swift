import Foundation

/// A FOREIGN test error — never part of application source — used only to plant a raw
/// sentinel string somewhere `ConnectivityState`'s suppression (fold item 4) must stop.
/// `errorDescription` is the positive control: it genuinely carries the raw text, so
/// `DegradedStateTests.sentinelErrorCarriesRawText` has something real to prove suppression
/// against — this is what `TransportError.failed(raw:)` used to be, moved OUT of
/// application source entirely per the diff-gate blocker 2 fold.
struct SentinelTransportError: Error, LocalizedError, Sendable {
  let raw: String

  var errorDescription: String? { raw }
}
