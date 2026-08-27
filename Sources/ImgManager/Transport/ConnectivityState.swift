import Foundation
import Observation

/// The one degraded state P3 owns (fold item 3; [/link/3220] §4.1): "Not connected to the
/// home network" — specific copy, not a generic error. The rest of the native
/// degraded-state set (tier-unmounted, empty-filter, no-preview, missing-original,
/// tile-load-failure) is an OPEN item for a later phase (functional spec, *Degraded and
/// unreachable states*) — this type intentionally has no case for any of them.
enum DegradedStateCopy {
  static let notConnected = "Not connected to the home network"
}

/// Drives the shell's one connectivity-dependent surface (the sidebar/Queue placeholder)
/// from the injected `ImgManagerTransport`. `status` NEVER carries the underlying error —
/// `.unreachable` has no associated value — which is the structural half of fold item 4's
/// suppression guarantee: there is no stored property here `localizedDescription`, a
/// server body, a hostname or raw transport text could occupy even by mistake. See
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
  private let transport: any ImgManagerTransport

  init(transport: any ImgManagerTransport) {
    self.transport = transport
  }

  /// Fires on `RootView`'s `.task` (launch) and is safe to call again on any later
  /// re-check (foreground, pull-to-refresh once one exists) — the same path serves both
  /// "retry" and "recovery" from an `.unreachable` state (fold item 2).
  func check() async {
    status = .checking
    do {
      let health = try await transport.health()
      status = health.ok ? .connected : .unreachable
    } catch {
      status = .unreachable
    }
  }
}
