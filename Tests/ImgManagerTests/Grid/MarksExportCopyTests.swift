import Foundation
import ImgManagerAPI
import Testing
import UIKit

@testable import ImgManager

/// WP13 P5a (IMGMGR-221): "Copy for Lightroom" — what lands on the pasteboard, and what the
/// reader is told about it.
@MainActor
@Suite("Copy for Lightroom (WP13 P5a)")
struct MarksExportCopyTests {

  private func export(
    count: Int, stems: [String], truncated: Bool = false, state: [String] = ["pick"]
  ) -> Components.Schemas.MarksExport {
    Components.Schemas.MarksExport(
      count: count, state: state, stems: stems, truncated: truncated)
  }

  /// The plan's named test. `GET /api/marks/export` answers for the WHOLE marked set, never the
  /// browse scope (the endpoint's own description says so), and `count` describes the PAYLOAD —
  /// so the confirmation states the scope, and states the truncation when the server flagged it.
  @Test("The copy states the whole-library scope and reports truncation")
  func copyStatesWholeLibraryScopeAndReportsTruncation() {
    let plain = MarksExportCopy.confirmation(export(count: 211, stems: ["a", "b"]))
    #expect(plain == "Copied 211 picked filenames (whole library)")

    let one = MarksExportCopy.confirmation(export(count: 1, stems: ["a"]))
    #expect(one == "Copied 1 picked filename (whole library)")

    let cut = MarksExportCopy.confirmation(export(count: 500, stems: ["a"], truncated: true))
    #expect(cut.contains("(whole library)"), "the truncated message dropped the scope")
    #expect(cut.contains("truncated"), "a truncated export did not say so")

    // A message that never mentions the scope would be the failure this test exists for, so
    // assert it on EVERY branch — including the empty one, which writes nothing.
    let empty = MarksExportCopy.confirmation(export(count: 0, stems: []))
    #expect(empty == "Nothing to copy — no picked photographs in the whole library.")

    // The mark word comes from the RESPONSE, not from what the request meant.
    let disliked = MarksExportCopy.confirmation(
      export(count: 2, stems: ["a", "b"], state: ["dislike"]))
    #expect(disliked == "Copied 2 disliked filenames (whole library)")
  }

  /// The plan's named test, with its positive control: the stems themselves are asserted
  /// PRESENT, so the "no path separator" check cannot pass on an empty payload.
  @Test("The pasteboard payload contains the stems and no path separator")
  func pasteboardPayloadContainsStemsAndNoPathSeparator() {
    let stems = ["_AR50001", "_AR50002", "DSC_0042"]
    let payload = MarksExportCopy.pasteboardPayload(export(count: 3, stems: stems))

    // Positive control.
    for stem in stems {
      #expect(payload.contains(stem), "the payload lost the stem \(stem)")
    }
    #expect(payload.split(separator: "\n").map(String.init) == stems)
    #expect(!payload.contains("/"), "the payload carries a path separator")
    #expect(!payload.contains("\\"), "the payload carries a path separator")
    // Stems, not filenames: nothing here adds an extension either.
    #expect(!payload.contains(".jpg"))
  }

  /// LOCAL ONLY. `UIPasteboard.general.string = …` participates in Universal Clipboard, which
  /// would put the household's filenames on another device; the shipped writer uses
  /// `setItems(_:options:)` with `.localOnly: true`, and this asserts the options it writes with
  /// rather than asserting a comment.
  @Test("The pasteboard write is local-only, never Universal Clipboard / Handoff")
  func pasteboardIsLocalOnlyNeverUniversalClipboard() {
    let options = SystemMarksPasteboard.localOnlyOptions
    // Positive control: the dictionary really carries the key being read.
    #expect(options.keys.contains(.localOnly))
    #expect(options[.localOnly] as? Bool == true, "the pasteboard write is not local-only")
  }

  @Test("A copy fetches marks/export with the server's defaults — never format=txt")
  func copyRequestsJSONDefaultsAndNeverTxt() async {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let pasteboard = SpyMarksPasteboard()
    let store = GridStore(
      service: GridService(client: client),
      preferences: GridPreferences(defaults: makeEphemeralDefaults()), pasteboard: pasteboard)

    await transport.setMarksExport(
      export(count: 2, stems: ["_AR50001", "_AR50002"]))
    await store.copyMarkedFilenamesForLightroom()

    #expect(pasteboard.writes == ["_AR50001\n_AR50002"])
    #expect(store.marksCopyMessage == "Copied 2 picked filenames (whole library)")

    let queries = await transport.recordedMarksExportQueries
    #expect(queries.count == 1, "the copy did not call GET /api/marks/export exactly once")
    // The vendored document declares only `application/json` for the 200 response, so a `txt`
    // request is unrepresentable by the generated client. Positive control first.
    let exportCalls = await transport.callCount(Operations.ExportMarksApiMarksExportGet.id)
    #expect(exportCalls == 1)
    #expect(queries.allSatisfy { $0["format"] != "txt" }, "a format=txt request was made")
  }

  @Test("An empty marked set writes nothing to the pasteboard")
  func anEmptyExportLeavesThePasteboardAlone() async {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let pasteboard = SpyMarksPasteboard()
    let store = GridStore(
      service: GridService(client: client),
      preferences: GridPreferences(defaults: makeEphemeralDefaults()), pasteboard: pasteboard)

    await transport.setMarksExport(export(count: 0, stems: []))
    await store.copyMarkedFilenamesForLightroom()

    #expect(pasteboard.writes.isEmpty, "an empty export overwrote whatever was on the pasteboard")
    #expect(store.marksCopyMessage?.contains("Nothing to copy") == true)
  }

  @Test("An unreachable export says so, and writes nothing")
  func anUnreachableExportSaysSo() async {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let pasteboard = SpyMarksPasteboard()
    let store = GridStore(
      service: GridService(client: client),
      preferences: GridPreferences(defaults: makeEphemeralDefaults()), pasteboard: pasteboard)

    await transport.setMarksExportShouldFail(true)
    await store.copyMarkedFilenamesForLightroom()

    #expect(pasteboard.writes.isEmpty)
    #expect(store.marksCopyMessage?.contains("Couldn't reach") == true)
    // Opaque by construction: no transport text reaches the message.
    #expect(store.marksCopyMessage?.contains("GridStubTransport") == false)
  }
}
