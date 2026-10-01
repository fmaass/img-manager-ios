#!/usr/bin/env bash
# lane-remove.sh <branch> — remove ONE dead gate lane of this repo from the Mac build host, under
# the gate's own lane lock. Run only for a branch the owner saw as CANDIDATE in
# scripts/lane-inventory.sh's list; this script re-checks the branch itself and never widens it.
#
# Sequence (each host step is its own ssh, tagged `# lane-remove:<step>` on its first line):
#   mkdir-lock      a symlink anywhere from the gate root (from $HOME under the production root)
#                   down to the lane → REFUSED, exit 2. The lane's own mtime and work/'s are read
#                   BEFORE the mkdir (it bumps the lane mtime); not both strictly older than 24 h →
#                   `SKIP young <age>`, unreadable → SKIP UNMEASURED age. Then
#                   `mkdir gate/<branch>/.lock` exactly as bin/mac-gate.sh:392-397 takes it, then
#                   write `holder` = `lane-remove <utc> <pid>`. mkdir fails → `SKIP locked by
#                   <holder>`, exit 0, nothing touched.
#   holder-readback read the holder back; anything else → release (only a holder that is ours) and SKIP.
#   (re-probe)      on this machine: the inventory's branch probes and live-package probe for this
#                   branch; present anywhere, live, or UNMEASURED → release and SKIP.
#   mv              `mv gate/<branch> gate/.reaping-<flat>-<utc>` — the lock directory travels inside
#                   and is still held; df before; du of the renamed tree. A `gate/<branch>` a gate
#                   creates after this is a new lane and is never touched. Then the holder is read
#                   inside the renamed tree, and the tree is scanned for a lane of a DESCENDANT
#                   branch (gate/<branch>/<x>/...) a gate created after the layout check: any child
#                   directory besides work/ and .lock, or a work/ or .lock directory below them. One
#                   found → the tree goes back to gate/<branch>, the lock is released, `SKIP nested
#                   lane appeared <path>`, exit 0; if gate/<branch> was re-created meanwhile the tree
#                   stays renamed with this run's lock inside, nothing released, exit 1.
#   rm              `rm -rf` of the RENAMED path only, then confirm it is gone.
#   df              the volume read again.
# Then one row is appended to $LANE_REAPS_TSV:
#   utc  branch  removed_kb  free_before_gib  free_after_gib  renamed_path
# <flat> is the branch with `%` as %25 and `/` as %2F, so a nested lane lands directly under gate/.
#
# Never: an rm of a path that was not renamed first, `.host.lock`, flock, any other repo's tree.
# A row that cannot be appended → `AUDIT-WRITE-FAILED <path>`, exit 1 (the lane IS removed).
#
# Trust boundary: the gate root must be the production `$HOME/build/img-manager-ios/gate`
# (scripts/lane-inventory.sh gate_root_ok); LANE_GATE_ROOT_FIXTURE=1 lifts that for the fixture
# suite only, whose caller owns the root it names. Every other LANE_* override is trusted input too.
#
# Exit: 0 removed or SKIP; 1 a step failed after the lock was taken (the message says what is left),
# the audit row was not written, or a SKIP's release of this run's lock was not confirmed (the
# message names the lock that may remain); 2 refused (bad input, wrong root, symlink in the path).

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lane-inventory.sh
. "$here/lane-inventory.sh"

: "${LANE_REAPS_TSV:=/home/fabian/projects/worktrees/gate-reaps.tsv}"

refuse() { echo "lane-remove: REFUSED: $*" >&2; exit 2; }

[ $# -eq 1 ] || refuse "usage: lane-remove.sh <branch>"
branch="$1"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || refuse "not a valid branch name: $branch"
case "$branch" in
  -* | */ | .reaping-* | .host.lock) refuse "not a lane branch: $branch" ;;
esac
gate_root_ok || refuse "LANE_GATE_ROOT is not $LANE_PROD_GATE_ROOT (without LANE_GATE_ROOT_FIXTURE=1) or has characters outside [A-Za-z0-9._/\$-]"
now="${LANE_NOW:-$(date +%s)}"
case "$now:$LANE_MIN_AGE_S" in *[!0-9:]* | :* | *:) refuse "LANE_NOW / LANE_MIN_AGE_S not whole seconds" ;; esac

