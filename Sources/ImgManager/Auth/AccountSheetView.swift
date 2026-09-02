import SwiftUI

/// The account sheet — opened from the persistent `person.crop.circle` toolbar item
/// (p1-spec-rev2.md §3 item 2). "Sign Out…" is last and destructive, and every tap routes
/// through `SignOutFlow` so a reflexive second tap can never revoke a live credential without
/// the confirmation dialog actually being answered.
///
/// WP13 P8 (IMGMGR-214) makes it the app's settings surface as well as its account one: this is
/// where a persisted preference is reachable WITHOUT being in the loupe, which is the second
/// chrome for advance-on-mark since IMGMGR-348 removed the loupe header's own toggle.
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
        Section("Culling") {
          Toggle("Advance After Marking", isOn: $preferences.autoAdvanceOnMark)
            .accessibilityIdentifier("accountAutoAdvanceToggle")
          Text("After a mark lands in the loupe, move to the next photograph.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
