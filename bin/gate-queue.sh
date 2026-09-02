#!/usr/bin/env bash
#
# gate-queue.sh — the serial mac-gate queue and its control surface (IMGMGR-335).
#
# WHY A QUEUE: bin/mac-gate.sh drives one shared Mac. Concurrent runs pile up on Xcode and
# SwiftPM global locks until the gate's own wall-clock cap kills them (2026-08-30: five lanes
# gated for ~2.5 h with zero usable runs). Every run from this machine therefore goes through
# one jupiter-local flock, and the checkout of the gated ref happens INSIDE that lock so a
# queued run can never move a worktree's HEAD under a running one. This file is the
# checked-in successor of the session-local prototype ~/projects/worktrees/wp13-gate-queue-v4.sh;
# the enqueue leg's semantics are that prototype's, unchanged.
#
# WHY `drop` PARSES ARGV: replacing a queued spec means killing the `flock` process that is
# still waiting for the lock. Finding it with `pgrep -f '<worktree>:<sha>:<label>'` matches the
# CALLER's own command line — the pattern is a literal in it — and the caller kills itself.
# That happened three times (2026-08-30 ×2, 2026-09-01). So the queue writes a record per spec,
# `drop` takes the pid from that record, and it signals only after /proc/<pid>/cmdline parses,
# NUL-split into argv entries, as this script's own `__run` invocation of that exact label:
#
#     argv[0]        basename == flock
#     argv[i]        basename == this script's own name, for some i >= 1
#     argv[i+1..i+4] == __run  <worktree>  <ref>  <label>   (all four exact, whole entries)
#
# and never when the pid is this process, its parent, <= 1, dead, or in state running/done.
# No substring ever matches a whole command line here.
#
# Usage:
#   bin/gate-queue.sh enqueue <worktree>:<ref>:<label> [<worktree>:<ref>:<label> …]
#   bin/gate-queue.sh list
#   bin/gate-queue.sh drop <label> [--dry-run]
#   bin/gate-queue.sh --help
#
# enqueue runs the specs strictly in order, one at a time, each one: wait for the lock ->
# refuse a dirty tree -> checkout <ref> -> MAC_GATE_HOST=merkur MAC_GATE_BRANCH=<the worktree's
# branch> bin/mac-gate.sh > <worktree>/.gate-artifacts/queue-<label>-<HHMMSS>.log -> copy the
# run's test-iphone/test-ipad logs beside it (a RED run's logs are overwritten by the next
# run's copyback) -> restore the branch -> append the summary line. Launch it detached, e.g.
#   setsid nohup bin/gate-queue.sh enqueue "$PWD:$(git rev-parse HEAD):lane-a" >/dev/null 2>&1 &
#
# STATE: one record per label under $GATE_QUEUE_STATE, `key=value` lines, written by the
# processes that own the transitions and never inferred by an observer: the enqueue process
# writes `waiting` (and the flock pid), the run itself writes `running` (and its own pid) as
# its first action inside the lock, and the enqueue process writes `done rc=<n>` when the run
# returns. `list` reads the records back and adds a `kill -0` liveness note per pid.
#
# Environment:
#   GATE_QUEUE_LOCK     lock file that serializes the runs
#                       (default: /home/fabian/projects/worktrees/.wp13-gate.lock)
#   GATE_QUEUE_STATE    directory holding the <label>.spec records
#                       (default: /home/fabian/projects/worktrees/.gate-queue/)
#   GATE_QUEUE_SUMMARY  file the one-line per-run summaries are appended to
#                       (default: /home/fabian/projects/worktrees/wp13-gate-queue.summary)
#
# Exit codes:
#   0  the command did what it says (enqueue: every spec's gate returned 0)
#   1  enqueue only: at least one spec's gate returned non-zero (per-spec rc is in the record
#      and in the summary line)
#   2  usage error, or a spec/label this script will not accept
#   3  drop refused: the spec is not `waiting` (a gate is running under it, or it is finished)
#   4  drop refused: there is no record for that label
#   5  drop refused: the recorded pid failed the argv verification above (own/parent pid, not
#      alive, unreadable, or not this script's `__run` of that label)
#
# Linux only: `drop` reads /proc/<pid>/cmdline. The queue is jupiter-local by design — the Mac
# side is guarded by mac-gate.sh's own host-wide lock.
set -uo pipefail