utc="$(date -u +%Y%m%dT%H%M%SZ)"
holder="lane-remove $utc $$"
flat="$(printf '%s' "$branch" | sed 's/%/%25/g; s|/|%2F|g')"
renamed_rel=".reaping-$flat-$utc"

pre="G=\"$LANE_GATE_ROOT\"; B=$(sq "$branch"); H=$(sq "$holder"); R=$(sq "$renamed_rel"); DFP=$(sq "$LANE_DF_PATH")
D=\"\$G/\$B\"; RP=\"\$G/\$R\"; N=$now; A=$LANE_MIN_AGE_S"

# Host-side helpers every step carries.
lib='
# The first symlink from the gate root (from $HOME when the root is under it) down to <path>.
symlink_in() {
  local p="$1" stop
  case "$G/" in "$HOME"/*) stop="$HOME" ;; *) stop="${G%/*}" ;; esac
  while [ -n "$p" ] && [ "$p" != "$stop" ] && [ "$p" != / ]; do
    if [ -L "$p" ]; then printf "%s" "$p"; return 0; fi
    p="${p%/*}"
  done
  return 1
}
mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# The first lane marker inside <tree> other than its own work/ and .lock: any other child
# directory, or a work/ or .lock directory at any depth below those. A scan that errors counts.
nested_in() {
  local t="$1" c f
  for c in "$t"/* "$t"/.[!.]* "$t"/..?*; do
    [ -d "$c" ] || continue
    case "${c##*/}" in work | .lock) ;; *) printf "%s" "${c##*/}"; return ;; esac
  done
  f="$(find "$t" -mindepth 2 -type d \( -name work -o -name .lock \) 2>/dev/null)" || { printf "%s" "?scan-failed"; return; }
  f="$(printf "%s\n" "$f" | head -n 1)"
  [ -z "$f" ] || printf "%s" "${f#"$t"/}"
}'

step() { # <name> <body> — the host script for one step
  printf '# lane-remove:%s\n%s\n%s\n%s\n' "$1" "$pre" "$lib" "$2"
}

say() { printf 'lane-remove: %s\n' "$*"; }

release() {
  local out
  out="$(host_run "$(step release '
h="$(cat "$D/.lock/holder" 2>/dev/null)" || h=""
if [ "$h" = "$H" ]; then
  rm -rf "$D/.lock"
  if [ -e "$D/.lock" ]; then echo RELEASE-FAILED; else echo RELEASED; fi
else
  echo "NOT-MINE $h"
fi')" 2>/dev/null)"
  local rc=$?
  say "release: $out"
  # A foreign holder is never deleted and nothing of ours is left there; any other answer means
  # this run's lock may still block the next gate.
  case "$rc:$out" in
    0:RELEASED | "0:NOT-MINE "*) return 0 ;;
  esac
  say "FAIL release rc=$rc output=[$out] — this run's lock may remain at gate/$branch/.lock (holder: $holder); remove it only if that holder is still in it"
  return 1
}

# --- mkdir-lock --------------------------------------------------------------------------------
out="$(host_run "$(step mkdir-lock '
if p="$(symlink_in "$D")"; then echo "SYMLINK $p"; exit 0; fi
[ -d "$D" ] || { echo NOLANE; exit 0; }
[ -d "$D/work" ] || [ -e "$D/.lock" ] || { echo NOTALANE; exit 0; }
for c in "$D"/* "$D"/.[!.]* "$D"/..?*; do
  [ -d "$c" ] || continue
  case "${c##*/}" in work | .lock) ;; *) echo "NESTED ${c##*/}"; exit 0 ;; esac
done
[ ! -d "$D/work/work" ] || { echo "NESTED work/work"; exit 0; }
# Age BEFORE mkdir: taking the lock bumps the lane mtime. Strictly older than the bar, both read.
lm="$(mt "$D")"; wm="$(mt "$D/work")"
case "$lm" in "" | *[!0-9]*) echo "AGE-UNMEASURED lane"; exit 0 ;; esac
case "$wm" in "" | *[!0-9]*) echo "AGE-UNMEASURED work"; exit 0 ;; esac
[ $((N - lm)) -gt "$A" ] || { echo "YOUNG $((N - lm)) lane"; exit 0; }
[ $((N - wm)) -gt "$A" ] || { echo "YOUNG $((N - wm)) work"; exit 0; }
if ! mkdir "$D/.lock" 2>/dev/null; then
  h="$(cat "$D/.lock/holder" 2>/dev/null)" || h=unknown
  printf "LOCKED %s\n" "$(printf "%s" "$h" | tr "\t\r\n" "   ")"
  exit 0
