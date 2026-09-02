#!/usr/bin/env bash
#
# mac-gate.sh — the build authority for this repo.
#
# Swift cannot be built on the Linux machine this repo is developed on, so every build,
# test, lint and dependency check runs on a Mac build host over SSH. This script is the
# ONLY sanctioned way to get there. Pattern ported from the estate's reference project
# (memos-ng-ios/bin/mac-gate.sh) — the rsync-mirror-never-checkout rule and the
# DEVELOPER_DIR build path are adopted verbatim. The per-package memos mechanics
# (entitlement greps, keychain-group checks, the MemosFeatures warnings-canary, the
# layering dependency-rule greps, markdown parity) are NOT ported because img-manager-ios
# has no equivalent architecture yet — they get added when a phase introduces the thing
# they check.
#
# LOCK DISCIPLINE — NOT VERBATIM (corrected 2026-08-27, P0a fix round; an earlier
# revision of this file claimed "verbatim" and that claim was false). What IS ported: an
# owner token is written on acquire and READ BACK before the run proceeds (the reference
# gate's own reasoning, memos-ng-ios/bin/mac-gate.sh ~line 589: "Read back, because the
# claim is only as good as what the next run will find in there"), and release compares
# the token before removing the lock and reads back that the removal actually took,
# recording the outcome as a gate leg (`lock-release=<rc>`) rather than swallowing it.
# What is DELIBERATELY NOT ported: the reference gate's dead-holder reaping — a remote
# liveness probe (a canary process plus `pgrep` against the branch's own gate/work paths)
# that lets a NEW run take over a lock whose holder process is provably gone
# (memos-ng-ios/bin/mac-gate.sh ~lines 644-721). This script's lock is strictly
# non-reentrant: a live OR a stale lock both refuse (exit 3) and both require a human to
# clear them (`ssh <host> rm -rf '<lockdir>'`), which is safe (never wrongly steals a
# lock) but less convenient than the reference gate's self-healing behaviour. Porting the
# full reaping logic is future work if orphaned locks turn out to recur in practice.
#
# HOST-WIDE LOCK (IMGMGR-203, 2026-09-02): the per-branch lock above only stops two runs of
# the SAME branch; on 2026-08-29 five lanes gated at once and drove merkur to load 40. A second
# lock, `<gate root>/.host.lock`, admits ONE gate per Mac. It is acquired controller-side with
# short ssh calls (never one long ssh), WAITED for (up to MAC_GATE_LOCK_WAIT seconds, polled
# every 30 s) rather than refused, written with the same owner token + read-back as the branch
# lock, released with the same owner compare, and recorded as its own `lock-wait` leg
# (0 = taken, 3 = still busy at the wait cap, 2 = read-back mismatch). A stale host lock
# (holder gone) is cleared by a human exactly like a stale branch lock:
# `ssh <host> rm -rf '<gate root>/.host.lock'`; the LOCKED line prints the holder and its
# start time so the age is visible.
#
# DETACHED REMOTE RUN (IMGMGR-203, 2026-09-02): the remote build+test script used to run inside
# ONE `timeout 1800 ssh`, so every full run that outlived 30 min was killed mid-test while
# xcodebuild finished on the Mac (14+ recurrences across three sessions; the legs were then
# re-run by hand). The script is now copied to the gate dir and launched with nohup in the
# background; the controller polls a done-marker over short ssh calls every 20 s, prints every
# remote step exit line that appeared since the previous poll, and fetches the run log at the
# end. The wall-clock budget is MAC_GATE_REMOTE_CAP; a Mac unreachable for 15 consecutive polls
# ends the wait the same way. On either stop the remote run's PROCESS GROUP is signalled
# (SIGTERM, then SIGKILL; never a command-line literal) and the run records remote-run=124; if
# an empty group cannot be confirmed, both locks are deliberately LEFT IN PLACE
# (lock-release=1) so no later lane rsyncs over a still-running build.
#
# NEW versus the reference gate (WP8 plan round-2 delta, adopted advisory): the gate
# directory on merkur is a MIRROR with no .git — same as memos-ng-ios's — so this script
# cannot report a remote SHA or `git status`. Instead it computes a CONTENT MANIFEST (git
# blob hashes, via `git hash-object` — deterministic and needs no .git on either side) over
# the mirrored tree and asserts it equals the manifest of the SAME paths in the local
# checkout's HEAD, which is the identity-and-clean-tree-equivalence check the plan's
# Execution Protocol requires. SHA and `git status` language stays reserved for this
# machine's real checkout.
#
# Usage:
#   MAC_GATE_HOST=merkur bin/mac-gate.sh
#   bin/mac-gate.sh --help
#
# Environment:
#   MAC_GATE_HOST          (required) ssh alias/host of the Mac build host
#   MAC_GATE_IPHONE_TYPE    simctl device type identifier for the iPhone destination
#                            (default: com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
#   MAC_GATE_IPAD_TYPE      simctl device type identifier for the iPad destination
#                            (default: com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB)
#   MAC_GATE_ARTIFACTS      local directory for copied-back logs (default: .gate-artifacts/)
#   MAC_GATE_REMOTE_CAP     wall-clock budget in seconds for the detached remote run
#                            (default: 7200, at most 7 digits); exceeding it records
#                            remote-run=124 and stops the remote process tree (SIGTERM, then
#                            SIGKILL); if that cannot be confirmed both locks stay in place
#   MAC_GATE_LOCK_WAIT      seconds to wait for the host-wide gate lock (default: 21600, at
#                            most 7 digits);
#                            exceeding it records lock-wait=3 and the run ends
#
# Exit codes: 2 = refusal (unsafe/unusable inputs, nothing was copied or run);
#             3 = another run of this branch holds the gate lock;
#             otherwise the exit code of the first failing step (which now includes
#             `copyback`, `lock-release`, `lock-wait` and `remote-run` — see the leg list below).
#
# WP21 P2 (IMGMGR-336) added the `ui-orientation-base-grep` leg: every UI test class must inherit
# `OrientationPinnedUITestCase`, because device orientation is simulator-global and a class that
# pins nothing silently runs against the previous class's leftover rotation. A comment in a test
# file had already failed to stop that recurring, so the rule graduated to a gate leg.
#
# WP12 (IMGMGR-199) added the `widget-embed` leg and gave build/test an explicit
# `-derivedDataPath` inside the mirrored work directory. The leg reads the BUILT app bundle
# (never project.yml) to assert the widget extension is really embedded, and a deterministic
# DerivedData path is what makes "the bundle this run just built" nameable at all — the default
# location is outside the work tree and a broad search there can match a stale build. The path is
# excluded from the rsync mirror and from the content manifest, exactly as the default one was.

