import Foundation
import Security

/// A single generic-password Keychain namespace, addressed by name.
///
/// Ported from memos-ng-ios's `MemosCore/Security/Keychain.swift`, narrowed from that
/// project's multi-namespace `CredentialVault`/`DeviceCredentials` migration system to the ONE
/// namespace this app's pinned contract names (p1-spec-rev2.md §3 item 3): access group
/// `$(AppIdentifierPrefix)live.discomarder.imgmanager.credentials`, service
/// `live.discomarder.imgmanager`, account `native-pat`, `kSecAttrSynchronizable=false`,
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` — the most restrictive class available,
/// pinned because this app has no background-auth requirement (unlike memos-ng-ios's
/// `AfterFirstUnlockThisDeviceOnly`, chosen there for its background outbox-refresh task; this
/// app has no equivalent).
///
/// Synchronous by design — every query names its access group explicitly and every `SecItem*`
/// call is microseconds long, so nothing here suspends. `CredentialStore` is the actor above
/// this that gives the pair of calls making up a save/load/clear its atomicity.
struct Keychain: Sendable {
  enum Failure: Error, Equatable {
    case unexpectedStatus(OSStatus)
    /// `errSecMissingEntitlement`: this build cannot reach data it owns. Its own case because
    /// it must never be read as "nothing here" — the entitlement is missing, not the token.
    case notEntitled
    case dataNotUTF8
    /// The keychain returned an item that is not data. Like `dataNotUTF8`, this is CORRUPTION,
    /// not absence — answering "nothing here" would tell a session nobody is signed in on the
    /// evidence that something unreadable is stored.
    case itemNotData
  }

  let service: String
  let accessGroup: String

  private nonisolated static func failure(_ status: OSStatus) -> Failure {
    status == errSecMissingEntitlement ? .notEntitled : .unexpectedStatus(status)
  }

  private nonisolated func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: accessGroup,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private nonisolated func attributes(for value: String) throws -> [String: Any] {
    guard let data = value.data(using: .utf8) else { throw Failure.dataNotUTF8 }
    return [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
    ]
  }

  /// Update-then-add, so a fresh save and a replace (renewal's atomic Keychain swap) are the
  /// same call: `SecItemUpdate` finds nothing on the first save and falls through to add.
  nonisolated func set(_ value: String, for account: String) throws {
    let query = baseQuery(account: account)
    let attributes = try attributes(for: value)

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    if updateStatus != errSecItemNotFound { throw Self.failure(updateStatus) }

    var insert = query
    insert.merge(attributes) { current, _ in current }
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw Self.failure(addStatus) }
  }

  /// `nil` means the namespace holds nothing for this account, and NOTHING else. Every other
  /// answer — a status, an item of the wrong type, bytes that are not UTF-8 — is thrown, so a
  /// caller can tell "there is no credential" from "there is one and it will not come back".
  nonisolated func string(for account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Self.failure(status) }
    guard let data = item as? Data else { throw Failure.itemNotData }
    guard let value = String(data: data, encoding: .utf8) else { throw Failure.dataNotUTF8 }
    return value
  }

  /// Removing a credential that was never there is success, not an error: sign-out must leave
  /// nothing behind whatever state it started from.
  nonisolated func remove(_ account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.failure(status)
    }
  }
}

/// The access group `$(AppIdentifierPrefix)live.discomarder.imgmanager.credentials` actually
/// resolves to for THIS build's code signature.
///
/// A Swift string literal cannot express a build-time Xcode substitution: `$(AppIdentifierPrefix)`
/// is expanded when Xcode processes the `.entitlements` FILE, never inside compiled Swift
/// source, so the literal string pinned by the contract (p1-spec-rev2.md §3 item 3) is only
/// ever the CORRECT value to pass to `SecItem*` on a build where that expands to nothing
/// (no team, ad-hoc signing) or is otherwise queried by the caller who already knows the
/// resolved prefix. Every other build needs the REAL resolved value, and the only place that
/// value is knowable at runtime is the keychain itself.
///
/// Ported from memos-ng-ios's `KeychainAccessGroup.probe()` (same mechanism, this app's single
/// namespace — no multi-namespace precedence walk needed here, only the resolution itself).
enum KeychainAccessGroup {
  /// A service nothing else uses, so a probe item can never collide with a real credential.
  private static let probeService = "live.discomarder.imgmanager.access-group-probe"

  /// Adds one throwaway item naming NO access group (which lands in this build's DEFAULT
  /// group — the first entry of its effective `keychain-access-groups` list, i.e. the one
  /// pinned entry, once code signing has resolved it), reads that group back, and deletes the
  /// item again BY that group. This is the only keychain call in the app that names no access
  /// group explicitly — every read, write and delete elsewhere names one, which is only
  /// possible because this probe found it first.
  ///
  /// Resolved once per process (`static let`) — the resolution is a property of this BUILD's
  /// code signature, not of the moment, so nothing here needs to change between calls.
  static let resolved: String? = {
    let account = UUID().uuidString
    let insert: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: probeService,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
      kSecReturnAttributes as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemAdd(insert as CFDictionary, &item)
    guard status == errSecSuccess,
      let attributes = item as? [String: Any],
      let group = attributes[kSecAttrAccessGroup as String] as? String,
      !group.isEmpty
    else { return nil }
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: probeService,
        kSecAttrAccount as String: account,
        kSecAttrAccessGroup as String: group,
        kSecAttrSynchronizable as String: false,
      ] as CFDictionary)
    return group
  }()
}
