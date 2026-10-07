#!/usr/bin/env bash
#
# mac-gate-mount-test.sh — the gate's mount step (MEMNG-602), from the clean-tree check to exit:
# bin/mac-gate.sh, unchanged, run inside throwaway repositories with PATH stubs for ssh and rsync
# that log every call by kind. The stub serves the build host's mount guard
# (scripts/gate-mount-guard.sh) the answer a case scripts, so what is checked is what the gate DOES
# with that answer:
#   - a refusal ends the run at once with `mount=16 mountguard=enforced | exit=16`: exactly one ssh
#     call, the guard's — no host-lock mkdir, no preflight, no rsync, no lock give-back;
#   - an answer that is not exactly one verdict line and one matching state line, a failed ssh, a
#     guard missing from the tree, or a guard whose sha256 is not the one
#     scripts/GATE_MOUNT_GUARD_SOURCE records is a refusal too (the last two before any ssh);
#   - a valid pending marker's `pending:REFUSE` lets the run go on to the host lock, its first
#     remote write, and `mountguard=` stays on the SUMMARY after the later fields.
# The guard itself is held by scripts/gate-mount-guard-test.sh; this suite never runs it.
#
# Run it directly; it needs no Mac. MAC_GATE_SCRIPT points it at another copy of the gate (the
# mutation proofs). Exit: 0 = every case behaved as expected; 1 = at least one did not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -r "$GATE" ] || { echo "FAIL: $GATE is not readable"; exit 1; }
HELPER="$repo_root/scripts/gate-mount-guard.sh"
RECORD="$repo_root/scripts/GATE_MOUNT_GUARD_SOURCE"
[ -r "$HELPER" ] && [ -r "$RECORD" ] || { echo "FAIL: $HELPER or $RECORD is missing"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mac-gate-mount-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
unset MAC_GATE_BRANCH MAC_GATE_LEGS MAC_GATE_ARTIFACTS

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

# --- the fixture ---------------------------------------------------------------------------------
# A committed, clean repository holding the gate and its library, and — unless $2 says otherwise —
# the guard and its source record: "noguard" leaves the guard out, "tampered" changes one byte of it.
new_repo() {
  local name="$1" guard="${2:-guard}" work="$tmp/$1"
  git init --quiet -b main "$work" || return 1
  git -C "$work" config user.email gate-test@example.invalid
  git -C "$work" config user.name "gate test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" config core.hooksPath "$tmp/no-hooks"
  mkdir -p "$work/bin" "$work/scripts" "$work/Sources"
  printf 'let app = 1\n' > "$work/Sources/App.swift"
  printf '.gate-artifacts/\n' > "$work/.gitignore"
  cp "$GATE" "$work/bin/mac-gate.sh" && chmod +x "$work/bin/mac-gate.sh" || return 1
  cp "$repo_root/bin/gate-lib.sh" "$work/bin/gate-lib.sh" || return 1
  cp "$RECORD" "$work/scripts/GATE_MOUNT_GUARD_SOURCE" || return 1
  case "$guard" in
    guard) cp "$HELPER" "$work/scripts/gate-mount-guard.sh" || return 1 ;;
    tampered) { cat "$HELPER"; printf '# one more line\n'; } > "$work/scripts/gate-mount-guard.sh" || return 1 ;;
    noguard) ;;
  esac
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  printf '%s' "$work"
}

# ssh and rsync, replaced. Every call is logged by kind to $STUB_DIR/calls. The guard's call is
# known by the line the gate appends to the helper's text (its script is kept); the host lock by
# its lock directory, answered HELD so that MAC_GATE_LOCK_WAIT=0 ends the run right there.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
case "$*" in
  *'.host.lock'*) echo "ssh hostlock" >> "$STUB_DIR/calls"; echo "HELD by stub since then"; exit 0 ;;
esac
last=""; for a in "$@"; do last="$a"; done
if [ "$last" = "bash -s" ]; then
  script="$(cat)"
  case "$script" in
    *'
gate_mount_guard report'*)
      echo "ssh mount" >> "$STUB_DIR/calls"
      printf '%s\n' "$script" > "$STUB_DIR/mount-script.txt"
      [ -z "${STUB_MOUNT_ERR:-}" ] || cat "$STUB_MOUNT_ERR" >&2
      [ -z "${STUB_MOUNT_OUT:-}" ] || cat "$STUB_MOUNT_OUT"
      if [ -n "${STUB_MOUNT_SLEEP:-}" ]; then : > "$STUB_DIR/mount-in-flight"; sleep "$STUB_MOUNT_SLEEP"; fi
      exit "${STUB_MOUNT_RC:-0}" ;;
  esac