self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
self_name="$(basename "$0")"
LOCK="${GATE_QUEUE_LOCK:-/home/fabian/projects/worktrees/.wp13-gate.lock}"
STATE="${GATE_QUEUE_STATE:-/home/fabian/projects/worktrees/.gate-queue/}"
STATE="${STATE%/}"
SUMMARY="${GATE_QUEUE_SUMMARY:-/home/fabian/projects/worktrees/wp13-gate-queue.summary}"
LOCK_WAIT=21600

die() { local code=$1; shift; printf '%s: %s\n' "$self_name" "$*" >&2; exit "$code"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
rec_file() { printf '%s/%s.spec' "$STATE" "$1"; }

# rec_set LABEL key=value … — replace those keys in the record (append if new), holding a
# per-record lock so the run process and the enqueue process cannot clobber each other.
rec_set() {
  local label=$1 rec kv key val line out found
  shift
  rec="$(rec_file "$label")"
  mkdir -p "$STATE"
  exec 9>>"$STATE/.$label.lock"
  flock 9
  [ -f "$rec" ] || : > "$rec"
  for kv in "$@"; do
    key=${kv%%=*}; val=${kv#*=}
    out=""; found=0
    while IFS= read -r line; do
      if [ "${line%%=*}" = "$key" ]; then out="$out$key=$val"$'\n'; found=1
      else out="$out$line"$'\n'; fi
    done < "$rec"
    [ "$found" -eq 1 ] || out="$out$key=$val"$'\n'
    printf '%s' "$out" > "$rec"
  done
  exec 9>&-
}

rec_get() { # LABEL KEY — print the value, or nothing
  local rec line
  rec="$(rec_file "$1")"
  [ -f "$rec" ] || return 1
  while IFS= read -r line; do
    [ "${line%%=*}" = "$2" ] && { printf '%s\n' "${line#*=}"; return 0; }
  done < "$rec"
  return 1
}

pid_note() { # PID — "1234 alive" / "1234 dead" / "-"
  case "${1:-}" in
    ''|*[!0-9]*) printf -- '-' ;;
    *) if kill -0 "$1" 2>/dev/null; then printf '%s alive' "$1"; else printf '%s dead' "$1"; fi ;;
  esac
}

# read_argv PID — fill the global array QARGV from /proc/PID/cmdline, NUL-split.
QARGV=()
read_argv() {
  local a
  QARGV=()
  [ -r "/proc/$1/cmdline" ] || return 1
  while IFS= read -r -d '' a; do QARGV+=("$a"); done < "/proc/$1/cmdline"
  [ "${#QARGV[@]}" -gt 0 ]
}

# verify_waiting_pid PID LABEL — 0 when PID is provably this script's own waiting flock parent
# for LABEL. Sets vmsg with the reason on refusal. See the argv rule in the header.
vmsg=""
verify_waiting_pid() {
  local pid=$1 label=$2 wt ref i n
  vmsg=""
  case "$pid" in
    ''|*[!0-9]*) vmsg="the record for '$label' holds no usable pid ('$pid') — the spec has not been launched yet"; return 1 ;;
  esac
  [ "$pid" -gt 1 ] || { vmsg="refusing to signal pid $pid"; return 1; }
  [ "$pid" != "$$" ] || { vmsg="refusing to signal pid $pid: that is this process"; return 1; }
  [ "$pid" != "$PPID" ] || { vmsg="refusing to signal pid $pid: that is this process's parent — the shell that ran the drop. This is exactly the self-kill a 'pgrep -f <label>' produces."; return 1; }
  kill -0 "$pid" 2>/dev/null || { vmsg="pid $pid from the record for '$label' is not alive (or not ours); nothing to signal"; return 1; }
  read_argv "$pid" || { vmsg="cannot read /proc/$pid/cmdline; refusing to signal a pid whose argv cannot be verified"; return 1; }
  [ "$(basename "${QARGV[0]}")" = "flock" ] || {
    vmsg="pid $pid is '${QARGV[0]}', not a waiting flock parent; refusing"; return 1; }
  wt="$(rec_get "$label" worktree)" || wt=""
  ref="$(rec_get "$label" ref)" || ref=""
  n=${#QARGV[@]}
  i=1
  while [ "$i" -lt "$n" ]; do
    if [ "$(basename "${QARGV[$i]}")" = "$self_name" ] && [ $((i + 4)) -lt "$n" ] \
       && [ "${QARGV[$((i + 1))]}" = "__run" ] \
       && [ "${QARGV[$((i + 2))]}" = "$wt" ] \
       && [ "${QARGV[$((i + 3))]}" = "$ref" ] \
       && [ "${QARGV[$((i + 4))]}" = "$label" ]; then
      return 0
    fi
    i=$((i + 1))
  done
  vmsg="pid $pid does not parse as '$self_name __run $wt $ref $label …' (argv: ${QARGV[*]}); refusing to signal it"
  return 1
}

