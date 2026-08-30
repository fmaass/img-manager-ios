import Foundation
import ImgManagerAPI
import UIKit
import UniformTypeIdentifiers

/// WP13 P5a (IMGMGR-221): "Copy for Lightroom" — the marked set's filename STEMS on the
/// pasteboard, and a confirmation that states the scope the endpoint can actually back.
///
/// FIDELITY, load-bearing: `GET /api/marks/export` returns the WHOLE marked set, never the
/// browse scope (`app/api/marks.py`, and the endpoint's own description says so), and it can be
/// truncated — `MarksExport.count` describes the PAYLOAD, not the uncapped total. So the
/// confirmation says "whole library", and says when the list was cut short. A label implying
/// "the shoot you are looking at" would be a lie this endpoint cannot back.
///
/// Live-probed 2026-08-30 against the deployed backend: `count=211`, `state=["pick"]`,
/// `truncated=false`, stems like `_AR50001` — bare stems, no extension and no separator.
enum MarksExportCopy {

  /// One stem per line: the shape a reader pastes into Lightroom Classic's Library filter.
  /// STEMS ONLY — the server sends `images.stem`, which carries no directory component, and
  /// nothing here adds one. The path-leak contract (p3220 §4.5) forbids a filesystem path in
  /// any UI surface, and the pasteboard is one.
  static func pasteboardPayload(_ export: Components.Schemas.MarksExport) -> String {
    _ = export
    return ""  // RED stub
  }

  /// What the reader is told after the copy. Names the COUNT, the mark word the response itself
  /// reports, and the scope — plus the truncation, when the server flagged it.
  static func confirmation(_ export: Components.Schemas.MarksExport) -> String {
    _ = markWord(export.state)
    return "Copied \(export.count) filenames"  // RED stub
  }

  /// The mark vocabulary comes from the RESPONSE, never from what the request meant to ask for:
  /// the app only ever requests the server's default (`state=pick`, `format=json`), and the
  /// response echoes what it actually exported.
  private static func markWord(_ state: [String]) -> String {
    switch state {
    case ["pick"]: return "picked"
    case ["dislike"]: return "disliked"
    default: return "marked"
    }
  }
}

/// The pasteboard seam — one method, so a test can read back exactly what a copy wrote without
/// touching the system pasteboard (which is shared simulator state and would make the suite
/// order-dependent).
@MainActor
protocol MarksPasteboard: AnyObject {
  func write(_ string: String)
}

/// LOCAL ONLY, never Universal Clipboard / Handoff. `UIPasteboard.general.string = …`
/// participates in Universal Clipboard by default, which would put the household's filenames on
/// another device entirely; `setItems(_:options:)` with `.localOnly: true` is the documented way
/// to refuse that, so this type writes through that call and nothing else.
@MainActor
final class SystemMarksPasteboard: MarksPasteboard {
  /// Exposed so a test can assert the options this type actually writes with, rather than
  /// asserting a comment.
  static let localOnlyOptions: [UIPasteboard.OptionsKey: Any] = [:]  // RED stub

  func write(_ string: String) {
    UIPasteboard.general.setItems(
      [[UTType.utf8PlainText.identifier: string]], options: Self.localOnlyOptions)
  }
}
