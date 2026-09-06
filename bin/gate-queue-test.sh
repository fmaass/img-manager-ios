#!/usr/bin/env bash
# gate-queue-test.sh — proves bin/gate-queue.sh's drop safety rules on a disposable queue
# (IMGMGR-335): a live pid whose COMMAND LINE contains the label but whose argv is not an
# enqueue of it is refused (that is the `pgrep -f` self-kill class — three occurrences,
# 2026-08-30 ×2 and 2026-09-01), a running gate is refused, --dry-run signals nothing, and a
# genuinely waiting spec is killed through the pid in its own record.
#
# The test re-execs itself once with the self-match label as one of its OWN argv entries, so
# the shell that invokes `drop` really is a process `pgrep -f <label>` matches — the exact
# shape that killed the caller. Case 1 asserts pgrep would have matched (positive control)
# and that gate-queue.sh's argv parser refuses anyway.
#
# It also covers the round-2 proofs: a flock parent of ANOTHER queue lock, a recycled pid (a
# record whose start time no longer matches the live process), a spec that turns `running`
# while the drop waits for the per-record lock, that lock still being held at --lock-wait, and
# two concurrent enqueues racing for one label.
#
# Needs no Mac: bin/mac-gate.sh is stubbed inside a throwaway git worktree and
# GATE_QUEUE_{LOCK,STATE,SUMMARY} point into a temp dir, so the real queue is never touched.
set -u
self_label=drop-self-decoy
[ "${1:-}" = "__body" ] || exec bash "$0" __body "$self_label"

