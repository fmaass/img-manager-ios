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
# `drop` takes the pid from that record, and no signal is ever sent until the pid is PROVEN to
# be the flock parent of exactly that spec of exactly this queue. The proof, all of it required:
#
#   record   state == waiting, and the record's `lock` is the lock this invocation would use
#   /proc/<pid>/cmdline, NUL-split into argv entries:
#     argv[0]        basename == flock
#     then flock's OWN options are walked and skipped (-w/--wait/--timeout, -E/--conflict-exit-code
#                      and -c/--command with their values, attached -wN forms, --opt=value forms,
#                      the valueless flags, and a terminating --); an option flock does not have
#                      refuses the drop rather than guessing where the operand is
#     the first non-option entry == the resolved lock path — flock's lock OPERAND, so no flock
#                      of any other lock file can match, wherever the path also appears
#     the entry after it == this script (same path string, or the same file by inode)
#     the next four    == __run  <worktree>  <ref>  <label>   (all four exact, whole entries)
#   /proc/<pid>/stat field 22 (start time) == the record's `flock_start`, recorded when the
#                      process was spawned — a recycled pid cannot pass
#   /proc/<pid>/task/<pid>/children empty — a flock that has already forked its run child
#                      holds the lock and is no longer waiting
#   pid              is not this process, not its parent, and not <= 1
#
# No substring ever matches a whole command line here, and nothing is ever searched for by name.
# Accepted residual: bash has no signal-by-identity primitive, so a pid could in principle be
# recycled between the re-check and the kill — a microsecond window inside the per-record lock
# that needs a full pid wraparound to hit, and the start-time match rejects any other process
# at check time; it is accepted rather than mitigated.
#
# WHY A PER-RECORD LOCK: `drop` must not read `state=waiting`, then have the run acquire the
# queue lock, and only then land its signal. The run's first act inside the queue lock is to
# write `state=running` while holding `<state dir>/<label>.lock`, and `drop` holds that same
# lock across read-state -> verify -> signal, so the two cannot interleave. A run that finds
# `drop_requested` in its record — set by drop under that lock — exits 99 without touching the
# worktree, which closes the last window (a fork that happened between the children check and
# the signal).
#
# Usage:
#   bin/gate-queue.sh enqueue <worktree>:<ref>:<label> [<worktree>:<ref>:<label> …]
#   bin/gate-queue.sh list
#   bin/gate-queue.sh drop <label> [--dry-run] [--lock-wait <seconds>]
#   bin/gate-queue.sh --help
#
# enqueue runs the specs strictly in order, one at a time, each one: wait for the lock ->
# refuse a dirty tree -> checkout <ref> -> MAC_GATE_HOST=merkur MAC_GATE_BRANCH=<the worktree's
# branch> bin/mac-gate.sh > <worktree>/.gate-artifacts/queue-<label>-<HHMMSS>.log -> copy the
# run's test-iphone/test-ipad logs beside it (a RED run's logs are overwritten by the next
# run's copyback) -> restore the branch -> append the summary line. Launch it detached, e.g.
#   setsid nohup bin/gate-queue.sh enqueue "$PWD:$(git rev-parse HEAD):lane-a" >/dev/null 2>&1 &
# A label may hold only [A-Za-z0-9._-] (it is a file name), and its record is created with
# O_EXCL, so two concurrent enqueues of one label admit exactly one: the loser exits 2.
#
# STATE: one record per label under $GATE_QUEUE_STATE, `key=value` lines, written by the
# processes that own the transitions and never inferred by an observer: the enqueue process
# writes `waiting`, the flock pid and its start time, the run writes `running` and its own pid
# as its first action inside the lock, and the enqueue process writes `done rc=<n>` when the
# run returns (if a drop outlives its enqueue process, the drop records the end and says so).
# `list` reads the records back and adds a `kill -0` liveness note per pid.
#
# Environment:
#   GATE_QUEUE_LOCK     lock file that serializes the runs; resolved to an absolute path and
#                       bound into every record and every argv proof
#                       (default: /home/fabian/projects/worktrees/.wp13-gate.lock)
#   GATE_QUEUE_STATE    directory holding the <label>.spec records and their <label>.lock files
#                       (default: /home/fabian/projects/worktrees/.gate-queue/)
#   GATE_QUEUE_SUMMARY  file the one-line per-run summaries are appended to
#                       (default: /home/fabian/projects/worktrees/wp13-gate-queue.summary)
#
# Exit codes:
#   0  the command did what it says (enqueue: every spec's gate returned 0)
#   1  enqueue only: at least one spec's gate returned non-zero (per-spec rc is in the record
#      and in the summary line)
#   2  usage error, or a spec/label this script will not accept (including a label whose
#      record already exists)
#   3  drop refused: the spec is not `waiting` (a gate is running under it, or it is finished)
#   4  drop refused: there is no record for that label
#   5  drop refused: the recorded pid failed the proof above, or the signal did not take
#   6  drop refused: the per-record lock was still held after --lock-wait seconds
#   99 a run that found a drop request in its record and exited without starting the gate
#
# Linux only: `drop` reads /proc. The queue is jupiter-local by design — the Mac side is
# guarded by mac-gate.sh's own host-wide lock.
set -uo pipefail

