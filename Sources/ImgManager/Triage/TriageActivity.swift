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

  /// Makes `activity` carry this payload, eligible for Handoff. The activity type is the one
  /// `TriageActivityAdvertiser` created it with.
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

/// IMGMGR-501: the ONE Triage activity the app keeps current, whichever surface advertises it.
///
/// Triage and the Pass Summary each hold a `TriageActivityAdvertiser`, and the handover between
/// them has no fixed order: the cover's content can disappear before the sheet's appears, or
/// after it. Both advertisers therefore share this holder. Advertising reuses its one
/// `NSUserActivity` and makes the advertiser that asked its OWNER; only the owner's `end()`
/// resigns it. So in either order exactly one activity stays current, carrying the payload of
/// whoever advertised last, and a late `end()` from the surface that was replaced resigns
/// nothing.
@MainActor
final class TriageActivityCurrency {
  /// The app's holder; a unit test makes its own.
  static let shared = TriageActivityCurrency()

  /// The activity made current, held strongly until its owner ends it.
  private(set) var activity: NSUserActivity?
  /// The advertiser whose payload `activity` carries.
  private(set) weak var owner: TriageActivityAdvertiser?
  /// How many `NSUserActivity` instances were made — read by the tests.
  private(set) var activitiesMade = 0

  init() {}

  /// Makes `payload` current on behalf of `advertiser`, which becomes the owner.
  func makeCurrent(_ payload: TriageActivity, for advertiser: TriageActivityAdvertiser)
    -> NSUserActivity
  {
    let activity: NSUserActivity
    if let existing = self.activity {
      activity = existing
      payload.configure(activity)
      activity.needsSave = true
    } else {
      activity = NSUserActivity(activityType: TriageActivity.activityType)
      payload.configure(activity)
      self.activity = activity
      activitiesMade += 1
    }
    owner = advertiser
    activity.becomeCurrent()
    return activity
  }

  /// Resigns and invalidates the activity — only when `advertiser` still owns it.
  func resign(for advertiser: TriageActivityAdvertiser) {
    guard owner === advertiser, let activity else { return }
    activity.resignCurrent()
    activity.invalidate()
    self.activity = nil
    owner = nil
  }
}

/// Review round 3: the advertising side, owned explicitly. SwiftUI's `.userActivity(_:isActive:_:)`
/// never ran its update closure in the simulator (gate on 1bfc834: the activity probe stayed
/// empty), so a surface that advertises holds one of these instead: it makes a `TriageActivity`
/// current with `becomeCurrent()` through the shared `TriageActivityCurrency` (which keeps a
/// STRONG reference — an activity nobody holds is released and stops being current), and
/// resigns and invalidates it on `end()` while it is still the owner. A new position reuses the
/// same instance.
///
/// `UIWindowScene.userActivity` is deliberately left alone: SwiftUI owns it for the
/// `WindowGroup(for:)` scene and its restoration, and `becomeCurrent()` is what Handoff reads.
@MainActor
final class TriageActivityAdvertiser {
  /// The probe's `source=` — which surface advertises.
  let source: String
  private let currency: TriageActivityCurrency

  convenience init(source: String) {
    self.init(source: source, currency: .shared)
  }

  init(source: String, currency: TriageActivityCurrency) {
    self.source = source
    self.currency = currency
  }

  /// The current activity while THIS advertiser owns it; nil otherwise.
  var activity: NSUserActivity? {
    currency.owner === self ? currency.activity : nil
  }

  var isCurrent: Bool { activity != nil }

  /// Makes `payload` the current activity; nil ends any advertising of this advertiser's.
  func advertise(_ payload: TriageActivity?) {
    guard let payload else {
      end()
      return
    }
    let activity = currency.makeCurrent(payload, for: self)
    // Read back from the instance just made current — never re-encoded from the payload.
    TriageActivityProbe.record(activity, source: source)
  }

  /// The surface went away or the pass ended: no longer offered to other devices — unless
  /// another surface has advertised since, which then keeps its activity current.
  func end() {
    currency.resign(for: self)
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
  /// Records the activity `TriageActivityAdvertiser` just made current into
  /// `DebugProbe.activity`, read off that instance (review round 3), fixture launches only.
  /// Assigned only on a change: the probe is `@Observable`, and an unconditional write would
  /// re-render the surface that reads it.
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
