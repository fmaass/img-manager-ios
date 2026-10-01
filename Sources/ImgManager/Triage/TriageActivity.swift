import Foundation

/// WP31 P2 (IMGMGR-461), plan decisions 4 and 6: the Handoff payload of a Triage pass — the shoot
/// and the continuation position, carried by an `NSUserActivity` of type
/// `live.discomarder.imgmanager.triage` (declared under `NSUserActivityTypes` in `project.yml`).
///
/// Native-to-native only: no `webpageURL`, no associated domains (Adjudication A). The receiver
/// resolves the photograph by `imageID`, never by `index` — the receiver's ordering may differ,
/// so the index is informational. A payload of another version, or with a key missing or of the
/// wrong type, decodes to nil and is ignored: no navigation on a payload this build cannot read.
struct TriageActivity: Equatable, Sendable {
  static let activityType = "live.discomarder.imgmanager.triage"
  static let version = 1

  /// The `userInfo` keys, versioned by `v`.
  enum Key {
    static let version = "v"
    static let folderID = "folderID"
    static let tier = "tier"
    static let imageID = "imageID"
    static let index = "index"
    static let completed = "completed"
  }

  let folderID: Int
  /// The grid's source tier; nil when the sender's grid named none (the key is then absent).
  let tier: GridSourceTier?
  /// The continuation position (decision 4): the photograph last displayed — on a completed pass
  /// the final one, never "one past it".
  let imageID: Int
  /// The position's 1-based index in the sender's pool; nil when it was not in it.
  let index: Int?
  let completed: Bool

  init(folderID: Int, tier: GridSourceTier?, imageID: Int, index: Int?, completed: Bool) {
    self.folderID = folderID
    self.tier = tier
    self.imageID = imageID
    self.index = index
    self.completed = completed
  }

  /// Property-list values only, as `NSUserActivity.userInfo` requires: an optional field that is
  /// nil is left out, never encoded as a placeholder.
  var userInfo: [AnyHashable: Any] {
    var info: [AnyHashable: Any] = [
      Key.version: Self.version,
      Key.folderID: folderID,
      Key.imageID: imageID,
      Key.completed: completed,
    ]
    if let tier { info[Key.tier] = tier.rawValue }
    if let index { info[Key.index] = index }
    return info
  }

  /// Decodes a received payload; nil for an unknown version, a missing required key, or any key
  /// of the wrong type or out of range.
  ///
  /// Review round 1 (B2): numbers and Booleans are told apart by IDENTITY, not by what `as?`
  /// will bridge. A property list or JSON payload arrives as `NSNumber`s, and `as? Int` accepts a
  /// Boolean `NSNumber` (true → 1) while `as? Bool` accepts the numbers 0 and 1 — so a `v: true`
  /// or a `completed: 1` would decode. An integer key refuses a Boolean; `completed` refuses
  /// anything that is not one.
  init?(userInfo: [AnyHashable: Any]?) {
    guard let userInfo,
      let version = Self.integer(userInfo[Key.version]), version == Self.version,
      let folderID = Self.integer(userInfo[Key.folderID]), folderID > 0,
      let imageID = Self.integer(userInfo[Key.imageID]), imageID > 0,
      let completed = Self.boolean(userInfo[Key.completed])
    else { return nil }

    var tier: GridSourceTier?
    if let raw = userInfo[Key.tier] {
      // An unknown tier is refused rather than dropped: opening the shoot under no tier would
      // be a different scope from the one the sender was in.
      guard let name = raw as? String, let known = GridSourceTier(rawValue: name) else {
        return nil
      }
      tier = known
    }
    var index: Int?
    if let raw = userInfo[Key.index] {
      guard let value = Self.integer(raw), value > 0 else { return nil }
      index = value
    }
    self.init(
      folderID: folderID, tier: tier, imageID: imageID, index: index, completed: completed)
  }

