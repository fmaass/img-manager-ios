import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Composition root for the generated client's LIVE wire transport (P1's native-auth lane).
/// `OpenAPIURLSession` stays confined to this package — it already depends on it to build the
/// generated client in the first place — rather than becoming a second package reference the
/// app target has to declare, mirroring memos-ng-ios's `MemosAPI/APIClientFactory.swift`
/// (`URLSessionTransport(configuration: .init(session: urlSession))`, same library, same call).
///
/// The app layer's own `AuthenticatedClientTransport` (`Sources/ImgManager/Transport/`) wraps
/// whatever this returns and adds the Bearer header from `CredentialStore` — Bearer injection
/// stays app-layer because it is the one place this package's boundary comment (P0a) still
/// holds: "this package knows the wire format and nothing about the domain", and a credential
/// is domain.
public enum ImgManagerAPI {
  public static func liveTransport(urlSession: URLSession = .shared) -> any ClientTransport {
    URLSessionTransport(configuration: .init(session: urlSession))
  }
}
