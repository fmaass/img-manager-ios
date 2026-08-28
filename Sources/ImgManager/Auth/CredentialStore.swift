import Foundation
import Security

/// The token, its expiry and the subject it was minted for — stored together, because a token
/// with no known expiry or owner is not a usable credential (p1-spec-rev2.md §3 item 3: "Store
/// token, expiry and subject together").
struct Credential: Codable, Sendable, Equatable {
  let token: String
  let expiresAt: Date
  let subject: String
}

/// What reading the stored credential answered. Three cases, not two, mirroring
/// memos-ng-ios's `CredentialReadOutcome`: "there is nothing here" and "I cannot tell you what
/// is here" must never collapse into the same answer, because only the first is evidence of
/// being signed out. A missing entitlement, corrupted JSON or an unreadable Keychain item is an
/// ERROR — never "signed out" (p1-spec-rev2.md §3 item 3, verbatim).
enum CredentialLoadResult: Sendable, Equatable {
  case absent
  case present(Credential)
  case error(CredentialStoreError)
}

enum CredentialStoreError: Error, Sendable, Equatable {
  case keychain(Keychain.Failure)
  /// The stored bytes are not the `Credential` JSON shape — corruption, not absence.
  case corrupted
}

/// The device credential's one home. An ACTOR: a renewal's replace and a sign-out's clear must
/// not interleave — a clear racing a replace could otherwise land the replace's write after the
/// clear ran, leaving a revoked token readable, or the clear's delete after the replace's write,
/// leaving no credential where a fresh renewal just landed one.
///
/// Ported in shape from memos-ng-ios's `CredentialVault` (also an actor over `Keychain`,
/// `Packages/MemosCore/Sources/MemosCore/Security/CredentialVault.swift`), narrowed to this
/// app's single pinned namespace — there is no multi-namespace precedence walk here because
/// there is only one namespace to walk.
actor CredentialStore {
  private let keychain: Keychain
  private let account: String
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  /// `service`/`accessGroup`/`account` default to the pinned contract (p1-spec-rev2.md §3 item
  /// 3): service `live.discomarder.imgmanager`, access group
  /// `$(AppIdentifierPrefix)live.discomarder.imgmanager.credentials`, account `native-pat`. The
  /// access group default is `KeychainAccessGroup.resolved` — the RUNTIME-resolved value
  /// (`Keychain.swift`'s own doc comment: a Swift string literal cannot express Xcode's
  /// build-time `$(AppIdentifierPrefix)` substitution) — falling back to the contract's literal
  /// value only if the probe itself could not resolve anything (which is itself an entitlement
  /// problem `load()`/`save()`/`clear()` will then surface as `.notEntitled` on the first real
  /// call, never silently).
  /// Overridable only for tests, which use a throwaway account under the SAME real Keychain
  /// (mirrors memos-ng-ios's own test pattern — the test bundle is HOSTED in the app precisely
  /// so it holds the keychain entitlement in the simulator; see project.yml's comment on
  /// `ImgManagerTests`).
  init(
    service: String = "live.discomarder.imgmanager",
    accessGroup: String = KeychainAccessGroup.resolved
      ?? "$(AppIdentifierPrefix)live.discomarder.imgmanager.credentials",
    account: String = "native-pat"
  ) {
    self.keychain = Keychain(service: service, accessGroup: accessGroup)
    self.account = account
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
  }

  func load() -> CredentialLoadResult {
    let raw: String?
    do {
      raw = try keychain.string(for: account)
    } catch let failure as Keychain.Failure {
      return .error(.keychain(failure))
    } catch {
      return .error(.keychain(.unexpectedStatus(errSecInternalError)))
    }
    guard let raw else { return .absent }
    guard let data = raw.data(using: .utf8),
      let credential = try? decoder.decode(Credential.self, from: data)
    else {
      return .error(.corrupted)
    }
    return .present(credential)
  }

  /// Saves a credential, replacing whatever this namespace held. `Keychain.set` is
  /// update-then-add, so this is the same call whether it is the FIRST save after an exchange
  /// or the atomic replace a renewal performs after its request already succeeded — "atomically
  /// replace the Keychain item only after a successful response" (p1-spec-rev2.md §3) is
  /// satisfied by the CALLER never invoking this until the new token is already in hand, not by
  /// anything transactional here beyond the actor's own serialization.
  func save(_ credential: Credential) throws {
    let data = try encoder.encode(credential)
    guard let raw = String(data: data, encoding: .utf8) else {
      throw CredentialStoreError.corrupted
    }
    do {
      try keychain.set(raw, for: account)
    } catch let failure as Keychain.Failure {
      throw CredentialStoreError.keychain(failure)
    }
  }

  /// Removes the stored credential. Idempotent — clearing an already-empty namespace is
  /// success, which is what sign-out needs whatever state it started from.
  func clear() throws {
    do {
      try keychain.remove(account)
    } catch let failure as Keychain.Failure {
      throw CredentialStoreError.keychain(failure)
    }
  }
}
