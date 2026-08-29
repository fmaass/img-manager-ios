import Foundation
import ImgManagerAPI
import Observation

/// The one degraded state P3 owns (fold item 3; [/link/3220] §4.1): "Not connected to the
/// home network" — specific copy, not a generic error. The rest of the native
/// degraded-state set (tier-unmounted, empty-filter, no-preview, missing-original,
/// tile-load-failure) is an OPEN item for a later phase (functional spec, *Degraded and
/// unreachable states*) — this type intentionally has no case for any of them.
enum DegradedStateCopy {
  static let notConnected = "Not connected to the home network"

  /// IMGMGR-198's second banner line. Lives HERE, beside `notConnected`, so degraded copy stays
  /// in exactly one place. A replayed cache is NEVER shown unlabelled — line one says the server
  /// is out of reach, this line says how old what you are looking at is. Below a minute it reads
  /// "just now" rather than a seconds count: the answer's age is what matters, not its precision.
  static func showingCached(since fetchedAt: Date) -> String {
    let elapsed = Date().timeIntervalSince(fetchedAt)
    guard elapsed >= 60 else { return "Showing shoots from just now" }
    return "Showing shoots from "
      + fetchedAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
  }
}

/// Drives the shell's one connectivity-dependent surface (the sidebar/Queue placeholder)
/// from the injected `ImgManagerAPIService`, which itself wraps the REAL generated client
/// (diff-gate blocker 1 fold). `check()` maps the decoded `ApiHealthResponse.status` field
/// into this closed state. `status` NEVER carries the underlying error — `.unreachable` has
/// no associated value — which is the structural half of fold item 4's suppression
/// guarantee: there is no stored property here `localizedDescription`, a server body, a
/// hostname or raw transport text could occupy even by mistake. See
/// `DegradedStateTests.swift` for the sentinel-based proof.
@MainActor
@Observable
final class ConnectivityState {
  enum Status: Equatable {
    case checking
    case connected
    case unreachable
  }

  private(set) var status: Status = .checking
  private let service: ImgManagerAPIService

  init(service: ImgManagerAPIService) {
    self.service = service
  }

  /// Fires on `RootView`'s `.task` (launch) and is safe to call again on any later
  /// re-check (foreground, pull-to-refresh once one exists) — the same path serves both
  /// "retry" and "recovery" from an `.unreachable` state (fold item 2).
  func check() async {
    status = .checking
    do {
      let health = try await service.health()
      status = health.status == "ok" ? .connected : .unreachable
    } catch {
      status = .unreachable
    }
  }
}
