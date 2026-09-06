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
# LOCK ORDER (round-3 review): no code path may hold one record's lock while asking for
# another's, or two enqueues deadlock on each other and the snapshot timeout surfaces as a
# spurious refusal. `enqueue` therefore scans the other records BEFORE taking its own label's
# lock, and only the run holds one and asks for others — runs are serialized by the queue lock,
# so no cycle can form. Reading a record for a hold decision takes that record's own lock and
# reads it once (rec_snapshot), instead of assembling a decision from several unlocked reads
# while rec_set is rewriting the file.
#
# WHY A PER-RECORD LOCK: `drop` must not read `state=waiting`, then have the run acquire the
# queue lock, and only then land its signal. The run's first act inside the queue lock is to
# write `state=running` while holding `<state dir>/<label>.lock`, and `drop` holds that same
# lock across read-state -> verify -> signal, so the two cannot interleave. A run that finds
# `drop_requested` in its record — set by drop under that lock — exits 99 without touching the
# worktree, which closes the last window (a fork that happened between the children check and
# the signal).
#
# NEVER COMMIT INTO A WORKTREE THAT IS UNDER A RUNNING OR QUEUED GATE (IMGMGR-398,
# 2026-09-05, second occurrence). While a run holds a worktree, that worktree is DETACHED at the gated ref. A
# commit made into it then hangs off the detached HEAD, and the old `git checkout <branch>`
# restore below walked away from it: the commit survived only in the reflog, and the next
# `git rev-parse HEAD` read the OLD sha, so a ~50-minute Mac run would have gated stale code.
# Three rules now hold that shut, and all three are refusals, not repairs:
#
#   * `enqueue` refuses (exit 7) a spec whose worktree is already held — a record in state
#     `running` with a live run pid, a spec merely QUEUED on that tree (`waiting`: a queued gate
#     claims its worktree, which is why the rule above says "or queued" — `list` prints those
#     holds too), or a finished record whose restore was skipped and whose worktree is therefore
#     still detached (`checked_out` is cleared only by a restore that really happened). The
#     last one is self-healing: check the tree out on its branch by hand and the refusal goes
#     away by itself, with no record to edit. If that is impossible, `drop <label> --finished`
#     retires the hold explicitly (the record only — the worktree is left exactly as it is, and
#     the next gate there will check its ref out over whatever is in it). A hold whose worktree
#     path is GONE voids itself; a path that is there but does not answer as a git worktree keeps
#     the hold, because an unknown is not an absence.
#   * a run also checks the `gen` its enqueue stamped on the record before it touches anything:
#     a spec that was dropped while queued must not run against whoever re-used its label.
#   * the RUN re-checks the same predicate under the record lock immediately before it detaches
#     the worktree, and refuses there too (`state=refused-held`, `rc=7`, `REFUSED-HELD …` in the
#     run log, nothing launched, the tree untouched). Admission alone is not enough: a spec can
#     sit in the queue for an hour, and the tree it was admitted for may be left held by a spec
#     that finished in between — the same incident reached sequentially instead of concurrently.
#     A `waiting` spec deliberately does NOT count as a hold in this check, or a spec queued
#     behind a finished one would refuse itself the moment it got the lock.
#   * the run RESTORES the branch only if nothing moved under it: HEAD still at the gated ref
#     AND the branch still where the run found it. Otherwise it leaves the worktree exactly as
#     it is and prints `HEAD MOVED <old> -> <new>` or `BRANCH MOVED <old> -> <new>` (also into
#     the run log, the record's `restore=` field and the summary line). It never checks a
#     branch out over commits it did not make.
#
# So: let the gate finish (`list` prints the worktree beside every record and names the held
# trees), or `drop` the spec, before committing into that tree.
#
# TRACKED CHANGES REFUSE, IGNORED FILES DO NOT (IMGMGR-399): the run's clean-tree check is
# `git status --porcelain` WITHOUT `--ignored`, so gitignored working files (docs/plans/,
# docs/session-reviews/, .tools) never block a gate. bin/mac-gate.sh mirrors exactly what
# `git ls-files` reports, so nothing outside the tracked set reaches the Mac at all — ignored or
# not. Tracked modifications and untracked NON-ignored files still refuse with exit 97: they mean
# the tree is not the commit that would be gated.
#
# Usage:
#   bin/gate-queue.sh enqueue <worktree>:<ref>:<label> [<worktree>:<ref>:<label> …]
#   bin/gate-queue.sh list
#   bin/gate-queue.sh drop <label> [--dry-run] [--force] [--lock-wait <seconds>]
#   bin/gate-queue.sh drop <label> --finished [--dry-run]
#   bin/gate-queue.sh --help
#
# `drop --force` skips the grace window that protects a record whose flock may still be spawning;
# `drop --finished` retires the hold a FINISHED spec still has on its worktree (the record only —
# the worktree is left exactly as that run left it). Both are operator overrides: the ordinary way
# out of a hold is to check that worktree out on its branch, which clears it by itself.
#
# enqueue runs the specs strictly in order, one at a time, each one: wait for the lock ->
# refuse a dirty tree -> checkout <ref> -> MAC_GATE_HOST=merkur MAC_GATE_BRANCH=<the worktree's
# branch> bin/mac-gate.sh > <worktree>/.gate-artifacts/queue-<label>-<HHMMSS>.log -> copy the
# run's test-iphone/test-ipad logs beside it (a RED run's logs are overwritten by the next
# run's copyback) -> restore the branch -> append the summary line. Launch it detached, e.g.
#   setsid nohup bin/gate-queue.sh enqueue "$PWD:$(git rev-parse HEAD):lane-a" >/dev/null 2>&1 &
# A label may hold only [A-Za-z0-9._-] (it is a file name), and its record is created with
# O_EXCL, so two concurrent enqueues of one label admit exactly one. The loser exits 2 when it
# loses on the label itself, or 7 when it first sees the winner's hold on that worktree; either
# way exactly one is admitted and the loser writes nothing.
#
# STATE: one record per label under $GATE_QUEUE_STATE, `key=value` lines, written by the
# processes that own the transitions and never inferred by an observer: the enqueue process
# writes `waiting`, the flock pid and its start time, the run writes `running` and its own pid
# as its first action inside the lock, `checked_out=<sha>` and `branch_at=<sha>` the moment it
# detaches the worktree, `restore=ok|skipped-head-moved|skipped-branch-moved|failed` when it
# lets go of it (clearing `checked_out` only on `ok`), and the enqueue process writes
# `done rc=<n>` when the run returns — or the run writes `state=refused-held rc=7` plus
# `refused=<holder>` when it finds the worktree held just before the detach (if a drop outlives
# its enqueue process, the drop records the end and says so). `list` reads the records back and adds a `kill -0` liveness note per
# pid, the worktree of every record, and a `held` line per worktree still under a record.
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
#   2  usage error, or a spec/label this script will not accept (including a label whose record
#      already exists — though two enqueues racing for one label on one worktree may instead see
#      the worktree hold and get 7; either way exactly one is admitted)
#   3  drop refused: the spec is not `waiting` (a gate is running under it, or it is finished);
#      or `--finished` was given for a spec that is not finished, or that holds nothing
#   4  drop refused: there is no record for that label
#   5  drop refused: the recorded pid failed the proof above, the signal did not take, or the
#      record has no flock pid yet and is younger than the grace window (see --force)
#   6  drop refused: the per-record lock was still held after --lock-wait seconds
#   7  refused because the spec's worktree is held by another record in this state dir — a gate
#      RUNNING under it, a gate QUEUED on it, or a finished run's branch restore that was skipped
#      and left it detached. From `enqueue` (at admission: no record written, nothing launched)
#      or from the run itself (immediately before the detach: `state=refused-held rc=7`, the
#      reason in the record's `refused` key and in the summary line, the gate never started and
#      the worktree never touched).
#   97 the run refused the worktree because it is not clean (`git status --porcelain` is
#      non-empty: tracked modifications or untracked NON-ignored files; ignored files are fine).
#      Recorded as that spec's `rc`, with DIRTY-TREE in its run log; the gate never started.
#   98 the run could not check the gated ref out (CHECKOUT-FAIL in the run log)
#   99 a run that found a drop request in its record and exited without starting the gate
#
# FINAL STATE vs AGGREGATE EXIT: each spec's own outcome lives in its record — `state` ends as
# `done` with `rc=<the gate's exit code, or 97/98/99>`, or as `refused-held` with `rc=7` when the
# run refused a held worktree — and in its summary line. `enqueue`'s exit code is the AGGREGATE
# over the specs it was given: 7 if any spec was refused (a refused spec never ran, so that must
# not read as a gate result), otherwise 1 if any gate returned non-zero, otherwise 0. An
# admission refusal (also 7) stops the whole command at that spec: the ones after it are not
# started, and the ones before it keep their own records.
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
DROP_GRACE=10

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