fi
if ! printf "%s\n" "$H" > "$D/.lock/holder"; then
  rm -rf "$D/.lock"
  echo WRITEFAIL
  exit 0
fi
echo TAKEN')" 2>/dev/null)"
rc=$?
case "$out" in
  TAKEN) ;;
  "SYMLINK "*) refuse "symlink in the lane path: ${out#SYMLINK }" ;;
  "YOUNG "*) set -- ${out#YOUNG }; say "SKIP young ${1}s ($2) — not strictly older than ${LANE_MIN_AGE_S}s"; exit 0 ;;
  "AGE-UNMEASURED "*) say "SKIP UNMEASURED age (${out#AGE-UNMEASURED } mtime)"; exit 0 ;;
  "LOCKED "*) say "SKIP locked by ${out#LOCKED }"; exit 0 ;;
  NOLANE) say "SKIP no lane gate/$branch on the host"; exit 0 ;;
  NOTALANE) say "SKIP gate/$branch holds neither work/ nor .lock — not a lane"; exit 0 ;;
  "NESTED "*) say "SKIP gate/$branch holds ${out#NESTED } — another lane may live inside it"; exit 0 ;;
  WRITEFAIL) say "SKIP could not write the holder; the lock this run created was removed"; exit 0 ;;
  *)
    say "FAIL mkdir-lock rc=$rc output=[$out] — whether .lock was taken is unknown; read gate/$branch/.lock/holder (ours would be: $holder)"
    exit 1
    ;;
esac

# --- holder-readback ---------------------------------------------------------------------------
out="$(host_run "$(step holder-readback 'cat "$D/.lock/holder" 2>/dev/null')" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] || [ "$out" != "$holder" ]; then
  say "SKIP holder read-back mismatch (rc=$rc wrote=[$holder] read=[$out])"
  release || exit 1
  exit 0
fi

# --- re-probe ----------------------------------------------------------------------------------
collect_worktrees
collect_live
presence_for "$branch"
pv="$(presence_verdict)"
if [ -n "$pv" ]; then
  say "SKIP $pv (main=$P_MAIN lane=$P_LANE worktree=$P_WT origin=$P_ORIGIN live=$P_LIVE)"
  release || exit 1
  exit 0
fi

# --- mv ----------------------------------------------------------------------------------------
out="$(host_run "$(step mv '
case "$RP" in "$G"/.reaping-*) ;; *) echo BADPATH; exit 1 ;; esac
[ ! -e "$RP" ] || { echo EXISTS; exit 1; }
if p="$(symlink_in "$D")"; then echo "SYMLINK $p"; exit 1; fi
h="$(cat "$D/.lock/holder" 2>/dev/null)" || h=""
[ "$h" = "$H" ] || { echo "NOT-MINE $h"; exit 1; }
before="$(df -k "$DFP" 2>/dev/null | tail -n 1)"
mv "$D" "$RP" || { echo MVFAIL; exit 1; }
h2="$(cat "$RP/.lock/holder" 2>/dev/null)" || h2=""
[ "$h2" = "$H" ] || { echo "MOVED-LOCK-LOST $h2"; exit 1; }
# A gate for a descendant branch may have created its lane inside this one after the layout
# check; it travelled with the rename. One created from here on lands at the fresh "$D".
n="$(nested_in "$RP")"
if [ -n "$n" ]; then
  if [ -e "$D" ] || [ -L "$D" ]; then printf "NESTED-STUCK\t%s\n" "$n"; exit 1; fi
  mv "$RP" "$D" 2>/dev/null
  if [ ! -e "$RP" ] && [ "$(cat "$D/.lock/holder" 2>/dev/null)" = "$H" ]; then printf "NESTED-BACK\t%s\n" "$n"; exit 0; fi
  printf "NESTED-BACKFAIL\t%s\n" "$n"; exit 1