set -uo pipefail

GATE_ROOT_REMOTE='$HOME/build/img-manager-ios/gate'
IPHONE_TYPE="${MAC_GATE_IPHONE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
IPAD_TYPE="${MAC_GATE_IPAD_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB}"

die_refuse() { printf 'mac-gate: REFUSED: %s\n' "$1" >&2; exit 2; }
say() { printf '%s\n' "$1"; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    *) die_refuse "unknown argument: $arg (see --help)" ;;
  esac
done

host="${MAC_GATE_HOST:-}"
[ -n "$host" ] || die_refuse "MAC_GATE_HOST is not set (ssh alias of the Mac build host)"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die_refuse "not inside a git working tree"
cd "$repo_root"

head_sha="$(git rev-parse HEAD 2>/dev/null)" \
  || die_refuse "no HEAD — nothing has been committed yet (the orchestrator's snapshot commit, plan Execution Protocol step 2b, runs before this gate)"
porcelain_status="$(git status --porcelain 2>&1)"
[ -z "$porcelain_status" ] || die_refuse "controller tree is not clean — commit or stash before gating (git status --porcelain is non-empty)"

branch="${MAC_GATE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
[ "$branch" != "HEAD" ] || die_refuse "detached HEAD — set MAC_GATE_BRANCH"
esc() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }
esc_branch="$(esc "$branch")"

artifacts="${MAC_GATE_ARTIFACTS:-$repo_root/.gate-artifacts}"
mkdir -p "$artifacts"
log="$artifacts/mac-gate.log"
: > "$log"

first_fail=0
record() { # $1=name $2=exit-code
  [ "$2" -eq 0 ] || { [ "$first_fail" -eq 0 ] && first_fail="$2"; }
  step_summary="$step_summary $1=$2"
}
step_summary=""

# Set once the lock is genuinely ours (after acquire AND its readback both succeed) —
# release_lock is a no-op before that, and idempotent after (guarded by lock_released),
# since it runs both explicitly (inside summary_and_exit, so its own result is recorded
# in the printed summary) and via the EXIT trap as a safety net for early-refusal paths
# that never reach summary_and_exit at all.
lock_held=0
host_lock_held=0
locks_frozen=0
lock_released=0
lock_owner=""
target_dir=""

