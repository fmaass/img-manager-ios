import Foundation

/// The widget's own last-good snapshot, on disk in the extension's private container.
///
/// There is no App Group in v1 (a second entitlement and a second profile), so this is the
/// EXTENSION's Application Support directory, not the app's — the app never reads or writes it,
/// and nothing here is shared. That is sufficient because the only thing that needs to survive
/// is "what the last successful widget refresh saw", which the widget process itself produced.
///
/// File protection is pinned to `completeUntilFirstUserAuthentication` rather than left to the
/// default: the whole point of the snapshot is to be readable BETWEEN unlocks (the credential's
/// own accessibility class deliberately is not — owner decision, this lane), and a file written
/// under complete protection would be unreadable in exactly the state it exists to serve.
struct ReadinessSnapshotStore: Sendable {
  private let fileURL: URL

  /// Injectable for tests, which point it at a throwaway temporary directory — the production
  /// path is `applicationSupport()` below.
  init(directory: URL) {
    self.fileURL = directory.appendingPathComponent("readiness-snapshot.json")
  }

  /// `nil` when the container cannot be resolved at all — the caller then runs with no
  /// persistence, which degrades to `.noData` on a failed fetch rather than crashing.
  static func applicationSupport() -> ReadinessSnapshotStore? {
    guard
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return ReadinessSnapshotStore(directory: directory)
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  /// `nil` means "no snapshot" and nothing else — an unreadable or undecodable file is treated
  /// the same as an absent one, because the only consumer's fallback for both is identical
  /// (render the never-fetched state), and a widget must never fail to render.
  func load() -> ReadinessEntry? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? Self.decoder().decode(ReadinessEntry.self, from: data)
  }

  /// Only a `.live` entry is ever persisted — a snapshot is by definition the last SUCCESSFUL
  /// fetch, so re-persisting a `.lastKnown` (which would re-date nothing but is still not a new
  /// reading) or a `.signedOut`/`.noData` placeholder is refused here rather than trusted to
  /// every call site.
  func save(_ entry: ReadinessEntry) {
    // NOT IMPLEMENTED YET (RED).
    _ = entry
  }

  /// Sign-out drops the snapshot: a device with no credential must not keep rendering the
  /// counts the credential fetched.
  func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
