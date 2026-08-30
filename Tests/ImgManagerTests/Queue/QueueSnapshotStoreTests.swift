import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// The REAL cache actor, unmocked, against a throwaway directory — the counterpart to
/// `FakeQueueSnapshotStore` (which exists so `QueueStore`'s own tests never touch a file
/// system). What is pinned here is exactly what the store promises the UI: a round-trip that
/// preserves the answer, tolerance for a file that cannot be read (nil, NEVER a throw reaching
/// the UI), a clear that really removes it, and the two at-rest protections — complete file
/// protection plus backup exclusion, so a cached shoot list cannot be recovered from an
/// iCloud/device backup after sign-out.
@Suite("QueueSnapshotStore — the app-private cached server answer")
struct QueueSnapshotStoreTests {
  private func makeDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("QueueSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func removeDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func makeSummary(_ folderId: Int) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 2, disliked: 1, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: Date(timeIntervalSince1970: 1_699_000_000), nothingLeftUnmarked: false,
      path: "2026-08-01/shoot-\(folderId)", picked: 3, previewOutstanding: 0,
      readiness: .init(rawValue: "ready_to_review")!, sourceTier: "local", sync: nil, total: 9,
      unmarked: 4, withMasters: 9)
  }

  private func makeSnapshot() -> QueueSnapshot {
    QueueSnapshot(
      summaries: [makeSummary(1), makeSummary(2)],
      fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
      baseURL: "https://img.example.invalid", subject: "alice")
  }

  @Test("A cold install (no file yet) loads as nil, not a throw")
  func coldLoadIsNil() async {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)

    #expect(await store.load() == nil)
  }

  @Test("Round-trip: a saved snapshot loads back identical, dates included")
  func roundTrip() async {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    let snapshot = makeSnapshot()

    await store.save(snapshot)
    let loaded = await store.load()

    #expect(loaded == snapshot)
    #expect(loaded?.summaries.map(\.folderId) == [1, 2])
    #expect(loaded?.summaries.first?.lastTouched == Date(timeIntervalSince1970: 1_699_000_000))
  }

  @Test("An undecodable file loads as nil — a corrupt cache never throws into the UI")
  func undecodableFileLoadsAsNil() async throws {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())
    try Data("{ this is not the snapshot you are looking for".utf8)
      .write(to: store.fileURL)

    #expect(await store.load() == nil)
  }

  @Test("A second save replaces the file in place — one file, the newer answer, no temp leftovers")
  func saveReplacesInPlace() async throws {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())

    let newer = QueueSnapshot(
      summaries: [makeSummary(7)], fetchedAt: Date(timeIntervalSince1970: 1_700_009_999),
      baseURL: "https://img.example.invalid", subject: "alice")
    await store.save(newer)

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents.count == 1)
    #expect(await store.load() == newer)
  }

  @Test("clear() removes the file; a later load is nil")
  func clearRemovesTheFile() async {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())
    #expect(await store.load() != nil)

    await store.clear()

    #expect(await store.load() == nil)
    #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
  }

  @Test("clear() on a cache that was never written is a no-op, not a failure")
  func clearWithoutFileIsHarmless() async {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)

    await store.clear()

    #expect(await store.load() == nil)
  }

  @Test("The cache file AND its directory are excluded from backup (read back from the disk)")
  func cacheIsExcludedFromBackup() async throws {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())

    let fileValues = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(fileValues.isExcludedFromBackup == true)
    let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(directoryValues.isExcludedFromBackup == true)
  }

  @Test("A re-saved file keeps its backup exclusion (an atomic write replaces the inode)")
  func exclusionSurvivesReSave() async throws {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())
    await store.save(makeSnapshot())

    let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test("The DIRECTORY's protections are re-applied by every save, not only the one that made it")
  func directoryProtectionsReAppliedOnEverySave() async throws {
    // Diff-gate blocker 2: both objects must carry both protections after EVERY atomic write.
    // BOTH of the directory's attributes are stripped between the two saves, so each assertion
    // below is answered by the SECOND save rather than by what the first one left behind.
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())

    // BOTH attributes are stripped, not just the exclusion: a regression that sets the
    // directory's protection class once and never again would sail past a test that only ever
    // takes the exclusion away.
    var stripped = directory
    var cleared = URLResourceValues()
    cleared.isExcludedFromBackup = false
    try stripped.setResourceValues(cleared)
    let strippedValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(strippedValues.isExcludedFromBackup == false)

    // Whether the platform reports a protection class at all is decided HERE, from what the
    // first save actually produced — a simulator has no data protection and reports none, which
    // makes this half vacuous there and is why the exclusion half above carries the proof on
    // that platform. On a device this strips complete protection and demands it back.
    let afterFirstSave = try FileManager.default.attributesOfItem(atPath: directory.path)
    let protectionIsReportable = afterFirstSave[.protectionKey] != nil
    if protectionIsReportable {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.none], ofItemAtPath: directory.path)
      let strippedAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
      #expect(strippedAttributes[.protectionKey] as? FileProtectionType == FileProtectionType.none)
    }

    await store.save(makeSnapshot())

    if protectionIsReportable {
      let restored = try FileManager.default.attributesOfItem(atPath: directory.path)
      #expect(restored[.protectionKey] as? FileProtectionType == .complete)
    }

    let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(directoryValues.isExcludedFromBackup == true)
    let fileValues = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(fileValues.isExcludedFromBackup == true)

    // Protection class: asserted only where the platform reports one — a simulator has no data
    // protection and returns no attribute, which is why the exclusion above (which IS enforced
    // there) carries the simulator half of this proof.
    for path in [directory.path, store.fileURL.path] {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      if let protection = attributes[.protectionKey] as? FileProtectionType {
        #expect(protection == .complete)
      }
    }
  }

  @Test("The file is written with complete file protection where the platform enforces it")
  func cacheIsWrittenWithCompleteProtection() async throws {
    let directory = makeDirectory()
    defer { removeDirectory(directory) }
    let store = QueueSnapshotStore(directoryURL: directory)
    await store.save(makeSnapshot())

    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    // The simulator has no data protection, so the attribute is simply absent there — this
    // asserts the value WHERE the platform reports one (a real device) rather than pretending
    // the simulator can prove it; `QueueSnapshotStore.save` has exactly one write call, and it
    // carries `.completeFileProtection`.
    if let protection = attributes[.protectionKey] as? FileProtectionType {
      #expect(protection == .complete)
    }
  }
}
