# TestFlight distribution

Ported from `memos-ng-ios/docs/TESTFLIGHT.md` (same headless fastlane pipeline, adapted for
one app target and hardened per the WP8 P0b premise-gate fold). Internal TestFlight distribution
only — nothing here submits to the App Store, and no step starts a review.

## What App Store Connect side is assumed done

- An app record for `live.discomarder.imgmanager` (team `Y2JQ4VAF85`).
- An internal tester group named `household`, created with **automatic distribution unticked** —
  the App Store Connect create dialog pre-checks it and warns the choice is **permanent**; once a
  group exists with it on, Apple's API refuses to turn it off, and a group that started on cannot
  be recreated with the same members without re-inviting them. With it off, every build is added
  to the group explicitly — that add is what `fastlane beta` verifies in `verify_attach`.
- Internal testing needs **no Beta App Review** — the whole reason distribution stays internal.
  `submit_beta_review: false` is passed explicitly in the `beta` lane regardless (its default is
  `true` and posts an external-testing review submission this app does not satisfy).
- The two household members already invited to the group as internal testers.

## Running a release

**The bump commit adds the build's release notes.** The same commit that sets
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` adds a `## <version> (<build>)`
section at the top of `Sources/ImgManager/Resources/ReleaseNotes.md`: plain one-line bullets for
the person testing — what changed on screen, no ticket keys, no host names. The gate's `notes` leg
refuses a tree whose `project.yml` pair has no section (or two), and `beta` loads that section
as TestFlight's "What to Test" text after the archive and refuses the cut, before the dSYM copy
and the upload, when it is missing, empty or duplicated (`fastlane/lib/release_notes.rb`). The app
shows the same notes under Settings › About › Version.

**Gate the bump sha from a worktree on a local branch.** `MAC_GATE_BRANCH` set in the enqueue's
environment does not reach the queued run, so create the gate worktree with a branch:
a detached HEAD is refused by `bin/mac-gate.sh`; use `git worktree add -b gate/<label> <path> <sha>`.

    ssh <merkur host>
    cd ~/projects/img-manager-ios
    set -a; source ~/.config/<the ci env file>; set +a
    export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export IMGMGR_CERT_STRATEGY=import   # or: create — see "Certificate decision" below
    fastlane beta expected_sha:<the exact commit HEAD must be at>

`archive_ipa` (which `beta` calls first) runs, in this order: canonicalize `signing.local.yml`
to the empty stub (see "The `signing.local.yml` input" below), `bin/generate.sh`, an assertion
that the project's `Package.resolved` is byte-equal to the tracked root file, signing, the
archive itself (`-onlyUsePackageVersionsFromResolvedFile`), and the archive/pre-upload check
below — before any IPA is assembled. `beta` then **preserves dSYMs with a provenance record
beside them BEFORE it uploads**, and finally reads App Store Connect back.

**`expected_sha:` is required, not optional.** The lane refuses a dirty working tree and refuses
to build any commit other than the one named — `verify_attach` proves a build reached the
household, never what source produced it. The SHA, marketing version and build number are
written as `provenance.json` next to that build's dSYMs.

**Read "What to Test" back after the cut.** The `~/build/asc-read` helper on the build host
takes the bundle id, not the numeric App Store Connect id, as `app_id:` (the numeric id fails
with "undefined method downcase for nil"):
`fastlane read_notes app_id:live.discomarder.imgmanager version:<version> build:<build>` must
report one en-US localization carrying the build's section.

## The archive/pre-upload check

Before the IPA is assembled, `fastlane/lib/archive_check.rb` verdicts on facts read off the
**built** `.xcarchive` — never off `project.yml`, which is the intent, not what Xcode emitted:
bundle id; `0.1.0 (1)` for the first proof, a strictly increasing build number after that (the
max of every `provenance.json` under EVERY reachable dSYM store, unioned with App Store
Connect's own build listing — never just the first store that happened to answer, and never
guessed); `ITSAppUsesNonExemptEncryption`
is a real Boolean `false` (a string `"NO"` satisfies nothing at upload time); all four orientations;
the icon asset and its compiled `Assets.car` are present; the code signature is a valid Apple
Distribution signature; the embedded profile's application identifier and team match; `get-task-allow`
is `false`; and at least one `dSYM` UUID matches the built binary. `get-task-allow` is checked as
`false` — and ONLY `false`; a failed or missing extraction (`nil`) fails the check too, never
passes as an implicit false. Every branch is a pure function, unit-tested without a Mac:
`ruby -Ifastlane/lib fastlane/test/archive_check_test.rb`.