abs_dir() { # PATH — the resolved directory, or the input unchanged when it does not exist
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "${1%/}"
}

# rec_snapshot LABEL — the record's whole contents, read ONCE under that record's own lock
# (round-2 review: a hold decision must not be assembled from several unlocked reads while
# rec_set is rewriting the file). fd 6, so it never collides with the per-record lock on fd 8
# or rec_set's fd 9; when this process already holds the record's lock, the file is simply read
# — flocking the same file twice from one process would deadlock. Returns 1, with no output,
# when the lock is still busy after 5 s: a writer is mid-transition and the caller treats that
# as a hold.
rec_snapshot() {
  local rec
  rec="$(rec_file "$1")"
  [ -f "$rec" ] || return 0
  if [ "$REC_LOCK_HELD" = "$1" ]; then cat "$rec" 2>/dev/null; return 0; fi
  mkdir -p "$STATE"
  exec 6>>"$(rec_lock_file "$1")"
  if flock -w 5 6; then cat "$rec" 2>/dev/null; exec 6>&-; return 0; fi
  exec 6>&-
  return 1
}

snap_get() { # SNAPSHOT KEY — the value from a snapshot taken by rec_snapshot
  local line
  while IFS= read -r line; do
    [ "${line%%=*}" = "$2" ] && { printf '%s\n' "${line#*=}"; return 0; }
  done <<< "$1"
  return 1
}