fi
echo "ssh other" >> "$STUB_DIR/calls"
exit 0
SSH_EOF
  cat > "$dir/bin/rsync" <<'RSYNC_EOF'
#!/usr/bin/env bash
echo "rsync" >> "$STUB_DIR/calls"
exit 0
RSYNC_EOF
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync"
}

# One run of the gate against the stubs: OUT, RC and CALLS after it.
run_gate() { # $1 = case name, $2 = repo
  local name="$1" work="$2"
  CASE_DIR="$tmp/case-$name"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
  OUT="$(cd "$work" && env "PATH=$CASE_DIR/bin:$PATH" MAC_GATE_HOST=stub-host MAC_GATE_LOCK_WAIT=0 \
    MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" STUB_DIR="$CASE_DIR" \
    STUB_MOUNT_OUT="${STUB_MOUNT_OUT:-}" STUB_MOUNT_RC="${STUB_MOUNT_RC:-0}" STUB_MOUNT_ERR="${STUB_MOUNT_ERR:-}" \
    bin/mac-gate.sh 2>&1 </dev/null)"
  RC=$?
  CALLS="$(cat "$CASE_DIR/calls" 2>/dev/null)"
}
summary() { printf '%s\n' "$OUT" | grep -E '^mac-gate SUMMARY: '; }

answer() { # $1 = file, then its lines
  local f="$1"; shift
  printf '%s\n' "$@" > "$f"
}
REFUSE_LINE="MOUNT REFUSE diskutil info /Users/fabian/build failed (rc 1): not a mounted volume; recovery once the image is mounted correctly: launchctl kickstart -k gui/501/live.discomarder.merkur-build-image"
answer "$tmp/refuse.txt" "$REFUSE_LINE" "mountguard=enforced marker=missing"
answer "$tmp/pending.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid"
answer "$tmp/garbage.txt" "bash: line 1: gate_mount_guard: command not found"
answer "$tmp/mismatch.txt" "$REFUSE_LINE" "mountguard=enforced marker=not-read"
answer "$tmp/two-states.txt" "MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=enforced marker=not-read" "mountguard=pending:OK marker=valid"
answer "$tmp/quoted.txt" "bash: line 9: MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=enforced marker=not-read"
answer "$tmp/pending-missing.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=missing"
answer "$tmp/pending-expired.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=expired"
answer "$tmp/trailing.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid" "something else"
answer "$tmp/trailing-blank.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid" "" ""
answer "$tmp/second-state.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid" "mountguard=bogus"
answer "$tmp/ok-refuse-state.txt" "MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=pending:REFUSE marker=valid"
answer "$tmp/enforced-valid.txt" "MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=enforced marker=valid"
answer "$tmp/healthy.txt" "MOUNT OK uuid=EE4304C8-021C-489D-B57B-6D846E76B1CF dev=/dev/disk8s1" "mountguard=enforced marker=not-read"
answer "$tmp/noise.txt" "Warning: Permanently added 'stub-host' to the list of known hosts."

w="$(new_repo guarded)" || { echo "FAIL: cannot build the fixture"; exit 1; }

R16='^mac-gate SUMMARY: legs=full \| mount=16 mountguard=enforced \| exit=16$'
# A refusal: the run stops at the mount step, having asked the build host one question.
expect_refused() { # $1 = label
  local label="$1" n
  if [ "$RC" -eq 16 ]; then ok "$label: exit 16"; else bad "$label: exit $RC, expected 16"; show "$OUT"; fi
  n="$(printf '%s\n' "$OUT" | grep -cE "$R16")"
  if [ "$n" -eq 1 ]; then ok "$label: the run ends with $(summary)"
  else bad "$label: expected one SUMMARY matching [$R16], found $n: [$(summary)]"; fi
  if [ "$CALLS" = "ssh mount" ]; then ok "$label: exactly one ssh call, the guard's — no host lock, preflight, rsync or lock give-back"
  else bad "$label: the build host was called as [$(printf '%s' "$CALLS" | tr '\n' ',')], expected [ssh mount]"; fi
}

