# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/release_notes_test.rb
#
# IMGMGR-587: the beta lane's "What to Test" text. The loader's refusals (missing, empty,
# duplicated, oversized), the tracked notes file against project.yml's own version and build, and
# the beta lane's WIRING read from the Fastfile itself: the section is loaded before the dSYM copy
# and the upload, and the upload carries it as `changelog:`. Needs no Mac and no fastlane.
require "minitest/autorun"
require "release_notes"

class ReleaseNotesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FASTFILE = File.join(ROOT, "fastlane/Fastfile")
  TRACKED = File.join(ROOT, "Sources/ImgManager/Resources/ReleaseNotes.md")

  NOTES = <<~MARKDOWN
    # Release notes

    Anything above the first release heading is ignored.

    ## 0.15.2 (24)

    - Newest entry.

    ### A subheading stays inside its section

    - Still 24.

    ## 0.15.1 (23)

    - Square layout.
    - Scene push.

    ## 0.15.0 (22)

    - Oldest entry.
  MARKDOWN

  def section(text, version: "0.15.1", build: "23")
    ReleaseNotes.section(text, version: version, build: build)
  end

  def assert_refused(result, pattern)
    status, message = result
    assert_equal(:refuse, status, "expected a refusal, got #{result.inspect}")
    assert_match(pattern, message)
  end

  def test_the_matching_section_is_returned_without_its_heading_or_neighbours
    assert_equal([:ok, "- Square layout.\n- Scene push."], section(NOTES))
  end

  def test_the_last_section_runs_to_the_end_of_the_file
    assert_equal([:ok, "- Oldest entry."], section(NOTES, version: "0.15.0", build: "22"))
  end

  def test_a_deeper_heading_stays_inside_its_section
    status, notes = section(NOTES, version: "0.15.2", build: "24")
    assert_equal(:ok, status)
    assert_includes(notes, "### A subheading stays inside its section")
    assert_includes(notes, "- Still 24.")
  end

  def test_a_missing_section_is_refused_and_names_what_was_looked_for
    assert_refused(section(NOTES, version: "0.15.3", build: "25"), /no section "## 0\.15\.3 \(25\)"/)
  end

  def test_a_neighbouring_build_is_not_taken_for_this_one
    assert_refused(section(NOTES, version: "0.15.1", build: "2"), /no section/)
    assert_refused(section(NOTES, version: "0.15", build: "23"), /no section/)
  end

  def test_a_dot_in_the_version_is_literal
    assert_refused(section("## 0x15x1 (23)\n- a\n"), /no section/)
  end

  def test_an_empty_section_is_refused
    assert_refused(section("## 0.15.1 (23)\n\n## 0.15.0 (22)\n- a\n"), /is empty/)
  end

  def test_a_whitespace_only_last_section_is_refused
    assert_refused(section("## 0.15.1 (23)\n   \n\t\n"), /is empty/)
  end

  def test_an_empty_file_is_refused
    assert_refused(section(""), /no section/)
  end

  def test_a_duplicated_section_is_refused_as_ambiguous
    assert_refused(section("## 0.15.1 (23)\n- a\n## 0.15.1 (23)\n- b\n"),
                   /2 sections "## 0\.15\.1 \(23\)"/)
  end

  def test_a_heading_inside_a_code_fence_neither_opens_nor_ends_a_section
    text = "## 0.15.1 (23)\n- a\n````\n## 0.15.0 (22)\n```\n~~~~\n````\n- b\n"
    status, notes = section(text)
    assert_equal(:ok, status)
    assert(notes.end_with?("- b"), notes)
    assert_refused(section("```\n## 0.15.1 (23)\n```\n"), /no section/)
  end

  def test_trailing_whitespace_and_crlf_on_the_heading_are_tolerated
    assert_equal([:ok, "- a"], section("## 0.15.1 (23)  \r\n- a\r\n"))
  end

  def test_a_blank_version_or_build_is_refused_before_the_file_is_searched
    assert_refused(section(NOTES, version: "", build: "23"), /version and build/)
    assert_refused(section(NOTES, version: "0.15.1", build: "  "), /version and build/)
    assert_refused(section(NOTES, version: nil, build: "23"), /version and build/)
  end

  def test_notes_at_the_testflight_limit_are_kept_and_one_past_it_is_refused
    at_limit = "x" * ReleaseNotes::MAX_CHARACTERS
    assert_equal([:ok, at_limit], section("## 0.15.1 (23)\n#{at_limit}\n"))
    assert_refused(section("## 0.15.1 (23)\n#{at_limit}x\n"), /4001 characters/)
  end

  def test_an_absent_file_is_refused_and_named
    missing = File.join(__dir__, "no-such-notes-file.md")
    assert_refused(ReleaseNotes.load(missing, version: "0.15.1", build: "23"),
                   /no-such-notes-file\.md/)
  end

  # The pair project.yml declares -- the first key lines, the app target's, as the gate's `notes`
  # leg reads them -- has its section in the tracked file the app bundles.
  def test_the_tracked_file_carries_the_notes_for_project_yml_s_version_and_build
    yml = File.read(File.join(ROOT, "project.yml"))
    version = yml[/^\s*MARKETING_VERSION:\s*"?([^"\s#]+)/, 1]
    build = yml[/^\s*CURRENT_PROJECT_VERSION:\s*"?([^"\s#]+)/, 1]
    refute_nil(version, "project.yml names no MARKETING_VERSION")
    refute_nil(build, "project.yml names no CURRENT_PROJECT_VERSION")
    status, notes = ReleaseNotes.load(TRACKED, version: version, build: build)
    assert_equal(:ok, status, notes)
    refute_empty(notes)
  end

  # --- The beta lane's wiring, read from the Fastfile: a refusal must stop the cut BEFORE the
  # dSYM copy and the upload, and the upload must carry what was loaded.

  def beta_lane
    text = File.read(FASTFILE)
    lane = text[/^  lane :beta do.*?^  end$/m]
    refute_nil(lane, "the Fastfile has no `lane :beta` block")
    lane
  end

  def test_the_fastfile_loads_the_notes_from_the_file_the_app_bundles
    text = File.read(FASTFILE)
    # assert(match?) rather than assert_match: a miss would print the whole Fastfile.
    assert(text.match?(%r{^require File\.expand_path\("lib/release_notes", __dir__\)$}),
           "the Fastfile does not require lib/release_notes")
    assert(text.match?(%r{^NOTES\s*=\s*"\#\{ROOT\}/Sources/ImgManager/Resources/ReleaseNotes\.md"}),
           "the Fastfile's NOTES is not the file the app bundles")
    assert(File.file?(TRACKED), "#{TRACKED} is missing")
    helper = text[/^def testflight_changelog\(version, build_number\)\n.*?^end$/m]
    refute_nil(helper, "the Fastfile has no testflight_changelog(version, build_number)")
    assert_match(/ReleaseNotes\.load\(NOTES, version: version, build: build_number\)/, helper)
    assert_match(/UI\.user_error!\(.*\) unless status == :ok/, helper)
  end

  def test_the_beta_lane_refuses_before_the_dsym_copy_and_the_upload
    lane = beta_lane
    load_at = lane.index(/^\s+changelog = testflight_changelog\(version, build_number\)$/)
    dsyms_at = lane.index(/^\s+preserve_dsyms\(/)
    upload_at = lane.index(/^\s+upload_to_testflight\(/)
    refute_nil(load_at, "the beta lane never loads the build's notes")
    refute_nil(dsyms_at, "the beta lane no longer preserves dSYMs")
    refute_nil(upload_at, "the beta lane no longer uploads")
    assert_operator(load_at, :<, dsyms_at, "the notes are loaded after the dSYM copy")
    assert_operator(load_at, :<, upload_at, "the notes are loaded after the upload")
  end

  def test_the_upload_carries_the_loaded_notes_as_its_changelog
    call = beta_lane[/^\s+upload_to_testflight\(.*?^\s+\)$/m]
    refute_nil(call, "the beta lane has no upload_to_testflight(...) call")
    assert(call.match?(/\bchangelog: changelog\b/), "the upload passes no `changelog: changelog`")
  end
end