# record_hold LABEL [SCOPE] [WORKTREE] — print WHY this record holds its worktree, or return 1
# when it does not. SCOPE is `admission` (default, used by enqueue and list) or `run` (used by
# the run itself just before it detaches). WORKTREE, when given, also requires the record to be
# about that tree — compared from the same snapshot, so no unlocked read decides anything.
# Three holds (IMGMGR-398):
#   1. a gate RUNNING under the tree, proven by a LIVE run pid — a record left `running` by a
#      killed run holds nothing by itself; if that run left the tree detached, hold 3 catches it;
#   2. a gate QUEUED on it (state `waiting`). Admission only: the rule is "never commit into a
#      worktree under a running OR QUEUED gate", so a second spec for that tree is refused up
#      front. The RUN must not count it, or a spec queued behind a finished one would refuse
#      itself the moment it got the lock;
#   3. a tree this queue took off its branch and deliberately left there (`checked_out` set and
#      the worktree still DETACHED) because restoring would have walked over commits made during
#      the run. Verified against the LIVE worktree, never from the record alone, so checking the
#      tree out by hand clears the hold with no record to edit.
record_hold() {
  local label="$1" scope="${2:-admission}" want="${3:-}" snap st wt co head rpid fpid fstart
  snap="$(rec_snapshot "$label")" || {
    # The record's own writer holds its lock. Refusing is the safe direction, but only for the
    # worktree this record is actually about: an unlocked read that clearly names a DIFFERENT
    # tree is enough to skip it (this check is advisory — the run re-checks under the queue lock
    # before it detaches anything), and without that a single busy record refused every enqueue
    # in the queue, whatever worktree it was for.
    if [ -n "$want" ]; then
      wt="$(rec_get "$label" worktree)" || wt=""
      [ -z "$wt" ] || [ "$(abs_dir "$wt")" = "$want" ] || return 1
    fi
    printf 'its record %s is locked by another process, so a state transition is in flight; refusing is the safe direction\n' "$(rec_file "$label")"
    return 0
  }
  [ -n "$snap" ] || return 1
  wt="$(snap_get "$snap" worktree)" || wt=""
  [ -n "$wt" ] || return 1
  [ -z "$want" ] || [ "$(abs_dir "$wt")" = "$want" ] || return 1
  st="$(snap_get "$snap" state)" || st=""
  co="$(snap_get "$snap" checked_out)" || co=""
  rpid="$(snap_get "$snap" run_pid)" || rpid=""
  if [ "$st" = "running" ] \
     && { [ -z "$rpid" ] || { [ "$rpid" != "$$" ] && kill -0 "$rpid" 2>/dev/null; }; }; then
    printf 'a gate is RUNNING under it (run pid %s, log %s)\n' \
      "${rpid:-not recorded yet}" "$(snap_get "$snap" log)"
    return 0
  fi
  if [ "$scope" = "admission" ] && [ "$st" = "waiting" ]; then
    # Proven the same way as a running hold: a QUEUED spec claims its worktree only while its
    # flock is really there. An empty pid is the microsecond between the record and the spawn
    # (hold — the safe direction); a pid that is dead, alive but not a flock, or alive with a
    # different start time than the record wrote for it (a recycled pid) is a stale or
    # hand-written record and holds nothing — otherwise one abandoned enqueue would block a
    # worktree for good.
    fpid="$(snap_get "$snap" flock_pid)" || fpid=""
    fstart="$(snap_get "$snap" flock_start)" || fstart=""
    if [ -z "$fpid" ] || { kill -0 "$fpid" 2>/dev/null && read_argv "$fpid" \
         && [ "$(basename "${QARGV[0]}")" = "flock" ] \
         && { [ -z "$fstart" ] || [ "$fstart" = "$(proc_starttime "$fpid")" ]; }; }; then
      printf 'a gate is QUEUED on it (that spec is waiting for the queue lock, flock pid %s); let it run or drop it first\n' \
        "${fpid:-not launched yet}"
      return 0
    fi
  fi
  [ -n "$co" ] || return 1
  # `checked_out` is cleared only by a restore that really put the tree back on its branch, so a
  # non-empty value plus a DETACHED worktree means this queue took it off its branch and left it
  # there. Deliberately not a sha comparison: after a skipped restore the HEAD is usually the
  # NEW commit, which is exactly the case that must stay held. Checking a branch out by hand
  # ends the hold with no record to edit.
  # A worktree that no longer EXISTS holds nothing: the commits this hold protected are gone with
  # it, and a record that can never be satisfied would block that path for good (round-4 review,
  # R2). That is the only void case. A path that is still there but does not answer as a git
  # worktree — a leftover directory, a permission problem, a transient error — is an UNKNOWN, and
  # an unknown keeps the hold (round-5 review, 1): retiring a record whose hold could not be
  # evaluated is exactly how the preserved commits get checked out over.
  [ -e "$wt" ] || return 1
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'that run gated %s and its restore was skipped (restore=%s), and %s does not answer as a git worktree — the hold cannot be evaluated, so it STANDS. Look at that path; `%s drop %s --finished` retires the hold deliberately\n' \
      "$co" "$(snap_get "$snap" restore)" "$wt" "$self_name" "$label"
    return 0
  fi
  git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1 && return 1
  head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || head="<unreadable>"
  printf 'that run gated %s and its restore was skipped (restore=%s), so the tree is still DETACHED (at %s); check it out on its branch by hand first\n' \
    "$co" "$(snap_get "$snap" restore)" "$head"
  return 0
}

