# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/archive_check_test.rb
require "minitest/autorun"
require "archive_check"

class ArchiveCheckTest < Minitest::Test
  BUNDLE_ID = "live.discomarder.imgmanager"
  TEAM_ID = "Y2JQ4VAF85"

  def good_facts(overrides = {})
    {
      bundle_id: BUNDLE_ID, expected_bundle_id: BUNDLE_ID,
      version: "0.1.0", build_number: "1", previous_build: nil,
      encryption_flag: false,
      orientations: ArchiveCheck::REQUIRED_ORIENTATIONS,
      icon_name: "AppIcon", assets_car_present: true,
      signing_authority: "Apple Distribution: Fabian Maass (#{TEAM_ID})", codesign_verify_ok: true,
      profile_app_id: "#{TEAM_ID}.#{BUNDLE_ID}", profile_team_ids: [TEAM_ID], expected_team_id: TEAM_ID,
      get_task_allow: false,
      binary_uuids: ["ABCD-1234"], dsym_uuids: ["ABCD-1234"],
    }.merge(overrides)
  end

  def verdict(overrides = {})
    ArchiveCheck.verdict(**good_facts(overrides))
  end

  def test_a_fully_correct_archive_passes_every_check
    results = verdict
    assert(ArchiveCheck.pass?(results), ArchiveCheck.failures(results).map(&:message).join("; "))
    assert_equal(9, results.size)
  end

  def test_wrong_bundle_id_fails_only_that_check
    results = verdict(bundle_id: "live.discomarder.somethingelse")
    refute(ArchiveCheck.pass?(results))
    failed_names = ArchiveCheck.failures(results).map(&:name)
    assert_equal(["bundle_id"], failed_names)
  end

  def test_first_proof_must_be_exactly_0_1_0_build_1
    results = verdict(version: "0.1.0", build_number: "2", previous_build: nil)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["version_build"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_first_proof_at_the_pinned_version_passes
    results = verdict(version: "0.1.0", build_number: "1", previous_build: nil)
    assert(ArchiveCheck.pass?(results))
  end

  def test_a_later_build_must_strictly_exceed_the_previous
    results = verdict(version: "0.1.1", build_number: "4", previous_build: 4)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["version_build"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_a_later_build_below_the_previous_also_fails
    results = verdict(version: "0.1.1", build_number: "3", previous_build: 4)
    refute(ArchiveCheck.pass?(results))
  end

  def test_a_later_build_strictly_above_the_previous_passes
    results = verdict(version: "0.1.1", build_number: "5", previous_build: 4)
    assert(ArchiveCheck.pass?(results))
  end

  def test_a_non_numeric_build_fails
    results = verdict(build_number: "abc", previous_build: nil)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["version_build"], ArchiveCheck.failures(results).map(&:name))
  end

  # MEMNG-style blocker this exists for: a string "NO"/"false" must not pass where Apple expects
  # a real Boolean.
  def test_encryption_flag_as_a_string_fails
    ["NO", "false", "0"].each do |bad|
      results = verdict(encryption_flag: bad)
      refute(ArchiveCheck.pass?(results), "#{bad.inspect} must not satisfy the Boolean check")
      assert_equal(["encryption_flag"], ArchiveCheck.failures(results).map(&:name))
    end
  end

  def test_encryption_flag_true_fails
    results = verdict(encryption_flag: true)
    refute(ArchiveCheck.pass?(results))
  end

  def test_encryption_flag_missing_fails
    results = verdict(encryption_flag: nil)
    refute(ArchiveCheck.pass?(results))
  end

  def test_missing_one_orientation_fails_and_names_it
    results = verdict(orientations: ArchiveCheck::REQUIRED_ORIENTATIONS - ["UIInterfaceOrientationLandscapeRight"])
    refute(ArchiveCheck.pass?(results))
    failure = ArchiveCheck.failures(results).find { |r| r.name == "orientations" }
    assert_match(/LandscapeRight/, failure.message)
  end

  def test_extra_orientations_beyond_the_required_four_still_pass
    results = verdict(orientations: ArchiveCheck::REQUIRED_ORIENTATIONS + ["UIInterfaceOrientationSomethingNew"])
    assert(ArchiveCheck.pass?(results))
  end

  def test_missing_icon_name_fails
    results = verdict(icon_name: nil)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["icon"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_icon_name_present_but_no_compiled_catalog_fails
    results = verdict(icon_name: "AppIcon", assets_car_present: false)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["icon"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_codesign_verify_failure_fails_regardless_of_authority_string
    results = verdict(codesign_verify_ok: false)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["signature"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_non_distribution_authority_fails
    results = verdict(signing_authority: "Apple Development: Fabian Maass (#{TEAM_ID})")
    refute(ArchiveCheck.pass?(results))
    assert_equal(["signature"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_profile_for_the_wrong_app_id_fails
    results = verdict(profile_app_id: "#{TEAM_ID}.live.discomarder.somethingelse")
    refute(ArchiveCheck.pass?(results))
    assert_equal(["profile"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_profile_for_the_wrong_team_fails
    results = verdict(profile_team_ids: ["OTHERTEAMID"])
    refute(ArchiveCheck.pass?(results))
    assert_equal(["profile"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_get_task_allow_true_fails
    results = verdict(get_task_allow: true)
    refute(ArchiveCheck.pass?(results))
    assert_equal(["get_task_allow"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_get_task_allow_absent_is_treated_as_false
    results = verdict(get_task_allow: nil)
    assert(ArchiveCheck.pass?(results))
  end

  def test_no_matching_dsym_fails
    results = verdict(binary_uuids: ["AAAA"], dsym_uuids: ["BBBB"])
    refute(ArchiveCheck.pass?(results))
    assert_equal(["dsym_match"], ArchiveCheck.failures(results).map(&:name))
  end

  def test_one_matching_dsym_among_several_passes
    results = verdict(binary_uuids: ["AAAA", "BBBB"], dsym_uuids: ["CCCC", "BBBB"])
    assert(ArchiveCheck.pass?(results))
  end

  def test_multiple_simultaneous_failures_are_all_reported_not_just_the_first
    results = verdict(bundle_id: "wrong", get_task_allow: true, encryption_flag: "NO")
    failed_names = ArchiveCheck.failures(results).map(&:name).sort
    assert_equal(%w[bundle_id encryption_flag get_task_allow], failed_names)
  end
end