here="$(cd "$(dirname "$0")" && pwd)"
qs="$here/gate-queue.sh"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
export GATE_QUEUE_LOCK="$tmp/gate.lock"
export GATE_QUEUE_STATE="$tmp/state"
export GATE_QUEUE_SUMMARY="$tmp/summary"
fail=0
strays=""
kids() { cat "/proc/$1/task/$1/children" 2>/dev/null; }
release() { # PID of a `flock … <command>` holder — a killed flock parent leaves its child
            # holding the inherited descriptor, and with it the lock
  local k; for k in $(kids "$1"); do kill "$k" 2>/dev/null; done
  kill "$1" 2>/dev/null; wait "$1" 2>/dev/null
}
cleanup() { local p k; for p in $strays; do for k in $(kids "$p"); do kill -9 "$k" 2>/dev/null; done; kill -9 "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT
ok()  { echo "PASS $1: $2"; }
bad() { echo "FAIL $1: $2"; fail=1; }
alive() { kill -0 "$1" 2>/dev/null; }
dead()  { ! kill -0 "$1" 2>/dev/null; }
field() { sed -n "s/^$2=//p" "$GATE_QUEUE_STATE/$1.spec" 2>/dev/null; }
waitfor() { # SECONDS CMD… — poll CMD every 100 ms
  local n=$1 i=0; shift
  while [ "$i" -lt $((n * 10)) ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
proc_start() { # PID — /proc/PID/stat field 22, the way gate-queue.sh reads it
  local rest; rest="$(cat "/proc/$1/stat")"; rest="${rest##*) }"
  set -f; set -- $rest; set +f; printf '%s\n' "${20}"
}
state_is() { [ "$(field "$1" state)" = "$2" ]; }
has_pid()  { case "$(field "$1" flock_pid)" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

[ -x "$qs" ] || { echo "FAIL setup: $qs is missing or not executable"; exit 1; }

# A throwaway repo + worktree with a stubbed mac-gate, so enqueue runs its real legs.
repo="$tmp/repo"; wt="$tmp/lane"
mkdir -p "$repo/bin"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "gate-queue test"
printf '.gate-artifacts/\n' > "$repo/.gitignore"
cat > "$repo/bin/mac-gate.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p .gate-artifacts
printf 'stub iphone log\n' > .gate-artifacts/test-iphone.log
echo "mac-gate SUMMARY: stub=0 branch=${MAC_GATE_BRANCH:-?} host=${MAC_GATE_HOST:-?}"
# IMGMGR-398 cases only: reproduce, from inside the gated worktree while the queue holds it
# detached, the two ways the tree can move under a run. Unset by default, so every other case
# sees the stub unchanged.
[ -z "${STUB_GATE_COMMIT:-}" ] || git commit -q --allow-empty -m "interloper $STUB_GATE_COMMIT"
[ -z "${STUB_GATE_MOVE_TO:-}" ] || git branch -f "${STUB_GATE_MOVE_BRANCH:-lane}" "$STUB_GATE_MOVE_TO"
sleep "${STUB_GATE_SLEEP:-1}"
exit 0
STUB
chmod +x "$repo/bin/mac-gate.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm init
git -C "$repo" worktree add -q -b lane "$wt"
sha="$(git -C "$wt" rev-parse HEAD)"
mkdir -p "$GATE_QUEUE_STATE"

# ---------------------------------------------------------------- 1: self-match refusal
# The record points at THIS shell, whose command line carries the label as an argv entry.
cat > "$GATE_QUEUE_STATE/$self_label.spec" <<EOF
spec=$wt:$sha:$self_label
worktree=$wt
ref=$sha
label=$self_label
log=$tmp/never.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=$$
run_pid=
state=waiting
rc=
EOF
if command -v pgrep >/dev/null 2>&1 && pgrep -f "$self_label" | grep -qx "$$"; then
  ok 1-control "pgrep -f $self_label matches this test shell (pid $$) — the trap is real"
else
  bad 1-control "pgrep -f $self_label did not match this shell; the case is not set up"
fi
out="$("$qs" drop "$self_label" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && alive $$; then
  ok 1-self "drop refused its own caller (rc=$rc): ${out##*$'\n'}"
else
  bad 1-self "expected a refusal, got rc=$rc: $out"
fi

# 1b: a live decoy whose cmdline CONTAINS the label (pgrep -f would match) but whose argv is
# not an enqueue of it.
# `bash -c '<simple command>'` execs the command and loses its own argv, so the decoy's
# payload is a compound command: its argv keeps every entry below, including the label.
bash -c 'sleep 60; :' _ gate-queue.sh __run "$wt" "$sha" "$self_label" "$tmp/never.log" &
decoy=$!; strays="$strays $decoy"
sed -i "s/^flock_pid=.*/flock_pid=$decoy/" "$GATE_QUEUE_STATE/$self_label.spec"
if pgrep -f "$self_label" | grep -qx "$decoy"; then
  ok 1b-control "pgrep -f $self_label matches the decoy (pid $decoy)"
else
  bad 1b-control "the decoy is not pgrep-visible; the case is not set up"
fi
out="$("$qs" drop "$self_label" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && alive "$decoy"; then
  ok 1b-argv "drop refused a cmdline-substring match and left pid $decoy alive (rc=$rc)"
else
  bad 1b-argv "expected a refusal with the decoy alive, got rc=$rc: $out"
fi
kill "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null

# 1c: the record points at the very shell that INVOKES the drop (its parent process) — the
# literal shape of the 2026-09-01 self-kill, where the killer was the caller.
sed -e "s/^label=.*/label=ppid-demo/" "$GATE_QUEUE_STATE/$self_label.spec" \
    > "$GATE_QUEUE_STATE/ppid-demo.spec"
bash -c 'echo $$ > "$1"; while [ ! -e "$2" ]; do sleep 0.05; done; "$3" drop ppid-demo > "$4" 2>&1; echo "rc=$?" >> "$4"' \
     _ "$tmp/w.pid" "$tmp/w.go" "$qs" "$tmp/w.out" &
wrapper=$!; strays="$strays $wrapper"
if waitfor 10 test -s "$tmp/w.pid"; then
  sed -i "s/^flock_pid=.*/flock_pid=$(cat "$tmp/w.pid")/" "$GATE_QUEUE_STATE/ppid-demo.spec"
  touch "$tmp/w.go"
  wait "$wrapper" 2>/dev/null
  if grep -q '^rc=[1-9]' "$tmp/w.out" && grep -qi "parent" "$tmp/w.out"; then
    ok 1c-ppid "drop refused the pid of the shell that invoked it: $(head -1 "$tmp/w.out")"
  else
    bad 1c-ppid "expected a parent-pid refusal, got: $(cat "$tmp/w.out")"
  fi
else
  bad 1c-ppid "the wrapper shell never reported its pid"
fi
rm -f "$GATE_QUEUE_STATE/ppid-demo.spec"

# ------------------------------------------------------------- 2: running-gate refusal
STUB_GATE_SLEEP=6 "$qs" enqueue "$wt:$sha:running-demo" > "$tmp/enq1.out" 2>&1 &
enq1=$!; strays="$strays $enq1"
if waitfor 20 state_is running-demo running; then
  ok 2-setup "spec running-demo reached state=running (run pid $(field running-demo run_pid))"
else
  bad 2-setup "spec running-demo never reached state=running"
fi
out="$("$qs" drop running-demo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(field running-demo state)" = running ]; then
  ok 2-running "drop refused a running gate (rc=$rc): ${out##*$'\n'}"
else
  bad 2-running "expected a refusal of the running gate, got rc=$rc: $out"
fi
wait "$enq1"; enq1rc=$?
log1="$(field running-demo log)"
if [ "$(field running-demo state)" = done ] && [ "$(field running-demo rc)" = 0 ] && [ "$enq1rc" -eq 0 ]; then
  ok 2-done "the enqueue process recorded state=done rc=0 itself (queue exit $enq1rc)"
else
  bad 2-done "state=$(field running-demo state) rc=$(field running-demo rc) queue exit=$enq1rc"
fi
if grep -q 'running-demo ref=.* rc=0 mac-gate SUMMARY: stub=0' "$GATE_QUEUE_SUMMARY" \
   && grep -q 'QUEUE-DONE' "$GATE_QUEUE_SUMMARY"; then
  ok 2-summary "the v4 summary line and QUEUE-DONE were appended"
else
  bad 2-summary "summary file: $(cat "$GATE_QUEUE_SUMMARY")"
fi
if [ -f "${log1%.log}-test-iphone.log" ]; then
  ok 2-logs "the run's test-iphone.log was preserved beside the run log"
else
  bad 2-logs "no preserved test log beside $log1"
fi
if [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = lane ]; then
  ok 2-restore "the worktree was restored to its branch after the run"
else
  bad 2-restore "worktree HEAD is $(git -C "$wt" rev-parse --abbrev-ref HEAD), expected lane"
fi

# ------------------------------------------- 3/4: a genuinely waiting spec, dry-run then kill
flock -w 120 "$GATE_QUEUE_LOCK" sleep 90 &
holder=$!; strays="$strays $holder"
sleep 0.5

# F4: two enqueues race for one label; the record is created with O_EXCL so exactly one wins.
( "$qs" enqueue "$wt:$sha:dup-demo" > "$tmp/d1.out" 2>&1; echo $? > "$tmp/d1.rc" ) &
dup1=$!; strays="$strays $dup1"
( "$qs" enqueue "$wt:$sha:dup-demo" > "$tmp/d2.out" 2>&1; echo $? > "$tmp/d2.rc" ) &
dup2=$!; strays="$strays $dup2"
waitfor 20 test -s "$tmp/d1.rc" -o -s "$tmp/d2.rc"
sleep 0.5
losers=0; loser_rc=""; loser_out=""
for n in 1 2; do
  if [ -s "$tmp/d$n.rc" ]; then losers=$((losers + 1)); loser_rc="$(cat "$tmp/d$n.rc")"; loser_out="$(cat "$tmp/d$n.out")"; fi
done
if [ "$losers" -eq 1 ] && [ "$loser_rc" = 2 ] && state_is dup-demo waiting    && printf '%s' "$loser_out" | grep -q "dup-demo"; then
  ok F4-dup "one enqueue of dup-demo was admitted, the other exited 2: ${loser_out##*: }"
else
  bad F4-dup "losers=$losers rc=$loser_rc state=$(field dup-demo state): $loser_out"
fi
out="$("$qs" drop dup-demo 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok F4-cleanup "the admitted dup-demo spec was dropped (rc=0)" \
                || bad F4-cleanup "drop dup-demo rc=$rc: $out"
wait "$dup1" "$dup2" 2>/dev/null
if state_is dup-demo done; then
  ( "$qs" enqueue "$wt:$sha:dup-demo" > "$tmp/r1.out" 2>&1; echo $? > "$tmp/r1.rc" ) &
  re1=$!; strays="$strays $re1"
  ( "$qs" enqueue "$wt:$sha:dup-demo" > "$tmp/r2.out" 2>&1; echo $? > "$tmp/r2.rc" ) &
  re2=$!; strays="$strays $re2"
  waitfor 20 test -s "$tmp/r1.rc" -o -s "$tmp/r2.rc"
  sleep 0.5
  losers=0; loser_rc=""; loser_out=""
  for n in 1 2; do
    if [ -s "$tmp/r$n.rc" ]; then losers=$((losers + 1)); loser_rc="$(cat "$tmp/r$n.rc")"; loser_out="$(cat "$tmp/r$n.out")"; fi
  done
  if [ "$losers" -eq 1 ] && [ "$loser_rc" = 2 ] && state_is dup-demo waiting; then
    ok F4-readmit "two re-enqueues of a finished label admitted exactly one (loser rc=2)"
  else
    bad F4-readmit "losers=$losers rc=$loser_rc state=$(field dup-demo state): $loser_out"
  fi
  "$qs" drop dup-demo > /dev/null 2>&1
  wait "$re1" "$re2" 2>/dev/null
else
  bad F4-readmit "dup-demo did not end up done: state=$(field dup-demo state)"
fi

STUB_GATE_SLEEP=1 "$qs" enqueue "$wt:$sha:waiting-demo" > "$tmp/enq2.out" 2>&1 &
enq2=$!; strays="$strays $enq2"
if waitfor 20 has_pid waiting-demo && state_is waiting-demo waiting; then
  ok 3-setup "spec waiting-demo is waiting on the lock (flock pid $(field waiting-demo flock_pid))"
else
  bad 3-setup "state=$(field waiting-demo state) flock_pid=$(field waiting-demo flock_pid)"
fi
wpid="$(field waiting-demo flock_pid)"
rec="$GATE_QUEUE_STATE/waiting-demo.spec"

# F2: a record whose start time no longer matches the live pid is a recycled pid.
true_start="$(field waiting-demo flock_start)"
sed -i "s/^flock_start=.*/flock_start=$((true_start + 7))/" "$rec"
out="$("$qs" drop waiting-demo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && alive "$wpid" && printf '%s' "$out" | grep -q "recycled pid"; then
  ok F2-starttime "drop refused a pid whose start time does not match the record (rc=$rc)"
else
  bad F2-starttime "rc=$rc alive=$(alive "$wpid" && echo yes || echo no): $out"
fi
sed -i "s/^flock_start=.*/flock_start=$true_start/" "$rec"

# F3a: the per-record lock is held; drop waits and then names the reason.
flock "$GATE_QUEUE_STATE/waiting-demo.lock" sleep 6 &
reclock=$!; strays="$strays $reclock"
sleep 0.3
out="$("$qs" drop waiting-demo --lock-wait 1 2>&1)"; rc=$?
if [ "$rc" -eq 6 ] && alive "$wpid" && printf '%s' "$out" | grep -q "per-record lock"; then
  ok F3a-lockwait "drop timed out on the per-record lock and signalled nothing (rc=6)"
else
  bad F3a-lockwait "rc=$rc: $out"
fi
release "$reclock"

# F3b: the spec turns `running` while the drop is waiting for that same lock.
flock "$GATE_QUEUE_STATE/waiting-demo.lock" \
  bash -c 'sleep 2; sed -i "s/^state=waiting/state=running/" "$1"' _ "$rec" &
flipper=$!; strays="$strays $flipper"
sleep 0.3
out="$("$qs" drop waiting-demo --lock-wait 15 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && alive "$wpid" && printf '%s' "$out" | grep -q "RUNNING"; then
  ok F3b-transition "a spec that turned running while drop waited was refused (rc=3)"
else
  bad F3b-transition "rc=$rc alive=$(alive "$wpid" && echo yes || echo no): $out"
fi
wait "$flipper" 2>/dev/null
sed -i "s/^state=running/state=waiting/" "$rec"

# F1: a real flock parent with this script's __run argv for the same label — but on ANOTHER
# lock. Only the lock operand differs, so only the argv lock binding can refuse it.
other="$tmp/other.lock"
flock -w 60 "$other" sleep 30 &
olholder=$!; strays="$strays $olholder"
sleep 0.3
flock -w 60 "$other" "$qs" __run "$wt" "$sha" otherlock-demo "$tmp/never.log" &
opid=$!; strays="$strays $opid"
sleep 0.5
sed -e "s/^label=.*/label=otherlock-demo/" -e "s/^flock_pid=.*/flock_pid=$opid/" \
    -e "s|^flock_start=.*|flock_start=$(proc_start "$opid")|" \
    "$rec" > "$GATE_QUEUE_STATE/otherlock-demo.spec"
out="$("$qs" drop otherlock-demo 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && alive "$opid" && printf '%s' "$out" | grep -q "flock operand"; then
  ok F1-argvlock "drop refused a flock parent of another queue lock (rc=5)"
else
  bad F1-argvlock "rc=$rc alive=$(alive "$opid" && echo yes || echo no): $out"
fi
sed -i "s|^lock=.*|lock=$other|" "$GATE_QUEUE_STATE/otherlock-demo.spec"
out="$("$qs" drop otherlock-demo 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && alive "$opid" && printf '%s' "$out" | grep -q "belongs to queue lock"; then
  ok F1-reclock "drop refused a record written for another queue lock (rc=5)"
else
  bad F1-reclock "rc=$rc: $out"
fi
# …and the same trick with this queue's lock present in argv as flock's COMMAND rather than
# as its operand: the entry is there, but the process waits on another lock.
flock "$other" "$GATE_QUEUE_LOCK" "$qs" __run "$wt" "$sha" otherlock-demo "$tmp/never.log" &
opid2=$!; strays="$strays $opid2"
sleep 0.5
sed -e "s/^label=.*/label=otherlock-demo/" -e "s/^flock_pid=.*/flock_pid=$opid2/" \
    -e "s|^flock_start=.*|flock_start=$(proc_start "$opid2")|" \
    "$rec" > "$GATE_QUEUE_STATE/otherlock-demo.spec"
out="$("$qs" drop otherlock-demo 2>&1)"; rc=$?
if [ "$rc" -eq 5 ] && alive "$opid2" && printf '%s' "$out" | grep -q "flock operand"; then
  ok F1-operand "drop refused a flock whose operand is another lock, our lock being its command"
else
  bad F1-operand "rc=$rc alive=$(alive "$opid2" && echo yes || echo no): $out"
fi
kill "$opid2" 2>/dev/null; wait "$opid2" 2>/dev/null
kill "$opid" 2>/dev/null; wait "$opid" 2>/dev/null
release "$olholder"
rm -f "$GATE_QUEUE_STATE/otherlock-demo.spec"
out="$("$qs" drop waiting-demo --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "$wpid" && alive "$wpid" \
   && [ "$(field waiting-demo state)" = waiting ]; then
  ok 3-dryrun "--dry-run named pid $wpid and signalled nothing"
else
  bad 3-dryrun "rc=$rc alive=$(alive "$wpid" && echo yes || echo no): $out"
fi
sed -e "s/^label=.*/label=hijack-demo/" -e "s/^flock_pid=.*/flock_pid=$wpid/" \
    "$GATE_QUEUE_STATE/waiting-demo.spec" > "$GATE_QUEUE_STATE/hijack-demo.spec"
out="$("$qs" drop hijack-demo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && alive "$wpid"; then
  ok 3b-label "drop refused a record pointing at another spec's flock parent (rc=$rc)"
else
  bad 3b-label "expected a refusal, got rc=$rc: $out"
fi
rm -f "$GATE_QUEUE_STATE/hijack-demo.spec"

out="$("$qs" drop waiting-demo 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && waitfor 10 dead "$wpid"; then
  ok 4-kill "drop killed the waiting flock parent $wpid (rc=$rc)"
else
  bad 4-kill "rc=$rc, pid $wpid alive=$(alive "$wpid" && echo yes || echo no): $out"
fi
wait "$enq2" 2>/dev/null
if [ "$(field waiting-demo state)" = done ] && [ "$(field waiting-demo rc)" = 143 ]; then
  ok 4-state "the record moved to done rc=143 (SIGTERM)"
else
  bad 4-state "state=$(field waiting-demo state) rc=$(field waiting-demo rc)"
fi
if [ ! -s "$(field waiting-demo log)" ] && [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = lane ]; then
  ok 4-nogate "no gate ran for the dropped spec and the worktree was never checked out"
else
  bad 4-nogate "log=$(field waiting-demo log) head=$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
fi
out="$("$qs" drop waiting-demo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok 4-done "drop refuses a finished spec (rc=$rc): ${out##*$'\n'}"
else
  bad 4-done "expected a refusal for the finished spec, got rc=$rc"
fi
release "$holder"

# 4b: the last window F3 leaves — a run that forks between the children check and the signal.
# (a) A REAL drop, while the test holds the per-record lock: it can neither write its marker nor
# signal until the lock is free, which is the ordering F3 requires. (b) A real __run started for
# the record that drop marked exits 99 without touching the worktree. No marker is ever injected.
flock -w 60 "$GATE_QUEUE_LOCK" sleep 60 &
holder2=$!; strays="$strays $holder2"
sleep 0.3
"$qs" enqueue "$wt:$sha:abortsrc-demo" > "$tmp/enq3.out" 2>&1 &
enq3=$!; strays="$strays $enq3"
if waitfor 20 has_pid abortsrc-demo && state_is abortsrc-demo waiting; then
  apid="$(field abortsrc-demo flock_pid)"
  exec 7>>"$GATE_QUEUE_STATE/abortsrc-demo.lock"
  flock 7
  # fd 7 must NOT reach the drop: an inherited descriptor carries the test's own lock, and the
  # drop would then block on a lock its own process already holds through that copy.
  ( exec 7>&-; "$qs" drop abortsrc-demo --lock-wait 30 > "$tmp/drop_a.out" 2>&1; echo $? > "$tmp/drop_a.rc" ) &
  dropbg=$!; strays="$strays $dropbg"
  sleep 1.5
  if [ -z "$(field abortsrc-demo drop_requested)" ] && alive "$apid" && [ ! -s "$tmp/drop_a.rc" ]; then
    ok 4b-ordering "while the test held the record lock the real drop wrote no marker and signalled nothing"
  else
    bad 4b-ordering "marker=$(field abortsrc-demo drop_requested) alive=$(alive "$apid" && echo yes || echo no) rc=$(cat "$tmp/drop_a.rc" 2>/dev/null)"
  fi
  exec 7>&-
  wait "$dropbg" 2>/dev/null
  if [ "$(cat "$tmp/drop_a.rc" 2>/dev/null)" = 0 ] && [ -n "$(field abortsrc-demo drop_requested)" ] \
     && dead "$apid"; then
    ok 4b-marker "once the lock was free the drop wrote its marker and killed the flock parent"
  else
    bad 4b-marker "rc=$(cat "$tmp/drop_a.rc" 2>/dev/null) marker=$(field abortsrc-demo drop_requested): $(cat "$tmp/drop_a.out")"
  fi
  wait "$enq3" 2>/dev/null
  release "$holder2"
  flock -w 30 "$GATE_QUEUE_LOCK" "$qs" __run "$wt" "$sha" abortsrc-demo "$tmp/abort-b.log"
  brc=$?
  if [ "$brc" -eq 99 ] && grep -q DROPPED-BEFORE-START "$tmp/abort-b.log" \
     && [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = lane ]; then
    ok 4b-abort "a run started for that marked record exited 99 without touching the worktree"
  else
    bad 4b-abort "rc=$brc log=$(cat "$tmp/abort-b.log" 2>&1) head=$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
  fi
else
  bad 4b-ordering "spec abortsrc-demo never reached the queue"
  release "$holder2"
fi

# ---------------------------------------------- 6: enqueue refuses a held worktree (IMGMGR-398)
# A second worktree, so these cases cannot disturb the lane the drop cases use.
wt2="$tmp/lane2"
git -C "$repo" worktree add -q -b lane2 "$wt2"
sha2="$(git -C "$wt2" rev-parse HEAD)"

STUB_GATE_SLEEP=6 "$qs" enqueue "$wt2:$sha2:hold-demo" > "$tmp/enq6.out" 2>&1 &
enq6=$!; strays="$strays $enq6"
if waitfor 20 state_is hold-demo running; then
  ok 6-setup "hold-demo is RUNNING with $wt2 checked out at $sha2"
else
  bad 6-setup "hold-demo never reached state=running"
fi
out="$("$qs" enqueue "$wt2:$sha2:second-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && [ ! -e "$GATE_QUEUE_STATE/second-demo.spec" ] \
   && printf '%s' "$out" | grep -q "hold-demo"; then
  ok 6-refuse "enqueue on a worktree held by a running gate exited 7 and wrote no record: ${out##*: }"
else
  bad 6-refuse "rc=$rc record=$([ -e "$GATE_QUEUE_STATE/second-demo.spec" ] && echo written || echo none): $out"
fi
out="$("$qs" list 2>&1)"
# On the HOLDER line itself, not merely somewhere in the output: a summary tail line already
# carries both strings through the run log path, so a whole-output grep is not evidence.
if printf '%s\n' "$out" | grep '^holder' | grep -q "hold-demo" \
   && printf '%s\n' "$out" | grep '^holder' | grep -q "$wt2" \
   && printf '%s\n' "$out" | grep -q 'WORKTREE'; then
  ok 6-list "the holder line names $wt2 beside hold-demo, and the table has a WORKTREE column"
else
  bad 6-list "list does not show the held worktree: $out"
fi
wait "$enq6" 2>/dev/null
# Control: the same spec is admitted once the hold is gone — the refusal is not blanket.
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:second-demo" > "$tmp/enq6b.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field second-demo state)" = done ]; then
  ok 6-control "the same spec was admitted after the running gate finished (rc=0)"
else
  bad 6-control "rc=$rc state=$(field second-demo state): $(cat "$tmp/enq6b.out")"
fi

# ------------------------------- 7: a commit made into the detached worktree is never orphaned
STUB_GATE_COMMIT=1 STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:moved-demo" > "$tmp/enq7.out" 2>&1; rc7=$?
head_after="$(git -C "$wt2" rev-parse HEAD)"
if [ "$head_after" != "$sha2" ] && [ "$(git -C "$wt2" rev-parse lane2)" = "$sha2" ] \
   && ! git -C "$wt2" symbolic-ref -q HEAD >/dev/null 2>&1 \
   && grep -q "HEAD MOVED $sha2 -> $head_after" "$tmp/enq7.out"; then
  ok 7-headmoved "the run left the worktree at its new commit $head_after and said so (queue rc=$rc7)"
else
  bad 7-headmoved "head=$head_after lane2=$(git -C "$wt2" rev-parse lane2): $(cat "$tmp/enq7.out")"
fi
if [ "$(field moved-demo restore)" = skipped-head-moved ] && [ "$(field moved-demo checked_out)" = "$sha2" ]; then
  ok 7-record "the record carries restore=skipped-head-moved and keeps checked_out=$sha2"
else
  bad 7-record "restore=$(field moved-demo restore) checked_out=$(field moved-demo checked_out)"
fi
out="$("$qs" enqueue "$wt2:$sha2:after-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && printf '%s' "$out" | grep -q "moved-demo"; then
  ok 7-hold "a worktree left checked out by a skipped restore refuses the next enqueue (rc=7)"
else
  bad 7-hold "rc=$rc: $out"
fi
git -C "$wt2" checkout -q lane2
out="$(STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:heal-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field heal-demo restore)" = ok ]; then
  ok 7-heal "once the tree is back on its branch by hand the queue admits it again (rc=0)"
else
  bad 7-heal "rc=$rc restore=$(field heal-demo restore): $out"
fi

# ---------------------------------------- 8: a branch that moved during the run is never rewound
git -C "$repo" branch -q -f elsewhere "$sha2" 2>/dev/null || git -C "$repo" branch -q elsewhere "$sha2"
git -C "$repo" commit -q --allow-empty -m "moved tip" 2>/dev/null
moved_to="$(git -C "$repo" rev-parse HEAD)"
[ "$moved_to" != "$sha2" ] || bad 8-setup "the repo HEAD did not move; the case is not set up"
STUB_GATE_MOVE_BRANCH=lane2 STUB_GATE_MOVE_TO="$moved_to" STUB_GATE_SLEEP=1 \
  "$qs" enqueue "$wt2:$sha2:bmove-demo" > "$tmp/enq8.out" 2>&1; rc8=$?
if [ "$(git -C "$wt2" rev-parse HEAD)" = "$sha2" ] \
   && ! git -C "$wt2" symbolic-ref -q HEAD >/dev/null 2>&1 \
   && [ "$(git -C "$wt2" rev-parse lane2)" = "$moved_to" ] \
   && grep -q "BRANCH MOVED $sha2 -> $moved_to" "$tmp/enq8.out"; then
  ok 8-branchmoved "the run left lane2 at $moved_to and the worktree detached at $sha2 (queue rc=$rc8)"
else
  bad 8-branchmoved "head=$(git -C "$wt2" rev-parse HEAD) lane2=$(git -C "$wt2" rev-parse lane2): $(cat "$tmp/enq8.out")"
fi
if [ "$(field bmove-demo restore)" = skipped-branch-moved ]; then
  ok 8-record "the record carries restore=skipped-branch-moved"
else
  bad 8-record "restore=$(field bmove-demo restore)"
fi
git -C "$wt2" checkout -q lane2

# ------- 9: a run that reaches the queue lock after the tree was left held refuses (round 2)
# The sequential race: spec A finishes and deliberately leaves the worktree detached over the
# commits made during its run; spec B was queued BEFORE that and would check its own ref out on
# top, orphaning them again. `__run` behind the queue lock is exactly what a queued spec does
# when the lock is finally granted.
STUB_GATE_COMMIT=r2 STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:held-src" > "$tmp/enq9.out" 2>&1
preserved="$(git -C "$wt2" rev-parse HEAD)"
if [ "$preserved" != "$sha2" ] && [ "$(field held-src restore)" = skipped-head-moved ]; then
  ok 9-setup "held-src left $wt2 detached at the new commit $preserved"
else
  bad 9-setup "head=$preserved restore=$(field held-src restore)"
fi
flock -w 30 "$GATE_QUEUE_LOCK" "$qs" __run "$wt2" "$sha2" queued-demo "$tmp/queued.log"; qrc=$?
if [ "$qrc" -eq 7 ] && [ "$(git -C "$wt2" rev-parse HEAD)" = "$preserved" ] \
   && grep -q 'REFUSED-HELD' "$tmp/queued.log" && ! grep -q 'mac-gate SUMMARY' "$tmp/queued.log" \
   && [ "$(field queued-demo state)" = refused-held ] && [ "$(field queued-demo rc)" = 7 ]; then
  ok 9-queued "the queued run refused the held worktree (rc=7), left HEAD at $preserved and never started the gate"
else
  bad 9-queued "rc=$qrc head=$(git -C "$wt2" rev-parse HEAD) state=$(field queued-demo state) log=$(cat "$tmp/queued.log" 2>&1)"
fi
# Control: the very same direct run proceeds once the tree is back on its branch by hand.
git -C "$wt2" checkout -q lane2
rm -f "$GATE_QUEUE_STATE/queued-demo.spec"
flock -w 30 "$GATE_QUEUE_LOCK" "$qs" __run "$wt2" "$sha2" queued-ok "$tmp/queued2.log"; qrc2=$?
if [ "$qrc2" -eq 0 ] && grep -q 'mac-gate SUMMARY' "$tmp/queued2.log" \
   && [ "$(field queued-ok restore)" = ok ] && [ "$(git -C "$wt2" rev-parse --abbrev-ref HEAD)" = lane2 ]; then
  ok 9-control "the same run proceeds on a free worktree (rc=0) and restores the branch"
else
  bad 9-control "rc=$qrc2 restore=$(field queued-ok restore) head=$(git -C "$wt2" rev-parse --abbrev-ref HEAD)"
fi

# ------------------------- 10: a WAITING spec holds its worktree too (never commit under a
# running OR QUEUED gate), and `list` says so.
flock -w 60 "$GATE_QUEUE_LOCK" sleep 30 &
holder3=$!; strays="$strays $holder3"
sleep 0.5
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:queued-a" > "$tmp/enq10.out" 2>&1 &
enq10=$!; strays="$strays $enq10"
if waitfor 20 has_pid queued-a && state_is queued-a waiting; then
  ok 10-setup "queued-a is waiting for the queue lock on $wt2"
else
  bad 10-setup "state=$(field queued-a state)"
fi
out="$("$qs" enqueue "$wt2:$sha2:queued-b" 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && printf '%s' "$out" | grep -q 'queued-a' \
   && printf '%s' "$out" | grep -qi 'queued' && [ ! -e "$GATE_QUEUE_STATE/queued-b.spec" ]; then
  ok 10-queued-hold "a second spec on a worktree with a QUEUED gate was refused (rc=7), no record written"
else
  bad 10-queued-hold "rc=$rc record=$([ -e "$GATE_QUEUE_STATE/queued-b.spec" ] && echo written || echo none): $out"
fi
out="$("$qs" list 2>&1)"
if printf '%s\n' "$out" | grep '^held' | grep -q 'queued-a'; then
  ok 10-list "list reports the queued hold on a held line"
else
  bad 10-list "no held line for the queued spec: $(printf '%s\n' "$out" | grep '^held')"
fi
# A DIFFERENT worktree is unaffected while queued-a waits — the hold is per worktree.
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt:$sha:otherwt-demo" > "$tmp/enq10b.out" 2>&1 &
enq10b=$!; strays="$strays $enq10b"
if waitfor 20 state_is otherwt-demo waiting; then
  ok 10-control "a spec on another worktree was admitted while queued-a holds $wt2"
else
  bad 10-control "state=$(field otherwt-demo state): $(cat "$tmp/enq10b.out")"
fi
"$qs" drop otherwt-demo > /dev/null 2>&1
wait "$enq10b" 2>/dev/null
"$qs" drop queued-a > /dev/null 2>&1
release "$holder3"
wait "$enq10" 2>/dev/null

# ---- 11: retiring a finished label must not throw away the hold it has on ANOTHER worktree
# (round-3 review, B3): label `a` finished on worktree A leaving it detached over a preserved
# commit; re-enqueuing `a` on worktree B used to delete A's record — and with it the only
# evidence that A is held.
STUB_GATE_COMMIT=b3 STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:retire-demo" > "$tmp/enq11.out" 2>&1
preserved2="$(git -C "$wt2" rev-parse HEAD)"
if [ "$preserved2" != "$sha2" ] && [ "$(field retire-demo restore)" = skipped-head-moved ]; then
  ok 11-setup "retire-demo finished holding $wt2 at $preserved2"
else
  bad 11-setup "head=$preserved2 restore=$(field retire-demo restore)"
fi
out="$("$qs" enqueue "$wt:$sha:retire-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && printf '%s' "$out" | grep -q "$wt2" && [ -f "$GATE_QUEUE_STATE/retire-demo.spec" ] \
   && [ "$(field retire-demo checked_out)" = "$sha2" ]; then
  ok 11-refuse "re-enqueuing the finished label on another worktree was refused (rc=7) and its record survived"
else
  bad 11-refuse "rc=$rc record=$([ -f "$GATE_QUEUE_STATE/retire-demo.spec" ] && echo kept || echo DELETED) checked_out=$(field retire-demo checked_out): $out"
fi
out="$("$qs" enqueue "$wt2:$sha2:later-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 7 ] && [ "$(git -C "$wt2" rev-parse HEAD)" = "$preserved2" ]; then
  ok 11-evidence "the hold on $wt2 still refuses a later enqueue, so the preserved commit stands"
else
  bad 11-evidence "rc=$rc head=$(git -C "$wt2" rev-parse HEAD)"
fi
git -C "$wt2" checkout -q lane2
out="$(STUB_GATE_SLEEP=1 "$qs" enqueue "$wt:$sha:retire-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field retire-demo worktree)" = "$wt" ]; then
  ok 11-control "once $wt2 is back on its branch the label retires and runs on the other worktree (rc=0)"