# --- 1: the guard refuses (no valid marker) ---------------------------------------------------------
STUB_MOUNT_OUT="$tmp/refuse.txt" STUB_MOUNT_RC=16 run_gate refuse "$w"
expect_refused "guard REFUSE"
if printf '%s\n' "$OUT" | grep -qF "$REFUSE_LINE"; then ok "guard REFUSE: the guard's own reason and recovery command reach the output"
else bad "guard REFUSE: the guard's refusal line is not in the output"; show "$OUT"; fi
# What was sent: the helper, byte for byte, then the one call in report mode on this repo's subtree.
if [ -s "$CASE_DIR/mount-script.txt" ]; then
  sent="$CASE_DIR/mount-script.txt"
  last="$(tail -n 1 "$sent")"
  if [ "$last" = "gate_mount_guard report img-manager-ios/gate" ]; then
    ok "the guard is asked in report mode about img-manager-ios/gate, the gate root's one subtree"
  else bad "the guard's call is [$last]"; fi
  if head -n "$(wc -l < "$HELPER")" "$sent" | cmp -s - "$HELPER" \
     && [ "$(wc -l < "$sent")" -eq $(( $(wc -l < "$HELPER") + 1 )) ]; then
    ok "the script sent is scripts/gate-mount-guard.sh byte for byte plus that one line"
  else bad "the script sent to the build host is not the helper plus one call"; fi
  if bash -n "$sent" 2>/dev/null; then ok "the script sent parses"; else bad "the script sent does not parse"; fi
else
  bad "the guard's script was never sent"
fi

# --- 2: answers that are not a well-formed verdict are refusals --------------------------------------
STUB_MOUNT_OUT="$tmp/garbage.txt" STUB_MOUNT_RC=0 run_gate garbage "$w"
expect_refused "rc 0 without a verdict"
STUB_MOUNT_OUT="$tmp/mismatch.txt" STUB_MOUNT_RC=0 run_gate mismatch "$w"
expect_refused "rc 0 with MOUNT REFUSE and an enforced state"
STUB_MOUNT_OUT="$tmp/two-states.txt" STUB_MOUNT_RC=0 run_gate two-states "$w"
expect_refused "rc 0 with two state lines"
STUB_MOUNT_OUT="$tmp/quoted.txt" STUB_MOUNT_RC=0 run_gate quoted "$w"
expect_refused "rc 0 with the verdict quoted inside another line"
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=255 run_gate ssh-failed "$w"
expect_refused "a pending answer behind a failed ssh (rc 255)"
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=124 run_gate ssh-timeout "$w"
expect_refused "a pending answer behind a timed-out ssh (rc 124)"
STUB_MOUNT_OUT="$tmp/pending-missing.txt" STUB_MOUNT_RC=0 run_gate pending-missing "$w"
expect_refused "rc 0, REFUSE + pending with marker=missing"
STUB_MOUNT_OUT="$tmp/pending-expired.txt" STUB_MOUNT_RC=0 run_gate pending-expired "$w"
expect_refused "rc 0, REFUSE + pending with marker=expired"
STUB_MOUNT_OUT="$tmp/trailing.txt" STUB_MOUNT_RC=0 run_gate trailing "$w"
expect_refused "rc 0, a valid pair followed by a garbage line"
STUB_MOUNT_OUT="$tmp/trailing-blank.txt" STUB_MOUNT_RC=0 run_gate trailing-blank "$w"
expect_refused "rc 0, a valid pair followed by two blank lines (a third line is a third line)"
STUB_MOUNT_OUT="$tmp/second-state.txt" STUB_MOUNT_RC=0 run_gate second-state "$w"
expect_refused "rc 0, a valid pair followed by a second, malformed mountguard= line"
STUB_MOUNT_OUT="$tmp/ok-refuse-state.txt" STUB_MOUNT_RC=0 run_gate ok-refuse-state "$w"
expect_refused "rc 0, MOUNT OK with a disagreeing pending:REFUSE state"
STUB_MOUNT_OUT="$tmp/enforced-valid.txt" STUB_MOUNT_RC=0 run_gate enforced-valid "$w"
expect_refused "rc 0, MOUNT OK with enforced but marker=valid (the guard never says that)"
STUB_MOUNT_OUT="/dev/null" STUB_MOUNT_RC=0 run_gate empty "$w"
expect_refused "rc 0 with an empty answer"
STUB_MOUNT_ERR="$tmp/noise.txt" STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 run_gate noise "$w"
expect_refused "rc 0, a valid pair with stderr noise mixed in"
if printf '%s\n' "$OUT" | grep -qF "Permanently added 'stub-host'"; then ok "the refused answer is quoted in the output, noise included"
else bad "the refused answer was not quoted in the output"; show "$OUT"; fi

