import SwiftUI

/// The sign-in surface. Every string here is VERBATIM from the pinned contract
/// (p1-spec-rev2.md §3 item 1) — title, description, button label and footnote are quoted
/// directly, not paraphrased. System components only (no editable server or PAT field: the
/// backend URL is a single constant, `ImgManagerAPIClient.baseURL`).
struct SignInView: View {
  var auth: AuthSession
  @State private var isSigningIn = false

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      VStack(spacing: 8) {
        Text("img-manager")
          .font(.largeTitle.bold())
        Text("Review your photo library at home.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      Button {
        Task {
          isSigningIn = true
          await auth.signIn()
          isSigningIn = false
        }
      } label: {
        if isSigningIn {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text("Sign in")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(isSigningIn)

      if let message = auth.signInError?.message {
        // Non-raw by construction: SignInError.message is a closed, hand-written sentence per
        // case — there is no stored property anywhere on SignInError a raw transport string,
        // server body or hostname could occupy.
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }

      Text("Opens the household sign-in. img-manager never sees your password.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Spacer()
      Spacer()
    }
    .padding(.horizontal, 32)
  }
}