else
  bad 11-control "rc=$rc worktree=$(field retire-demo worktree): $out"
fi

# ---- 12: no lock inversion between concurrent enqueues (round-3 review, B5). The deterministic
# half: a record whose own lock is held by someone else must not block an enqueue for a DIFFERENT
# worktree — that was a blanket refusal, and it is also the shape the inversion degraded into.
flock -w 60 "$GATE_QUEUE_LOCK" sleep 25 &
holder4=$!; strays="$strays $holder4"
sleep 0.5
# fd 5 is taken AFTER the lock holder is launched and closed inside every child below: an
# inherited descriptor carries this lock into that process and would keep it long after the
# test released it (flock locks belong to the open file description, not to the process).
exec 5>>"$GATE_QUEUE_STATE/retire-demo.lock"
flock 5
( exec 5>&-; STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:inv-b" > "$tmp/enq12b.out" 2>&1 ) &
enq12b=$!; strays="$strays $enq12b"
if waitfor 20 state_is inv-b waiting; then
  ok 12-locked-other "an enqueue for $wt2 was admitted while another record's lock is held by a third party"
else
  bad 12-locked-other "state=$(field inv-b state): $(cat "$tmp/enq12b.out")"
fi
exec 5>&-
# The concurrent half: two enqueues of finished labels on DIFFERENT worktrees, started together,
# must both be admitted — neither may see the other as a hold or time out on its record lock.
"$qs" drop inv-b > /dev/null 2>&1; wait "$enq12b" 2>/dev/null
( STUB_GATE_SLEEP=1 "$qs" enqueue "$wt:$sha:inv-x" > "$tmp/i1.out" 2>&1; echo $? > "$tmp/i1.rc" ) &
ix=$!; strays="$strays $ix"
( STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:inv-y" > "$tmp/i2.out" 2>&1; echo $? > "$tmp/i2.rc" ) &
iy=$!; strays="$strays $iy"
if waitfor 25 state_is inv-x waiting && waitfor 25 state_is inv-y waiting; then
  ok 12-concurrent "two concurrent enqueues on different worktrees were both admitted, neither refused"
else
  bad 12-concurrent "inv-x=$(field inv-x state) inv-y=$(field inv-y state) rc=$(cat "$tmp/i1.rc" 2>/dev/null)/$(cat "$tmp/i2.rc" 2>/dev/null) out=$(cat "$tmp/i1.out" "$tmp/i2.out" 2>/dev/null)"
fi
"$qs" drop inv-x > /dev/null 2>&1; "$qs" drop inv-y > /dev/null 2>&1
release "$holder4"; wait "$ix" "$iy" 2>/dev/null

# ---- 13: a run-side refusal reaches the CALLER as exit 7 and finalizes its own record (B6).
# The hold appears AFTER admission, which is the only way the run-side check can be reached
# through the real enqueue path: the spec is admitted while the tree is free, and the tree is
# left held while the spec waits for the queue lock.
flock -w 60 "$GATE_QUEUE_LOCK" sleep 20 &
holder5=$!; strays="$strays $holder5"
sleep 0.5
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:late-demo" > "$tmp/enq13.out" 2>&1 &
enq13=$!; strays="$strays $enq13"
if waitfor 20 state_is late-demo waiting; then
  ok 13-setup "late-demo was admitted while $wt2 was free and is waiting for the lock"
else
  bad 13-setup "state=$(field late-demo state)"
fi
# Another spec leaves the tree held while late-demo waits (written the way a finished run does).
git -C "$wt2" checkout -q --detach "$sha2"
git -C "$wt2" commit -q --allow-empty -m "interloper b6"
held_head="$(git -C "$wt2" rev-parse HEAD)"
cat > "$GATE_QUEUE_STATE/holder-demo.spec" <<EOF
spec=$wt2:$sha2:holder-demo
worktree=$wt2
ref=$sha2
label=holder-demo
log=$tmp/holder.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=
run_pid=
state=done
rc=0
checked_out=$sha2
restore=skipped-head-moved
EOF
release "$holder5"
wait "$enq13"; rc13=$?
if [ "$rc13" -eq 7 ] && [ "$(field late-demo state)" = refused-held ] && [ "$(field late-demo rc)" = 7 ] \
   && grep -q 'REFUSED-HELD' "$(field late-demo log)" && [ "$(git -C "$wt2" rev-parse HEAD)" = "$held_head" ]; then
  ok 13-exit7 "the enqueue caller got exit 7, the record stayed refused-held rc=7 and $wt2 was untouched"
else
  bad 13-exit7 "enqueue rc=$rc13 state=$(field late-demo state) rc=$(field late-demo rc) head=$(git -C "$wt2" rev-parse HEAD): $(cat "$tmp/enq13.out")"
fi
if grep -q 'refused-held' "$GATE_QUEUE_SUMMARY"; then
  ok 13-summary "the summary line records the refusal"
else
  bad 13-summary "summary tail: $(tail -2 "$GATE_QUEUE_SUMMARY")"
fi
rm -f "$GATE_QUEUE_STATE/holder-demo.spec"
git -C "$wt2" checkout -q lane2

# ---- 14: the enqueue process never finalizes a record it no longer owns (B6). The label is
# taken over mid-run (what a replacement enqueue does after a refusal); the original parent must
# leave that record alone.
STUB_GATE_SLEEP=6 "$qs" enqueue "$wt:$sha:own-demo" > "$tmp/enq14.out" 2>&1 &
enq14=$!; strays="$strays $enq14"
if waitfor 20 state_is own-demo running && waitfor 10 has_pid own-demo; then
  # Take the label over the way the queue itself writes: under the record's lock. An unlocked
  # edit races the enqueue's own `rec_set flock_pid=…` and gets clobbered — the record is shared
  # state, and this test is a writer like any other.
  exec 4>>"$GATE_QUEUE_STATE/own-demo.lock"
  flock 4
  sed -i 's/^enqueue_pid=.*/enqueue_pid=999999/' "$GATE_QUEUE_STATE/own-demo.spec"
  exec 4>&-
  wait "$enq14" 2>/dev/null
  if [ "$(field own-demo enqueue_pid)" = 999999 ] && [ "$(field own-demo state)" != done ]; then
    ok 14-ownership "the enqueue process left a record owned by another enqueue alone (state=$(field own-demo state))"
  else
    bad 14-ownership "enqueue_pid=$(field own-demo enqueue_pid) state=$(field own-demo state)"
  fi
else
  bad 14-ownership "own-demo never reached state=running"
fi

# ---- 15: A1 — a queued hold is bound to the flock's start time, and drop can retire a waiting
# record whose enqueue died before it ever spawned a flock.
flock -w 60 "$GATE_QUEUE_LOCK" sleep 20 &
holder6=$!; strays="$strays $holder6"
sleep 0.5
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:start-demo" > "$tmp/enq15.out" 2>&1 &
enq15=$!; strays="$strays $enq15"
if waitfor 20 has_pid start-demo && state_is start-demo waiting; then
  out="$("$qs" list 2>&1)"
  true_start15="$(field start-demo flock_start)"
  sed -i "s/^flock_start=.*/flock_start=$((true_start15 + 7))/" "$GATE_QUEUE_STATE/start-demo.spec"
  out2="$("$qs" list 2>&1)"
  if printf '%s\n' "$out" | grep '^held' | grep -q 'start-demo' \
     && ! printf '%s\n' "$out2" | grep '^held' | grep -q 'start-demo'; then
    ok 15-starttime "the queued hold is bound to the flock start time: it vanishes when the record's start time no longer matches"
  else
    bad 15-starttime "before: $(printf '%s\n' "$out" | grep '^held') after: $(printf '%s\n' "$out2" | grep '^held')"
  fi
  sed -i "s/^flock_start=.*/flock_start=$true_start15/" "$GATE_QUEUE_STATE/start-demo.spec"
else
  bad 15-starttime "start-demo never reached waiting with a pid"
fi
"$qs" drop start-demo > /dev/null 2>&1
release "$holder6"
wait "$enq15" 2>/dev/null
# A record left `waiting` with no flock pid at all: the enqueue died between writing the record
# and spawning. drop retires it instead of refusing forever.
cat > "$GATE_QUEUE_STATE/orphan-demo.spec" <<EOF
spec=$wt2:$sha2:orphan-demo
worktree=$wt2
ref=$sha2
label=orphan-demo
log=$tmp/orphan.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=999999
flock_pid=
run_pid=
state=waiting
rc=
enqueued=$(date -d '2 hours ago' '+%Y-%m-%d %H:%M:%S')
EOF
out="$("$qs" drop orphan-demo 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field orphan-demo state)" = done ] && [ "$(field orphan-demo rc)" = 143 ]; then
  ok 15-orphan "drop retired a waiting record whose enqueue never spawned a flock (rc=0): ${out##*$'\n'}"
else
  bad 15-orphan "rc=$rc state=$(field orphan-demo state) rc=$(field orphan-demo rc): $out"
fi

# ---- 16: the caller gets 7 for a run-side refusal even when the label was taken over while the
# spec waited (round-4 review, R1): the enqueue must carry its own child's outcome, not re-read it
# from a record that is no longer its own.
hold_wt2() { # detach $wt2 over a new commit and record a holder spec, the way a skipped restore does
  git -C "$wt2" checkout -q --detach "$sha2"
  git -C "$wt2" commit -q --allow-empty -m "$1"
  cat > "$GATE_QUEUE_STATE/holder-demo.spec" <<EOF
spec=$wt2:$sha2:holder-demo
worktree=$wt2
ref=$sha2
label=holder-demo
log=$tmp/holder.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=
run_pid=
state=done
rc=0
checked_out=$sha2
restore=skipped-head-moved
EOF
}
flock -w 60 "$GATE_QUEUE_LOCK" sleep 20 &
holder7=$!; strays="$strays $holder7"
sleep 0.5
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:r1-demo" > "$tmp/enq16.out" 2>&1 &
enq16=$!; strays="$strays $enq16"
if waitfor 20 state_is r1-demo waiting; then
  sed -i 's/^enqueue_pid=.*/enqueue_pid=999999/' "$GATE_QUEUE_STATE/r1-demo.spec"
  hold_wt2 "interloper r1"
  r1_head="$(git -C "$wt2" rev-parse HEAD)"
  release "$holder7"
  wait "$enq16"; rc16=$?
  if [ "$rc16" -eq 7 ] && [ "$(field r1-demo state)" = refused-held ] \
     && [ "$(git -C "$wt2" rev-parse HEAD)" = "$r1_head" ]; then
    ok 16-takeover "a run-side refusal reached the caller as exit 7 although the record had been taken over (state=$(field r1-demo state))"
  else
    bad 16-takeover "rc=$rc16 state=$(field r1-demo state) head=$(git -C "$wt2" rev-parse HEAD)"
  fi
else
  bad 16-takeover "r1-demo never reached waiting"
  release "$holder7"
fi

# ---- 17: a hold whose worktree is GONE is void, and a finished held record can be retired on
# purpose (round-4 review, R2).
vanish="$tmp/vanish"
git -C "$repo" worktree add -q -b vanishing "$vanish"
vsha="$(git -C "$vanish" rev-parse HEAD)"
git -C "$vanish" checkout -q --detach "$vsha"
cat > "$GATE_QUEUE_STATE/vanish-demo.spec" <<EOF
spec=$vanish:$vsha:vanish-demo
worktree=$vanish
ref=$vsha
label=vanish-demo
log=$tmp/vanish.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=
run_pid=
state=done
rc=0
checked_out=$vsha
restore=skipped-head-moved
EOF
before="$("$qs" list 2>&1 | grep '^held' | grep -c vanish-demo)"
rm -rf "$vanish"
after="$("$qs" list 2>&1 | grep '^held' | grep -c vanish-demo)"
if [ "$before" -eq 1 ] && [ "$after" -eq 0 ]; then
  ok 17-vanished "a hold is void once its worktree is gone (held before=$before, after=$after)"
else
  bad 17-vanished "held lines before=$before after=$after"
fi
rm -f "$GATE_QUEUE_STATE/vanish-demo.spec"
# 17b: --finished retires a hold on a worktree that is still there, deliberately and loudly.
hold_wt2 "interloper r2"
out="$("$qs" drop holder-demo 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ -n "$(field holder-demo checked_out)" ]; then
  ok 17-plain-drop "a plain drop still refuses a finished record (rc=3)"
else
  bad 17-plain-drop "rc=$rc checked_out=$(field holder-demo checked_out): $out"
fi
out="$("$qs" drop holder-demo --finished 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(field holder-demo checked_out)" ] \
   && [ "$("$qs" list 2>&1 | grep '^held' | grep -c holder-demo)" -eq 0 ]; then
  ok 17-finished "drop --finished retired the hold on $wt2 (rc=0): ${out##*$'\n'}"