self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
self_name="$(basename "$0")"

die() { local code=$1; shift; printf '%s: %s\n' "$self_name" "$*" >&2; exit "$code"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }

# resolve_path PATH — absolute path with the directory resolved, the leaf left alone (the lock
# file need not exist yet). Prints the input unchanged when the directory does not exist.
resolve_path() {
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  d="$(cd "$d" 2>/dev/null && pwd -P)" || { printf '%s\n' "$1"; return 1; }
  printf '%s/%s\n' "${d%/}" "$b"
}

LOCK="$(resolve_path "${GATE_QUEUE_LOCK:-/home/fabian/projects/worktrees/.wp13-gate.lock}")"
STATE="${GATE_QUEUE_STATE:-/home/fabian/projects/worktrees/.gate-queue/}"
STATE="${STATE%/}"
SUMMARY="${GATE_QUEUE_SUMMARY:-/home/fabian/projects/worktrees/wp13-gate-queue.summary}"
LOCK_WAIT=21600

rec_file() { printf '%s/%s.spec' "$STATE" "$1"; }
rec_lock_file() { printf '%s/%s.lock' "$STATE" "$1"; }

# The per-record lock (fd 8) serializes the run's waiting->running transition against drop's
# read-verify-signal. rec_set skips its own locking while this process already holds it.
REC_LOCK_HELD=""
rec_lock_open() { # LABEL [TIMEOUT_SECONDS] — no timeout means wait
  mkdir -p "$STATE"
  exec 8>>"$(rec_lock_file "$1")"
  if [ -n "${2:-}" ]; then flock -w "$2" 8 || { exec 8>&-; return 1; }
  else flock 8 || { exec 8>&-; return 1; }; fi
  REC_LOCK_HELD="$1"
}
rec_lock_close() { REC_LOCK_HELD=""; exec 8>&-; }