# --- 3: a signal while the guard's ssh is in flight sends nothing more --------------------------------
CASE_DIR="$tmp/case-signal"; mkdir -p "$CASE_DIR"; make_stubs "$CASE_DIR"
( cd "$w" && exec env "PATH=$CASE_DIR/bin:$PATH" MAC_GATE_HOST=stub-host MAC_GATE_LOCK_WAIT=0 \
    MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" STUB_DIR="$CASE_DIR" \
    STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 STUB_MOUNT_SLEEP=3 \
    bin/mac-gate.sh ) > "$CASE_DIR/out" 2>&1 </dev/null &
gate_pid=$!
n=0; while [ ! -e "$CASE_DIR/mount-in-flight" ] && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
if [ -e "$CASE_DIR/mount-in-flight" ]; then
  kill -TERM "$gate_pid" 2>/dev/null
  wait "$gate_pid"; RC=$?
  sleep 3.5   # the stub's own sleep ends; anything the gate still sent would be logged by now
  CALLS="$(cat "$CASE_DIR/calls" 2>/dev/null)"
  if [ "$RC" -eq 143 ] && [ "$CALLS" = "ssh mount" ]; then
    ok "TERM during the guard's ssh: exit 143 and no further ssh (no lock give-back)"
  else bad "TERM during the guard's ssh: exit $RC, calls [$(printf '%s' "$CALLS" | tr '\n' ',')], expected 143 and [ssh mount]"
       show "$(cat "$CASE_DIR/out")"; fi
else
  kill -KILL "$gate_pid" 2>/dev/null; wait "$gate_pid" 2>/dev/null
  bad "the signal case never reached the guard's ssh"; show "$(cat "$CASE_DIR/out")"
fi

# --- 4: a tree without the guard, or with one that is not the recorded copy, never calls the host ----
w2="$(new_repo unguarded noguard)" || { echo "FAIL: cannot build the unguarded fixture"; exit 1; }
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 run_gate unguarded "$w2"
if [ "$RC" -eq 16 ] && [ -z "$CALLS" ] && [ "$(summary)" = "mac-gate SUMMARY: legs=full | mount=16 mountguard=enforced | exit=16" ]; then
  ok "no guard in the tree: mount=16, exit 16, and the build host was never called"
else
  bad "no guard in the tree: exit $RC, calls [$(printf '%s' "$CALLS" | tr '\n' ',')]"; show "$OUT"
fi
w3="$(new_repo tampered tampered)" || { echo "FAIL: cannot build the tampered fixture"; exit 1; }
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 run_gate tampered "$w3"
if [ "$RC" -eq 16 ] && [ -z "$CALLS" ] && [ "$(summary)" = "mac-gate SUMMARY: legs=full | mount=16 mountguard=enforced | exit=16" ] \
   && printf '%s\n' "$OUT" | grep -q 'GATE_MOUNT_GUARD_SOURCE'; then
  ok "a guard whose sha256 is not the recorded one: mount=16, exit 16, the build host never called, the record named"
else
  bad "a tampered guard: exit $RC, calls [$(printf '%s' "$CALLS" | tr '\n' ',')]"; show "$OUT"
fi

# --- 5: a valid pending marker reports the refusal and the run goes on to its first remote write ------
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 run_gate pending "$w"
if [ "$CALLS" = "ssh mount
ssh hostlock" ]; then ok "pending:REFUSE: the guard is the first call and the host lock (the first remote write) comes next"
else bad "pending:REFUSE: the calls were [$(printf '%s' "$CALLS" | tr '\n' ',')]"; show "$OUT"; fi
if [ "$RC" -eq 3 ] && [ "$(summary)" = "mac-gate SUMMARY: legs=full | mount=0 lock-wait=3 mountguard=pending:REFUSE | exit=3" ]; then
  ok "pending:REFUSE: mount=0, the run went on, mountguard=pending:REFUSE after the later fields ($(summary))"
else bad "pending:REFUSE: exit $RC, SUMMARY [$(summary)]"; show "$OUT"; fi
STUB_MOUNT_OUT="$tmp/healthy.txt" STUB_MOUNT_RC=0 run_gate healthy "$w"
if [ "$RC" -eq 3 ] && [ "$CALLS" = "ssh mount
ssh hostlock" ] && [ "$(summary)" = "mac-gate SUMMARY: legs=full | mount=0 lock-wait=3 mountguard=enforced | exit=3" ]; then
  ok "the exact healthy pair (MOUNT OK + enforced, not-read) -> mount=0 mountguard=enforced, the run goes on"
else bad "the healthy pair: exit $RC, calls [$(printf '%s' "$CALLS" | tr '\n' ',')], SUMMARY [$(summary)]"; show "$OUT"; fi

echo "mac-gate-mount-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
