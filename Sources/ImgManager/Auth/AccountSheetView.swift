import SwiftUI

/// The account sheet — opened from the persistent `person.crop.circle` toolbar item
/// (p1-spec-rev2.md §3 item 2). "Sign Out…" is last and destructive, and every tap routes
/// through `SignOutFlow` so a reflexive second tap can never revoke a live credential without
/// the confirmation dialog actually being answered.
///
/// WP13 P8 (IMGMGR-214) makes it the app's settings surface as well as its account one: this is
/// where a persisted preference is reachable WITHOUT being in the loupe, which is the second
/// half of the persistent-chrome rule for advance-on-mark (the loupe header carries the first).
/// It takes `GridPreferences` rather than reaching for a global, so the sheet a test builds owns
/// its own suite exactly like every other consumer of that type.
struct AccountSheetView: View {
  var auth: AuthSession
  @Bindable var preferences: GridPreferences
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
        // RED-3 MUTATION (WP13 P8): the Culling section is removed on purpose. Round 2 could not
        // prove `testAccountSheetCarriesTheAutoAdvanceRow` real — it failed before ever reaching
        // the sheet, on the toolbar query. With that query fixed, this build is the one where
        // the row is genuinely absent, so the row assertion itself is observed failing. The
        // GREEN commit puts the section back.
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
