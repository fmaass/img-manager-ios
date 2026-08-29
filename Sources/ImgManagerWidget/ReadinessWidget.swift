import ImgManagerAPI
import SwiftUI
import WidgetKit

/// `ReadinessEntry` is deliberately WidgetKit-free (it is compiled into the app target and into
/// `ImgManagerTests` as well, neither of which has any business importing WidgetKit) — the
/// framework conformance is declared HERE, in the only target that needs it. Same module, so
/// this is an ordinary conformance, not a retroactive one.
extension ReadinessEntry: TimelineEntry {}

/// Carries a WidgetKit completion handler across the `Task` boundary the async resolution
/// needs. The framework's completion parameter is not itself `Sendable` under this project's
/// strict-concurrency setting, and WidgetKit calls it exactly once from the same process —
/// this box is the narrowest possible statement of that fact, rather than loosening the
/// project-wide concurrency setting for one call shape.
private final class CompletionBox<Value>: @unchecked Sendable {
  private let completion: (Value) -> Void

  init(_ completion: @escaping (Value) -> Void) {
    self.completion = completion
  }

  func call(_ value: Value) {
    completion(value)
  }
}

/// The WidgetKit adapter. It owns the framework call shape and NOTHING else — every decision
/// (credential validity, what to render when a fetch fails, how long to ask for) belongs to
/// `ReadinessTimelineResolver`, which is testable because it is not this type.
struct ReadinessTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> ReadinessEntry {
    ReadinessEntryBuilder.noData(at: Date())
  }

  func getSnapshot(in context: Context, completion: @escaping (ReadinessEntry) -> Void) {
    let box = CompletionBox(completion)
    Task {
      let resolution = await Self.resolve()
      box.call(resolution.entry)
    }
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ReadinessEntry>) -> Void) {
    let box = CompletionBox(completion)
    Task {
      let resolution = await Self.resolve()
      box.call(
        Timeline(entries: [resolution.entry], policy: .after(resolution.nextRefresh)))
    }
  }

  /// The extension's composition root: the SAME keychain namespace the app uses (one access
  /// group, resolved at use time — see `KeychainAccessGroup`), the SAME generated client, and
  /// the queue's own read-only service. No renewal is wired in and none is possible from here:
  /// `AuthenticatedClientTransport`'s terminal-401 handler defaults to a no-op, and `AuthSession`
  /// is not compiled into this target at all. An expired token is the app's problem to fix.
  private static func resolve(now: Date = Date()) async -> ReadinessTimelineResolver.Resolution {
    let credentialStore = CredentialStore()
    let client = ImgManagerAPIClient.make(
      transport: AuthenticatedClientTransport(credentialStore: credentialStore))
    let service = QueueService(client: client)
    let snapshot = ReadinessSnapshotStore.applicationSupport()
    let resolver = ReadinessTimelineResolver(
      loadCredential: { await credentialStore.load() },
      fetchSummaries: { try await service.summaries() },
      readSnapshot: {
        guard let snapshot else { return nil }
        return snapshot.load()
      },
      writeSnapshot: { entry in
        guard let snapshot else { return }
        snapshot.save(entry)
      },
      clearSnapshot: {
        guard let snapshot else { return }
        snapshot.clear()
      }
    )
    return await resolver.resolve(now: now)
  }
}

/// The rendered widget. Counts are the queue home's own section counts, in the queue home's own
/// `displayOrder` — this view derives nothing (Q4 drift hazard: readiness is never recomputed
/// from counts, dates or sync state, here least of all).
struct ReadinessWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: ReadinessEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Shoots")
        .font(.caption)
        .foregroundStyle(.secondary)
      if entry.hasFetchedCounts {
        counts
        Spacer(minLength: 0)
        Text(footerText)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      } else {
        Text(emptyStateText)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .containerBackground(.fill.tertiary, for: .widget)
  }

  /// Small has room for the two numbers the queue is actually driven by; medium shows the whole
  /// six-section vocabulary. Nothing is invented for either size — both read the same entry.
  @ViewBuilder
  private var counts: some View {
    if family == .systemSmall {
      row(.readyToReview)
      row(.syncProblem)
    } else {
      ForEach(ReadinessSection.displayOrder, id: \.self) { section in
        row(section)
      }
    }
  }

  private func row(_ section: ReadinessSection) -> some View {
    HStack(spacing: 6) {
      Text(section.title)
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text("\(entry.count(for: section))")
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
  }

  /// "as of" is stamped from `fetchedAt` — the moment the counts were really fetched — never
  /// from the entry's timeline date, which is only when WidgetKit last asked.
  private var footerText: String {
    guard let fetchedAt = entry.fetchedAt else { return "" }
    let stamp = fetchedAt.formatted(date: .omitted, time: .shortened)
    switch entry.state {
    case .live:
      return "as of \(stamp)"
    case .lastKnown:
      return "\(DegradedStateCopy.notConnected) · as of \(stamp)"
    case .signedOut, .noData:
      return ""
    }
  }

  private var emptyStateText: String {
    switch entry.state {
    case .signedOut:
      return "Open the app to sign in"
    case .noData:
      return "No data yet"
    case .live, .lastKnown:
      return ""
    }
  }
}

struct ReadinessWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: ReadinessWidgetKind.value, provider: ReadinessTimelineProvider()) {
      entry in
      ReadinessWidgetView(entry: entry)
    }
    .configurationDisplayName("Shoot readiness")
    .description("How many shoots are waiting, by readiness section.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct ImgManagerWidgetBundle: WidgetBundle {
  var body: some Widget {
    ReadinessWidget()
  }
}
