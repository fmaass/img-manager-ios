import SwiftUI

/// The account sheet — opened from the persistent `person.crop.circle` toolbar item
/// (p1-spec-rev2.md §3 item 2). "Sign Out…" is last and destructive, and every tap routes
/// through `SignOutFlow` so a reflexive second tap can never revoke a live credential without
/// the confirmation dialog actually being answered.
struct AccountSheetView: View {
  var auth: AuthSession
  @Environment(\.dismiss) private var dismiss
  @State private var stage: SignOutFlow.Stage = .idle

  private var subject: String? {
    if case .signedIn(let subject) = auth.status { return subject }
    return nil
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(subject.map { "Signed in as \($0)" } ?? "Signed in")
        }
        Section {
          Button("Sign Out…", role: .destructive) {
            stage = SignOutFlow.next(stage, on: .requested)
          }
        }
      }
      .navigationTitle("Account")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .confirmationDialog(
      "Sign out of img-manager?",
      isPresented: Binding(
        get: { stage == .asking },
        set: { presented in
          if !presented { stage = SignOutFlow.next(stage, on: .cancelled) }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) { confirmSignOut() }
      Button("Cancel", role: .cancel) { stage = SignOutFlow.next(stage, on: .cancelled) }
    }
    .alert(
      "Sign-out incomplete",
      isPresented: Binding(
        get: {
          if case .explaining = stage { return true }
          return false
        },
        set: { presented in
          if !presented { stage = SignOutFlow.next(stage, on: .cancelled) }
        }
      ),
      presenting: explainingDecision
    ) { decision in
      Button(decision.discardTitle, role: .destructive) {
        Task {
          await auth.forgetDeviceAnyway()
          dismiss()
        }
      }
      Button("Try Again") { confirmSignOut() }
      Button("Cancel", role: .cancel) { stage = SignOutFlow.next(stage, on: .cancelled) }
    } message: { decision in
      Text(decision.message)
    }
  }

  private var explainingDecision: SignOutFlow.Decision? {
    guard case .explaining(let decision) = stage else { return nil }
    return decision
  }

  private func confirmSignOut() {
    stage = SignOutFlow.next(stage, on: .confirmed)
    Task {
      let outcome = await auth.signOut()
      stage = SignOutFlow.next(stage, on: .revokeReturned(outcome))
      if outcome != .revokeFailed { dismiss() }
    }
  }
}
