import Foundation
import UniformTypeIdentifiers

/// What the user asked to hand to the system share sheet.
///
/// RAW ORIGINALS ARE NOT A CASE HERE AND NEVER WILL BE. img-manager refuses `content=original`
/// for a RAW with `403` + `X-Img-Policy: raw-original`, and this client never asks: no value of
/// this enum names an original, so no code path — present or future — can request one by
/// mistake. The refusal is still MAPPED (`ShareRefusal.rawOriginalPolicy`) because the policy is
/// the server's to change and a refusal that does arrive must be surfaced, never swallowed.
enum ShareVariant: String, Sendable, Equatable, CaseIterable {
  /// The web-preview proxy the loupe already renders (`ProxyTier.preview`) — the same bytes,
  /// through the same `GridService.proxy` operation, never a second kind of thing.
  case preview
  /// The freshest edited master export. Gated behind `ShareMasterSeam` — see that type.
  case master
}

/// Every way an export can end WITHOUT a file, each carrying the exact inline copy the view
/// renders. No case carries server text, a hostname or a transport string — the same opaque
/// discipline as `GridServiceError`: there is no storage here for raw text to occupy.
enum ShareRefusal: Sendable, Equatable {
  /// `403` WITH `X-Img-Policy: raw-original` — the application's own policy answer.
  case rawOriginalPolicy
  /// The tier has no web preview for this image yet.
  case noPreview
  /// `404` on the master lane: this image has no export.
  case noMaster
  /// Unreachable, or a bare `403` (a proxy/session refusal, never a policy answer).
  case notConnected
  /// Past the lane's named byte cap — the partial file is deleted, nothing is shared.
  case tooLarge
  /// The bytes arrived but could not be written to the temp directory.
  case couldNotPrepare
  /// `ShareMasterSeam.isAvailable == false` — see that type for what activates it.
  case masterContractUnavailable

  var copy: String {
    switch self {
    case .rawOriginalPolicy:
      return "RAW originals can't be exported — share the preview or the edited master instead."
    case .noPreview:
      return "No preview for this photo yet."
    case .noMaster:
      return "No edited master for this photo yet."
    case .notConnected:
      // The one degraded-state string this app already owns — reused verbatim, never a second
      // phrasing of the same condition (`Transport/ConnectivityState.swift`).
      return DegradedStateCopy.notConnected
    case .tooLarge:
      return "This export is too large to share from here."
    case .couldNotPrepare:
      return "Couldn't prepare this photo for sharing."
    case .masterContractUnavailable:
      return "Sharing the edited master isn't available in this build yet."
    }
  }
}

/// A prepared export: bytes that are ALREADY on disk, under a name the share sheet can show.
/// Nothing in this app presents a system sheet without one of these in hand.
struct ShareExportFile: Sendable, Equatable {
  let url: URL
  let filename: String
  let contentType: UTType
}

/// The share lane's pure decisions — naming, caps, refusal mapping — deliberately free of
/// SwiftUI, `GridService` and the generated client so every one of them is unit-testable on
/// its own, including the parts of the master lane whose BYTES are still parked (see
/// `ShareMasterSeam`).
enum ShareExportPlan {
  /// Mirrors `GridService.proxy`'s own cap (`Grid/GridService.swift:163`) so a share never
  /// buffers more than rendering the same image already would.
  static let previewByteCap = 30 * 1024 * 1024

  /// The master lane's own, deliberately larger, NAMED cap: an edited export off a 60 MP frame
  /// is bigger than any proxy but still bounded. `ShareStreamWriter` aborts and deletes the
  /// partial file past this — the client never buffers whatever the server happens to send.
  static let masterByteCap = 256 * 1024 * 1024

  /// The proxy is a JPEG whatever the original was.
  static let previewContentType = UTType.jpeg