else
  bad 17-finished "rc=$rc checked_out=$(field holder-demo checked_out): $out"
fi
rm -f "$GATE_QUEUE_STATE/holder-demo.spec"
git -C "$wt2" checkout -q lane2

# ---- 18: the run records its own flock pid, and drop will not retire a young empty-pid record
# (round-4 review, R4).
flock -w 30 "$GATE_QUEUE_LOCK" "$qs" __run "$wt" "$sha" selfpid-demo "$tmp/selfpid.log" &
selfflock=$!; strays="$strays $selfflock"
if STUB_GATE_SLEEP=6 waitfor 20 state_is selfpid-demo running; then
  if [ "$(field selfpid-demo flock_pid)" = "$selfflock" ] && [ -n "$(field selfpid-demo flock_start)" ]; then
    ok 18-selfpid "the run wrote its own flock pid ($selfflock) and start time into the record"
  else
    bad 18-selfpid "flock_pid=$(field selfpid-demo flock_pid) expected $selfflock, flock_start=$(field selfpid-demo flock_start)"
  fi
else
  bad 18-selfpid "selfpid-demo never reached running"
fi
wait "$selfflock" 2>/dev/null
cat > "$GATE_QUEUE_STATE/young-demo.spec" <<EOF
spec=$wt2:$sha2:young-demo
worktree=$wt2
ref=$sha2
label=young-demo
log=$tmp/young.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=999999
flock_pid=
run_pid=
state=waiting
rc=
enqueued=$(date '+%Y-%m-%d %H:%M:%S')
EOF
out="$("$qs" drop young-demo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(field young-demo state)" = waiting ] && printf '%s' "$out" | grep -qi 'grace\|too young\|--force'; then
  ok 18-young "drop refused a record whose flock may still be spawning (rc=$rc), record untouched"