release_lock() {
  [ "$lock_held" = 1 ] || [ "$host_lock_held" = 1 ] || return 0
  [ "$lock_released" = 1 ] && return 0
  lock_released=1
  if [ "$locks_frozen" = 1 ]; then
    # A remote run may still be writing into the work dir (cap hit or the Mac unreachable, and
    # the kill could not be confirmed). Releasing now would let the next lane rsync --delete
    # over a live build — the exact overlap the host lock exists to prevent. A human clears
    # both once the Mac is quiet: ssh <host> rm -rf '<gate root>/.host.lock' '<branch dir>/.lock'
    say "LOCKS LEFT IN PLACE: the remote run could not be confirmed stopped (pid file $target_dir/.gate-run.pid); clear the host and branch locks by hand once it is"
    record lock-release 1
    return 0
  fi
  local out rc worst=0
  if [ "$lock_held" = 1 ]; then
    out="$(timeout 20 ssh -o BatchMode=yes "$host" "
      lockdir='$target_dir/.lock'
      if [ ! -d \"\$lockdir\" ]; then echo 'ALREADY-GONE'; exit 0; fi
      owner=\"\$(cat \"\$lockdir/holder\" 2>/dev/null)\"
      if [ \"\$owner\" != '$lock_owner' ]; then
        echo \"OWNER-MISMATCH wrote=$lock_owner found=\$owner\"; exit 1
      fi
      rm -rf \"\$lockdir\"
      if [ -d \"\$lockdir\" ]; then echo 'REMOVE-FAILED'; exit 1; fi
      echo 'RELEASED'
    " 2>&1)"
    rc=$?
    printf 'branch lock: %s\n' "$out" >> "$log" 2>/dev/null || true
    [ "$rc" -eq 0 ] || say "LOCK RELEASE WARNING (branch lock, recorded as lock-release leg): $out"
    [ "$rc" -le "$worst" ] || worst=$rc
  fi
  if [ "$host_lock_held" = 1 ]; then
    out="$(timeout 20 ssh -o BatchMode=yes "$host" "
      lockdir=\"$GATE_ROOT_REMOTE/.host.lock\"
      if [ ! -d \"\$lockdir\" ]; then echo 'ALREADY-GONE'; exit 0; fi
      owner=\"\$(cat \"\$lockdir/holder\" 2>/dev/null)\"
      if [ \"\$owner\" != '$lock_owner' ]; then
        echo \"OWNER-MISMATCH wrote=$lock_owner found=\$owner\"; exit 1
      fi
      rm -rf \"\$lockdir\"
      if [ -d \"\$lockdir\" ]; then echo 'REMOVE-FAILED'; exit 1; fi
      echo 'RELEASED'
    " 2>&1)"
    rc=$?
    printf 'host lock: %s\n' "$out" >> "$log" 2>/dev/null || true
    [ "$rc" -eq 0 ] || say "LOCK RELEASE WARNING (host lock, recorded as lock-release leg): $out"
    [ "$rc" -le "$worst" ] || worst=$rc
  fi
  record lock-release "$worst"
}
trap release_lock EXIT

summary_and_exit() {
  release_lock
  printf 'mac-gate SUMMARY:%s | exit=%s\n' "$step_summary" "$first_fail" | tee -a "$log"
  exit "$first_fail"
}

# --- Local (controller-side) content manifest: git blob hashes over tracked files. -------
say "--- step: content manifest (controller side, HEAD=$head_sha) ---"
local_manifest="$(git ls-files -s | awk '{print $2, $4}' | sort)"
manifest_count="$(printf '%s\n' "$local_manifest" | grep -c .)"
say "controller manifest: $manifest_count tracked files at HEAD $head_sha, working tree clean (git status --porcelain: 0 bytes)"

# --- Gate lock + rsync mirror (never a checkout — see header). ---------------------------
say "--- step: rsync ---"
lock_owner="ctrl-$$-$(date -u +%s)-$RANDOM"
esc_owner="$(esc "$lock_owner")"

# --- Host-wide gate lock: ONE gate per Mac (IMGMGR-203, see header). --------------------
lock_wait_cap="${MAC_GATE_LOCK_WAIT:-21600}"
case "$lock_wait_cap" in ''|*[!0-9]*) die_refuse "MAC_GATE_LOCK_WAIT must be a whole number of seconds (got '$lock_wait_cap')" ;; esac
[ "${#lock_wait_cap}" -le 7 ] || die_refuse "MAC_GATE_LOCK_WAIT must be at most 7 digits (got '$lock_wait_cap')"
lock_wait_started=$SECONDS
while :; do
  hl_out="$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "
    lockdir=\"$GATE_ROOT_REMOTE/.host.lock\"
    mkdir -p \"$GATE_ROOT_REMOTE\"
    if mkdir \"\$lockdir\" 2>/dev/null; then
      printf '%s\n' '$esc_owner' > \"\$lockdir/holder\"
      date -u +%Y-%m-%dT%H:%M:%SZ > \"\$lockdir/since\"
      rb=\"\$(cat \"\$lockdir/holder\" 2>/dev/null)\"
      if [ \"\$rb\" = '$esc_owner' ]; then echo TAKEN; else echo \"MISMATCH holder=\$rb\"; fi
    else
      printf 'HELD by %s since %s\n' \"\$(cat \"\$lockdir/holder\" 2>/dev/null || echo unknown)\" \"\$(cat \"\$lockdir/since\" 2>/dev/null || echo unknown)\"
    fi
  " 2>&1)"
  hl_rc=$?
  case "$hl_out" in
    TAKEN) host_lock_held=1; break ;;
    HELD*) ;;
    MISMATCH*)
      # The dir was ours a moment ago and now names another holder: a human cleared a stale lock
      # and another gate re-acquired it in between. Leave it — it is theirs now — and stop.
      echo "mac-gate: host lock read-back mismatch ($hl_out) — left in place, not ours" >&2
      record lock-wait 2
      summary_and_exit ;;
    *)
      if [ "$hl_rc" -eq 0 ]; then
        echo "mac-gate: unexpected host-lock reply: $hl_out" >&2
        record lock-wait 2
        summary_and_exit
      fi ;;   # nonzero rc with no reply = transient ssh failure: retry below
  esac
  waited=$((SECONDS - lock_wait_started))
  if [ "$waited" -ge "$lock_wait_cap" ]; then
    echo "mac-gate: host lock still busy after ${waited}s (${hl_out:-no reply}) — giving up (MAC_GATE_LOCK_WAIT=$lock_wait_cap)" >&2
    record lock-wait 3
    summary_and_exit
  fi
  say "host lock   : ${hl_out:-merkur unreachable} — waited ${waited}s, retry in 30s"
  sleep 30
done
record lock-wait 0
say "host lock   : taken after $((SECONDS - lock_wait_started))s (owner=$lock_owner)"
remote_prep_script=$(cat <<EOF
set -e
target="$GATE_ROOT_REMOTE/$esc_branch"
case "\$target" in
  "$GATE_ROOT_REMOTE"/*) ;;
  *) echo "mac-gate(remote): REFUSED: branch resolves outside gate root" >&2; exit 2 ;;
esac
mkdir -p "\$target/work"
lockdir="$GATE_ROOT_REMOTE/$esc_branch/.lock"
if ! mkdir "\$lockdir" 2>/dev/null; then
  holder="\$(cat "\$lockdir/holder" 2>/dev/null || echo unknown)"
  echo "mac-gate(remote): LOCKED by \$holder" >&2
  exit 3
fi
printf '%s\n' '$esc_owner' > "\$lockdir/holder"
# Read back — ported reasoning from the reference gate (see header note): the claim is
# only as good as what a read of the same file finds.
readback="\$(cat "\$lockdir/holder" 2>/dev/null)"
if [ "\$readback" != '$esc_owner' ]; then
  echo "mac-gate(remote): LOCK MISMATCH wrote='$esc_owner' read='\$readback'" >&2
  rm -rf "\$lockdir"
  exit 2
fi
echo "\$target"
EOF
)
target_dir="$(printf '%s\n' "$remote_prep_script" | timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' 2>&1)"
lock_rc=$?
if [ $lock_rc -eq 3 ]; then
  echo "$target_dir" >&2
  record lock 3
  # lock_held stays 0 — this run never acquired anything, so release_lock is correctly a no-op.
  summary_and_exit
elif [ $lock_rc -ne 0 ]; then
  echo "$target_dir" >&2
  record lock "$lock_rc"
  summary_and_exit
fi
target_dir="$(printf '%s' "$target_dir" | tail -1)"
lock_held=1
say "gate lock   : taken (owner=$lock_owner)"

rsync -a --delete -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
  --exclude '.git' --exclude 'signing.local.yml' --exclude '.build' \
  --exclude 'DerivedData' --exclude '*.xcodeproj' --exclude '*.xcresult' \
  --exclude '.gate-artifacts' --exclude '.tools' --exclude '.phase-ledger.md' \
  ./ "$host:${target_dir#$HOME/}/work/" 2>&1 | tee -a "$log"
record rsync "${PIPESTATUS[0]}"
[ "$first_fail" -eq 0 ] || summary_and_exit

# --- Remote content manifest: git hash-object needs no .git — deterministic blob hash. ---
say "--- step: content manifest (mirror side) ---"
# 180s, not 30 (WP12/IMGMGR-199): this step forks `git hash-object` once PER FILE over one ssh
# connection, so its cost grows with the tree and with whatever else the build host is doing.
# Observed 2026-08-29 with five WP12 lanes gating concurrently (merkur load average 46-122): the
# same 139-file tree came back in time on one run and timed out on the next two, i.e. the cap was
# turning host load into a false "the mirror differs from HEAD" verdict on a tree that was in fact
# identical. The CHECK is unchanged — only the patience is.
# Prune, don't filter: -not -path still STAT-WALKS every file under .build/DerivedData
# (observed 2026-08-30: 129s real / 0.4s cpu over 9k files while a Plex transcode owned the
# disk), and the per-file `git hash-object` fork added 139 more spawns. Pruned traversal +
# one batched hash-object spawn keeps the same file set and fits the cap on a busy disk.
manifest_t0=$SECONDS
remote_manifest="$(timeout 180 ssh -o BatchMode=yes "$host" "
  cd '$target_dir/work'
  tmp=\$(mktemp -d)
  find . \( -name .git -o -name .build -o -name DerivedData -o -name '*.xcodeproj' -o -name '*.xcresult' -o -name .gate-artifacts -o -name .tools \) -prune \
    -o -type f -not -name '.phase-ledger.md' -not -name 'signing.local.yml' -print \
  | sed 's|^\./||' | sort > \"\$tmp/f\"
  tr '\n' '\0' < \"\$tmp/f\" | xargs -0 git hash-object > \"\$tmp/h\"
  paste -d' ' \"\$tmp/h\" \"\$tmp/f\"
  rm -rf \"\$tmp\"
" 2>&1)"
remote_rc=$?
say "mirror manifest walk: $((SECONDS - manifest_t0))s (cap 180 s)"
if [ $remote_rc -ne 0 ]; then
  echo "$remote_manifest" >&2
  record manifest "$remote_rc"
  summary_and_exit
fi
remote_manifest_sorted="$(printf '%s\n' "$remote_manifest" | sort)"
if [ "$local_manifest" = "$remote_manifest_sorted" ]; then
  say "MANIFEST OK: mirror tree is identical to jupiter HEAD $head_sha ($manifest_count files, blob-hash equal)"
  record manifest 0
else
  say "MANIFEST FAIL: mirror tree DIFFERS from jupiter HEAD $head_sha"
  diff <(printf '%s\n' "$local_manifest") <(printf '%s\n' "$remote_manifest_sorted") | head -40 | tee -a "$log"
  record manifest 1
fi
[ "$first_fail" -eq 0 ] || summary_and_exit

# --- Remote build: DEVELOPER_DIR is the build path (delta finding 4), not a workaround. --
say "--- step: api-nullable-tests, then xcodegen (strategy-conditional bar) ---"
build_script=$(cat <<'REMOTE'
set -uo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "__WORK__"

summary=""
step() { # $1=name -- rest is the command
  name="$1"; shift
  "$@" > ".gate-artifacts/${name}.log" 2>&1
  rc=$?
  summary="$summary $name=$rc"
  echo "--- $name exit=$rc ---"
  tail -30 ".gate-artifacts/${name}.log"
}
mkdir -p .gate-artifacts

# FAIL-FAST: the OpenAPI nullable-survival probe (P0a's generation-probe regression
# guard, still enforced after WP8 P1-ios retired the bridge — docs/OPENAPI_NORMALIZATION_
# DEBT.md) needs no xcodegen project at all — plain `swift test` against the SwiftPM
# package — so it runs FIRST and cheapest, before any simulator is created. A red result
# here means img-manager's OpenAPI schema regressed back to the anyOf-nullable idiom
# swift-openapi-generator drops, and there is no point spending simulator minutes on a
# client generated from a broken contract.
step api-nullable-tests swift test --package-path Packages/ImgManagerAPI

api_nullable_rc="$(printf '%s\n' "$summary" | tr ' ' '\n' | sed -n 's/^api-nullable-tests=//p')"
if [ "$api_nullable_rc" != "0" ]; then
  echo "api-nullable-tests failed (exit $api_nullable_rc) — skipping xcodegen/build/test/lint/pins (fail-fast)"
  summary="$summary xcodegen=skipped build=skipped widget-embed=skipped test-iphone=skipped test-ipad=skipped idiom-grep=skipped lint=skipped pins=skipped"
  echo "MAC_GATE_REMOTE_SUMMARY:$summary"
  exit 0
fi

# The strategy-conditional bar for a GENERATED project (plan §Phase 0a (a)): delete the
# project, regenerate from spec, build and test.
rm -rf ImgManager.xcodeproj
step xcodegen ./bin/generate.sh

# One explicit DerivedData root for every xcodebuild invocation below, inside the mirrored work
# directory (rsync --exclude'd and manifest-excluded, like the default location was) — see the
# header note. Sharing it across build and the two test legs also keeps the tests reusing the
# build the `build` leg already produced, which is what the default path did implicitly.
derived="$PWD/DerivedData"

# The widget-embed leg reads the built .app for PlugIns/ImgManagerWidget.appex, and DerivedData
# persists across gate runs (rsync excludes it) — a stale product bundle from an earlier green
# run could satisfy the check even if this commit's config no longer embeds the widget. Purge
# only the emitted products (module/build caches stay), so the inspected bundle is this run's.
rm -rf "$derived/Build/Products"

if [ -d ImgManager.xcodeproj ]; then
  step build xcodebuild build \
    -project ImgManager.xcodeproj -scheme ImgManager \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived" \
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile

  # WP12 (IMGMGR-199): the readiness widget is only really shipped if the BUILT app bundle
  # contains it. `embed: true` in project.yml is a claim about the spec, and a green xcodegen
  # proves only that the spec parsed — this reads the product Xcode actually emitted, the same
  # "read the artefact, never the spec" doctrine fastlane's archive checks follow.
  # Positive control in the SAME invocation (idiom-grep's shape): the host app's own bundle id is
  # read from the same tree, so a check that found nothing because it was pointed at an empty or
  # stale DerivedData fails instead of quietly passing.
  widget_app="$derived/Build/Products/Debug-iphonesimulator/ImgManager.app"
  widget_appex="$widget_app/PlugIns/ImgManagerWidget.appex"
  widget_point=""
  widget_control=""
  if [ -f "$widget_appex/Info.plist" ]; then
    widget_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget_appex/Info.plist" 2>/dev/null || true)"
  fi
  if [ -f "$widget_app/Info.plist" ]; then
    widget_control="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget_app/Info.plist" 2>/dev/null || true)"
  fi
  {
    echo "app bundle : $widget_app"
    echo "extension  : $widget_appex"
    echo "NSExtensionPointIdentifier (expect com.apple.widgetkit-extension): $widget_point"
    echo "positive control — host CFBundleIdentifier (expect live.discomarder.imgmanager): $widget_control"
    echo "every .appex found in the built app (diagnostic, expect exactly the one above):"
    find "$widget_app" -name '*.appex' 2>/dev/null || true
  } > .gate-artifacts/widget-embed.log
  if [ "$widget_point" = "com.apple.widgetkit-extension" ] \
    && [ "$widget_control" = "live.discomarder.imgmanager" ]; then
    echo "widget-embed exit=0"; summary="$summary widget-embed=0"
  else
    echo "widget-embed exit=1"; summary="$summary widget-embed=1"
    tail -20 .gate-artifacts/widget-embed.log
  fi
else
  echo "xcodegen did not produce ImgManager.xcodeproj — build/test/lint/pins skipped"
  summary="$summary build=skipped widget-embed=skipped test-iphone=skipped test-ipad=skipped lint=skipped pins=skipped"
fi

if [ -d ImgManager.xcodeproj ]; then
  iphone_udid="$(xcrun simctl create "mac-gate-iphone-$$" "__IPHONE_TYPE__" com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
  ipad_udid="$(xcrun simctl create "mac-gate-ipad-$$" "__IPAD_TYPE__" com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
  cleanup_sims() {
    xcrun simctl shutdown "$iphone_udid" >/dev/null 2>&1
    xcrun simctl shutdown "$ipad_udid" >/dev/null 2>&1
    xcrun simctl delete "$iphone_udid" >/dev/null 2>&1
    xcrun simctl delete "$ipad_udid" >/dev/null 2>&1
  }
  trap cleanup_sims EXIT

  step test-iphone xcodebuild test \
    -project ImgManager.xcodeproj -scheme ImgManager \
    -destination "id=$iphone_udid" \
    -derivedDataPath "$derived" \
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile

  step test-ipad xcodebuild test \
    -project ImgManager.xcodeproj -scheme ImgManager \
    -destination "id=$ipad_udid" \
    -derivedDataPath "$derived" \
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile

  # Absence legs (IMGMGR-346): each scan keeps grep's own exit status through bin/gate-lib.sh,
  # so a scan ERROR (rc 2 — unreadable directory, bad pattern) turns the leg red instead of
  # reading as a green zero-hit; every leg carries a positive control in the same invocation.
  . bin/gate-lib.sh

  # Device-idiom-branching absence.
  scan grep -rnI --exclude-dir=.build 'userInterfaceIdiom' Sources/ Tests/ Packages/
  idiom_hits=$scan_out; idiom_rc=$scan_rc
  scan grep -rlI 'NavigationSplitView' Sources/
  absence_leg idiom-grep "device-idiom-branching hits" "$idiom_hits" "$idiom_rc" \
    "NavigationSplitView hits" "$scan_out" "$scan_rc"

  # `C` (compare) absence in SHIPPED code: native compare is cancelled outright (Amendment 7)
  # and P3's fold requires it declared NOWHERE, never present-and-dead. Scoped to
  # Sources/+Packages/ only (never Tests/) and to the actual SwiftUI keyboard-binding call
  # shape — the Swift-level ShortcutCatalogTests already cover the enum's own case list
  # exhaustively; this leg exists so a future hand-rolled `.keyboardShortcut("c")` bypassing
  # the catalog entirely is still caught — "a check a comment can defeat is not a check".
  scan grep -rniIE --exclude-dir=.build 'keyboardShortcut\("c"|keyEquivalent: *"c"' Sources/ Packages/
  c_hits=$scan_out; c_rc=$scan_rc
  scan grep -rlI 'ShortcutCatalog' Sources/
  absence_leg no-c-shortcut-grep "C-shortcut/compare hits" "$c_hits" "$c_rc" \
    "ShortcutCatalog hits" "$scan_out" "$scan_rc"

  # Every UI test class inherits `OrientationPinnedUITestCase` (IMGMGR-336). Device orientation
  # is SIMULATOR-GLOBAL and outlives the class that set it, so a class that subclasses
  # `XCTestCase` directly runs against whatever the previously-sorted class left behind — the
  # failure this repo has paid two gate cycles for, and the one a comment inside a test file did
  # not stop. The base class disarms it for the classes that exist; this leg is what keeps the
  # NEXT one from slipping out. The control is the base's own declaration, so a check pointed
  # at a renamed or empty tree fails instead of passing quietly.
  scan grep -rnE --include='*.swift' --exclude='OrientationPinnedUITestCase.swift' \
    'class [A-Za-z0-9_]+: *XCTestCase' Tests/ImgManagerUITests
  ui_hits=$scan_out; ui_rc=$scan_rc
  scan grep -nE 'class OrientationPinnedUITestCase: *XCTestCase' \
    Tests/ImgManagerUITests/OrientationPinnedUITestCase.swift
  absence_leg ui-orientation-base-grep "UI test classes bypassing the orientation-pinned base" \
    "$ui_hits" "$ui_rc" "the base class's own declaration" "$scan_out" "$scan_rc"

  step lint swift format lint --strict --recursive Sources Tests Packages/ImgManagerAPI/Sources Packages/ImgManagerAPI/Tests

  # Dependency-pin check (mirrors memos-ng-ios's `pins` step): resolve against the restored
  # Package.resolved and diff package-by-package.
  cp Package.resolved .gate-artifacts/Package.resolved.before 2>/dev/null || true
  step pins xcodebuild -resolvePackageDependencies \
    -project ImgManager.xcodeproj -scheme ImgManager \
    -onlyUsePackageVersionsFromResolvedFile
  if [ -f Package.resolved ] && [ -f .gate-artifacts/Package.resolved.before ]; then
    if diff -q Package.resolved .gate-artifacts/Package.resolved.before >/dev/null; then
      echo "PINS OK: Package.resolved unchanged by resolution"
    else
      echo "PINS FAIL: Package.resolved drifted — a dependency moved since it was pinned"
    fi
  fi
fi

echo "MAC_GATE_REMOTE_SUMMARY:$summary"
REMOTE
)
build_script="${build_script//__WORK__/$target_dir/work}"
build_script="${build_script//__IPHONE_TYPE__/$IPHONE_TYPE}"
build_script="${build_script//__IPAD_TYPE__/$IPAD_TYPE}"

# --- Remote run: launched DETACHED on the Mac and polled over short ssh calls (IMGMGR-203). --
# stop_remote_run: stop the detached run by PROCESS GROUP. The launch runs under job control,
# so the recorded subshell pid is also its pgid; SIGTERM then SIGKILL go to the whole group,
# which — unlike a parent-pid tree walk — still reaches a child that was reparented to launchd
# after its parent died (probed live on merkur 2026-09-02). Confirmation is group membership
# (`pgrep -g`), never a command-line literal. Anything short of an empty group — a survivor,
# a missing pid file or gate dir, an unreachable Mac — freezes both locks (see release_lock):
# the work dir may still be written to. The body is piped to the Mac as a script.
stop_remote_script=$(cat <<'REMOTESTOP'
cd "__TARGET__" 2>/dev/null || { echo NO-DIR; exit 0; }
pid="$(cat .gate-run.pid 2>/dev/null)"
[ -n "$pid" ] || { echo NO-PID; exit 0; }
# The run was launched under job control, so the subshell leads its own process group
# (pgid == pid). Group membership survives reparenting; a tree walk does not.
members() { pgrep -g "$pid" 2>/dev/null | tr '\n' ' '; }
kill -TERM -- -"$pid" 2>/dev/null
i=0; while [ "$i" -lt 20 ] && [ -n "$(members)" ]; do sleep 1; i=$((i + 1)); done
[ -z "$(members)" ] || kill -KILL -- -"$pid" 2>/dev/null
i=0; while [ "$i" -lt 10 ] && [ -n "$(members)" ]; do sleep 1; i=$((i + 1)); done
left="$(members)"
[ -z "$left" ] || { echo "STILL-RUNNING pids=$left"; exit 0; }
if [ -f .gate-run.done ]; then echo "STOPPED code=$(cat .gate-run.done)"; else echo "STOPPED code=none"; fi
REMOTESTOP
)
stop_remote_run() {
  local out script
  script="${stop_remote_script//__TARGET__/$target_dir}"
  out="$(printf '%s\n' "$script" | timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' 2>&1)"
  case "$out" in
    STOPPED*) say "remote run  : $out" ;;
    *) locks_frozen=1; say "remote run  : could not confirm the remote run stopped (${out:-no reply}) — locks frozen" ;;
  esac
}
remote_cap="${MAC_GATE_REMOTE_CAP:-7200}"
case "$remote_cap" in ''|*[!0-9]*) die_refuse "MAC_GATE_REMOTE_CAP must be a whole number of seconds (got '$remote_cap')" ;; esac
[ "${#remote_cap}" -le 7 ] || die_refuse "MAC_GATE_REMOTE_CAP must be at most 7 digits (got '$remote_cap')"
launch_out="$(printf '%s\n' "$build_script" | timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "
  set -e
  cd \"$target_dir\"
  cat > .gate-run.sh
  rm -f .gate-run.done .gate-run.log .gate-run.pid
  set -m
  ( nohup bash .gate-run.sh </dev/null >.gate-run.log 2>&1; echo \$? >.gate-run.done ) >/dev/null 2>&1 </dev/null &
  echo \$! > .gate-run.pid
  set +m
  echo \"LAUNCHED pid=\$(cat .gate-run.pid)\"
" 2>&1)"
launch_rc=$?
remote_out=""
if [ "$launch_rc" -ne 0 ] || ! printf '%s\n' "$launch_out" | grep -q '^LAUNCHED pid='; then
  printf 'remote launch failed (rc=%s): %s\n' "$launch_rc" "$launch_out" | tee -a "$log" >&2
  record remote-run 1
else
  say "remote run  : $launch_out — detached, cap ${remote_cap}s (MAC_GATE_REMOTE_CAP), polling every 20s"
  poll_started=$SECONDS
  unreachable=0
  done_code=""
  seen_steps=0
  while :; do
    poll_out="$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "
      cd \"$target_dir\" 2>/dev/null || { echo GONE; exit 0; }
      if [ -f .gate-run.done ]; then echo \"DONE-\$(cat .gate-run.done)\"; else echo RUNNING; fi
      grep -E '^(--- )?[a-z-]+ exit=[0-9]+' .gate-run.log 2>/dev/null | sed -n \"$((seen_steps + 1)),\\\$p\"
    " 2>&1)"
    poll_rc=$?
    if [ "$poll_rc" -ne 0 ]; then
      unreachable=$((unreachable + 1))
      if [ "$unreachable" -ge 15 ]; then
        say "remote run  : $host unreachable for $unreachable consecutive polls — giving up on this run (last reply: $poll_out)"
        stop_remote_run
        break
      fi
      sleep 20
      continue
    fi
    unreachable=0
    state="$(printf '%s\n' "$poll_out" | sed -n '1p')"
    new_steps="$(printf '%s\n' "$poll_out" | sed -n '2,$p' | sed '/^$/d')"
    if [ -n "$new_steps" ]; then
      while IFS= read -r step_line; do
        say "remote run  : $step_line (t=$((SECONDS - poll_started))s)"
        seen_steps=$((seen_steps + 1))
      done <<< "$new_steps"
    fi
    case "$state" in
      DONE-*) done_code="${state#DONE-}"; break ;;
      GONE) say "remote run  : gate dir vanished on $host"; break ;;
    esac
    if [ $((SECONDS - poll_started)) -ge "$remote_cap" ]; then
      say "remote run  : still running after ${remote_cap}s (MAC_GATE_REMOTE_CAP) — recorded as remote-run=124; stopping the remote run"
      stop_remote_run
      break
    fi
    sleep 20
  done
  remote_out="$(timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "cd \"$target_dir\" && { cp -f .gate-run.log work/.gate-artifacts/remote-run.log 2>/dev/null || true; }; cat \"$target_dir/.gate-run.log\" 2>/dev/null" 2>&1 | tee -a "$log")"
  remote_line="$(printf '%s\n' "$remote_out" | grep '^MAC_GATE_REMOTE_SUMMARY:' | tail -1)"
  if [ -z "$done_code" ]; then
    record remote-run 124
  elif [ -z "$remote_line" ]; then
    case "$done_code" in
      0|'') record remote-run 1 ;;
      *) record remote-run "$done_code" ;;
    esac
  else
    say "remote run  : finished in $((SECONDS - poll_started))s (script exit $done_code)"
    [ "$done_code" = 0 ] || record remote-run "$done_code"
    for pair in ${remote_line#MAC_GATE_REMOTE_SUMMARY:}; do
      name="${pair%%=*}"; code="${pair##*=}"
      [ "$code" = "skipped" ] && continue
      record "$name" "$code"
    done
  fi
fi

# Copyback: previously `|| true`-swallowed, so a failed copy still produced a green
# summary line with silently missing/incomplete evidence in .gate-artifacts/ — fixed
# 2026-08-27 (P0a fix round) to record its own exit code as a real leg.
copyback_out="$(rsync -a -e 'ssh -o BatchMode=yes' "$host:${target_dir#$HOME/}/work/.gate-artifacts/" "$artifacts/" 2>&1)"
copyback_rc=$?
[ "$copyback_rc" -eq 0 ] || { echo "$copyback_out" >&2; }
printf '%s\n' "$copyback_out" >> "$log" 2>/dev/null || true
record copyback "$copyback_rc"

summary_and_exit