cmd_help() {
  sed -n '2,/^set -uo/p' "$self_path" | sed -e 's/^# \{0,1\}//' -e '/^set -uo/d'
}

# __run WORKTREE REF LABEL LOG — the gated run itself; only ever started by enqueue, and only
# with the queue lock held. Semantics unchanged from wp13-gate-queue-v4.sh.
cmd_run() {
  local wt=$1 ref=$2 label=$3 log=$4 branch rc
  rec_set "$label" "state=running" "run_pid=$$" "started=$(now)"
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
  [ -z "$(git -C "$wt" status --porcelain)" ] || { echo "DIRTY-TREE" > "$log"; exit 97; }
  git -C "$wt" checkout -q "$ref" || { echo "CHECKOUT-FAIL $ref" > "$log"; exit 98; }
  ( cd "$wt" && MAC_GATE_HOST=merkur MAC_GATE_BRANCH="$branch" bin/mac-gate.sh ) > "$log" 2>&1
  rc=$?
  cp "$wt/.gate-artifacts/test-iphone.log" "${log%.log}-test-iphone.log" 2>/dev/null
  cp "$wt/.gate-artifacts/test-ipad.log" "${log%.log}-test-ipad.log" 2>/dev/null
  git -C "$wt" checkout -q "$branch"
  exit "$rc"
}

cmd_enqueue() {
  [ $# -ge 1 ] || die 2 "enqueue needs at least one <worktree>:<ref>:<label> spec"
  local spec wt rest ref label log fpid rc worst=0 prev
  mkdir -p "$STATE"
  for spec in "$@"; do
    case "$spec" in
      *:*:*) ;;
      *) die 2 "bad spec '$spec': want <worktree>:<ref>:<label>" ;;
    esac
    wt=${spec%%:*}; rest=${spec#*:}; ref=${rest%%:*}; label=${rest#*:}
    case "$label" in
      ''|*[!A-Za-z0-9._-]*) die 2 "bad label '$label': the record is a file name, so a label may hold only [A-Za-z0-9._-]" ;;
    esac
    [ -d "$wt" ] || die 2 "no such worktree: $wt"
    [ -x "$wt/bin/mac-gate.sh" ] || die 2 "$wt/bin/mac-gate.sh is missing or not executable"
    prev="$(rec_get "$label" state)" || prev=""
    case "$prev" in
      waiting|running) die 2 "a spec named '$label' is already $prev (pid $(rec_get "$label" flock_pid)); pick another label, or drop it first" ;;
    esac
    mkdir -p "$wt/.gate-artifacts"
    log="$wt/.gate-artifacts/queue-$label-$(date +%H%M%S).log"
    : > "$(rec_file "$label")"
    rec_set "$label" "spec=$spec" "worktree=$wt" "ref=$ref" "label=$label" "log=$log" \
      "enqueue_pid=$$" "flock_pid=" "run_pid=" "state=waiting" "rc=" "enqueued=$(now)"
    flock -w "$LOCK_WAIT" "$LOCK" "$self_path" __run "$wt" "$ref" "$label" "$log" &
    fpid=$!
    rec_set "$label" "flock_pid=$fpid"
    wait "$fpid"
    rc=$?
    rec_set "$label" "state=done" "rc=$rc" "finished=$(now)"
    echo "$(date +%H:%M) $label ref=$ref rc=$rc $(grep -o 'mac-gate SUMMARY:.*' "$log" 2>/dev/null | tail -1) log=$log" >> "$SUMMARY"
    [ "$rc" -eq 0 ] || worst=1
  done
  echo "$(date +%H:%M) QUEUE-DONE($*)" >> "$SUMMARY"
  return "$worst"
}