else
  bad 18-young "rc=$rc state=$(field young-demo state): $out"
fi
out="$("$qs" drop young-demo --force 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field young-demo state)" = done ] && [ "$(field young-demo rc)" = 143 ]; then
  ok 18-force "drop --force retired it anyway (rc=0)"
else
  bad 18-force "rc=$rc state=$(field young-demo state): $out"
fi

# ---- 19: a dry-run writes NOTHING, on the orphan path too (round-4 review, R5).
sed -e 's/^label=.*/label=dry-demo/' -e "s/^state=.*/state=waiting/" -e 's/^rc=.*/rc=/' \
    -e "s/^enqueued=.*/enqueued=$(date -d '2 hours ago' '+%Y-%m-%d %H:%M:%S')/" \
    "$GATE_QUEUE_STATE/young-demo.spec" > "$GATE_QUEUE_STATE/dry-demo.spec"
sed -i -e '/^finished=/d' -e '/^dropped_by=/d' -e '/^drop_requested=/d' "$GATE_QUEUE_STATE/dry-demo.spec"
md5_before="$(md5sum < "$GATE_QUEUE_STATE/dry-demo.spec")"
out="$("$qs" drop dry-demo --dry-run 2>&1)"; rc=$?
md5_after="$(md5sum < "$GATE_QUEUE_STATE/dry-demo.spec")"
if [ "$rc" -eq 0 ] && [ "$md5_before" = "$md5_after" ] && printf '%s' "$out" | grep -qi 'DRY-RUN'; then
  ok 19-dryrun "a dry-run of an orphan record left it byte-identical (md5 unchanged) and signalled nothing"