  /// Whether `value` is a Boolean by identity: a Swift `Bool` bridges to the `CFBoolean`
  /// singletons, and so do JSON `true`/`false` and a property list's `<true/>`; an integer
  /// `NSNumber` never does.
  private static func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// An integer that is not a Boolean in disguise; nil otherwise (a fraction included).
  private static func integer(_ value: Any?) -> Int? {
    guard let value, !isBoolean(value) else { return nil }
    return value as? Int
  }

  /// A Boolean by identity — never the numbers 0 and 1.
  private static func boolean(_ value: Any?) -> Bool? {
    guard let value, isBoolean(value), let number = value as? NSNumber else { return nil }
    return number.boolValue
  }

  /// Makes `activity` carry this payload, eligible for Handoff. The activity type is the one the
  /// `.userActivity` modifier was declared with.
  func configure(_ activity: NSUserActivity) {
    activity.isEligibleForHandoff = true
    activity.userInfo = userInfo
  }

  /// The payload a Triage pass advertises: the shoot the grid shows and the cursor. Nil while
  /// there is no shoot or no cursor — nothing to continue.
  static func advertised(
    folderID: Int?, tier: GridSourceTier?, imageID: Int?, pool: [Int], completed: Bool
  ) -> TriageActivity? {
    guard let folderID, let imageID else { return nil }
    let index = pool.firstIndex(of: imageID).map { $0 + 1 }
    return TriageActivity(
      folderID: folderID, tier: tier, imageID: imageID, index: index, completed: completed)
  }
}

#if DEBUG
  /// Review round 1: the fixture's half of the payload — the launch argument's JSON entry and
  /// the probe's wording — compiled into Debug builds only, like every caller of it.
  extension TriageActivity {
    /// The DEBUG launch argument's form of a payload: a JSON object with the `userInfo` keys.
    /// Not an object (or not JSON at all) → nil, which the decoder then refuses.
    static func userInfo(json: String) -> [AnyHashable: Any]? {
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any]
      else { return nil }
      var info: [AnyHashable: Any] = [:]
      for (key, value) in dictionary { info[key] = value }
      return info
    }

    /// EVIDENCE for the UI tests (`debugProbe.activity`): what an activity was configured with —
    /// its type, its Handoff eligibility, and its `userInfo` as a receiver would decode it. Read
    /// off the `NSUserActivity` itself, never re-encoded from the session.
    static func probeDescription(
      source: String, type: String, eligible: Bool, userInfo: [AnyHashable: Any]?
    ) -> String {
      let head = "source=\(source);type=\(type);eligible=\(eligible)"
      guard let decoded = TriageActivity(userInfo: userInfo) else {
        return "\(head);payload=undecodable"
      }
      let index = decoded.index.map { String($0) } ?? ""
      return "\(head);v=\(version);folderID=\(decoded.folderID);"
        + "tier=\(decoded.tier?.rawValue ?? "");imageID=\(decoded.imageID);index=\(index);"
        + "completed=\(decoded.completed)"
    }
  }
#endif

#if DEBUG
  /// Records what a `.userActivity` closure configured into `DebugProbe.activity` — called from
  /// INSIDE that closure (plan P2), fixture launches only. Assigned only on a change: the probe
  /// is `@Observable`, and an unconditional write would re-render the surface that reads it.
  @MainActor
  enum TriageActivityProbe {
    static func record(_ activity: NSUserActivity, source: String) {
      guard DebugStubLaunch.isActive else { return }
      let described = TriageActivity.probeDescription(
        source: source, type: activity.activityType, eligible: activity.isEligibleForHandoff,
        userInfo: activity.userInfo)
      if DebugProbe.shared.activity != described {
        DebugProbe.shared.activity = described
      }
    }
  }
#else
  @MainActor
  enum TriageActivityProbe {
    static func record(_ activity: NSUserActivity, source: String) {}
  }
#endif