cmd_list() {
  local rec label st holder="unknown (no record is in state=running)" n=0
  echo "lock    : $LOCK"
  echo "state   : $STATE"
  echo "summary : $SUMMARY"
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    [ "$(rec_get "$label" state)" = "running" ] || continue
    holder="$label (run pid $(pid_note "$(rec_get "$label" run_pid)"))"
  done
  echo "holder  : $holder   # flock has no holder API; this is derived from the records"
  echo
  printf '%-22s %-8s %-4s %-16s %-16s %s\n' LABEL STATE RC "ENQUEUE PID" "FLOCK/RUN PID" REF
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    n=$((n + 1))
    st="$(rec_get "$label" state)"
    printf '%-22s %-8s %-4s %-16s %-16s %s\n' \
      "$label" "${st:-?}" "$(rec_get "$label" rc)" \
      "$(pid_note "$(rec_get "$label" enqueue_pid)")" \
      "$(pid_note "$(rec_get "$label" flock_pid)")/$(pid_note "$(rec_get "$label" run_pid)")" \
      "$(rec_get "$label" ref)"
  done
  [ "$n" -gt 0 ] || echo "(no spec records)"
  echo
  echo "last summary lines ($SUMMARY):"
  tail -n 5 "$SUMMARY" 2>/dev/null || echo "(none)"
}

cmd_drop() {
  local label="" dry=0 a pid st i
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -*) die 2 "drop: unknown option '$a'" ;;
      *) [ -z "$label" ] || die 2 "drop takes exactly one <label>"; label="$a" ;;
    esac
  done
  [ -n "$label" ] || die 2 "drop needs a <label> (see: $self_name list)"
  [ -f "$(rec_file "$label")" ] || die 4 "no spec record for '$label' in $STATE (see: $self_name list)"
  st="$(rec_get "$label" state)" || st=""
  case "$st" in
    waiting) ;;
    running) die 3 "refusing to drop '$label': a gate is RUNNING under it (run pid $(rec_get "$label" run_pid), log $(rec_get "$label" log)). drop only kills a spec still waiting for the lock; let this one finish, or stop it on the Mac first." ;;
    done) die 3 "refusing to drop '$label': it already finished (rc=$(rec_get "$label" rc)); nothing to kill." ;;
    *) die 3 "refusing to drop '$label': unexpected state '$st'" ;;
  esac
  pid="$(rec_get "$label" flock_pid)" || pid=""
  verify_waiting_pid "$pid" "$label" || die 5 "$vmsg"
  if [ "$dry" -eq 1 ]; then
    echo "DRY-RUN: would send SIGTERM to pid $pid — the flock parent of spec '$label' (state=waiting)"
    echo "  argv: ${QARGV[*]}"
    echo "  nothing was signalled."
    return 0
  fi
  kill -TERM "$pid" || die 5 "kill -TERM $pid failed"
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "SIGTERM sent to pid $pid, but it is still alive after 5 s — check '$self_name list'" >&2
    return 5
  fi
  echo "dropped '$label': pid $pid (waiting flock parent) terminated"
  i=0
  while [ "$i" -lt 50 ] && [ "$(rec_get "$label" state)" = "waiting" ]; do sleep 0.1; i=$((i + 1)); done
  if [ "$(rec_get "$label" state)" = "waiting" ]; then
    rec_set "$label" "state=done" "rc=143" "finished=$(now)" "dropped_by=$$"
    echo "its enqueue process (pid $(rec_get "$label" enqueue_pid)) did not record the end, so this drop did: state=done rc=143"
  fi
  return 0
}

case "${1:---help}" in
  enqueue) shift; cmd_enqueue "$@" ;;
  list) shift; [ $# -eq 0 ] || die 2 "list takes no arguments"; cmd_list ;;
  drop) shift; cmd_drop "$@" ;;
  __run) shift; [ $# -eq 4 ] || die 2 "__run is internal: __run <worktree> <ref> <label> <log>"; cmd_run "$@" ;;
  --help|-h|help) cmd_help ;;
  *) die 2 "unknown command '$1' (enqueue | list | drop | --help)" ;;
esac