# worktree_holder WORKTREE [SCOPE] [SKIP_LABEL] — print "<label><TAB><reason>" for the first
# record holding WORKTREE. SKIP_LABEL is the caller's own spec (a run must not find itself, and
# it already holds that record's lock).
worktree_holder() {
  local want scope="${2:-admission}" skip="${3:-}" rec label hold
  want="$(abs_dir "$1")"
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    [ "$label" != "$skip" ] || continue
    hold="$(record_hold "$label" "$scope" "$want")" || continue
    printf '%s\t%s\n' "$label" "$hold"
    return 0
  done
  return 1
}

# outcome_note LABEL — the ` refused=…` / ` restore=…` fragment for the summary line, empty when
# the run happened and the worktree went back on its branch as it should.
outcome_note() {
  local r
  r="$(rec_get "$1" refused)" || r=""
  [ -z "$r" ] || { printf ' refused-held=%s' "$r"; return 0; }
  r="$(rec_get "$1" restore)" || r=""
  case "$r" in ''|ok) ;; *) printf ' restore=%s' "$r" ;; esac
}

# rec_age_seconds LABEL — whole seconds since the record's `enqueued` stamp, or nothing when it
# has none or it cannot be parsed (the caller treats that as "unknown", never as "old").
rec_age_seconds() {
  local ts then_s now_s
  ts="$(rec_get "$1" enqueued)" || return 1
  [ -n "$ts" ] || return 1
  then_s="$(date -d "$ts" +%s 2>/dev/null)" || return 1
  [ -n "$then_s" ] || return 1
  now_s="$(date +%s)"
  printf '%s\n' "$((now_s - then_s))"
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

# restore_worktree WORKTREE BRANCH REF_SHA BRANCH_AT LABEL LOG — put the worktree back on the
# branch the run took it from, and ONLY if nothing moved under the run (IMGMGR-398):
#
#   HEAD moved   commits were made into the detached tree while the gate held it. Checking the
#                branch out now abandons them to the reflog and hands the next enqueue the OLD
#                sha — the 2026-09-05 incident. Leave the tree on its new HEAD and say so.
#   branch moved someone moved the branch while the gate ran (it is free to move: the worktree
#                is detached). Checking it out would silently import that move into the tree.
#                Leave the tree detached at the gated ref and say so.
#
# The refusals are printed, appended to the run log, and recorded as `restore=` (with
# `checked_out` kept, so the next enqueue for that worktree refuses with 7 until a human has
# sorted it out). Returns 0 only when the worktree really is back on its branch.
restore_worktree() {
  local wt=$1 branch=$2 ref_sha=$3 branch_at=$4 label=$5 log=$6 head_now branch_now msg
  head_now="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || head_now=""
  branch_now="$(git -C "$wt" rev-parse --verify "$branch" 2>/dev/null)" || branch_now=""
  if [ "$head_now" != "$ref_sha" ]; then
    msg="HEAD MOVED $ref_sha -> ${head_now:-<unreadable>} : $wt gained commits while the gate held it detached. Leaving it there — '$branch' is NOT checked out, so nothing is orphaned. Merge or cherry-pick them, then check '$branch' out by hand."
    rec_set "$label" "restore=skipped-head-moved"
  elif [ "$branch_now" != "$branch_at" ]; then
    msg="BRANCH MOVED $branch_at -> ${branch_now:-<gone>} : '$branch' moved while the gate ran. Leaving $wt detached at $ref_sha rather than checking that branch out over it."
    rec_set "$label" "restore=skipped-branch-moved"
  elif git -C "$wt" checkout -q "$branch"; then
    rec_set "$label" "restore=ok" "checked_out="
    return 0
  else
    msg="RESTORE FAILED: git -C $wt checkout $branch did not succeed; the worktree stays detached at $ref_sha."
    rec_set "$label" "restore=failed"
  fi
  printf '%s\n' "$msg"
  printf '%s\n' "$msg" >> "$log" 2>/dev/null || true
  return 1
}

# __run WORKTREE REF LABEL LOG — the gated run itself; only ever started by enqueue, and only
# with the queue lock held. Semantics unchanged from wp13-gate-queue-v4.sh except the branch
# restore, which now refuses rather than rewinds (IMGMGR-398).
cmd_run() {
  local wt=$1 ref=$2 label=$3 log=$4 branch rc branch_at ref_sha hold
  rec_lock_open "$label"
  # FIRST OF ALL, before this run writes a single field: is this record still the one that queued
  # us? A drop can retire a spec while its child is still queued behind the queue lock, and the
  # label can then be re-used by somebody else — the new occupant's record carries a new `gen`,
  # and this child must not run against it (round-5 review, 2c). Only enforced when the enqueue
  # that spawned us passed its generation; a hand-run `__run` sets nothing and is unaffected.
  if [ -n "${GATE_QUEUE_GEN:-}" ] && [ "$(rec_get "$label" gen)" != "$GATE_QUEUE_GEN" ]; then
    rec_lock_close
    printf "STALE-GENERATION this run was queued for generation '%s' but the record for '%s' now holds '%s' — the spec was retired and the label re-used. Exiting without touching %s.\n" \
      "$GATE_QUEUE_GEN" "$label" "$(rec_get "$label" gen)" "$wt" > "$log"
    [ -z "${GATE_QUEUE_REFUSAL_FILE:-}" ] || printf 'stale generation\n' > "$GATE_QUEUE_REFUSAL_FILE"
    exit 7
  fi
  # Then: this process's parent IS the `flock` the enqueue spawned, so the
  # record can learn the pid from here even if the enqueue process died in the window between the
  # spawn and its own `rec_set flock_pid=` (round-4 review, R4). Without this, that record keeps an
  # empty pid while a gate really is starting under it, and a drop would read it as an orphan.
  # Only filled in when empty: the enqueue's own write is the same value.
  if [ -z "$(rec_get "$label" flock_pid)" ]; then
    rec_set "$label" "flock_pid=$PPID" "flock_start=$(proc_starttime "$PPID")" "pid_from=run"
  fi
  if [ -n "$(rec_get "$label" drop_requested)" ]; then
    rec_lock_close
    echo "DROPPED-BEFORE-START" > "$log"
    exit 99
  fi
  # Round-2 review, BLOCKING 1: revalidate the hold HERE — under this record's lock and inside
  # the queue lock, immediately before the detach. Admission checked it when this spec was
  # QUEUED, which can be an hour before the lock is granted: another spec may have finished in
  # between and deliberately left this worktree detached over commits made during its run.
  # Checking a ref out now would orphan exactly what that refusal preserved — the original
  # incident, reached sequentially. Nothing is launched and the worktree is never touched.
  hold="$(worktree_holder "$wt" run "$label")"
  if [ -n "$hold" ]; then
    rec_set "$label" "state=refused-held" "rc=7" "refused=${hold%%	*}" "finished=$(now)"
    # Tell the enqueue process that started us, through a file only IT named (round-4 review,
    # R1): by the time it wakes up, the label may already belong to a replacement enqueue, so the
    # record is not a safe place to read our outcome back from — and a gate can exit 7 on its own.
    [ -z "${GATE_QUEUE_REFUSAL_FILE:-}" ] || printf '%s\n' "$hold" > "$GATE_QUEUE_REFUSAL_FILE"
    rec_lock_close
    printf "REFUSED-HELD spec '%s' holds %s — %s\n" "${hold%%	*}" "$wt" "${hold#*	}" > "$log"
    exit 7
  fi
  rec_set "$label" "state=running" "run_pid=$$" "started=$(now)"
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
  # No --ignored: gitignored working files are allowed (see the header); tracked modifications
  # and untracked non-ignored files are what would reach the mirror and fail the manifest leg.
  [ -z "$(git -C "$wt" status --porcelain)" ] || { echo "DIRTY-TREE" > "$log"; exit 97; }
  branch_at="$(git -C "$wt" rev-parse --verify "$branch" 2>/dev/null)" || branch_at=""
  git -C "$wt" checkout -q "$ref" || { echo "CHECKOUT-FAIL $ref" > "$log"; exit 98; }
  ref_sha="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || ref_sha=""
  rec_set "$label" "checked_out=$ref_sha" "branch_at=$branch_at"
  # Only now is the tree provably this run's: the lock has covered the hold re-check, the
  # clean-tree refusal, the detach and the record of it as one unit.
  rec_lock_close
  ( cd "$wt" && MAC_GATE_HOST=merkur MAC_GATE_BRANCH="$branch" bin/mac-gate.sh ) > "$log" 2>&1
  rc=$?
  cp "$wt/.gate-artifacts/test-iphone.log" "${log%.log}-test-iphone.log" 2>/dev/null
  cp "$wt/.gate-artifacts/test-ipad.log" "${log%.log}-test-ipad.log" 2>/dev/null
  restore_worktree "$wt" "$branch" "$ref_sha" "$branch_at" "$label" "$log"
  exit "$rc"
}

cmd_enqueue() {
  [ $# -ge 1 ] || die 2 "enqueue needs at least one <worktree>:<ref>:<label> spec"
  local spec wt rest ref label log fpid rc worst=0 refused=0 prev prev_pid rec hold own_hold resfile gen
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
    # LOCK ORDER (round-3 review, B5): scan the other records BEFORE taking this label's lock.
    # Nothing in this script may hold one record's lock while asking for another's — two
    # enqueues would deadlock on each other and the snapshot timeout would surface as a
    # spurious refusal. The only place that holds one and asks for another is the run, and runs
    # are serialized by the queue lock, so no cycle can form.
    hold="$(worktree_holder "$wt")"
    if [ -n "$hold" ]; then
      die 7 "refusing to enqueue '$label' on $wt: spec '${hold%%	*}' holds that worktree — ${hold#*	} (see: $self_name list)"
    fi
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
      done|refused-held) ;;
    esac
    # A finished record may still HOLD ITS OWN worktree — which is not necessarily the worktree
    # being enqueued now (round-3 review, B3). Retiring it would delete the only evidence that
    # that tree is detached over commits a skipped restore preserved, and the next enqueue there
    # would check out over them. Read under this label's own lock (rec_snapshot reads directly
    # when this process holds it), so no second lock is requested while this one is held.
    own_hold="$(record_hold "$label")"
    if [ -n "$own_hold" ]; then
      rec_lock_close
      die 7 "refusing to re-enqueue '$label': its previous run still holds $(rec_get "$label" worktree) — $own_hold. Retire it by checking that worktree out on its branch, or use another label."
    fi
    case "$prev" in done|refused-held) rm -f "$rec" ;; esac
    # O_EXCL admission: two concurrent enqueues of one label cannot both create the record.
    ( set -o noclobber; : > "$rec" ) 2>/dev/null \
      || { rec_lock_close; die 2 "a record for '$label' already exists ($rec) — another enqueue admitted that label first; pick another label, or drop it"; }
    # A generation token for this admission: a child queued for an earlier occupant of this label
    # compares it before it touches anything (round-5 review, 2c).
    gen="$(date +%s)-$$-$RANDOM"
    rec_set "$label" "spec=$spec" "worktree=$wt" "ref=$ref" "label=$label" "log=$log" \
      "lock=$LOCK" "enqueue_pid=$$" "flock_pid=" "flock_start=" "run_pid=" "state=waiting" \
      "rc=" "enqueued=$(now)" "gen=$gen"
    # Released before the spawn so the child cannot inherit this descriptor's lock. A drop in
    # the gap sees an empty flock_pid and refuses; no other enqueue can pass the O_EXCL create.
    rec_lock_close
    # Named by THIS enqueue's pid, so a replacement enqueue of the same label cannot be confused
    # with our own child's outcome (round-4 review, R1).
    resfile="$STATE/.refusal-$$-$label"
    rm -f "$resfile"
    GATE_QUEUE_REFUSAL_FILE="$resfile" GATE_QUEUE_GEN="$gen" \
      flock -w "$LOCK_WAIT" "$LOCK" "$self_path" __run "$wt" "$ref" "$label" "$log" &
    fpid=$!
    rec_set "$label" "flock_pid=$fpid" "flock_start=$(proc_starttime "$fpid")"
    wait "$fpid"
    rc=$?
    # Finalize only while this process still owns the record (round-3 review, B6). After a
    # run-side refusal the label is free again, so a replacement enqueue may already have
    # created its own record under it — stamping our result on that one would erase a live spec.
    # And a refusal the run finalized itself is kept as `refused-held`: overwriting it with
    # `done` lost both the state and this command's exit code.
    # Our child's own outcome, carried in our own file — never re-read from a record that may
    # already belong to a replacement enqueue (round-4 review, R1).
    if [ -s "$resfile" ]; then refused=7; fi
    rm -f "$resfile"
    rec_lock_open "$label"
    if [ "$(rec_get "$label" enqueue_pid)" = "$$" ]; then
      case "$(rec_get "$label" state)" in
        refused-held) : ;;
        *) rec_set "$label" "state=done" "rc=$rc" "finished=$(now)" ;;
      esac
    fi
    rec_lock_close
    echo "$(date +%H:%M) $label ref=$ref rc=$rc$(outcome_note "$label") $(grep -o 'mac-gate SUMMARY:.*' "$log" 2>/dev/null | tail -1) log=$log" >> "$SUMMARY"
    [ "$rc" -eq 0 ] || worst=1
  done
  echo "$(date +%H:%M) QUEUE-DONE($*)" >> "$SUMMARY"
  # A refusal wins the aggregate exit code: it means a spec never ran at all, which the caller
  # must not read as a gate result. Otherwise 1 if any gate returned non-zero, else 0.
  [ "$refused" -eq 0 ] || return 7
  return "$worst"
}

