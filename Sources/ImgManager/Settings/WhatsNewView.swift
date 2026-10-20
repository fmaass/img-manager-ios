import SwiftUI

/// IMGMGR-587: what changed, build by build — the whole notes history, the running build's section
/// first and every earlier one after it in file order. Pushed from Settings › About › Version;
/// nothing on it acts on anything.
///
/// The words are the TestFlight notes themselves (`ReleaseNotes.bundled`): one file, so the screen
/// cannot say something the build's testers were not told.
struct WhatsNewView: View {
  /// The build this is, as the Version row reads it: `0.15.1 (23)`.
  let running: String
  var notes: [ReleaseNotes.Section] = ReleaseNotes.bundled

  static let title = "What's new"
  static let empty = "This build carries no release notes."

  var body: some View {
    let sections = ReleaseNotes.ordered(notes, running: running)
    List {
      if sections.isEmpty {
        Text(Self.empty)
          .foregroundStyle(.secondary)
      }
      ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
        Section {
          let points = ReleaseNotes.points(in: section.body)
          VStack(alignment: .leading, spacing: 8) {
            ForEach(points.indices, id: \.self) { point in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•")
                Text(Self.inline(points[point]))
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("whatsNewBody.\(index)")
        } header: {
          Text(section.version)
            .textCase(nil)
            .accessibilityIdentifier("whatsNewHeading.\(index)")
        }
      }
    }
    .accessibilityIdentifier("whatsNewList")
    .navigationTitle(Self.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  /// Inline Markdown (emphasis, code) in a point; a point that does not parse is shown as written.
  private static func inline(_ point: String) -> AttributedString {
    (try? AttributedString(markdown: point)) ?? AttributedString(point)
  }
}