# rec_set LABEL key=value … — replace those keys in the record (append if new) under the
# per-record lock, so the run process and the enqueue process cannot clobber each other.
rec_set() {
  local label=$1 rec kv key val line out found held
  shift
  rec="$(rec_file "$label")"
  mkdir -p "$STATE"
  held=0
  if [ "$REC_LOCK_HELD" = "$label" ]; then held=1; else exec 9>>"$(rec_lock_file "$label")"; flock 9; fi
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
  [ "$held" -eq 1 ] || exec 9>&-
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

# proc_starttime PID — field 22 of /proc/PID/stat (clock ticks since boot). Parsed from after
# the last ')' so a comm containing spaces or parens cannot shift the fields.
proc_starttime() {
  local raw rest
  raw="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  rest="${raw##*) }"
  set -f
  # shellcheck disable=SC2086
  set -- $rest
  set +f
  [ $# -ge 20 ] || return 1
  printf '%s\n' "${20}"
}

# proc_has_child PID — 0 = the kernel reports at least one child (this flock has forked its run
# and therefore holds the lock), 1 = none, 2 = the kernel does not tell us
proc_has_child() {
  local c
  [ -r "/proc/$1/task/$1/children" ] || return 2
  c="$(tr -d ' \n' < "/proc/$1/task/$1/children" 2>/dev/null)"
  [ -n "$c" ]
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

# verify_waiting_pid PID LABEL — 0 only when PID is provably this queue's own waiting flock
# parent for LABEL. Sets vmsg with the reason on refusal. Called immediately before the signal,
# with the per-record lock held. See the proof list in the header.
vmsg=""
verify_waiting_pid() {
  local pid=$1 label=$2 wt ref rlock start a i n hc
  vmsg=""
  case "$pid" in
    ''|*[!0-9]*) vmsg="the record for '$label' holds no usable pid ('$pid') — the spec has not been launched yet"; return 1 ;;
  esac
  [ "$pid" -gt 1 ] || { vmsg="refusing to signal pid $pid"; return 1; }
  [ "$pid" != "$$" ] || { vmsg="refusing to signal pid $pid: that is this process"; return 1; }
  [ "$pid" != "$PPID" ] || { vmsg="refusing to signal pid $pid: that is this process's parent — the shell that ran the drop. This is exactly the self-kill a 'pgrep -f <label>' produces."; return 1; }
  rlock="$(rec_get "$label" lock)" || rlock=""
  [ "$rlock" = "$LOCK" ] || { vmsg="the record for '$label' belongs to queue lock '${rlock:-<none>}', not to this invocation's '$LOCK'; refusing to signal another queue's process"; return 1; }
  kill -0 "$pid" 2>/dev/null || { vmsg="pid $pid from the record for '$label' is not alive (or not ours); nothing to signal"; return 1; }
  read_argv "$pid" || { vmsg="cannot read /proc/$pid/cmdline; refusing to signal a pid whose argv cannot be verified"; return 1; }
  [ "$(basename "${QARGV[0]}")" = "flock" ] || {
    vmsg="pid $pid is '${QARGV[0]}', not a waiting flock parent; refusing"; return 1; }
  wt="$(rec_get "$label" worktree)" || wt=""
  ref="$(rec_get "$label" ref)" || ref=""
  n=${#QARGV[@]}
  i=1
  while [ "$i" -lt "$n" ]; do
    a="${QARGV[$i]}"
    case "$a" in
      --) i=$((i + 1)); break ;;
      -w|--wait|--timeout|-E|--conflict-exit-code|-c|--command) i=$((i + 2)) ;;
      --*=*) i=$((i + 1)) ;;
      -n|--nb|--nonblock|-x|--exclusive|-s|--shared|-u|--unlock|-o|--close|-F|--no-fork|-e|-v|--verbose|-V|--version|-h|--help) i=$((i + 1)) ;;
      -w*|-E*|-c*) i=$((i + 1)) ;;
      -*) vmsg="pid $pid's argv carries '$a', which is not an option of flock this script knows; refusing to guess where its lock operand is (argv: ${QARGV[*]})"; return 1 ;;
      *) break ;;
    esac
  done
  if [ "$i" -ge "$n" ] || [ "${QARGV[$i]}" != "$LOCK" ]; then
    vmsg="pid $pid's flock operand is '${QARGV[$i]:-<none>}', not this queue's lock '$LOCK'; refusing"
    return 1
  fi
  i=$((i + 1))
  if [ $((i + 4)) -ge "$n" ] || [ "$(basename "${QARGV[$i]}")" != "$self_name" ] \
     || { [ "${QARGV[$i]}" != "$self_path" ] && ! [ "${QARGV[$i]}" -ef "$self_path" ]; } \
     || [ "${QARGV[$((i + 1))]}" != "__run" ] \
     || [ "${QARGV[$((i + 2))]}" != "$wt" ] \
     || [ "${QARGV[$((i + 3))]}" != "$ref" ] \
     || [ "${QARGV[$((i + 4))]}" != "$label" ]; then
    vmsg="pid $pid does not run '$self_path __run $wt $ref $label …' behind its lock operand (argv: ${QARGV[*]}); refusing to signal it"
    return 1
  fi
  start="$(rec_get "$label" flock_start)" || start=""
  case "$start" in
    ''|*[!0-9]*) vmsg="the record for '$label' has no usable process start time ('$start'); refusing to signal pid $pid, which may be a recycled pid"; return 1 ;;
  esac
  [ "$start" = "$(proc_starttime "$pid")" ] || {
    vmsg="pid $pid started at '$(proc_starttime "$pid")' but the record for '$label' was written for start time '$start' — this is a different, recycled pid; refusing"; return 1; }
  proc_has_child "$pid"; hc=$?
  [ "$hc" -ne 0 ] || {
    vmsg="pid $pid has already forked its run child, so it holds the queue lock and is no longer waiting; refusing"; return 1; }
  return 0
}

cmd_help() {
  sed -n '2,/^set -uo/p' "$self_path" | sed -e 's/^# \{0,1\}//' -e '/^set -uo/d'
}

