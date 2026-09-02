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