Build-number history is read from two independent sources and unioned — every reachable dSYM
store's `provenance.json` files, and App Store Connect's own build listing — and the higher of
the two is what the next build must strictly exceed. A store that is simply unreachable is
skipped (another store or ASC can still supply the history), but a `provenance.json` that IS
present and does not parse, or an App Store Connect that cannot be read at all, **fails the
release** rather than being treated as "no history" — a corrupt or partial record must never let
`0.1.0 (1)` pass a second time.

## The `signing.local.yml` input

`signing.local.yml` is git-ignored, but XcodeGen merges it as an arbitrary `project.yml`
fragment — not limited to the signing keys it exists for. Left alone, a stale or hand-edited
copy on disk could inject any build setting into a release archive while `expected_sha:`'s
clean-tree check stays green, because git never sees this file at all. The release lane's own
signing is fully decided downstream by `prepare_signing`'s explicit `update_code_signing_settings`
call, so a release build needs nothing from this file's content — `archive_ipa` therefore
overwrites it, unconditionally, with the canonical empty stub (`{}`) immediately before
generation, and records that stub's sha256 in `provenance.json` as `signing_local_sha256`. An
Xcode-GUI device build run directly through `bin/generate.sh` (outside this lane) is untouched —
it still stubs only when the file is absent, so a developer's real per-machine team id survives
their own local builds.

## Certificate decision and keychain reuse

`prepare_signing` refuses to run unless `IMGMGR_CERT_STRATEGY` is set to `import` or `create` —
there is no default, and `cert` against a freshly created, empty `imgmanager-ci` keychain is never
allowed to silently mint a certificate nobody decided to mint. Which one applies is a live Apple
Developer Portal decision (existing certificate count, expiry, whether its private key is
exportable) made at the merkur first-action census, not guessed here. `import` reads
`IMGMGR_DISTRIBUTION_P12_PATH` / `IMGMGR_DISTRIBUTION_P12_PASSWORD`; `create` calls `cert` as the
reference pipeline does — reusing an already-valid certificate rather than minting one, since
`force:` is never passed.

The `imgmanager-ci.keychain-db` keychain itself is **reused across every release after the
proof**, not recreated each time: `prepare_signing` writes a recognition marker file
(`imgmanager-ci.keychain-db.imgmanager-ci-marker`, beside the keychain in
`~/Library/Keychains/`) the moment it creates the keychain, and a later run that finds the
keychain already present reuses it only when that marker is also present and matches — an
existing keychain WITHOUT the marker is still refused exactly as before, on the theory it is not
this pipeline's. To deliberately replace the keychain, remove both the keychain and its marker
file together.

## The release mutex

`fastlane beta`/`archive_ipa` take a merkur-wide lock (`flock` on `~/.release-lock` — deliberately
non-overridable: both pipelines must lock the same file) around keychain-search-list mutation, certificate/profile prep and
the archive itself — two releases racing the same host's keychain search list or DerivedData can
select the wrong signing identity or exhaust disk (16 GiB free measured on merkur 2026-08-27).
`memos-ng-ios`'s own `Fastfile` (branch `fix/shared-release-lock`, MEMNG-195) takes the same lock
at the same default path around the same critical section, so once both branches are merged this
is a real cross-pipeline mutex, not merely self-protection — `flock` is cooperative and only
works because both sides agree to take it.

While the lock is held, the signing keychain search list is also narrowed to only
`imgmanager-ci.keychain-db` for the duration of signing and archiving, and restored afterward —
a generic `"Apple Distribution"` identity string can otherwise resolve against whichever keychain
happens to be searched first when more than one is visible.

## Crash symbols

`preserve_dsyms` copies the archive's `dSYMs/` to the NAS the moment the archive exists, into
`janus:/img-manager-ios/dSYMs/<marketing>-<build>/` (`/Users/Shared/nas/janus/…` as merkur sees
it, `/Volumes/lexosaurus` as the announced fallback), and prints every bundle's `dwarfdump --uuid`
line. When neither store is reachable the lane fails rather than skipping — a silent skip is how
the reference pipeline lost two builds' worth of crash symbols permanently.

## Before starting any of this

Run the gate:

    MAC_GATE_HOST=<merkur|mars|auto> bin/mac-gate.sh

`auto` takes the first idle Mac above the disk floor and prints `route : host=<h> reason=…`; the
summary carries `host=<h>`. A summary line ending in `| exit=0` is the only green. Helper-logic tests
(`asc_readback_test.rb`, `dsym_store_test.rb`, `timed_probe_test.rb`, `archive_check_test.rb`)
run standalone with plain `ruby -Ifastlane/lib fastlane/test/<name>.rb` and need no Mac.
