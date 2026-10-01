#!/usr/bin/env bash
# lane-inventory.sh — READ-ONLY inventory of this repo's gate lanes on the Mac build host.
#
# One TSV row per lane under `~/build/img-manager-ios/gate/<branch>/` (bin/mac-gate.sh:386-391),
# per `gate/.reaping-*` leftover and per scratch mirror ARCH-1064 names, then a TOTAL line (the
# candidate count and the sum of their size_kb) and a DF line (`df -k` of the host's data volume).
# Nothing on the host or on this machine is written: every probe is a read.
#
# The directory name IS the branch: bin/mac-gate.sh's `esc` only shell-quotes a `'` for the
# remote script, so `feature/x` lives at `gate/feature/x/` (nested) and `it's` at `gate/it's/`.
# A lane is a directory holding `work/` or `.lock`; `gate/.host.lock` is the host lock, not a
# lane, and is never listed.
#
# Verdicts. CANDIDATE = branch absent from every source (both clones' local branches, every
# worktree either lists — the lane clone's container paths read at their container counterpart —
# every worktree directory, hidden ones included, under the worktree roots, origin), lane lock free,
# lane and work mtimes both measured and strictly older than 24 h, branch not part of a live
# package. Anything else is `KEEP <reason>`, or `UNMEASURED <probe>` when a probe could not
# answer. UNMEASURED never means absent and is never a candidate.
#
# Exit: 0 when the host listing came back complete (rows may still be UNMEASURED); 3 when the
# host listing itself failed — then no lane row can be judged and none is printed.
#
# Every external is an env override so a fixture can stand in for it (scripts/lane-inventory-test.sh):
#   LANE_HOST_RUN        executable taking ONE argument, the command for the build host; unset = ssh
#   LANE_HOST            ssh alias of the build host (merkur.local from jupiter)
#   LANE_GATE_ROOT       gate root, expanded ON the host; only the production root
#                        `$HOME/build/img-manager-ios/gate` unless LANE_GATE_ROOT_FIXTURE=1 (tests)
#   LANE_DF_PATH         volume read by df on the host
#   LANE_MAIN_CLONE / LANE_LANE_CLONE      the two clones whose branches and worktrees count
#   LANE_HOST_PROJECTS / LANE_CONTAINER_PROJECTS
#                        a worktree the LANE clone lists under $LANE_HOST_PROJECTS/<repo>-wt/ is the
#                        container's view; it is probed at $LANE_CONTAINER_PROJECTS/... only
#   LANE_WT_ROOTS        space-separated roots whose every directory is probed as a worktree
#   LANE_TMUX_LS         command listing the lane container's tmux sessions
#   LANE_CHAIN_LOG       lane m's chain.log, as seen from this host
#   LANE_TICKET_READER   command printing ARCH-1064
#   LANE_NOW             epoch "now" (tests); LANE_MIN_AGE_S the age bar (24 h)
#
# Sourced (not executed) it defines its probes and prints nothing: scripts/lane-remove.sh re-runs
# the same branch probes under the lane's lock.

set -uo pipefail

: "${LANE_HOST:=merkur.local}"
: "${LANE_SSH_TIMEOUT:=300}"
: "${LANE_HOST_RUN:=}"
: "${LANE_GATE_ROOT:=\$HOME/build/img-manager-ios/gate}"
: "${LANE_DF_PATH:=/System/Volumes/Data}"
: "${LANE_MAIN_CLONE:=/home/fabian/projects/img-manager-ios}"
: "${LANE_LANE_CLONE:=/home/fabian/projects/img-manager-ios-lane}"
: "${LANE_HOST_PROJECTS:=/home/fabian/projects}"
: "${LANE_CONTAINER_PROJECTS:=/srv/appdata/pfadfinder-lane/home/projects}"
: "${LANE_WT_ROOTS:=/srv/appdata/pfadfinder-lane/home/projects/img-manager-ios-lane-wt /home/fabian/projects/img-manager-ios-wt}"
: "${LANE_TMUX_LS:=docker exec pfadfinder-lane tmux ls}"
: "${LANE_CHAIN_LOG:=/srv/appdata/pfadfinder-lane/home/.claude/pfadfinder/lanes/m/chain.log}"
: "${LANE_TICKET_READER:=node /home/fabian/projects/archimedes/lib/windshift.mjs item-by-key ARCH-1064}"
: "${LANE_NOW:=}"
: "${LANE_MIN_AGE_S:=86400}"
: "${LANE_GIT_TIMEOUT:=60}"

