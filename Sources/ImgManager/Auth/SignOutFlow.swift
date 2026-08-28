/// Signing out, as a state machine rather than a button that does it directly.
///
/// Ported from memos-ng-ios's `MemosFeatures/SignOutFlow.swift`, same incident it exists to
/// prevent: a destructive row directly under the anchor that opened its menu/sheet is one
/// reflexive second tap away from revoking a live credential with no confirmation ever shown.
/// So the tap that opens the conversation (`requested`) and the tap that ends the session
/// (`confirmed`) are different events, and only `confirmed` — arriving from a confirmation
/// dialog that is not under the control that asked — ever reaches the server.
enum SignOutFlow {
  struct Decision: Equatable {
    let message: String
    /// "Forget This Device Anyway" — verbatim, p1-spec-rev2.md §3 item 2.
    let discardTitle: String
  }

  /// How far the conversation has got. `revoking` is the ONLY stage in which the app is
  /// allowed to talk to the server.
  enum Stage: Equatable {
    case idle
    case asking
    case revoking
    case explaining(Decision)
  }

  enum Event: Equatable {
    /// Somebody tapped "Sign Out…" in the account sheet.
    case requested
    /// The question was answered yes — in the confirmation dialog, or "Try again" after a
    /// failed revoke.
    case confirmed
    /// The question was dismissed, whether by Cancel or the sheet going away.
    case cancelled
    case revokeReturned(SignOutOutcome)
  }

  static func next(_ stage: Stage, on event: Event) -> Stage {
    switch event {
    case .requested:
      // Idempotent: a double-tap is one question asked once, and cannot restart a revoke
      // already in flight.
      return stage == .idle ? .asking : stage
    case .confirmed:
      switch stage {
      case .asking, .explaining: return .revoking
      case .idle, .revoking: return stage
      }
    case .cancelled:
      // Dismissal cannot abort a revoke already sent — the request is gone.
      switch stage {
      case .asking, .explaining, .idle: return .idle
      case .revoking: return .revoking
      }
    case .revokeReturned(let outcome):
      guard stage == .revoking else { return stage }
      return decision(for: outcome).map(Stage.explaining) ?? .idle
    }
  }

  /// The one stage allowed to reach the network. The view starts the request when the machine
  /// ENTERS it, so there is exactly one place a revoke can begin.
  static func revokes(_ stage: Stage) -> Bool { stage == .revoking }

  /// `nil` means the sign-out is settled and there is nothing to ask — `.revoked` and
  /// `.alreadyRevoked` both dismiss the sheet outright.
  static func decision(for outcome: SignOutOutcome) -> Decision? {
    guard outcome == .revokeFailed else { return nil }
    return Decision(
      message:
        "The server could not be reached to revoke this device's access."
        + " Forgetting it anyway leaves the credential valid on the server until it expires"
        + " or is revoked.",
      discardTitle: "Forget This Device Anyway"
    )
  }
}
