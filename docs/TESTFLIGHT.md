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

    ssh <merkur host>
    cd ~/projects/img-manager-ios
    set -a; source ~/.config/<the ci env file>; set +a
    export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export IMGMGR_CERT_STRATEGY=import   # or: create — see "Certificate decision" below
    fastlane beta expected_sha:<the exact commit HEAD must be at>

`archive_ipa` (which `beta` calls first) runs, in this order: `bin/generate.sh`, an assertion
that the project's `Package.resolved` is byte-equal to the tracked root file, signing, the
archive itself (`-onlyUsePackageVersionsFromResolvedFile`), and the archive/pre-upload check
below — before any IPA is assembled. `beta` then uploads, preserves dSYMs with a provenance
record beside them, and reads App Store Connect back.

**`expected_sha:` is required, not optional.** The lane refuses a dirty working tree and refuses
to build any commit other than the one named — `verify_attach` proves a build reached the
household, never what source produced it. The SHA, marketing version and build number are
written as `provenance.json` next to that build's dSYMs.

## The archive/pre-upload check

Before the IPA is assembled, `fastlane/lib/archive_check.rb` verdicts on facts read off the
**built** `.xcarchive` — never off `project.yml`, which is the intent, not what Xcode emitted:
bundle id; `0.1.0 (1)` for the first proof, a strictly increasing build number after that (read
from the newest `provenance.json` under the dSYM store, not guessed); `ITSAppUsesNonExemptEncryption`
is a real Boolean `false` (a string `"NO"` satisfies nothing at upload time); all four orientations;
the icon asset and its compiled `Assets.car` are present; the code signature is a valid Apple
Distribution signature; the embedded profile's application identifier and team match; `get-task-allow`
is `false`; and at least one `dSYM` UUID matches the built binary. Every branch is a pure function,
unit-tested without a Mac: `ruby -Ifastlane/lib fastlane/test/archive_check_test.rb`.

## Certificate decision

`prepare_signing` refuses to run unless `IMGMGR_CERT_STRATEGY` is set to `import` or `create` —
there is no default, and `cert` against a freshly created, empty `imgmanager-ci` keychain is never
allowed to silently mint a certificate nobody decided to mint. Which one applies is a live Apple
Developer Portal decision (existing certificate count, expiry, whether its private key is
exportable) made at the merkur first-action census, not guessed here. `import` reads
`IMGMGR_DISTRIBUTION_P12_PATH` / `IMGMGR_DISTRIBUTION_P12_PASSWORD`; `create` calls `cert` as the
reference pipeline does.

## The release mutex

`fastlane beta`/`archive_ipa` take a merkur-wide lock (`flock` on `~/.release-lock`, overridable
via `IMGMGR_RELEASE_LOCK_PATH`) around keychain-search-list mutation, certificate/profile prep and
the archive itself — two releases racing the same host's keychain search list or DerivedData can
select the wrong signing identity or exhaust disk (16 GiB free measured on merkur 2026-08-27).
**This only protects a run from this repository.** It is a mutex against the `memos-ng-ios`
pipeline only once that repository's own `Fastfile` takes the same lock — it does not yet as of
this port; that is a cross-repo follow-up, not assumed closed here.

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

    MAC_GATE_HOST=<the Mac build host> bin/mac-gate.sh

A summary line ending in `| exit=0` is the only green. Helper-logic tests
(`asc_readback_test.rb`, `dsym_store_test.rb`, `timed_probe_test.rb`, `archive_check_test.rb`)
run standalone with plain `ruby -Ifastlane/lib fastlane/test/<name>.rb` and need no Mac.