# Single-quote a value for a shell on the other side (the gate's own `esc`, wrapped).
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The host's login shell is zsh (a no-match glob is an error there), so every remote script runs
# under bash explicitly. ssh -n: nothing on stdin reaches the host.
host_run() {
  local wrapped
  wrapped="bash -c $(sq "$1")"
  if [ -n "$LANE_HOST_RUN" ]; then
    "$LANE_HOST_RUN" "$wrapped"
  else
    timeout "$LANE_SSH_TIMEOUT" ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$LANE_HOST" "$wrapped"
  fi
}

# Trust boundary: LANE_GATE_ROOT is expanded on the host and lane-remove.sh deletes below it, so
# only the production root is accepted; any other root needs LANE_GATE_ROOT_FIXTURE=1, which only
# the fixture suite sets. Both still refuse a root with characters outside [A-Za-z0-9._/$-].
LANE_PROD_GATE_ROOT='$HOME/build/img-manager-ios/gate'
gate_root_ok() {
  case "$LANE_GATE_ROOT" in
    *[!A-Za-z0-9._/\$-]* | "") return 1 ;;
  esac
  [ "$LANE_GATE_ROOT" = "$LANE_PROD_GATE_ROOT" ] || [ "${LANE_GATE_ROOT_FIXTURE:-}" = 1 ]
}

# --- branch presence ----------------------------------------------------------------------------

# yes | no | UNMEASURED — show-ref's own exit decides: 0 present, 1 absent, anything else unknown.
probe_local() {
  local clone="$1" branch="$2" rc
  [ -d "$clone" ] || { echo UNMEASURED; return; }
  git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"
  rc=$?
  case $rc in
    0) echo yes ;;
    1) echo no ;;
    *) echo UNMEASURED ;;
  esac
}

# yes | no | UNMEASURED — the full ref as the pattern, so `x/foo` never answers for `foo`.
probe_origin() {
  local branch="$1" out rc
  [ -d "$LANE_MAIN_CLONE" ] || { echo UNMEASURED; return; }
  out="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    timeout "$LANE_GIT_TIMEOUT" git -C "$LANE_MAIN_CLONE" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || { echo UNMEASURED; return; }
  if [ -z "$out" ]; then
    echo no
  elif printf '%s\n' "$out" | awk -v r="refs/heads/$branch" '$2 == r { f = 1 } END { exit !f }'; then
    echo yes
  else
    echo UNMEASURED
  fi
}

WT_BRANCHES=""   # one branch per line
WT_UNMEASURED="" # space-separated probe names that could not answer

wt_add() { WT_BRANCHES="$WT_BRANCHES$1"$'\n'; }
wt_unm() { WT_UNMEASURED="$WT_UNMEASURED${WT_UNMEASURED:+ }$1"; }

# The branch checked out in a worktree directory; a directory that is not a worktree (no .git)
# would let git answer for whatever repository encloses it, so it is a probe that cannot answer.
# The full symbolic ref, not `rev-parse --abbrev-ref`: a tag sharing the branch's name makes that
# answer `heads/<branch>`. symbolic-ref exits 1 for a detached HEAD (no branch checked out).
wt_head() {
  local dir="$1" head rc
  [ -e "$dir/.git" ] || { wt_unm "wt-not-a-worktree:$dir"; return; }
  head="$(git -C "$dir" symbolic-ref -q HEAD 2>/dev/null)"
  rc=$?
  case "$rc:$head" in
    0:refs/heads/?*) wt_add "${head#refs/heads/}" ;;
    1:) ;;
    *) wt_unm "wt-head:$dir" ;;
  esac
}