else
  bad 19-dryrun "rc=$rc md5 same=$([ "$md5_before" = "$md5_after" ] && echo yes || echo NO): $out"
fi
out="$("$qs" drop dry-demo 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field dry-demo state)" = done ]; then
  ok 19-control "the same drop without --dry-run does retire it (rc=0)"
else
  bad 19-control "rc=$rc state=$(field dry-demo state): $out"
fi

# ---- 20: a hold that cannot be EVALUATED is kept, not voided (round-5 review, 1). Only a path
# that is gone is proof that the commits it protected are gone with it; a path that is there but
# does not answer as a git worktree is an unknown, and an unknown must not retire a record.
notawt="$tmp/notawt"
mkdir -p "$notawt"
cat > "$GATE_QUEUE_STATE/opaque-demo.spec" <<EOF
spec=$notawt:$sha2:opaque-demo
worktree=$notawt
ref=$sha2
label=opaque-demo
log=$tmp/opaque.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=
run_pid=
state=done
rc=0
checked_out=$sha2
restore=skipped-head-moved
gen=old-gen
EOF
held_line="$("$qs" list 2>&1 | grep '^held' | grep -c opaque-demo)"
out="$("$qs" enqueue "$wt:$sha:opaque-demo" 2>&1)"; rc=$?
if [ "$held_line" -eq 1 ] && [ "$rc" -eq 7 ] && [ -f "$GATE_QUEUE_STATE/opaque-demo.spec" ] \
   && printf '%s' "$out" | grep -qi 'worktree\|probe'; then
  ok 20-unevaluable "a worktree path that is not a git worktree keeps the hold (rc=7) and its record survives"
