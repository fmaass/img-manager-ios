#!/usr/bin/env bash
#
# mac-gate.sh — the build authority for this repo.
#
# Swift cannot be built on the Linux machine this repo is developed on, so every build,
# test, lint and dependency check runs on a Mac build host over SSH. This script is the
# ONLY sanctioned way to get there. Pattern ported from the estate's reference project
# (memos-ng-ios/bin/mac-gate.sh) — the lock discipline, the rsync-mirror-never-checkout
# rule, and the DEVELOPER_DIR build path are adopted verbatim; the per-package memos
# mechanics (entitlement greps, keychain-group checks, the MemosFeatures warnings-canary,
# the layering dependency-rule greps, markdown parity) are NOT ported because
# img-manager-ios has no equivalent architecture yet — they get added when a phase
# introduces the thing they check.
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
#
# Exit codes: 2 = refusal (unsafe/unusable inputs, nothing was copied or run);
#             3 = another run of this branch holds the gate lock;
#             otherwise the exit code of the first failing step.

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

summary_and_exit() {
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
echo "\$\$ $(hostname) $(date -u +%FT%TZ)" > "\$lockdir/holder"
echo "\$target"
EOF
)
target_dir="$(printf '%s\n' "$remote_prep_script" | timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' 2>&1)"
lock_rc=$?
if [ $lock_rc -eq 3 ]; then
  echo "$target_dir" >&2
  record lock 3
  summary_and_exit
elif [ $lock_rc -ne 0 ]; then
  echo "$target_dir" >&2
  record lock "$lock_rc"
  summary_and_exit
fi
target_dir="$(printf '%s' "$target_dir" | tail -1)"
release_lock() {
  timeout 20 ssh -o BatchMode=yes "$host" "rm -rf '$target_dir/.lock'" >/dev/null 2>&1 || true
}
trap release_lock EXIT

rsync -a --delete -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
  --exclude '.git' --exclude 'signing.local.yml' --exclude '.build' \
  --exclude 'DerivedData' --exclude '*.xcodeproj' --exclude '*.xcresult' \
  --exclude '.gate-artifacts' --exclude '.tools' \
  ./ "$host:${target_dir#$HOME/}/work/" 2>&1 | tee -a "$log"
record rsync "${PIPESTATUS[0]}"
[ "$first_fail" -eq 0 ] || summary_and_exit

# --- Remote content manifest: git hash-object needs no .git — deterministic blob hash. ---
say "--- step: content manifest (mirror side) ---"
remote_manifest="$(timeout 30 ssh -o BatchMode=yes "$host" "
  cd '$target_dir/work'
  find . -type f \
    -not -path './.git/*' -not -path './.build/*' -not -path './DerivedData/*' \
    -not -name '*.xcodeproj' -not -path '*.xcresult*' -not -path './.gate-artifacts/*' \
    -not -path './.tools/*' -not -name 'signing.local.yml' \
  | sed 's|^\./||' | sort | while read -r f; do
      printf '%s %s\n' \"\$(git hash-object \"\$f\")\" \"\$f\"
    done
" 2>&1)"
remote_rc=$?
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
say "--- step: xcodegen (strategy-conditional bar: delete + regenerate + build + test) ---"
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

# The strategy-conditional bar for a GENERATED project (plan §Phase 0a (a)): delete the
# project, regenerate from spec, build and test.
rm -rf ImgManager.xcodeproj
step xcodegen ./bin/generate.sh

if [ -d ImgManager.xcodeproj ]; then
  step build xcodebuild build \
    -project ImgManager.xcodeproj -scheme ImgManager \
    -destination "generic/platform=iOS Simulator" \
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile
else
  echo "xcodegen did not produce ImgManager.xcodeproj — build/test/lint/pins skipped"
  summary="$summary build=skipped test-iphone=skipped test-ipad=skipped lint=skipped pins=skipped"
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
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile

  step test-ipad xcodebuild test \
    -project ImgManager.xcodeproj -scheme ImgManager \
    -destination "id=$ipad_udid" \
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile

  # Device-idiom-branching absence, WITH a positive control in the same invocation (bare grep -c
  # exits 1 on zero matches, which would wrongly fail this bare-gate step on the pass case —
  # so the check is "0 real hits" computed explicitly, not the exit code of the bare grep).
  idiom_hits="$(grep -rn 'userInterfaceIdiom' Sources/ Tests/ Packages/ 2>/dev/null | grep -v '^Binary' || true)"
  control_hits="$(grep -rln 'NavigationSplitView' Sources/ 2>/dev/null || true)"
  {
    echo "device-idiom-branching hits (expect 0):"
    echo "$idiom_hits"
    echo "positive control — NavigationSplitView hits (expect >=1, proves the grep runs over real content):"
    echo "$control_hits"
  } > .gate-artifacts/idiom-grep.log
  if [ -z "$idiom_hits" ] && [ -n "$control_hits" ]; then
    echo "idiom-grep exit=0" ; summary="$summary idiom-grep=0"
  else
    echo "idiom-grep exit=1"; summary="$summary idiom-grep=1"
  fi

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

remote_out="$(printf '%s\n' "$build_script" | timeout 900 ssh -o BatchMode=yes "$host" 'bash -s' 2>&1 | tee -a "$log")"
remote_line="$(printf '%s\n' "$remote_out" | grep '^MAC_GATE_REMOTE_SUMMARY:' | tail -1)"
if [ -z "$remote_line" ]; then
  record remote-run 1
else
  for pair in ${remote_line#MAC_GATE_REMOTE_SUMMARY:}; do
    name="${pair%%=*}"; code="${pair##*=}"
    [ "$code" = "skipped" ] && continue
    record "$name" "$code"
  done
fi

rsync -a -e 'ssh -o BatchMode=yes' "$host:${target_dir#$HOME/}/work/.gate-artifacts/" "$artifacts/" >/dev/null 2>&1 || true

summary_and_exit