# Where a listed worktree is read. The lane clone records the CONTAINER's paths, so a path it lists
# under $LANE_HOST_PROJECTS/<repo>-wt/ is read at its container counterpart and only there: a host
# directory of the same name is some other worktree. Every other listed path is read as listed.
wt_probe_path() {
  local clone="$1" path="$2" probe="$2"
  if [ "$clone" = "$LANE_LANE_CLONE" ]; then
    case "$path" in
      "$LANE_HOST_PROJECTS"/*-wt/*) probe="$LANE_CONTAINER_PROJECTS/${path#"$LANE_HOST_PROJECTS"/}" ;;
    esac
  fi
  [ -d "$probe" ] || return 1
  printf '%s' "$probe"
}

collect_worktrees() {
  WT_BRANCHES=""
  WT_UNMEASURED=""
  local clone out line path probe root dir
  for clone in "$LANE_MAIN_CLONE" "$LANE_LANE_CLONE"; do
    [ -d "$clone" ] || { wt_unm "wt-list:$clone"; continue; }
    out="$(git -C "$clone" worktree list --porcelain 2>/dev/null)" || { wt_unm "wt-list:$clone"; continue; }
    while IFS= read -r line; do
      case "$line" in
        "branch refs/heads/"*) wt_add "${line#branch refs/heads/}" ;;
        "worktree "*)
          path="${line#worktree }"
          probe="$(wt_probe_path "$clone" "$path")" || { wt_unm "wt-missing:$path"; continue; }
          wt_head "$probe"
          ;;
      esac
    done <<<"$out"
  done
  for root in $LANE_WT_ROOTS; do
    [ -d "$root" ] || { wt_unm "wt-root:$root"; continue; }
    # Readability first, by commands whose status is checked: a glob over a root that cannot be
    # read or searched expands to nothing and would pass for an empty root.
    { ls -A "$root" >/dev/null && (cd "$root"); } 2>/dev/null || { wt_unm "wt-root-unreadable:$root"; continue; }
    # Enumeration by glob, never by splitting a listing on newlines: a directory name may hold one.
    for dir in "$root"/* "$root"/.[!.]* "$root"/..?*; do
      [ -d "$dir" ] && wt_head "$dir"
    done
  done
}

# yes | no | UNMEASURED for one branch against the collected worktree set.
wt_presence() {
  if printf '%s' "$WT_BRANCHES" | grep -Fxq -- "$1"; then
    echo yes
  elif [ -n "$WT_UNMEASURED" ]; then
    echo UNMEASURED
  else
    echo no
  fi
}

# --- live packages ------------------------------------------------------------------------------

LIVE_IDS=""      # milestone ids of live packages, space-separated
LIVE_STATE="ok"  # or "UNMEASURED <probe>"

collect_live() {
  LIVE_IDS=""
  LIVE_STATE="ok"
  local out rc last
  out="$(bash -c "$LANE_TMUX_LS" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    LIVE_IDS="$(printf '%s\n' "$out" | sed -n 's/^wp\([0-9][0-9]*\):.*/\1/p' | tr '\n' ' ')"
  elif ! printf '%s' "$out" | grep -q 'no server running'; then
    LIVE_STATE="UNMEASURED tmux"
  fi
  if [ ! -r "$LANE_CHAIN_LOG" ]; then
    LIVE_STATE="UNMEASURED chain-log"
    return
  fi
  # The chain's most recent launch/adopt with no CHAIN EXIT after it is a package still running.
  # grep's own status: 1 is a log with no such line, anything above is a read that failed
  # (-r passes for a directory, for instance) and never means "not live".
  last="$(grep -E ' (LAUNCH|ADOPT) milestone [0-9]+| CHAIN EXIT ' "$LANE_CHAIN_LOG" 2>/dev/null)"
  rc=$?
  case $rc in
    0) last="$(printf '%s\n' "$last" | tail -n 1)" ;;
    1) last="" ;;
    *) LIVE_STATE="UNMEASURED chain-log"; return ;;
  esac
  case "$last" in
    *" LAUNCH milestone "* | *" ADOPT milestone "*)
      LIVE_IDS="$LIVE_IDS $(printf '%s\n' "$last" | sed -n 's/.* \(LAUNCH\|ADOPT\) milestone \([0-9][0-9]*\).*/\2/p')"
      ;;
  esac
}

