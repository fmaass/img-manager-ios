import Foundation

@testable import ImgManager

/// A scriptable double for `CredentialPersisting` — used ONLY to prove `AuthSession`'s
/// error-surfacing logic (diff-gate round 1, blocker 2), which needs a way to force a save- or
/// clear-only failure that a real, correctly-entitled Keychain cannot produce on demand (an
/// access group this build is not entitled to fails reads and writes symmetrically, proving
/// nothing about an isolated save or clear failure). The real `CredentialStore` actor remains
/// the only PRODUCTION conformer and is exercised unmocked in `CredentialStoreTests.swift`.
actor FakeCredentialStore: CredentialPersisting {
  struct ForcedFailure: Error, Sendable, Equatable {}

  /// Consumed front-to-back by successive `load()` calls; the LAST element repeats once the
  /// list is exhausted, so a test only has to script as many distinct answers as it cares about.
  private var loadResults: [CredentialLoadResult]
  private let saveShouldFail: Bool
  private let clearShouldFail: Bool
  private(set) var savedCredentials: [Credential] = []
  private(set) var clearCallCount = 0

  init(
    loadResults: [CredentialLoadResult] = [.absent],
    saveShouldFail: Bool = false,
    clearShouldFail: Bool = false
  ) {
    self.loadResults = loadResults
    self.saveShouldFail = saveShouldFail
    self.clearShouldFail = clearShouldFail
  }

  func load() async -> CredentialLoadResult {
    guard loadResults.count > 1 else { return loadResults.first ?? .absent }
    return loadResults.removeFirst()
  }

  func save(_ credential: Credential) async throws {
    savedCredentials.append(credential)
    if saveShouldFail { throw ForcedFailure() }
  }

  func clear() async throws {
    clearCallCount += 1
    if clearShouldFail { throw ForcedFailure() }
  }
}