# __run WORKTREE REF LABEL LOG — the gated run itself; only ever started by enqueue, and only
# with the queue lock held. Semantics unchanged from wp13-gate-queue-v4.sh.
cmd_run() {
  local wt=$1 ref=$2 label=$3 log=$4 branch rc
  rec_lock_open "$label"
  if [ -n "$(rec_get "$label" drop_requested)" ]; then
    rec_lock_close
    echo "DROPPED-BEFORE-START" > "$log"
    exit 99
  fi
  rec_set "$label" "state=running" "run_pid=$$" "started=$(now)"
  rec_lock_close
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
  local spec wt rest ref label log fpid rc worst=0 prev prev_pid rec
  mkdir -p "$STATE"
  [ -d "$(dirname "$LOCK")" ] || die 2 "the lock directory $(dirname "$LOCK") does not exist"
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
    rec="$(rec_file "$label")"
    mkdir -p "$wt/.gate-artifacts"
    log="$wt/.gate-artifacts/queue-$label-$(date +%H%M%S).log"
    # Admission holds the per-record lock, so re-admitting a finished label cannot interleave
    # with another enqueue doing the same (one reading `done` while the other re-creates).
    rec_lock_open "$label"
    prev="$(rec_get "$label" state)" || prev=""
    case "$prev" in
      waiting|running)
        prev_pid="$(rec_get "$label" flock_pid)" || prev_pid=""
        rec_lock_close
        die 2 "a spec named '$label' is already $prev (pid ${prev_pid:-not launched yet}); pick another label, or drop it first" ;;
      done) rm -f "$rec" ;;
    esac
    # O_EXCL admission: two concurrent enqueues of one label cannot both create the record.
    ( set -o noclobber; : > "$rec" ) 2>/dev/null \
      || { rec_lock_close; die 2 "a record for '$label' already exists ($rec) — another enqueue admitted that label first; pick another label, or drop it"; }
    rec_set "$label" "spec=$spec" "worktree=$wt" "ref=$ref" "label=$label" "log=$log" \
      "lock=$LOCK" "enqueue_pid=$$" "flock_pid=" "flock_start=" "run_pid=" "state=waiting" \
      "rc=" "enqueued=$(now)"
    # Released before the spawn so the child cannot inherit this descriptor's lock. A drop in
    # the gap sees an empty flock_pid and refuses; no other enqueue can pass the O_EXCL create.
    rec_lock_close
    flock -w "$LOCK_WAIT" "$LOCK" "$self_path" __run "$wt" "$ref" "$label" "$log" &
    fpid=$!
    rec_set "$label" "flock_pid=$fpid" "flock_start=$(proc_starttime "$fpid")"
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
  printf '%-22s %-8s %-4s %-14s %-24s %s\n' LABEL STATE RC "ENQUEUE PID" "FLOCK/RUN PID" REF
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    n=$((n + 1))
    st="$(rec_get "$label" state)"
    printf '%-22s %-8s %-4s %-14s %-24s %s\n' \
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
  local label="" dry=0 lock_wait=60 a pid st i want_wait=0
  for a in "$@"; do
    if [ "$want_wait" -eq 1 ]; then
      case "$a" in
        ''|*[!0-9]*) die 2 "drop: --lock-wait needs a number of seconds" ;;
        *) lock_wait="$a"; want_wait=0; continue ;;
      esac
    fi
    case "$a" in
      --dry-run) dry=1 ;;
      --lock-wait) want_wait=1 ;;
      -*) die 2 "drop: unknown option '$a'" ;;
      *) [ -z "$label" ] || die 2 "drop takes exactly one <label>"; label="$a" ;;
    esac
  done
  [ "$want_wait" -eq 0 ] || die 2 "drop: --lock-wait needs a number of seconds"
  [ -n "$label" ] || die 2 "drop needs a <label> (see: $self_name list)"
  [ -f "$(rec_file "$label")" ] || die 4 "no spec record for '$label' in $STATE (see: $self_name list)"
  rec_lock_open "$label" "$lock_wait" \
    || die 6 "the per-record lock $(rec_lock_file "$label") was still held after ${lock_wait}s — a run of '$label' is starting, or another drop holds it; nothing was signalled (raise --lock-wait to wait longer)"
  st="$(rec_get "$label" state)" || st=""
  case "$st" in
    waiting) ;;
    running) rec_lock_close; die 3 "refusing to drop '$label': a gate is RUNNING under it (run pid $(rec_get "$label" run_pid), log $(rec_get "$label" log)). drop only kills a spec still waiting for the lock; let this one finish, or stop it on the Mac first." ;;
    done) rec_lock_close; die 3 "refusing to drop '$label': it already finished (rc=$(rec_get "$label" rc)); nothing to kill." ;;
    *) rec_lock_close; die 3 "refusing to drop '$label': unexpected state '$st'" ;;
  esac
  pid="$(rec_get "$label" flock_pid)" || pid=""
  verify_waiting_pid "$pid" "$label" || { rec_lock_close; die 5 "$vmsg"; }
  if [ "$dry" -eq 1 ]; then
    rec_lock_close
    echo "DRY-RUN: would send SIGTERM to pid $pid — the flock parent of spec '$label' (state=waiting)"
    echo "  argv: ${QARGV[*]}"
    echo "  nothing was signalled."
    return 0
  fi
  # Under the per-record lock: mark the request first, so a run that forked between the
  # children check and the signal exits 99 instead of starting a gate nobody is waiting for.
  rec_set "$label" "drop_requested=$(now)"
  kill -TERM "$pid" || { rec_lock_close; die 5 "kill -TERM $pid failed"; }
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    rec_lock_close
    die 5 "SIGTERM sent to pid $pid, but it is still alive after 5 s — check '$self_name list'"
  fi
  rec_lock_close
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