  /// `DSC_1234.NEF` → `DSC_1234.jpg`.
  ///
  /// The EXTENSION comes from what is actually being shared, never from `ImageSummary.ext` —
  /// that field names the RAW, and labelling a JPEG proxy `.NEF` would hand the receiving app a
  /// file whose name lies about its bytes. Only the STEM is borrowed, so the shared file is
  /// still recognisably the same photograph.
  static func previewFilename(for sourceFilename: String) -> String {
    "\(stem(of: sourceFilename)).jpg"
  }

  /// The filename stem, stripped of anything that could make the temp path escape its own
  /// directory or name a hidden/dotted entry. Falls back to a fixed name rather than ever
  /// producing an empty or relative component.
  static func stem(of sourceFilename: String) -> String {
    let component = lastPathComponent(of: sourceFilename)
    var candidate = component
    if let dot = component.lastIndex(of: "."), dot != component.startIndex {
      candidate = String(component[component.startIndex..<dot])
    }
    return sanitize(candidate) ?? "photo"
  }

  /// Gate correction 5: a master's filename is the SERVER's (`Content-Disposition`), never
  /// `ImageSummary.filename`/`.ext`. Handles both `filename="x"` and RFC 5987
  /// `filename*=UTF-8''x`, preferring the encoded form when both are present. Returns `nil`
  /// when the header names nothing usable, and the caller then falls back to the stem plus the
  /// content type's own extension.
  static func filename(fromContentDisposition header: String?) -> String? {
    guard let header else { return nil }
    var plain: String?
    var encoded: String?
    for rawParameter in header.split(separator: ";") {
      let parameter = rawParameter.trimmingCharacters(in: .whitespaces)
      let lowercased = parameter.lowercased()
      if lowercased.hasPrefix("filename*=") {
        let value = String(parameter.dropFirst("filename*=".count))
        encoded = decodeRFC5987(value)
      } else if lowercased.hasPrefix("filename=") {
        var value = String(parameter.dropFirst("filename=".count))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
          value = String(value.dropFirst().dropLast())
        }
        plain = value
      }
    }
    guard let chosen = encoded ?? plain else { return nil }
    return sanitize(lastPathComponent(of: chosen))
  }

  /// Whether the loupe offers the edited-master entry at all — the ONE place that rule lives,
  /// called by the menu itself rather than restated there.
  ///
  /// Absence renders as absence, twice over: a photograph with no edit has no master to offer,
  /// and while the seam is off there is no master lane at all. Neither case shows a disabled
  /// control the user has no way to explain.
  static func offersMaster(hasEdit: Bool?, seamAvailable: Bool = ShareMasterSeam.isAvailable)
    -> Bool
  {
    seamAvailable && hasEdit == true
  }

  /// The download endpoint's declared refusals, mapped to app-owned copy.
  ///
  /// A `403` is a POLICY answer only when `X-Img-Policy` is present; the schema says so in as
  /// many words ("absent on a session refusal"). A bare `403` is the proxy or the session
  /// refusing — nothing the RAW-policy sentence would truthfully describe — so it maps to the
  /// connectivity copy instead.
  static func refusal(status: Int, policyHeader: String?) -> ShareRefusal {
    switch status {
    case 403 where policyHeader == "raw-original":
      return .rawOriginalPolicy
    case 404:
      return .noMaster
    default:
      return .notConnected
    }
  }

  private static func decodeRFC5987(_ value: String) -> String? {
    // `UTF-8''<pct-encoded>` — the charset and language segments are dropped; any charset this
    // app cannot decode simply yields nil and the plain `filename=` form is used instead.
    let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].lowercased() == "utf-8" else { return nil }
    return String(parts[2]).removingPercentEncoding
  }

  private static func lastPathComponent(of raw: String) -> String {
    raw.split(separator: "/").last.map(String.init) ?? raw
  }

  private static func sanitize(_ raw: String) -> String? {
    let scalars = raw.unicodeScalars.filter { scalar in
      scalar != "/" && scalar != "\\" && scalar != ":"
        && !CharacterSet.controlCharacters.contains(scalar)
    }
    let cleaned = String(String.UnicodeScalarView(scalars))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
    return cleaned
  }
}