# yes:<id> | no | UNMEASURED — the chain attributes a worktree to a milestone when its branch
# carries the id (lane m's CHECKPOINT lines); digit-bounded so 36 never matches 362.
live_for() {
  local branch="$1" id
  case "$LIVE_STATE" in UNMEASURED*) echo UNMEASURED; return ;; esac
  for id in $LIVE_IDS; do
    if printf '%s' "$branch" | grep -Eq "(^|[^0-9])$id([^0-9]|\$)"; then
      echo "yes:wp$id"
      return
    fi
  done
  echo no
}

# Fills P_MAIN P_LANE P_WT P_ORIGIN P_LIVE for one branch; collect_worktrees and collect_live first.
presence_for() {
  local branch="$1"
  P_MAIN="$(probe_local "$LANE_MAIN_CLONE" "$branch")"
  P_LANE="$(probe_local "$LANE_LANE_CLONE" "$branch")"
  P_WT="$(wt_presence "$branch")"
  P_ORIGIN="$(probe_origin "$branch")"
  P_LIVE="$(live_for "$branch")"
}

# The branch-side verdict: "" when absent everywhere and not live, else KEEP/UNMEASURED.
presence_verdict() {
  local present="" unm=""
  [ "$P_MAIN" = yes ] && present="$present,main-clone"
  [ "$P_LANE" = yes ] && present="$present,lane-clone"
  [ "$P_WT" = yes ] && present="$present,worktree"
  [ "$P_ORIGIN" = yes ] && present="$present,origin"
  if [ -n "$present" ]; then
    echo "KEEP present:${present#,}"
    return
  fi
  case "$P_LIVE" in yes:*) echo "KEEP live ${P_LIVE#yes:}"; return ;; esac
  [ "$P_MAIN" = UNMEASURED ] && unm="$unm main-clone"
  [ "$P_LANE" = UNMEASURED ] && unm="$unm lane-clone"
  [ "$P_WT" = UNMEASURED ] && unm="$unm worktree($WT_UNMEASURED)"
  [ "$P_ORIGIN" = UNMEASURED ] && unm="$unm origin"
  [ "$P_LIVE" = UNMEASURED ] && unm="$unm live(${LIVE_STATE#UNMEASURED })"
  [ -n "$unm" ] && echo "UNMEASURED${unm}"
}

# Verdict for a lane or a .reaping-* row, given the host's readings and the P_* presence.
judge() {
  local layout="$1" lock="$2" lmt="$3" wmt="$4" size="$5" now="$6" pv
  [ "$layout" = ok ] || { echo "UNMEASURED layout($layout)"; return; }
  case "$lock" in
    free) ;;
    "LOCKED by "*) echo "KEEP locked"; return ;;
    *) echo "UNMEASURED lock"; return ;;
  esac
  pv="$(presence_verdict)"
  [ -z "$pv" ] || { echo "$pv"; return; }
  # A missing work/ (`-`) is an age that was not measured, never one that qualifies.
  case "$lmt" in '' | *[!0-9]*) echo "UNMEASURED mtime"; return ;; esac
  case "$wmt" in '' | *[!0-9]*) echo "UNMEASURED mtime"; return ;; esac
  # Strictly older than the bar: exactly 24 h is still young.
  if [ $((now - lmt)) -le "$LANE_MIN_AGE_S" ]; then echo "KEEP young(lane)"; return; fi
  if [ $((now - wmt)) -le "$LANE_MIN_AGE_S" ]; then echo "KEEP young(work)"; return; fi
  case "$size" in '' | *[!0-9]*) echo "UNMEASURED du"; return ;; esac
  echo CANDIDATE
}

# `.reaping-<branch, / as %2F, % as %25>-<UTC>` back to the branch (lane-remove.sh writes it).
reaping_branch() {
  local name="$1" flat
  [[ "$name" =~ ^\.reaping-(.+)-([0-9]{8}T[0-9]{6}Z)$ ]] || return 1
  flat="${BASH_REMATCH[1]}"
  printf '%s' "$flat" | sed 's/%2F/\//g; s/%25/%/g'
}

