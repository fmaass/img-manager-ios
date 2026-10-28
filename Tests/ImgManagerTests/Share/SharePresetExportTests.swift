import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Which exports' `renderGone` ran, in order (IMGMGR-676).
@MainActor
private final class PresetGoneLog {
  var exports: [String] = []
}

/// IMGMGR-658: a preset render shares as its full-size `/file` JPEG, `<stem>-<preset>.jpg`,
/// bounded, and a superseded generation never delivers into the newer one.
@MainActor
@Suite("Share a preset render (IMGMGR-658)")
struct SharePresetExportTests {
  static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
  static let render = PresetRenderSnapshot(
    imageID: 1, presetID: "a1b2c3d4e5f6", generation: 2, status: .ok, renderHash: "h1", size: 8)

  private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "share-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func makeStore(
    _ transport: PresetStubTransport, directory: URL,
    presetByteCap: Int = PresetRenderPlan.fileByteCap
  ) -> ShareExportStore {
    ShareExportStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)),
      master: UnavailableMasterDownloader(), masterAvailable: false, directory: directory,
      presetByteCap: presetByteCap)
  }

  private func image(id: Int = 1) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "arw", filename: "DSC01234.ARW", folderId: 1, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  @Test("The /file JPEG under the render's hash is the export, named <stem>-<preset>.jpg")
  func exportsTheRender() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = PresetStubTransport()
    await transport.setFileOutcome(.ok(Self.jpeg))
    let store = makeStore(transport, directory: directory)

    await store.preparePreset(for: image(), presetName: "Warm Matte", render: Self.render)

    guard case .ready(let file) = store.state else {
      Issue.record("expected .ready, got \(store.state)")
      return
    }
    #expect(file.filename == "DSC01234-Warm Matte.jpg")
    #expect(file.contentType == .jpeg)
    #expect(try Data(contentsOf: file.url) == Self.jpeg)
    let paths = await transport.fileRequestPaths
    #expect(paths.count == 1)
    #expect(paths.first?.hasSuffix("/presets/a1b2c3d4e5f6/file?v=h1") == true)
  }

  @Test("The filename sanitizes the preset's name and falls back to its id")
  func presetFilename() {
    #expect(
      ShareExportPlan.presetFilename(for: "DSC01234.ARW", presetName: "Film/Warm", presetID: "p")
        == "DSC01234-FilmWarm.jpg")
    #expect(
      ShareExportPlan.presetFilename(for: "DSC01234.ARW", presetName: " / ", presetID: "abc")
        == "DSC01234-abc.jpg")
  }

  @Test("Eviction before download: a supersede while the bytes are on the wire delivers nothing")
  func supersededGenerationNeverDelivers() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = PresetStubTransport()
    await transport.setFileOutcome(.ok(Self.jpeg))
    await transport.holdFile()
    let store = makeStore(transport, directory: directory)

    let running = Task {
      await store.preparePreset(for: image(), presetName: "Warm Matte", render: Self.render)
    }
    await transport.waitForFileStart()
    #expect(store.isPreparing)
    store.supersede()
    await transport.releaseFile()
    await running.value

    #expect(store.state == .idle)
    let leftovers =
      (try? FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []
    #expect(leftovers.filter { $0.hasSuffix(".jpg") }.isEmpty)
  }

  @Test("A render evicted before its download refuses and writes nothing")
  func evictedRenderRefuses() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = PresetStubTransport()
    await transport.setFileOutcome(.notFound)
    let store = makeStore(transport, directory: directory)

    await store.preparePreset(for: image(), presetName: "Warm Matte", render: Self.render)

    #expect(store.state == .refused(.presetUnavailable))
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
  }

  @Test("A share that finds the render evicted drops the stale ok, so a tap requests again")
  func evictedShareInvalidatesTheRender() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = PresetStubTransport()
    await transport.setFileOutcome(.notFound)
    let store = makeStore(transport, directory: directory)
    let render = Self.render
    let model = PresetRenderModel(
      request: { _, _ in render }, status: { _, _ in render },
      clock: PresetPollClock(now: { ContinuousClock.now }, sleep: { _ in }))
    model.start(imageID: render.imageID, presetID: render.presetID)
    await model.settle()
    #expect(model.phase == .ok(render))

    await store.preparePreset(
      for: image(), presetName: "Warm Matte", render: render,
      renderGone: {
        model.invalidate(
          imageID: render.imageID, presetID: render.presetID, renderHash: "h1")
      })

    #expect(store.state == .refused(.presetUnavailable))
    #expect(model.phase(imageID: render.imageID, presetID: render.presetID) == .idle)
    model.start(imageID: render.imageID, presetID: render.presetID)
    #expect(model.phase == .requested)
  }

  /// The overlap the store allows: `run` refuses a second export while one is preparing, so B
  /// can only start once A is superseded (the loupe's focus moved) with A's bytes still on the
  /// wire. B's render answers 404 and B publishes the refusal; A's bytes land after that, into a
  /// generation that moved on, so A must not take B's refusal for its own.
  @Test(
    "Two overlapping preset exports: only the one whose render is gone invalidates it",
    .timeLimit(.minutes(1)))
  func overlappingExportsInvalidateOnlyTheGoneRender() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = PresetStubTransport()
    await transport.holdEachFile()
    let store = makeStore(transport, directory: directory)
    let gone = PresetGoneLog()
    let renderB = PresetRenderSnapshot(
      imageID: 2, presetID: "a1b2c3d4e5f6", generation: 1, status: .ok, renderHash: "h2", size: 8)

    let exportA = Task {
      await store.preparePreset(
        for: image(id: 1), presetName: "Warm Matte", render: Self.render,
        renderGone: { gone.exports.append("A") })
    }
    await transport.waitForHeldFiles(1)
    store.supersede()
    let exportB = Task {
      await store.preparePreset(
        for: image(id: 2), presetName: "Warm Matte", render: renderB,
        renderGone: { gone.exports.append("B") })
    }
    await transport.waitForHeldFiles(2)
    #expect(await transport.fileRequestPaths.count == 2)

    #expect(await transport.answerFile(containing: "file?v=h2", with: .notFound))
    await exportB.value
    #expect(store.state == .refused(.presetUnavailable))
    #expect(gone.exports == ["B"])

    #expect(await transport.answerFile(containing: "file?v=h1", with: .ok(Self.jpeg)))
    await exportA.value
    #expect(gone.exports == ["B"])
    #expect(store.state == .refused(.presetUnavailable))
    let leftovers =
      (try? FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []
    #expect(leftovers.filter { $0.hasSuffix(".jpg") }.isEmpty)
  }

  @Test("Bounded transfer: a render past the cap refuses as too large, before or after asking")
  func boundedTransfer() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = PresetStubTransport()
    await transport.setFileOutcome(.ok(Self.jpeg))
    // The status row's size already says too large: nothing is asked.
    let small = makeStore(transport, directory: directory, presetByteCap: 4)
    await small.preparePreset(for: image(), presetName: "Warm", render: Self.render)
    #expect(small.state == .refused(.tooLarge))
    #expect(await transport.fileRequestPaths.isEmpty)
    // No size on the row: the read itself stops at the cap.
    let unsized = PresetRenderSnapshot(
      imageID: 1, presetID: "p", generation: 1, status: .ok, renderHash: "h1")
    await small.preparePreset(for: image(), presetName: "Warm", render: unsized)
    #expect(small.state == .refused(.tooLarge))
    #expect(await transport.fileRequestPaths.count == 1)
  }
}
