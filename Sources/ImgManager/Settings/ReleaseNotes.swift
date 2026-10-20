import Foundation

/// IMGMGR-587: what changed in each build, as the What's new screen shows it — the sections of the
/// ONE notes file the TestFlight cut also sends as "What to Test" (`Resources/ReleaseNotes.md`).
///
/// A section is a `## <version> (<build>)` heading and the Markdown under it, read the way the
/// cut's loader reads it (`fastlane/lib/release_notes.rb`): a level-1 or level-2 heading outside a
/// code fence ends a section, a deeper heading belongs to it, and a heading inside a fence is text.
/// The heading is the very line `SettingsAbout.versionLine` writes for a build, which is what lets
/// the running build find its own section.
enum ReleaseNotes {
  struct Section: Equatable, Sendable {
    /// `0.15.1 (23)`: the heading, without its `## `.
    let version: String
    /// The Markdown under the heading, blank lines at either end dropped.
    let body: String
  }

  /// Every section, in file order. Text before the first section is the file's own preamble and
  /// belongs to none.
  static func sections(markdown: String) -> [Section] {
    var found: [Section] = []
    var heading: String?
    var lines: [Substring] = []
    // The open fence's character and run length: CommonMark closes a fence only on a line that is
    // nothing but the SAME character, at least as many times.
    var fence: (mark: Character, count: Int)?

    func close() {
      if let heading {
        let body = lines.joined(separator: "\n")
        found.append(
          Section(version: heading, body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
      }
      heading = nil
      lines = []
    }

    // `isNewline` rather than "\n": a CRLF file's "\r\n" is ONE Character to Swift.
    for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      if fence == nil, let level = headingLevel(line), level <= 2 {
        close()
        let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        if level == 2, !title.isEmpty { heading = title }
        continue
      }
      let indented = line.drop(while: { $0 == " " || $0 == "\t" })
      if let open = fence {
        let run = indented.prefix(while: { $0 == open.mark }).count
        let rest = indented.dropFirst(run)
        if run >= open.count, rest.allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
      } else if let mark = indented.first, mark == "`" || mark == "~" {
        let run = indented.prefix(while: { $0 == mark }).count
        if run >= 3 { fence = (mark, run) }
      }
      if heading != nil { lines.append(line) }
    }
    close()
    return found
  }

  /// The running build's section first, every other one after it in file order. A build the file
  /// does not name — a local build, `—` — leaves the order as written: nothing is dropped and
  /// nothing is invented.
  static func ordered(_ sections: [Section], running: String) -> [Section] {
    guard let index = sections.firstIndex(where: { $0.version == running }) else {
      return sections
    }
    var rest = sections
    let current = rest.remove(at: index)
    return [current] + rest
  }

  /// A section's points, as the screen lists them: each `- ` or `* ` line opens one, its marker
  /// dropped; any other non-blank line continues the point above it (or opens one when there is
  /// none). TestFlight shows the same body as plain text, so nothing here may be needed to read it.
  static func points(in body: String) -> [String] {
    var points: [String] = []
    for raw in body.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("- ") || line.hasPrefix("* ") {
        points.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
      } else if let last = points.popLast() {
        points.append(last + " " + line)
      } else {
        points.append(line)
      }
    }
    return points
  }

  /// The notes this build was made with, read once from the app bundle. An unreadable file is no
  /// sections, which the screen says, rather than a crash on the way to a courtesy.
  static let bundled: [Section] = {
    guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "md"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    return sections(markdown: text)
  }()

  /// `#` → 1, `##` → 2, and so on, when the line is an ATX heading: the hashes at the start of the
  /// line followed by a space, a tab or nothing.
  private static func headingLevel(_ line: Substring) -> Int? {
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard hashes > 0 else { return nil }
    let after = line.dropFirst(hashes).first
    return after == nil || after == " " || after == "\t" ? hashes : nil
  }
}