fi
kb="$(du -sk "$RP" 2>/dev/null)"
printf "MOVED\t%s\t%s\n" "${kb%%[[:space:]]*}" "${before:-UNMEASURED}"')" 2>/dev/null)"
rc=$?
case "$out" in
  "MOVED"$'\t'*) ;;
  "MOVED-LOCK-LOST"*)
    say "FAIL renamed to gate/$renamed_rel but the lock inside is not ours ([$out]); nothing removed — a human looks"
    exit 1
    ;;
  "NESTED-BACK"$'\t'*)
    say "SKIP nested lane appeared gate/$branch/${out#NESTED-BACK$'\t'} after the layout check — moved back to gate/$branch"
    release || exit 1
    exit 0
    ;;
  "NESTED-STUCK"$'\t'*)
    say "SKIP nested lane appeared gate/$renamed_rel/${out#NESTED-STUCK$'\t'} — gate/$branch was re-created meanwhile, so the tree stays at gate/$renamed_rel with this run's lock inside; nothing removed or released — a human looks"
    exit 1
    ;;
  "NESTED-BACKFAIL"$'\t'*)
    say "FAIL nested lane ${out#NESTED-BACKFAIL$'\t'} found after the rename and the move back to gate/$branch did not land; nothing removed or released — read gate/$branch and gate/$renamed_rel"
    exit 1
    ;;
  *)
    say "FAIL mv rc=$rc output=[$out]; nothing removed"
    release
    exit 1
    ;;
esac
removed_kb="$(printf '%s' "$out" | cut -f2)"
df_before="$(printf '%s' "$out" | cut -f3)"

# --- rm ----------------------------------------------------------------------------------------
out="$(host_run "$(step rm '
case "$RP" in "$G"/.reaping-*) ;; *) echo BADPATH; exit 1 ;; esac
if p="$(symlink_in "$RP")"; then echo "SYMLINK $p"; exit 1; fi
rm -rf "$RP"
if [ -e "$RP" ]; then echo STILL-THERE; exit 1; fi
echo GONE')" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] || [ "$out" != GONE ]; then
  say "FAIL rm of gate/$renamed_rel rc=$rc output=[$out] — the quarantine is left for a human"
  exit 1
fi

# --- df ----------------------------------------------------------------------------------------
df_after="$(host_run "$(step df 'df -k "$DFP" 2>/dev/null | tail -n 1')" 2>/dev/null)" || df_after=""

gib() { printf '%s' "$1" | awk 'NF >= 4 && $4 ~ /^[0-9]+$/ { printf "%.1f", $4 / 1048576; f = 1 } END { if (!f) printf "UNMEASURED" }'; }
free_before="$(gib "$df_before")"
free_after="$(gib "$df_after")"
case "$removed_kb" in '' | *[!0-9]*) removed_kb=UNMEASURED ;; esac

append_audit() {
  if [ ! -s "$LANE_REAPS_TSV" ]; then
    printf 'utc\tbranch\tremoved_kb\tfree_before_gib\tfree_after_gib\trenamed_path\n' >>"$LANE_REAPS_TSV" || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$utc" "$branch" "$removed_kb" "$free_before" "$free_after" "gate/$renamed_rel" >>"$LANE_REAPS_TSV"
}
say "REMOVED $branch removed_kb=$removed_kb free_before_gib=$free_before free_after_gib=$free_after renamed=gate/$renamed_rel"
if ! append_audit 2>/dev/null; then
  say "AUDIT-WRITE-FAILED $LANE_REAPS_TSV — the lane IS removed; the REMOVED line above is the only record of it"
  exit 1
fi
exit 0
