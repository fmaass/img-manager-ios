import ImgManagerAPI
import SwiftUI

/// One rendered line of the Status sheet: a label and a value, and nothing else. There is no
/// action on this type by construction — that is what makes "read-only surface" a property of
/// the model rather than a promise in a comment.
struct StatusSheetRow: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let value: String
}

struct StatusSheetSection: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let rows: [StatusSheetRow]
}

/// WP13 P5a (IMGMGR-221): `GET /api/status`, rendered. Maintenance state, last indexed, store
/// health, coverage and the recent runs — READ ONLY. `POST /api/reindex` exists in the vendored
/// spec and is deliberately NOT wired here or anywhere else in the client (plan invariant
/// (viii)); the sheet's only verbs are "close" and "try again".
///
/// A pure model so the shapes below — above all the timestamps — are testable without a render
/// host, the same posture `GridGroupControl.title(for:)` already uses.
enum StatusSheetModel {

  /// Estate ADR-0007 ([/link/2553](/link/2553)): every rendered timestamp is Europe/Zurich AND
  /// carries its zone, so a reader is never left guessing whether "21:51" is theirs or the
  /// server's. `en_US_POSIX` because this string is a fixed format, not a localized one — a
  /// locale-dependent rendering could not be pinned by a test.
  static let zone = TimeZone(identifier: "Europe/Zurich")!
  static let zoneLabel = "Europe/Zurich"

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "d MMM yyyy, HH:mm"
    return formatter
  }()

  static func timestamp(_ date: Date) -> String {
    "\(formatter.string(from: date)) \(zoneLabel)"
  }

  static func sections(_ status: Components.Schemas.StatusResponse) -> [StatusSheetSection] {
    [
      maintenanceSection(status), storesSection(status), coverageSection(status),
      runsSection(status),
    ]
    .filter { !$0.rows.isEmpty }
  }

  private static func maintenanceSection(_ status: Components.Schemas.StatusResponse)
    -> StatusSheetSection
  {
    var rows: [StatusSheetRow] = [
      StatusSheetRow(
        id: "maintenance.enabled", label: "Maintenance loop",
        value: status.maintenance.enabled ? "Enabled" : "Disabled"),
      StatusSheetRow(
        id: "maintenance.lock", label: "Executor lock",
        value: (status.maintenance.executorLock?.rawValue ?? "unknown").capitalized),
    ]
    if let note = status.maintenance.note, !note.isEmpty {
      rows.append(StatusSheetRow(id: "maintenance.note", label: "Note", value: note))
    }
    if let next = status.maintenance.nextRunAt {
      rows.append(
        StatusSheetRow(id: "maintenance.nextRun", label: "Next run", value: timestamp(next)))
    }
    if let indexed = status.lastIndexedAt {
      rows.append(
        StatusSheetRow(
          id: "maintenance.lastIndexed", label: "Last indexed",
          value: timestamp(indexed)))
    }
    // NO "running now" row: the vendored document declares `active_run` as
    // `anyOf: [MaintenanceRunView, null]`, and swift-openapi-generator DROPS that property
    // entirely — the generated `StatusResponse` has coverage/lastIndexedAt/maintenance/runs/
    // stores and no `activeRun` at all (verified in the gate's own generated Types.swift,
    // run p5a-red 22:38). Rendering it would need a re-vendor, which this phase does not do.
    // The most recent entry of `runs` is what the sheet shows instead.
    return StatusSheetSection(id: "maintenance", title: "Maintenance", rows: rows)
  }

  private static func storesSection(_ status: Components.Schemas.StatusResponse)
    -> StatusSheetSection
  {
    let rows = (status.stores ?? []).map { store in
      StatusSheetRow(
        id: "store.\(store.store)", label: store.store.capitalized,
        value: store.indexed == true
          ? "\(store.health.rawValue.capitalized) · indexed"
          : "\(store.health.rawValue.capitalized) · not indexed")
    }
    return StatusSheetSection(id: "stores", title: "Stores", rows: rows)
  }

  private static func coverageSection(_ status: Components.Schemas.StatusResponse)
    -> StatusSheetSection
  {
    var rows: [StatusSheetRow] = [
      StatusSheetRow(
        id: "coverage.images", label: "Photographs",
        value: "\(status.coverage.imagesActive) present · \(status.coverage.imagesMissing) missing")
    ]
    rows += status.coverage.tiers.map { tier in
      StatusSheetRow(
        id: "coverage.\(tier.tier)", label: "\(tier.tier.capitalized) proxies",
        value: String(format: "%.1f %% · %d failed", tier.coveragePercent, tier.failed))
    }
    return StatusSheetSection(id: "coverage", title: "Coverage", rows: rows)
  }

  /// The five most recent runs. A finished run is stamped with its FINISH time, a still-running
  /// one with its start — both through `timestamp`, so no run line can render an unlabelled or
  /// non-Zurich clock.
  private static func runsSection(_ status: Components.Schemas.StatusResponse)
    -> StatusSheetSection
  {
    let rows = status.runs.prefix(5).map { run in
      StatusSheetRow(
        id: "run.\(run.id)", label: "\(run.trigger) · \(run.state)",
        value: timestamp(run.finishedAt ?? run.startedAt))
    }
    return StatusSheetSection(id: "runs", title: "Recent runs", rows: Array(rows))
  }
}

/// The sheet itself. Every row is a `StatusSheetRow`, which has no action — the only controls
/// are Done and, when the read failed, Try Again (which re-READS; it triggers nothing on the
/// server).
struct StatusSheet: View {
  @Bindable var store: GridStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if let status = store.statusSnapshot {
          List {
            ForEach(StatusSheetModel.sections(status)) { section in
              Section(section.title) {
                ForEach(section.rows) { row in
                  LabeledContent(row.label, value: row.value)
                    .accessibilityIdentifier("statusRow.\(row.id)")
                }
              }
            }
          }
        } else if store.statusReadFailed {
          ContentUnavailableView {
            Label("Couldn't read the status", systemImage: "exclamationmark.triangle")
          } actions: {
            Button("Try Again") { Task { await store.loadStatus() } }
          }
        } else {
          ProgressView()
        }
      }
      .navigationTitle("Status")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