utc_of() {
  case "$1" in '' | *[!0-9]*) printf '%s' "$1" ;; *) date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ ;; esac
}

# --- the host listing ---------------------------------------------------------------------------

# Paths ARCH-1064 names, `~/build/...` only, plain characters only: the ticket is data and never
# reaches the host as anything but a quoted path.
ticket_paths() {
  local full base rel=""
  full="$(printf '%s' "$1" | grep -oE '~/build/[A-Za-z0-9._/-]+' | sed 's/[./]*$//')"
  # ARCH-1064 names the second mirror relative to the first one's repo dir
  # (`~/build/repaso-es-ios/work.noindex/pf367-int-tmp` ... `gate.noindex/pf367-int-tmp`).
  base="$(printf '%s\n' "$full" | sed -n 's#^\(~/build/[A-Za-z0-9._-]*\)/[A-Za-z0-9._-]*\.noindex/.*#\1#p' | head -n 1)"
  [ -z "$base" ] || rel="$(printf '%s' "$1" | grep -oE '`[A-Za-z0-9._-]+\.noindex/[A-Za-z0-9._/-]+`' | tr -d '`' | sed "s#^#$base/#")"
  printf '%s\n%s\n' "$full" "$rel" | grep -v '^$' | grep -v '/\.\./\|/\.\.$' | sort -u
}

remote_list_script() {
  local p
  printf 'G="%s"\nDFP=%s\n' "$LANE_GATE_ROOT" "$(sq "$LANE_DF_PATH")"
  cat <<'EOS'
mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo UNMEASURED; }
sz() { local o; o="$(du -sk "$1" 2>/dev/null)" && [ -n "$o" ] && { echo "${o%%[[:space:]]*}"; return; }; echo UNMEASURED; }
lockstate() {
  local l="$1/.lock" h
  if [ -e "$l" ] || [ -L "$l" ]; then
    if [ -d "$l" ] && [ -f "$l/holder" ] && h="$(cat "$l/holder" 2>/dev/null)"; then
      printf 'LOCKED by %s\n' "$(printf '%s' "$h" | tr '\t\r\n' '   ')"
    else
      echo UNMEASURED
    fi
  else
    echo free
  fi
}
layout() {
  local c
  for c in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -d "$c" ] || continue
    case "${c##*/}" in work | .lock) ;; *) echo nested; return ;; esac
  done
  if [ -d "$1/work/work" ]; then echo nested; else echo ok; fi
}
row() {
  local wm="-"
  [ -d "$3/work" ] && wm="$(mt "$3/work")"
  printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(sz "$3")" "$(mt "$3")" "$wm" "$(lockstate "$3")" "$(layout "$3")"
}
walk() {
  local d="$1" rel="$2" c n
  for c in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [ -d "$c" ] && [ ! -L "$c" ] || continue
    n="${c##*/}"
    if [ -z "$rel" ]; then
      case "$n" in
        .host.lock) continue ;;
        .reaping-*) row reaping "$n" "$c"; continue ;;
      esac
    fi
    if [ -d "$c/work" ] || [ -e "$c/.lock" ]; then row lane "$rel$n" "$c"; else walk "$c" "$rel$n/"; fi
  done
}
scratch() {
  if [ -e "$1" ]; then
    printf 'ROW\tscratch\t%s\t%s\t%s\t-\t-\tok\n' "$2" "$(sz "$1")" "$(mt "$1")"
  else
    printf 'ROW\tscratch\t%s\tABSENT\t-\t-\t-\tok\n' "$2"
  fi
}
if [ -d "$G" ]; then walk "$G" ""; else echo "NOROOT"; fi
EOS
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf 'scratch "$HOME"/%s %s\n' "$(sq "${p#\~/}")" "$(sq "$p")"
  done <<<"$SCRATCH_PATHS"
  cat <<'EOS'
d="$(df -k "$DFP" 2>/dev/null | tail -n 1)"
printf 'DF\t%s\n' "${d:-UNMEASURED}"
echo END
EOS
}