cmd_list() {
  local rec label st holder="unknown (no record is in state=running)" n=0 hold held=0
  echo "lock    : $LOCK"
  echo "state   : $STATE"
  echo "summary : $SUMMARY"
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    [ "$(rec_get "$label" state)" = "running" ] || continue
    holder="$label (run pid $(pid_note "$(rec_get "$label" run_pid)"), worktree $(rec_get "$label" worktree))"
  done
  echo "holder  : $holder   # flock has no holder API; this is derived from the records"
  # Which trees are held, and therefore must not be committed into (IMGMGR-398). A `held` line
  # is checked against the live worktree, not read out of the record.
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    hold="$(record_hold "$label")" || continue
    held=$((held + 1))
    echo "held    : $(rec_get "$label" worktree)   by '$label' — $hold"
  done
  [ "$held" -gt 0 ] || echo "held    : no worktree is held; none is checked out by this queue"
  echo
  printf '%-22s %-8s %-4s %-14s %-24s %-42s %s\n' LABEL STATE RC "ENQUEUE PID" "FLOCK/RUN PID" REF WORKTREE
  for rec in "$STATE"/*.spec; do
    [ -e "$rec" ] || continue
    label="$(basename "$rec" .spec)"
    n=$((n + 1))
    st="$(rec_get "$label" state)"
    printf '%-22s %-8s %-4s %-14s %-24s %-42s %s\n' \
      "$label" "${st:-?}" "$(rec_get "$label" rc)" \
      "$(pid_note "$(rec_get "$label" enqueue_pid)")" \
      "$(pid_note "$(rec_get "$label" flock_pid)")/$(pid_note "$(rec_get "$label" run_pid)")" \
      "$(rec_get "$label" ref)" "$(rec_get "$label" worktree)"
  done
  [ "$n" -gt 0 ] || echo "(no spec records)"
  echo
  echo "last summary lines ($SUMMARY):"
  tail -n 5 "$SUMMARY" 2>/dev/null || echo "(none)"
}

cmd_drop() {
  local label="" dry=0 lock_wait=60 a pid st i want_wait=0 epid force=0 finished=0 hold age young
  for a in "$@"; do
    if [ "$want_wait" -eq 1 ]; then
      case "$a" in
        ''|*[!0-9]*) die 2 "drop: --lock-wait needs a number of seconds" ;;
        *) lock_wait="$a"; want_wait=0; continue ;;
      esac
    fi
    case "$a" in
      --dry-run) dry=1 ;;
      --force) force=1 ;;
      --finished) finished=1 ;;
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
  if [ "$finished" -eq 1 ]; then
    # An operator override for the one state nothing else can clear: a FINISHED spec whose branch
    # restore was skipped still holds its worktree, and the intended way out is to check that tree
    # out on its branch by hand. When that is impossible or unwanted, this retires the hold
    # explicitly (round-4 review, R2). It touches the record only — the worktree is left exactly
    # as it is, so whatever is checked out there is what the next gate will run over.
    case "$st" in
      done|refused-held) ;;
      *) rec_lock_close; die 3 "drop --finished only retires a finished spec; '$label' is $st" ;;
    esac
    hold="$(record_hold "$label")" || hold=""
    if [ -z "$hold" ]; then
      rec_lock_close
      die 3 "'$label' holds no worktree; there is nothing to retire (see: $self_name list)"
    fi
    if [ "$dry" -eq 1 ]; then
      rec_lock_close
      echo "DRY-RUN: would retire the hold '$label' has on $(rec_get "$label" worktree) — $hold"
      echo "  nothing was written."
      return 0
    fi
    rec_set "$label" "checked_out=" "hold_retired=$(now)" "hold_retired_by=$$"
    rec_lock_close
    echo "retired the hold '$label' had on $(rec_get "$label" worktree): $hold"
    echo "  the WORKTREE was not touched — it is still exactly as that run left it, and the next"
    echo "  gate there will check its ref out over whatever is in it. Look before you enqueue."
    return 0
  fi
  case "$st" in
    waiting) ;;
    running) rec_lock_close; die 3 "refusing to drop '$label': a gate is RUNNING under it (run pid $(rec_get "$label" run_pid), log $(rec_get "$label" log)). drop only kills a spec still waiting for the lock; let this one finish, or stop it on the Mac first." ;;
    done) rec_lock_close; die 3 "refusing to drop '$label': it already finished (rc=$(rec_get "$label" rc)); nothing to kill." ;;
    *) rec_lock_close; die 3 "refusing to drop '$label': unexpected state '$st'" ;;
  esac
  pid="$(rec_get "$label" flock_pid)" || pid=""
  if [ -z "$pid" ]; then
    # The enqueue wrote the record and then died before spawning its flock (round-3 review, A1).
    # There is nothing to signal and nobody will ever finish this spec, so retire it here rather
    # than leave a record that refuses every drop and holds its worktree for good. The drop
    # marker goes in too: if that enqueue is somehow still alive and spawns after all, the run
    # finds the marker and exits 99 without touching the worktree.
    # A spec is an orphan only when its ENQUEUE process is gone AND no child pid was ever
    # recorded (round-5 review, 2a). A live enqueue means the spec is alive whatever its age:
    # it may be waiting behind an hour-long run, or about to spawn its flock this instant.
    epid="$(rec_get "$label" enqueue_pid)" || epid=""
    if [ -n "$epid" ] && kill -0 "$epid" 2>/dev/null && [ "$force" -ne 1 ]; then
      rec_lock_close
      die 5 "refusing to retire '$label': it has no flock pid yet, but its enqueue process $epid is ALIVE — the spec is waiting for the queue lock or about to spawn. Let it be, or pass --force if you know that enqueue is not coming back."
    fi
    # The pid is empty and the enqueue is gone — but "gone" is not enough on a YOUNG record. The
    # age is measured from `enqueued`, the stamp written when the record was created, NOT from
    # when a pid was recorded (round-5 review, 2b): a spec queued behind a long run may wait an
    # hour, and reading its age from a pid it does not have yet would retire it while it waits.
    # Also: the
    # enqueue may have died in the window between spawning its flock and recording the pid, and
    # that flock is then running a gate nobody can see here. The run writes its own pid as its
    # first action, so a record that is still empty after the grace window really was abandoned
    # (round-4 review, R4). --force skips the wait.
    age="$(rec_age_seconds "$label")" || age=""
    young=0
    if [ "$force" -ne 1 ]; then
      case "$age" in
        ''|*[!0-9]*) young=1 ;;
        *) [ "$age" -ge "$DROP_GRACE" ] || young=1 ;;
      esac
    fi
    if [ "$young" -eq 1 ]; then
      rec_lock_close
      die 5 "refusing to retire '$label': its record has no flock pid and is ${age:-of unknown} seconds old (grace window ${DROP_GRACE}s). A flock spawned a moment ago writes its pid as its first action, so wait out the window and look again — or pass --force if you know no gate is starting."
    fi
    # R5: a dry-run must decide BEFORE anything is written, on this path too.
    if [ "$dry" -eq 1 ]; then
      rec_lock_close
      echo "DRY-RUN: would retire '$label' as done rc=143 — no flock was ever spawned (its enqueue process ${epid:-unknown} is gone, record age ${age:-unknown}s)"
      echo "  nothing was signalled and nothing was written."
      return 0
    fi
    rec_set "$label" "drop_requested=$(now)" "state=done" "rc=143" "finished=$(now)" "dropped_by=$$"
    rec_lock_close
    echo "dropped '$label': no flock was ever spawned (its enqueue process ${epid:-unknown} is gone), so nothing was signalled; the record is now done rc=143 and the label is free to re-use"
    return 0
  fi
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
