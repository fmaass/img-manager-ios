import SwiftUI

/// IMGMGR-586: one photograph whose mark write failed — the state the reader asked for, and the
/// server-truth snapshot the failed write was made against, so Retry can resubmit it even after
/// the scope it was made in no longer shows that photograph.
struct UnsavedMark: Sendable, Equatable {
  var state: MarkStateValue
  var prior: PriorMarkSnapshot
}

enum UnsavedMarksCopy {
  /// "Picks" while every unsaved mark is a pick — the case the owner hit — and "marks" as soon
  /// as a Dislike or a Clear is among them, so the noun never claims more than it knows.
  static func message(for marks: some Collection<UnsavedMark>) -> String {
    let count = marks.count
    let allPicks = marks.allSatisfy { $0.state == .pick }
    let noun = allPicks ? "pick" : "mark"
    return "\(count) \(noun)\(count == 1 ? "" : "s") didn't save"
  }
}

/// IMGMGR-586: the never-silent half of a failed mark write, in the `ConflictRecoveryBanner`
/// idiom — non-blocking, beside the content, gone once nothing is unsaved. Retry queues on the
/// mark lane, so it is disabled only to show that a write is already out.
struct UnsavedMarksBanner: View {
  @Bindable var store: GridStore

  var body: some View {
    if !store.unsavedMarks.isEmpty {
      HStack(spacing: 12) {
        Label(
          UnsavedMarksCopy.message(for: Array(store.unsavedMarks.values)),
          systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        // One element read as the message: otherwise the symbol's own "Warning" answers first.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UnsavedMarksCopy.message(for: Array(store.unsavedMarks.values)))
        .accessibilityIdentifier("unsavedMarksMessage")
        Spacer()
        Button("Dismiss") { store.dismissUnsavedMarks() }
          .font(.footnote)
          .accessibilityIdentifier("unsavedMarksDismiss")
        Button("Retry") { Task { await store.retryUnsavedMarks() } }
          .font(.footnote)
          .buttonStyle(.borderedProminent)
          .disabled(store.isMutatingMark)
          .accessibilityIdentifier("unsavedMarksRetry")
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.red.opacity(0.12))
    }
  }
}