else
  bad 20-unevaluable "held=$held_line rc=$rc record=$([ -f "$GATE_QUEUE_STATE/opaque-demo.spec" ] && echo kept || echo DELETED): $out"
fi
rm -rf "$notawt"
out="$("$qs" enqueue "$wt:$sha:opaque-demo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field opaque-demo worktree)" = "$wt" ]; then
  ok 20-gone "once that path is gone the hold is void and the label retires (rc=0)"
else
  bad 20-gone "rc=$rc worktree=$(field opaque-demo worktree): $out"
fi

# ---- 21: a spec still WAITING behind a busy queue is not an orphan while its enqueue lives
# (round-5 review, 2a/2b), and a stale child refuses on a generation mismatch (2c).
cat > "$GATE_QUEUE_STATE/live-demo.spec" <<EOF
spec=$wt2:$sha2:live-demo
worktree=$wt2
ref=$sha2
label=live-demo
log=$tmp/live.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=
run_pid=
state=waiting
rc=
enqueued=$(date -d '2 hours ago' '+%Y-%m-%d %H:%M:%S')
gen=live-gen
EOF
out="$("$qs" drop live-demo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(field live-demo state)" = waiting ]; then
  ok 21-live-enqueue "an hours-old waiting record whose enqueue process is alive is not an orphan (rc=$rc), record untouched"
