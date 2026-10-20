import Foundation
import Testing

@testable import ImgManager

/// IMGMGR-587: the What's new screen's reading of `Resources/ReleaseNotes.md` — the same sections
/// the TestFlight cut's loader picks from (`fastlane/lib/release_notes.rb`), and the bundled file
/// itself.
@Suite("Release notes — sections, order and the bundled file (IMGMGR-587)")
struct ReleaseNotesTests {

  private static let sample = """
    # Release notes

    Preamble that belongs to no section.

    ## 0.15.1 (23)

    - Square layout.
    ### A deeper heading stays inside
    - Scene push.

    ## 0.15.0 (22)

    - Settings sheet.
    """

  @Test("Each ## heading opens a section; the preamble belongs to none; ### stays inside")
  func sectionsInFileOrder() {
    let sections = ReleaseNotes.sections(markdown: Self.sample)
    #expect(sections.map(\.version) == ["0.15.1 (23)", "0.15.0 (22)"])
    #expect(
      sections.first?.body == "- Square layout.\n### A deeper heading stays inside\n- Scene push.")
    #expect(sections.last?.body == "- Settings sheet.")
  }

  @Test("A heading inside a code fence is text, and only the same fence character closes it")
  func fencedHeadingIsText() {
    let text = "## 1.0 (1)\n\n````\n## 9.9 (9)\n```\n~~~~\n````\n- after\n"
    let sections = ReleaseNotes.sections(markdown: text)
    #expect(sections.map(\.version) == ["1.0 (1)"])
    #expect(sections.first?.body.hasSuffix("- after") == true)
  }

  @Test("CRLF line endings read like LF")
  func crlf() {
    let sections = ReleaseNotes.sections(markdown: "## 1.0 (1)\r\n- a\r\n## 1.0 (2)\r\n- b\r\n")
    #expect(sections.map(\.version) == ["1.0 (1)", "1.0 (2)"])
    #expect(sections.map(\.body) == ["- a", "- b"])
  }

  @Test("The running build's section comes first, the rest in file order")
  func runningFirst() {
    let sections = ReleaseNotes.sections(markdown: Self.sample)
    #expect(
      ReleaseNotes.ordered(sections, running: "0.15.0 (22)").map(\.version)
        == ["0.15.0 (22)", "0.15.1 (23)"])
    #expect(
      ReleaseNotes.ordered(sections, running: "—").map(\.version) == ["0.15.1 (23)", "0.15.0 (22)"])
    #expect(ReleaseNotes.ordered([], running: "0.15.1 (23)").isEmpty)
  }

  @Test("Points: one per bullet, a wrapped line continues the point above it")
  func points() {
    let wrapped = ReleaseNotes.points(in: "- one\n* two\n  wrapped\n\n- three")
    #expect(wrapped == ["one", "two wrapped", "three"])
    #expect(ReleaseNotes.points(in: "plain line") == ["plain line"])
    #expect(ReleaseNotes.points(in: "").isEmpty)
  }

  /// The realness check on the BUNDLE: the hosted test's `Bundle.main` is the app, so this fails
  /// when the resources phase does not carry the file or the running build has no section.
  @Test("The app bundle carries the notes, with a non-empty section for the running build")
  func bundledHasTheRunningBuild() {
    let running = SettingsAbout.versionLine(info: Bundle.main.infoDictionary)
    let bundled = ReleaseNotes.bundled
    #expect(!bundled.isEmpty, "Resources/ReleaseNotes.md is missing from the app bundle")
    let mine = bundled.filter { $0.version == running }
    #expect(mine.count == 1, "\(running) heads \(mine.count) sections, exactly 1 wanted")
    #expect(mine.first.map { !ReleaseNotes.points(in: $0.body).isEmpty } == true)
  }
}
