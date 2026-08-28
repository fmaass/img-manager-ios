/// Where `RootView` routes for a given `AuthStatus` — pulled out as a pure function so
/// "signed-out routing" (p1-spec-rev2.md §5 test inventory) is a value test rather than a
/// rendered-view test. `RootView.body` is a straight `switch` over this and adds nothing to the
/// decision.
enum RootDestination: Equatable, Hashable {
  case checking
  case signIn
  /// Carries the message `AuthSession` already composed — never `signedIn`'s workspace, and
  /// never `signIn` (p1-spec-rev2.md §3 item 3: "not 'signed out'").
  case credentialError(String)
  case workspace
}

enum RootRouting {
  static func destination(for status: AuthStatus) -> RootDestination {
    switch status {
    case .checking: .checking
    case .signedOut: .signIn
    case .credentialError(let message): .credentialError(message)
    case .signedIn: .workspace
    }
  }
}