main() {
  local now listing rc ticket trc tag kind rel size lmt wmt lock layout branch verdict
  local candidates=0 cand_kb=0 df_line="UNMEASURED" rows="" end_seen=0 root_missing=0
  now="${LANE_NOW:-$(date +%s)}"
  gate_root_ok || { echo "lane-inventory: REFUSED: LANE_GATE_ROOT is not $LANE_PROD_GATE_ROOT (without LANE_GATE_ROOT_FIXTURE=1) or has characters outside [A-Za-z0-9._/\$-]" >&2; exit 2; }

  SCRATCH_PATHS=""
  ticket="$(bash -c "$LANE_TICKET_READER" 2>/dev/null)"
  trc=$?
  [ "$trc" -eq 0 ] && SCRATCH_PATHS="$(ticket_paths "$ticket")"

  listing="$(host_run "$(remote_list_script)" 2>/dev/null)"
  rc=$?

  printf 'kind\tpath\tbranch\tsize_kb\tlane_mtime_utc\twork_mtime_utc\tlock\tmain_local\tlane_local\tworktree\torigin\tlive\tverdict\n'
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$listing" | grep -qx END; then
    printf 'HOST\t%s\t-\t-\t-\t-\tUNMEASURED\t-\t-\t-\t-\t-\tUNMEASURED host-listing(rc=%s)\n' "$LANE_HOST" "$rc"
    printf 'TOTAL\tcandidates=0\tcandidate_kb=0\n'
    printf 'DF\t%s\tUNMEASURED\n' "$LANE_DF_PATH"
    exit 3
  fi

  collect_worktrees
  collect_live
  [ "$trc" -eq 0 ] || printf 'scratch\tARCH-1064\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tUNMEASURED ticket-reader(rc=%s)\n' "$trc"

  while IFS=$'\t' read -r tag kind rel size lmt wmt lock layout; do
    case "$tag" in
      NOROOT) root_missing=1; continue ;;
      DF) df_line="$kind"; continue ;;
      ROW) ;;
      *) continue ;;
    esac
    case "$kind" in
      scratch)
        if [ "$size" = ABSENT ]; then
          verdict="KEEP absent-on-host (ARCH-1064 scratch)"
          printf 'scratch\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$rel" "$verdict"
        else
          verdict="KEEP scratch (ARCH-1064, not an img-manager lane; lane-remove never takes it)"
          printf 'scratch\t%s\t-\t%s\t%s\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$rel" "$size" "$(utc_of "$lmt")" "$verdict"
        fi
        continue
        ;;
      lane) branch="$rel" ;;
      reaping)
        if ! branch="$(reaping_branch "$rel")"; then
          printf 'reaping\t%s\t?\t%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\tUNMEASURED reaping-name\n' \
            "$rel" "$size" "$(utc_of "$lmt")" "$(utc_of "$wmt")" "$lock"
          continue
        fi
        ;;
      *) continue ;;
    esac
    presence_for "$branch"
    verdict="$(judge "$layout" "$lock" "$lmt" "$wmt" "$size" "$now")"
    if [ "$verdict" = CANDIDATE ]; then
      candidates=$((candidates + 1))
      cand_kb=$((cand_kb + size))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$rel" "$branch" "$size" \
      "$(utc_of "$lmt")" "$(utc_of "$wmt")" "$lock" "$P_MAIN" "$P_LANE" "$P_WT" "$P_ORIGIN" "$P_LIVE" "$verdict"
  done <<<"$listing"

  [ "$root_missing" -eq 0 ] || printf 'HOST\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\tgate root absent (no lanes)\n' "$LANE_GATE_ROOT"
  printf 'TOTAL\tcandidates=%s\tcandidate_kb=%s\n' "$candidates" "$cand_kb"
  if [ "$df_line" = UNMEASURED ]; then
    printf 'DF\t%s\tUNMEASURED\n' "$LANE_DF_PATH"
  else
    printf 'DF\t%s\tavail_kb=%s\tfree_gib=%s\t%s\n' "$LANE_DF_PATH" "$(printf '%s' "$df_line" | awk '{print $4}')" \
      "$(printf '%s' "$df_line" | awk '{printf "%.1f", $4 / 1048576}')" "$df_line"
  fi
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
