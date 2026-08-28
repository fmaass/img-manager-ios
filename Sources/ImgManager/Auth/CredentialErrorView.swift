import SwiftUI

/// `AuthStatus.credentialError`'s screen — deliberately NOT the sign-in surface
/// (p1-spec-rev2.md §3 item 3: missing entitlement, corruption or a failed read is an error,
/// never "signed out"). Offers the same sign-in action as a recovery path (a fresh sign-in
/// overwrites whatever the store could not read back), but says plainly that something is
/// wrong first.
struct CredentialErrorView: View {
  let message: String
  var auth: AuthSession
  @State private var isRetrying = false

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.orange)
      Text("Something needs attention")
        .font(.title2.bold())
      Text(message)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Button {
        Task {
          isRetrying = true
          await auth.bootstrap()
          isRetrying = false
        }
      } label: {
        Text("Try Again")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(isRetrying)
      .padding(.horizontal, 32)
      Spacer()
      Spacer()
    }
  }
}
