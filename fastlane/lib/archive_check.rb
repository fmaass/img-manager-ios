# frozen_string_literal: true

# P0b fold item 5: the archive/pre-upload check, read from the BUILT archive, never from
# project.yml. A green `xcodegen generate` only proves the SPEC was well-formed -- it proves
# nothing about what Xcode actually emitted, and project.yml is not what App Store Connect
# receives. So every fact this module verdicts on is a value the Fastfile side reads back out of
# the .xcarchive itself (Info.plist, codesign, the embedded profile, dwarfdump) -- the same
# split as AscReadback: Spaceship/shell calls stay in the thin Fastfile adapter, the verdict is
# pure and takes only primitive facts, so every branch here is reachable in a test without a Mac.
module ArchiveCheck
  REQUIRED_ORIENTATIONS = %w[
    UIInterfaceOrientationPortrait
    UIInterfaceOrientationPortraitUpsideDown
    UIInterfaceOrientationLandscapeLeft
    UIInterfaceOrientationLandscapeRight
  ].freeze

  FIRST_PROOF_VERSION = "0.1.0"
  FIRST_PROOF_BUILD = 1

  # WP12 (IMGMGR-199). The archive stopped being single-target when the readiness widget shipped:
  # what App Store Connect receives is now an app WITH an embedded .appex, and every fact this
  # module already checks on the app is independently true-or-false for that extension. An
  # extension signed by the wrong identity, carrying a profile for another app id, missing the
  # shared Keychain group, or stamped with a version other than its container's is rejected at
  # upload (or, worse, uploads and cannot read the credential on device) -- and none of the
  # existing app-level checks can see any of it: `codesign --verify --deep` walks nested code but
  # says nothing about WHICH profile or entitlements the nested code carries.
  WIDGET_EXTENSION_POINT = "com.apple.widgetkit-extension"
  # The credential namespace the app and the extension must BOTH be entitled to -- the whole
  # reason the extension can render anything at all (no App Group in v1; the Keychain group is
  # the only shared surface).
  KEYCHAIN_GROUP_SUFFIX = "live.discomarder.imgmanager.credentials"

  Result = Struct.new(:ok, :name, :message) do
    def ok?
      ok
    end
  end

  # facts is one flat hash of values already read off the built archive -- see the keyword list
  # below. previous_build is nil for the very first distribution proof, else the integer build
  # number of the last build this pipeline shipped (read from the dSYM store / provenance record,
  # never from project.yml, which cannot know what was actually uploaded).
  #
  # Returns an Array of Result, one per check, in a fixed order so a failing run always names
  # every failure rather than stopping at the first one -- a signing problem and a stale build
  # number found on the SAME archive should not take two round trips to discover.
  def self.verdict(
    bundle_id:, expected_bundle_id:,
    version:, build_number:, previous_build:,
    encryption_flag:,
    orientations:,
    icon_name:, assets_car_present:,
    signing_authority:, codesign_verify_ok:,
    profile_app_id:, profile_team_ids:, expected_team_id:,
    get_task_allow:,
    binary_uuids:, dsym_uuids:,
    keychain_groups:,
    expected_extension_bundle_id:, extension:
  )
    [
      check_bundle_id(bundle_id, expected_bundle_id),
      check_version_build(version, build_number, previous_build),
      check_encryption_flag(encryption_flag),
      check_orientations(orientations),
      check_icon(icon_name, assets_car_present),
      check_signature(signing_authority, codesign_verify_ok),
      check_profile(profile_app_id, profile_team_ids, expected_bundle_id, expected_team_id),
      check_get_task_allow(get_task_allow),
      check_dsym_match(binary_uuids, dsym_uuids),
    ] + extension_verdict(
      facts: extension || {},
      expected_bundle_id: expected_extension_bundle_id,
      expected_team_id: expected_team_id,
      app_version: version, app_build: build_number, app_keychain_groups: keychain_groups,
    )
  end

  # The nine extension checks, in the same fixed order and with the same never-stop-at-the-first
  # discipline as the app's own: an archive with three things wrong in its .appex should name all
  # three, not cost three upload attempts. `facts` is the flat hash the Fastfile read off the
  # embedded bundle; an empty one (the extension is missing entirely) fails every check rather
  # than skipping them, because "not there" is the most serious version of each.
  def self.extension_verdict(
    facts:, expected_bundle_id:, expected_team_id:, app_version:, app_build:, app_keychain_groups:
  )
    [
      check_extension_present(facts[:present], expected_bundle_id),
      check_extension_bundle_id(facts[:bundle_id], expected_bundle_id),
      check_extension_point(facts[:extension_point]),
      check_extension_version(facts[:version], facts[:build_number], app_version, app_build),
      check_extension_signature(facts[:signing_authority], facts[:codesign_verify_ok]),
      check_extension_profile(
        facts[:profile_app_id], facts[:profile_team_ids], expected_bundle_id, expected_team_id
      ),
      check_extension_keychain_group(
        facts[:entitlement_keychain_groups], facts[:profile_keychain_groups], app_keychain_groups
      ),
      check_extension_get_task_allow(facts[:get_task_allow]),
      check_extension_dsym_match(facts[:binary_uuids], facts[:dsym_uuids]),
    ]
  end

  def self.pass?(results)
    results.all?(&:ok?)
  end

  def self.failures(results)
    results.reject(&:ok?)
  end

  def self.check_bundle_id(actual, expected)
    if actual == expected
      Result.new(true, "bundle_id", "bundle id is #{expected}")
    else
      Result.new(false, "bundle_id", "bundle id is #{actual.inspect}, expected #{expected.inspect}")
    end
  end
  private_class_method :check_bundle_id

  # The proof upload is pinned to exactly 0.1.0 (1) -- a first proof at any other number means
  # either project.yml drifted or a previous attempt already spent a number silently. Every
  # later upload only has to move strictly past whatever shipped last; the archive is free to
  # bump the marketing version too, but the build number is what App Store Connect keys on and
  # a repeat is refused server-side, so this check exists to catch it before the upload rather
  # than after.
  def self.check_version_build(version, build_number, previous_build)
    build_i = Integer(build_number.to_s, exception: false)
    if build_i.nil?
      return Result.new(false, "version_build", "build number #{build_number.inspect} is not an integer")
    end

    if previous_build.nil?
      if version == FIRST_PROOF_VERSION && build_i == FIRST_PROOF_BUILD
        Result.new(true, "version_build", "first proof is #{version} (#{build_i})")
      else
        Result.new(false, "version_build",
                   "first proof is #{version} (#{build_i}), expected #{FIRST_PROOF_VERSION} (#{FIRST_PROOF_BUILD})")
      end
    elsif build_i > previous_build
      Result.new(true, "version_build", "build #{build_i} is strictly greater than the previous #{previous_build}")
    else
      Result.new(false, "version_build",
                 "build #{build_i} does not exceed the previous shipped build #{previous_build}")
    end
  end
  private_class_method :check_version_build

  # Apple defines this key as a Boolean; a string "NO" or "false" satisfies nothing at upload
  # time and would only be caught by App Store Connect asking the export-compliance question
  # again. `==` is sufficient in Ruby (unlike Python's 0/False aliasing) -- an actual JSON string
  # or nil never equals the literal `false`.
  def self.check_encryption_flag(flag)
    if flag == false
      Result.new(true, "encryption_flag", "ITSAppUsesNonExemptEncryption is the Boolean false")
    else
      Result.new(false, "encryption_flag",
                 "ITSAppUsesNonExemptEncryption is #{flag.inspect}, expected the Boolean false")
    end
  end
  private_class_method :check_encryption_flag

  def self.check_orientations(actual)
    missing = REQUIRED_ORIENTATIONS - Array(actual)
    if missing.empty?
      Result.new(true, "orientations", "all four orientations declared")
    else
      Result.new(false, "orientations", "missing orientation(s): #{missing.join(', ')}")
    end
  end
  private_class_method :check_orientations

  def self.check_icon(icon_name, assets_car_present)
    if icon_name.nil? || icon_name.to_s.strip.empty?
      Result.new(false, "icon", "CFBundleIconName is absent or empty")
    elsif !assets_car_present
      Result.new(false, "icon", "Assets.car is missing from the bundle -- no compiled asset catalog shipped")
    else
      Result.new(true, "icon", "icon asset #{icon_name.inspect} present with a compiled Assets.car")
    end
  end
  private_class_method :check_icon

  def self.check_signature(authority, verify_ok)
    unless verify_ok
      return Result.new(false, "signature", "codesign --verify failed against the built app")
    end

    if authority.to_s.start_with?("Apple Distribution")
      Result.new(true, "signature", "signed by #{authority}")
    else
      Result.new(false, "signature", "signing authority is #{authority.inspect}, expected \"Apple Distribution: ...\"")
    end
  end
  private_class_method :check_signature

  # profile_app_id is the embedded profile's `application-identifier` entitlement, which Apple
  # writes as "<TEAMID>.<bundle id>" -- so this is the one check that catches a profile minted
  # for the WRONG app id or the wrong team ever getting embedded, which a bare "codesign verified
  # ok" cannot: a profile can be internally consistent and still be the wrong profile.
  def self.check_profile(profile_app_id, profile_team_ids, expected_bundle_id, expected_team_id)
    expected_app_id = "#{expected_team_id}.#{expected_bundle_id}"
    unless profile_app_id == expected_app_id
      return Result.new(false, "profile",
                        "embedded profile application-identifier is #{profile_app_id.inspect}, expected #{expected_app_id.inspect}")
    end

    unless Array(profile_team_ids).include?(expected_team_id)
      return Result.new(false, "profile",
                        "embedded profile team id(s) #{Array(profile_team_ids).inspect} do not include #{expected_team_id.inspect}")
    end

    Result.new(true, "profile", "embedded profile matches #{expected_app_id} / team #{expected_team_id}")
  end
  private_class_method :check_profile

  # A distribution build with get-task-allow true is debuggable -- Apple's own definition of a
  # development-signed binary -- and TestFlight/App Store both refuse an upload carrying it, so
  # this check exists to fail fast on the archive rather than wait for ASC's rejection e-mail.
  #
  # nil is NOT treated as false. A failed entitlement extraction (a bad codesign invocation, a
  # missing entitlements plist, plutil choking on it) also reads as nil, and letting that pass
  # silently as "false" would make a broken read-back indistinguishable from a genuinely correct
  # distribution entitlement -- exactly the class of bug this whole check exists to catch.
  def self.check_get_task_allow(value)
    if value.nil?
      Result.new(false, "get_task_allow",
                "get-task-allow could not be read (nil) -- a failed or missing extraction is " \
                "never treated as an implicit false")
    elsif value == false
      Result.new(true, "get_task_allow", "get-task-allow is false")
    else
      Result.new(false, "get_task_allow", "get-task-allow is #{value.inspect}, expected false")
    end
  end
  private_class_method :check_get_task_allow

  def self.check_dsym_match(binary_uuids, dsym_uuids)
    matched = Array(binary_uuids) & Array(dsym_uuids)
    if matched.empty?
      Result.new(false, "dsym_match",
                "no dSYM UUID matches the binary (binary: #{Array(binary_uuids).inspect}, " \
                "dSYMs: #{Array(dsym_uuids).inspect}) -- this build could ship unsymbolicated")
    else
      Result.new(true, "dsym_match", "#{matched.size} matching dSYM UUID(s): #{matched.join(', ')}")
    end
  end
  private_class_method :check_dsym_match

  def self.check_extension_present(present, expected_bundle_id)
    if present == true
      Result.new(true, "extension_present", "#{expected_bundle_id} is embedded in the app bundle")
    else
      Result.new(false, "extension_present",
                 "no embedded .appex for #{expected_bundle_id} was found in the archive -- " \
                 "the widget would simply not exist on the device")
    end
  end
  private_class_method :check_extension_present

  def self.check_extension_bundle_id(actual, expected)
    if actual == expected
      Result.new(true, "extension_bundle_id", "extension bundle id is #{expected}")
    else
      Result.new(false, "extension_bundle_id",
                 "extension bundle id is #{actual.inspect}, expected #{expected.inspect}")
    end
  end
  private_class_method :check_extension_bundle_id

  # A widget that declares any other extension point is not a widget: the system loads it for a
  # different host and it never appears in the widget gallery.
  def self.check_extension_point(actual)
    if actual == WIDGET_EXTENSION_POINT
      Result.new(true, "extension_point", "NSExtensionPointIdentifier is #{WIDGET_EXTENSION_POINT}")
    else
      Result.new(false, "extension_point",
                 "NSExtensionPointIdentifier is #{actual.inspect}, expected " \
                 "#{WIDGET_EXTENSION_POINT.inspect}")
    end
  end
  private_class_method :check_extension_point

  # App Store validation refuses an archive whose embedded extension carries a version or build
  # other than its container app's -- a rejection that arrives AFTER the upload, and after a
  # build number has been spent.
  def self.check_extension_version(version, build_number, app_version, app_build)
    mismatches = []
    mismatches << "CFBundleShortVersionString #{version.inspect} != app #{app_version.inspect}" \
      unless version.to_s == app_version.to_s
    mismatches << "CFBundleVersion #{build_number.inspect} != app #{app_build.inspect}" \
      unless build_number.to_s == app_build.to_s

    if mismatches.empty?
      Result.new(true, "extension_version",
                 "extension is #{version} (#{build_number}), identical to the app")
    else
      Result.new(false, "extension_version", mismatches.join("; "))
    end
  end
  private_class_method :check_extension_version

  # `codesign --verify --deep` on the app walks nested code, but this is the extension's OWN
  # authority: a nested bundle can be validly signed by the wrong identity and still pass a deep
  # verification of the container.
  def self.check_extension_signature(authority, verify_ok)
    unless verify_ok
      return Result.new(false, "extension_signature",
                        "codesign --verify failed against the embedded extension")
    end

    if authority.to_s.start_with?("Apple Distribution")
      Result.new(true, "extension_signature", "extension signed by #{authority}")
    else
      Result.new(false, "extension_signature",
                 "extension signing authority is #{authority.inspect}, expected " \
                 "\"Apple Distribution: ...\"")
    end
  end
  private_class_method :check_extension_signature

  def self.check_extension_profile(profile_app_id, profile_team_ids, expected_bundle_id, expected_team_id)
    expected_app_id = "#{expected_team_id}.#{expected_bundle_id}"
    unless profile_app_id == expected_app_id
      return Result.new(false, "extension_profile",
                        "extension profile application-identifier is #{profile_app_id.inspect}, " \
                        "expected #{expected_app_id.inspect}")
    end

    unless Array(profile_team_ids).include?(expected_team_id)
      return Result.new(false, "extension_profile",
                        "extension profile team id(s) #{Array(profile_team_ids).inspect} do not " \
                        "include #{expected_team_id.inspect}")
    end

    Result.new(true, "extension_profile",
               "extension profile matches #{expected_app_id} / team #{expected_team_id}")
  end
  private_class_method :check_extension_profile

  # The one entitlement the widget exists on: without the app's Keychain access group in BOTH its
  # signed entitlements AND the profile that authorises them, the extension installs, launches,
  # and renders "Open the app to sign in" forever on a signed-in device -- a failure that is
  # invisible to every other check here and to any smoke test run while signed out.
  def self.check_extension_keychain_group(entitlement_groups, profile_groups, app_groups)
    shared = Array(entitlement_groups) & Array(app_groups)
    credential_groups = shared.select { |group| group.to_s.end_with?(KEYCHAIN_GROUP_SUFFIX) }
    if credential_groups.empty?
      return Result.new(false, "extension_keychain_group",
                        "extension entitlements #{Array(entitlement_groups).inspect} share no " \
                        "#{KEYCHAIN_GROUP_SUFFIX} group with the app's " \
                        "#{Array(app_groups).inspect}")
    end

    unauthorised = credential_groups - Array(profile_groups)
    unless unauthorised.empty?
      return Result.new(false, "extension_keychain_group",
                        "extension profile does not carry #{unauthorised.inspect} -- signed " \
                        "entitlements the profile does not authorise are rejected at install")
    end

    Result.new(true, "extension_keychain_group",
               "extension shares #{credential_groups.join(', ')} with the app, authorised by its " \
               "own profile")
  end
  private_class_method :check_extension_keychain_group

  # Same rule and same nil handling as the app's: a failed extraction is never an implicit false.
  def self.check_extension_get_task_allow(value)
    if value.nil?
      Result.new(false, "extension_get_task_allow",
                 "extension get-task-allow could not be read (nil) -- a failed or missing " \
                 "extraction is never treated as an implicit false")
    elsif value == false
      Result.new(true, "extension_get_task_allow", "extension get-task-allow is false")
    else
      Result.new(false, "extension_get_task_allow",
                 "extension get-task-allow is #{value.inspect}, expected false")
    end
  end
  private_class_method :check_extension_get_task_allow

  # The extension has its OWN executable and therefore its own dSYM: an app-level match proves
  # nothing about whether a widget crash would symbolicate.
  def self.check_extension_dsym_match(binary_uuids, dsym_uuids)
    matched = Array(binary_uuids) & Array(dsym_uuids)
    if matched.empty?
      Result.new(false, "extension_dsym_match",
                 "no dSYM UUID matches the extension binary (binary: " \
                 "#{Array(binary_uuids).inspect}, dSYMs: #{Array(dsym_uuids).inspect})")
    else
      Result.new(true, "extension_dsym_match",
                 "#{matched.size} matching extension dSYM UUID(s): #{matched.join(', ')}")
    end
  end
  private_class_method :check_extension_dsym_match
end
