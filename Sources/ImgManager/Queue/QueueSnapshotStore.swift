import Foundation
import ImgManagerAPI

/// The LAST SERVER ANSWER the queue received, and when. Not offline review (spec p3231 §Q10,
/// "no offline review, no offline mutation queue, no client-side conflict merge" — still true):
/// nothing here is editable, nothing is queued, and no write path consults it. It is one
/// read-only answer, replayed labelled as stale, so a VPN drop shows the shoots you last saw
/// instead of an empty "Not connected" surface.
///
/// `subject` and `baseURL` are part of the payload, not just the file name, because they are
/// what makes replaying it legitimate: an answer fetched for a different account, or against a
/// different server, is not this session's answer and is discarded on read.
struct QueueSnapshot: Codable, Equatable, Sendable {
  var summaries: [Components.Schemas.FolderSummary]
  var fetchedAt: Date
  var baseURL: String
  var subject: String
}

/// The persistence seam `QueueStore` depends on. Failures are absorbed here, never surfaced:
/// a cache that cannot be read is simply `nil`, and a cache that cannot be written changes
/// nothing the user can see (the live answer is already published by then).
protocol QueueSnapshotPersisting: Sendable {
  func load() async -> QueueSnapshot?
  func save(_ snapshot: QueueSnapshot) async
  func clear() async
}

/// One JSON file in Application Support (never `UserDefaults` — this is a payload, not a
/// preference), written atomically so a kill mid-write cannot leave a half-file behind.
///
/// Two at-rest protections, both required: `.completeFileProtection` keeps it unreadable while
/// the device is locked, and `isExcludedFromBackup` keeps a shoot list the user has since signed
/// out of from being recoverable out of an iCloud or device backup. The exclusion is re-applied
/// after EVERY save because an atomic write replaces the file — the attribute belongs to the
/// inode that was just swapped out, so setting it once would silently lapse on the next write.
actor QueueSnapshotStore: QueueSnapshotPersisting {
  nonisolated let fileURL: URL
  private let directoryURL: URL

  init(directoryURL: URL = QueueSnapshotStore.defaultDirectoryURL) {
    self.directoryURL = directoryURL
    self.fileURL = directoryURL.appendingPathComponent("queue-snapshot.json", isDirectory: false)
  }

  static var defaultDirectoryURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return base.appendingPathComponent("ImgManager", isDirectory: true)
  }

  func load() async -> QueueSnapshot? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(QueueSnapshot.self, from: data)
  }

  func save(_ snapshot: QueueSnapshot) async {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true)
      try setExcludedFromBackup(directoryURL)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(snapshot)
      try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
      try setExcludedFromBackup(fileURL)
    } catch {
      // A cache that cannot be written changes nothing the user can see: the live answer it
      // came from is already published. There is deliberately nothing to surface here.
    }
  }

  func clear() async {
    try? FileManager.default.removeItem(at: fileURL)
  }

  private func setExcludedFromBackup(_ url: URL) throws {
    var target = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try target.setResourceValues(values)
  }
}