else
  bad 21-live-enqueue "rc=$rc state=$(field live-demo state): $out"
fi
out="$("$qs" drop live-demo --force 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(field live-demo state)" = done ]; then
  ok 21-force "--force retires it deliberately (rc=0)"
else
  bad 21-force "rc=$rc state=$(field live-demo state): $out"
fi
# The label is reused; the OLD child must not run against the new occupant's record.
cat > "$GATE_QUEUE_STATE/live-demo.spec" <<EOF
spec=$wt2:$sha2:live-demo
worktree=$wt2
ref=$sha2
label=live-demo
log=$tmp/live2.log
lock=$GATE_QUEUE_LOCK
enqueue_pid=$$
flock_pid=
run_pid=
state=waiting
rc=
enqueued=$(date '+%Y-%m-%d %H:%M:%S')
gen=new-gen
EOF
before_head="$(git -C "$wt2" rev-parse HEAD)"
before_md5="$(md5sum < "$GATE_QUEUE_STATE/live-demo.spec")"
GATE_QUEUE_GEN=old-gen flock -w 30 "$GATE_QUEUE_LOCK" "$qs" __run "$wt2" "$sha2" live-demo "$tmp/stale.log"
grc=$?
if [ "$grc" -eq 7 ] && grep -q 'STALE-GENERATION' "$tmp/stale.log" \
   && [ "$(git -C "$wt2" rev-parse HEAD)" = "$before_head" ] \
   && [ "$(md5sum < "$GATE_QUEUE_STATE/live-demo.spec")" = "$before_md5" ]; then
  ok 21-generation "a child from the retired generation refused (rc=7), touched neither $wt2 nor the new occupant's record"
else
  bad 21-generation "rc=$grc head=$(git -C "$wt2" rev-parse HEAD) log=$(cat "$tmp/stale.log" 2>&1)"
fi
GATE_QUEUE_GEN=new-gen flock -w 30 "$GATE_QUEUE_LOCK" "$qs" __run "$wt2" "$sha2" live-demo "$tmp/fresh.log"
grc2=$?
if [ "$grc2" -eq 0 ] && grep -q 'mac-gate SUMMARY' "$tmp/fresh.log" && [ "$(field live-demo restore)" = ok ]; then
  ok 21-gen-control "the matching generation runs normally (rc=0)"
else
  bad 21-gen-control "rc=$grc2 restore=$(field live-demo restore): $(cat "$tmp/fresh.log" 2>&1)"
fi
# A real enqueue stamps a generation of its own.
STUB_GATE_SLEEP=1 "$qs" enqueue "$wt2:$sha2:gen-demo" > "$tmp/enq21.out" 2>&1
if [ -n "$(field gen-demo gen)" ] && [ "$(field gen-demo rc)" = 0 ]; then
  ok 21-gen-stamp "enqueue stamped a generation on the record it created (gen=$(field gen-demo gen))"
else
  bad 21-gen-stamp "gen=$(field gen-demo gen) rc=$(field gen-demo rc)"
fi

# ------------------------------------------------------------------------------- 5: list
out="$("$qs" list 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q running-demo && printf '%s' "$out" | grep -q '^holder  :'; then
  ok 5-list "list reports the records, pid liveness and the derived lock holder"
else
  bad 5-list "rc=$rc: $out"
fi
out="$("$qs" drop no-such-label 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 5-missing "drop refuses an unknown label (rc=$rc)" \
                || bad 5-missing "expected a refusal for an unknown label"

[ "$fail" -eq 0 ] && echo "gate-queue-test: ALL PASS" || echo "gate-queue-test: FAILURES"
exit "$fail"
