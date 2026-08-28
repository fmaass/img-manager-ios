import Testing

@testable import ImgManager

/// Ported from memos-ng-ios's `SignOutFlowTests.swift` — same incident, same invariant: the tap
/// that opens the conversation never reaches the server by itself, and the tap that ends the
/// session must come from a confirmation dialog, not from the destructive row a reflexive
/// second tap would land on.
@Suite("SignOutFlow")
struct SignOutFlowTests {
  @Test("requested from idle asks; requested again while asking is idempotent")
  func requestedIsIdempotent() {
    #expect(SignOutFlow.next(.idle, on: .requested) == .asking)
    #expect(SignOutFlow.next(.asking, on: .requested) == .asking)
  }

  @Test("requested does not restart a revoke already in flight")
  func requestedDoesNotRestartRevoking() {
    #expect(SignOutFlow.next(.revoking, on: .requested) == .revoking)
  }

  @Test("confirmed from asking starts the revoke")
  func confirmedFromAskingRevokes() {
    #expect(SignOutFlow.next(.asking, on: .confirmed) == .revoking)
  }

  @Test("confirmed with no question asked is ignored")
  func confirmedFromIdleIsIgnored() {
    #expect(SignOutFlow.next(.idle, on: .confirmed) == .idle)
  }

  @Test("cancelled from asking returns to idle")
  func cancelledFromAsking() {
    #expect(SignOutFlow.next(.asking, on: .cancelled) == .idle)
  }

  @Test("cancelled cannot abort a revoke already sent")
  func cancelledCannotAbortRevoking() {
    #expect(SignOutFlow.next(.revoking, on: .cancelled) == .revoking)
  }

  @Test("revoked or alreadyRevoked settles the machine back to idle (the sheet dismisses)")
  func settledOutcomesReturnToIdle() {
    #expect(SignOutFlow.next(.revoking, on: .revokeReturned(.revoked)) == .idle)
    #expect(SignOutFlow.next(.revoking, on: .revokeReturned(.alreadyRevoked)) == .idle)
  }

  @Test("a failed revoke moves to explaining, carrying Forget This Device Anyway verbatim")
  func failedRevokeExplains() {
    guard
      case .explaining(let decision) = SignOutFlow.next(
        .revoking, on: .revokeReturned(.revokeFailed))
    else {
      Issue.record("expected .explaining")
      return
    }
    #expect(decision.discardTitle == "Forget This Device Anyway")
  }

  @Test("revokeReturned outside .revoking is ignored — it cannot end a sign-out never started")
  func revokeReturnedOutsideRevokingIsIgnored() {
    #expect(SignOutFlow.next(.idle, on: .revokeReturned(.revoked)) == .idle)
    #expect(SignOutFlow.next(.asking, on: .revokeReturned(.revoked)) == .asking)
  }

  @Test("only .revoking is allowed to reach the network")
  func onlyRevokingRevokes() {
    #expect(!SignOutFlow.revokes(.idle))
    #expect(!SignOutFlow.revokes(.asking))
    #expect(SignOutFlow.revokes(.revoking))
    #expect(!SignOutFlow.revokes(.explaining(.init(message: "x", discardTitle: "y"))))
  }

  @Test("decision(for:) is nil for a settled outcome and non-nil only for revokeFailed")
  func decisionOnlyForFailure() {
    #expect(SignOutFlow.decision(for: .revoked) == nil)
    #expect(SignOutFlow.decision(for: .alreadyRevoked) == nil)
    #expect(SignOutFlow.decision(for: .revokeFailed) != nil)
  }
}
