#!/usr/bin/env bash
# gate-route-test.sh — proves bin/gate-route.sh's host choice (IMGMGR-576) against stub hosts, and
# the simulator-slot wrappers of bin/gate-lib.sh against the vendored scripts/gate-admission.sh.
# Linux, no Mac: `ssh` and `df` are PATH stubs, a busy host is a live flock holder on a temp lock.
# Run by bin/gate-lib-test.sh; GATE_ROUTE_TEST_MUTANT=no-auto replaces gate_route_auto with a
# stub that always takes the first host, the realness check that a category goes red without it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
holders=()
cleanup() { local p; for p in "${holders[@]+"${holders[@]}"}"; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
ok() { echo "PASS route-$1: $2"; }
bad() { echo "FAIL route-$1: $2"; fail=1; }

stub="$tmp/stub"; mkdir -p "$stub/bin"
# ssh stub: `<host>.down` = no answer (255), `<host>.sleep` = hangs past the probe timeout;
# otherwise the command runs here with HOME = that host's fake home and the df stub on PATH.
cat > "$stub/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -o) shift 2 ;; *) break ;; esac; done
h="$1"; shift
echo "$h $*" >> "$STUB_DIR/ssh.log"
[ ! -e "$STUB_DIR/$h.down" ] || exit 255
[ ! -e "$STUB_DIR/$h.sleep" ] || sleep 5
mkdir -p "$STUB_DIR/home-$h/build"
[ "$*" != "bash -s" ] || { cat > /dev/null; cat "$STUB_DIR/$h.bash-s" 2>/dev/null; exit "$(cat "$STUB_DIR/$h.bash-s.rc" 2>/dev/null || echo 1)"; }
STUB_HOST="$h" HOME="$STUB_DIR/home-$h" exec bash -c "$*"
EOF
# df stub: `df -g PATH`, PATH under the fake home's build dir reads <host>.build, else <host>.home.
cat > "$stub/bin/df" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -g ] || exit 2
case "$2" in */build|*/build/*) f="$STUB_DIR/$STUB_HOST.build" ;; *) f="$STUB_DIR/$STUB_HOST.home" ;; esac
[ -f "$f" ] || exit 1
printf 'Filesystem 1G-blocks Used Available Capacity Mounted\n/dev/disk3s1 460 100 %s 50%% %s\n' "$(cat "$f")" "$2"
EOF
chmod +x "$stub/bin/ssh" "$stub/bin/df"
export STUB_DIR="$stub" PATH="$stub/bin:$PATH"
export MAC_GATE_PROBE_TIMEOUT=2
export MAC_GATE_HOSTS="merkur mars"
export MAC_GATE_HOST_LOCKS="merkur=$tmp/merkur.lock,mars=$tmp/mars.lock"

# The two vendored helpers are byte-identical to the reference whose sha256 their SOURCE file records.
for v in admission:GATE_ADMISSION_SOURCE mount-guard:GATE_MOUNT_GUARD_SOURCE; do
  f="$here/../scripts/gate-${v%%:*}.sh"; want="$(sed -n 's/.* sha256=\([0-9a-f]\{64\}\)$/\1/p' "$here/../scripts/${v#*:}")"
  if [ -n "$want" ] && [ "$(sha256sum "$f" | cut -c1-64)" = "$want" ]; then ok "vendored-${v%%:*}" "sha256 $want"
  else bad "vendored-${v%%:*}" "$f differs from ${v#*:} (want '${want}')"; fi
done
. "$here/gate-route.sh"
if [ "${GATE_ROUTE_TEST_MUTANT:-}" = no-auto ]; then
  gate_route_auto() { GATE_ROUTE_HOST="${GATE_ROUTE_NAMES[0]}"; GATE_ROUTE_REASON="free:${GATE_ROUTE_NAMES[0]}"; exec 9>>"${GATE_ROUTE_LOCKS[0]}"; return 0; }
fi

reset_hosts() {
  local p
  for p in "${holders[@]+"${holders[@]}"}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  holders=()
  rm -f "$stub"/*.down "$stub"/*.sleep "$stub/ssh.log"
  for h in merkur mars; do echo 100 > "$stub/$h.build"; echo 40 > "$stub/$h.home"; done
}
busy() { # HOST — a live holder of that host's lock, as another repo's run would be
  # -o: the sleep does not inherit the lock, so killing the flock frees it.
  flock -o "$tmp/$1.lock" sleep 60 & holders+=("$!")
  local i=0; while flock -n "$tmp/$1.lock" true 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
# route MODE — one routing decision in a subshell, so its fd 9 dies with it; prints rc|host|reason.
route() {
  ( gate_route_config || { echo "15||$GATE_ROUTE_WHY"; exit; }
    gate_route_auto "$@"; rc=$?
    # fd9 = this shell holds the chosen host's lock (a second open of it cannot take it).
    held=-; [ "$rc" -ne 0 ] || { held=free; flock -n "$tmp/$GATE_ROUTE_HOST.lock" true 2>/dev/null || held=fd9; }
    echo "$rc|$GATE_ROUTE_HOST|$GATE_ROUTE_REASON${GATE_ROUTE_WHY}|$held" )
}

reset_hosts
out="$(route)"
case "$out" in "0|merkur|free:merkur|fd9") ok both-idle "merkur, first in order, lock held on fd 9: $out" ;; *) bad both-idle "$out" ;; esac

reset_hosts; busy merkur
out="$(route)"
case "$out" in "0|mars|free:mars (merkur held)|fd9") ok merkur-busy "$out" ;; *) bad merkur-busy "$out" ;; esac

reset_hosts; busy mars
out="$(route)"
case "$out" in "0|merkur|free:merkur|fd9") ok mars-busy "$out" ;; *) bad mars-busy "$out" ;; esac

reset_hosts; busy merkur; busy mars
out="$(route pick-only)"
case "$out" in "0|merkur|busy:both -> waiting on merkur (first in order)|"*) ok both-busy-pick "$out" ;; *) bad both-busy-pick "$out" ;; esac
# Blocking: merkur's holder goes away after a second; the wait ends on merkur, holding it.
reset_hosts; busy mars
flock -o "$tmp/merkur.lock" sleep 1 & m=$!; holders+=("$m"); sleep 0.3
out="$(route)"
case "$out" in "0|merkur|busy:both -> waited on merkur (first in order)|fd9") ok both-busy-wait "$out" ;; *) bad both-busy-wait "$out" ;; esac

reset_hosts; busy merkur; touch "$stub/mars.down"
out="$(route pick-only)"
case "$out" in "0|merkur|busy:merkur (mars unreachable) -> waiting on merkur (first in order)|"*) ok mars-down "$out" ;; *) bad mars-down "$out" ;; esac

reset_hosts; busy merkur; touch "$stub/mars.sleep"
out="$(route pick-only)"
case "$out" in "0|merkur|busy:merkur (mars unreachable) -> waiting on merkur (first in order)|"*) ok mars-asleep "a probe past MAC_GATE_PROBE_TIMEOUT is unreachable: $out" ;; *) bad mars-asleep "$out" ;; esac

reset_hosts; echo 23 > "$stub/mars.home"; echo 9 > "$stub/mars.build"
out="$(route)"
case "$out" in "0|merkur|free:merkur|fd9") ok floor-unprobed "merkur free first, mars never probed: $out" ;; *) bad floor-unprobed "$out" ;; esac
busy merkur
out="$(route pick-only)"
case "$out" in "0|merkur|busy:merkur (mars below the disk floor (build=9G need 15G, home=23G need 11G)) -> waiting on merkur (first in order)|"*)
  ok mars-floor "a free host under the floor is not taken: $out" ;; *) bad mars-floor "$out" ;; esac
echo 100 > "$stub/mars.build"; echo 10 > "$stub/mars.home"
out="$(route pick-only)"
case "$out" in *"mars below the disk floor (build=100G need 15G, home=10G need 11G)"*) ok mars-home-floor "\$HOME is a floor of its own: $out" ;; *) bad mars-home-floor "$out" ;; esac

reset_hosts; busy merkur; touch "$stub/mars.down"; touch "$stub/merkur.down"
out="$(route pick-only)"
case "$out" in "15||no build host can take this run: merkur=busy-unusable mars=unusable"*) ok none "$out" ;; *) bad none "$out" ;; esac
# rc 15 left no lock behind: both are takeable once the holder is gone.
reset_hosts
if flock -n "$tmp/mars.lock" true && flock -n "$tmp/merkur.lock" true; then ok none-released "no lock kept after a refusal"; else bad none-released "a lock stayed held"; fi

out="$(MAC_GATE_HOST_LOCKS="merkur=$tmp/merkur.lock,venus=$tmp/v.lock" route)"
case "$out" in "15||MAC_GATE_HOST_LOCKS names venus, which is not a build host"*) ok unknown-host "$out" ;; *) bad unknown-host "$out" ;; esac
out="$(MAC_GATE_HOST_LOCKS="merkur=$tmp/merkur.lock" route)"
case "$out" in "15||MAC_GATE_HOST_LOCKS has no lock for mars"*) ok missing-lock "$out" ;; *) bad missing-lock "$out" ;; esac
out="$(MAC_GATE_HOST_LOCKS="merkur=$tmp/a,merkur=$tmp/b" route)"
case "$out" in "15||MAC_GATE_HOST_LOCKS names merkur twice"*) ok dup-host "$out" ;; *) bad dup-host "$out" ;; esac
out="$(MAC_GATE_HOSTS="mars" route)"
case "$out" in "0|mars|free:mars|fd9") ok hosts-subset "MAC_GATE_HOSTS narrows the set: $out" ;; *) bad hosts-subset "$out" ;; esac

# --- the slot wrappers against the vendored protocol -------------------------------------------------
# A fake simctl keeps devices in a file: create prints a udid, delete removes, list -j prints JSON.
sim="$tmp/sim"; mkdir -p "$sim"
cat > "$sim/simctl" <<'EOF'
#!/usr/bin/env bash
db="$SIM_DB"; touch "$db"
case "$1" in
  create) [ ! -e "$db.fail-create" ] || exit 1
          u="$(cat /proc/sys/kernel/random/uuid | tr a-f A-F)"; printf '%s\t%s\t%s\n' "$u" Booted "$2" >> "$db"; echo "$u" ;;
  delete) grep -v "^$2	" "$db" > "$db.n"; mv "$db.n" "$db" ;;
  shutdown) : ;;
  list) printf '{"devices":{"rt":['; sep=""
        while IFS='	' read -r u s n; do printf '%s{"udid":"%s","state":"%s","name":"%s"}' "$sep" "$u" "$s" "$n"; sep=,; done < "$db"
        printf ']}}\n' ;;
esac
EOF
chmod +x "$sim/simctl"
cat > "$sim/memory_pressure" <<'EOF'
#!/usr/bin/env bash
echo "System-wide memory free percentage: 60%"
EOF
cat > "$sim/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$2" in vm.swapusage) echo "total = 0.00M  used = 0.00M  free = 0.00M" ;; vm.loadavg) echo "{ 1.00 1.00 1.00 }" ;; esac
EOF
cat > "$sim/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 %s 1%% /\n' "${SIM_FREE_KB:-104857600}"
EOF
chmod +x "$sim/memory_pressure" "$sim/sysctl" "$sim/df"
slot_env() {
  export SIM_DB="$sim/devices" GATE_SLOT_ROOT="$tmp/slots" GATE_SIMCTL="$sim/simctl"
  export GATE_MEMORY_PRESSURE="$sim/memory_pressure" GATE_SYSCTL="$sim/sysctl" GATE_DF="$sim/df"
  export GATE_POLL_S=1 GATE_SLEEP=sleep
}
# Each run is its own bash in its own session (setsid), as the remote .gate-run.sh is on the Mac:
# the release stops what is left of the run's PROCESS GROUP, and a subshell of this test would
# share the test's group and be stopped with it.
cat > "$tmp/drive.sh" <<'DRIVE'
set -uo pipefail  # as the remote .gate-run.sh runs
. "$HERE/../scripts/gate-admission.sh"; . "$HERE/gate-lib.sh"
out="$TMPD/$1"
case "$1" in
  s1) gate_slot_sims_open feature/x tok1 mac-gate-iphone-1 iphone-type mac-gate-ipad-1 ipad-type rt > "$TMPD/open.out" 2>&1; echo "open=$?" > "$out"
      cp "$GATE_SLOT_ROOT/sim/owner" "$TMPD/owner.copy" 2>/dev/null
      echo "devices_open=$(wc -l < "$SIM_DB")" >> "$out"
      gate_slot_sims_close > "$TMPD/close.out" 2>&1; echo "close=$?" >> "$out"
      echo "devices_closed=$(wc -l < "$SIM_DB")" >> "$out" ;;
  holder) gate_slot_claim memos-ng-ios main other 0 "" >/dev/null; sleep 2; gate_sim_release >/dev/null; exit 0 ;;
  s2) gate_slot_sims_open feature/y tok2 mac-gate-iphone-2 t "" "" rt > "$TMPD/wait.out" 2>&1; echo "open=$? waited=$GATE_SLOT_WAITED" > "$out"
      gate_slot_sims_close >/dev/null 2>&1 ;;
  dead) gate_slot_claim memos-ng-ios main dead 0 "" >/dev/null; gate_slot_note_device gate-main-dead; $GATE_SIMCTL create gate-main-dead t rt >/dev/null; exit 0 ;;
  s3) gate_slot_sims_open feature/z tok3 mac-gate-iphone-3 t "" "" rt > "$TMPD/stale.out" 2>&1; echo "open=$?" > "$out"
      grep -c 'gate-main-dead' "$SIM_DB" >> "$out"; gate_slot_sims_close >/dev/null 2>&1 ;;
  s4) gate_slot_sims_open feature/w tok4 mac-gate-iphone-4 t "" "" rt >/dev/null 2>&1; echo "open=$?" > "$out"
      gate_slot_sims_close >/dev/null 2>&1; echo "close=$?" >> "$out" ;;
  # Stopped mid-recovery of a stale holder, right after taking the reap mutex: KILL as the cap
  # stop's second signal (no trap runs), TERM as its first (the run's TERM trap runs).
  bkill) GATE_TEST_HOOK="$TMPD/hook-kill" gate_slot_sims_open feature/b tokB mac-gate-iphone-b t "" "" rt >/dev/null 2>&1 ;;
  bterm) trap 'gate_slot_sims_close > "$TMPD/bterm.close" 2>&1; exit 143' TERM
         GATE_TEST_HOOK="$TMPD/hook-term" gate_slot_sims_open feature/c tokC mac-gate-iphone-c t "" "" rt >/dev/null 2>&1 ;;
  stop) gate_slot_after_stop "$STOP_TOKEN" > "$TMPD/stop.out" 2> "$TMPD/stop.err" ;;
  next) gate_slot_sims_open feature/n tokN mac-gate-iphone-n t "" "" rt > "$TMPD/next.log" 2>&1; echo "open=$?" > "$out"
        grep -c 'gate-main-dead' "$SIM_DB" >> "$out"; gate_slot_sims_close >/dev/null 2>&1 ;;
esac
[ -e "$GATE_SLOT_ROOT/sim" ] && echo slot=present >> "$out" || echo slot=gone >> "$out"
DRIVE
drive() { ( slot_env; HERE="$here" TMPD="$tmp" setsid bash "$tmp/drive.sh" "$1" ); }
drive s1
s1="$(tr '\n' ' ' < "$tmp/s1")"
own="$tmp/owner.copy"
if [ "$s1" = "open=0 devices_open=2 close=0 devices_closed=0 slot=gone " ] \
   && grep -qx 'project=img-manager-ios' "$own" && grep -qx 'branch=feature/x' "$own" && grep -qx 'state=held' "$own" \
   && grep -qx 'device=mac-gate-iphone-1' "$own" && grep -qx 'device=mac-gate-ipad-1' "$own" \
   && [ "$(grep -c '^udid=' "$own")" -eq 2 ] && grep -q '^pid=[0-9]' "$own" && grep -q '^pgid=[0-9]' "$own" \
   && grep -q '^lstart=.' "$own" && grep -q '^claimed=' "$own" \
   && grep -q '^MAC_GATE_SLOT slot=0 slot_wait=0 simrelease=0 reap=none$' "$tmp/close.out"; then
  ok slot-claim-release "claimed, both devices named+recorded, deleted and the claim renamed aside: $s1"
else
  bad slot-claim-release "$s1 owner=$(tr '\n' ' ' < "$own" 2>/dev/null) close=$(cat "$tmp/close.out")"
fi
# A live foreign holder (memos-ng's record shape, this machine's pid) is waited on; once it lets
# go (~2 s) the waiter claims.
rm -rf "$tmp/slots"; : > "$sim/devices"
drive holder & holder=$!; sleep 0.5
drive s2; wait "$holder"
s2="$(tr '\n' ' ' < "$tmp/s2")"
case "$s2" in "open=0 waited="[1-9]*" slot=gone ") grep -q 'waiting: slot held by memos-ng-ios main' "$tmp/wait.out" \
    && ok slot-wait "a live holder is waited for, then the slot is claimed and released: $s2" || bad slot-wait "no wait line: $(head -3 "$tmp/wait.out")" ;;
  *) bad slot-wait "$s2 $(head -3 "$tmp/wait.out")" ;; esac
# A stale holder (pid gone, group gone) with a device left behind is recovered: device deleted,
# slot claimed.
rm -rf "$tmp/slots"; : > "$sim/devices"
drive dead; drive s3
s3="$(tr '\n' ' ' < "$tmp/s3")"
case "$s3" in "open=0 0 slot=gone ") ok slot-stale "a dead holder's device is deleted and its slot recovered: $s3" ;; *) bad slot-stale "$s3 $(grep -i 'reap\|stale' "$tmp/stale.out" | head -2)" ;; esac
# A device that cannot be created fails the open (2) and the close still releases the slot.
rm -rf "$tmp/slots"; : > "$sim/devices"; touch "$sim/devices.fail-create"
drive s4
rm -f "$sim/devices.fail-create"
s4="$(tr '\n' ' ' < "$tmp/s4")"
case "$s4" in "open=2 close=0 slot=gone ") ok slot-create-fail "$s4" ;; *) bad slot-create-fail "$s4" ;; esac
# A run stopped while it recovers a stale holder leaves the reap mutex behind, which the protocol
# never expires (REAP-DEAD): the stop's cleanup (KILL) or the run's own trap (TERM) lets it go, so
# the next waiter recovers the stale holder itself. Bounded, so a fenced slot fails instead of hanging.
for sig in KILL TERM; do printf '#!/usr/bin/env bash\n[ "$1" = after-reap-claim ] || exit 0\nkill -%s -- -"$(ps -o pgid= -p "$PPID" | tr -d " ")"\n' "$sig" > "$tmp/hook-$(echo "$sig" | tr A-Z a-z)"; chmod +x "$tmp/hook-$(echo "$sig" | tr A-Z a-z)"; done
drive_t() { ( slot_env; HERE="$here" TMPD="$tmp" STOP_TOKEN="${STOP_TOKEN:-}" timeout 20 setsid bash "$tmp/drive.sh" "$1" ); }
rm -rf "$tmp/slots"; : > "$sim/devices"; rm -f "$tmp/next" "$tmp/stop.out"
drive dead; drive bkill
pre="$(sed -n 's/^token=//p' "$tmp/slots/reap/owner" 2>/dev/null):$(sed -n 's/^token=//p' "$tmp/slots/sim/owner" 2>/dev/null)"
STOP_TOKEN=tokB drive stop
drive_t next
nx="$(tr '\n' ' ' < "$tmp/next" 2>/dev/null)"
if [ "$pre" = "tokB:dead" ] && [ "$(cat "$tmp/stop.out" 2>/dev/null)" = "slot=released reap=undone" ] && [ "$nx" = "open=0 0 slot=gone " ]; then
  ok slot-reap-stop-kill "a run KILLed holding the reap mutex: the stop lets it go and the next waiter recovers: $(cat "$tmp/stop.out")"
else
  bad slot-reap-stop-kill "pre=$pre stop='$(cat "$tmp/stop.out" 2>/dev/null)' next='$nx' $(grep -o 'REAP-[A-Z]*' "$tmp/next.log" 2>/dev/null | head -1)"
fi
rm -rf "$tmp/slots"; : > "$sim/devices"; rm -f "$tmp/next" "$tmp/bterm.close"
drive dead; drive bterm
drive_t next
nx="$(tr '\n' ' ' < "$tmp/next" 2>/dev/null)"
if grep -q ' reap=undone$' "$tmp/bterm.close" 2>/dev/null && [ "$nx" = "open=0 0 slot=gone " ]; then
  ok slot-reap-term-trap "a run TERMed holding the reap mutex lets it go in its own trap: $(cat "$tmp/bterm.close")"
else
  bad slot-reap-term-trap "close='$(cat "$tmp/bterm.close" 2>/dev/null)' next='$nx'"
fi
# Somebody else's reap mutex is never touched by a stop.
rm -rf "$tmp/slots"; mkdir -p "$tmp/slots/reap"; printf 'token=other\npid=1\nlstart=x\npgid=1\nhost=h\n' > "$tmp/slots/reap/owner"
STOP_TOKEN=tokB drive stop
if [ "$(cat "$tmp/stop.out")" = "slot=released reap=none" ] && [ -f "$tmp/slots/reap/owner" ]; then ok slot-reap-foreign "kept: $(cat "$tmp/stop.out")"
else bad slot-reap-foreign "stop='$(cat "$tmp/stop.out")' reap=$([ -f "$tmp/slots/reap/owner" ] && echo kept || echo gone)"; fi

# --- bin/mac-gate.sh itself, up to its mount step -----------------------------------------------------
# A throwaway repo carrying the real scripts; the stub hosts answer the probe, and the mount guard's
# `bash -s` gets the answers named in <host>.bash-s.<n> (the n-th such call; none = exit 1), so a
# run ends at the mount step — or, accepted, at the remote branch lock — before anything is built.
repo="$tmp/repo"; mkdir -p "$repo/bin" "$repo/scripts"
cp "$here/mac-gate.sh" "$here/gate-lib.sh" "$here/gate-route.sh" "$repo/bin/"
cp "$here/../scripts/gate-mount-guard.sh" "$here/../scripts/gate-admission.sh" "$repo/scripts/"
( cd "$repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm t ) || bad mg-setup "git"
cat > "$stub/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -o) shift 2 ;; *) break ;; esac; done
h="$1"; shift
echo "$h $*" >> "$STUB_DIR/ssh.log"
[ ! -e "$STUB_DIR/$h.down" ] || exit 255
[ ! -e "$STUB_DIR/$h.sleep" ] || sleep 5
mkdir -p "$STUB_DIR/home-$h/build"
if [ "$*" = "bash -s" ]; then
  cat > /dev/null
  n=$(( $(cat "$STUB_DIR/$h.bash-s.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/$h.bash-s.n"
  [ -f "$STUB_DIR/$h.bash-s.$n" ] || exit 1
  cat "$STUB_DIR/$h.bash-s.$n"; exit 0
fi
STUB_HOST="$h" HOME="$STUB_DIR/home-$h" exec bash -c "$*"
EOF
chmod +x "$stub/bin/ssh"
mg() { ( cd "$repo" && MAC_GATE_ARTIFACTS="$tmp/art" bin/mac-gate.sh > "$tmp/mg.out" 2>&1; echo "$?" > "$tmp/mg.rc" ); }
mgsum() { grep '^mac-gate SUMMARY:' "$tmp/mg.out" | tail -1; }
mgroute() { grep '^route       :' "$tmp/mg.out" | tail -1; }
mg_reset() { reset_hosts; rm -f "$stub"/*.bash-s.*; }
ok_answer() { printf 'MOUNT OK host=%s uuid=U dev=/dev/disk5s1\nmountguard=enforced marker=missing\n' "$1" > "$stub/$1.bash-s.1"; }

mg_reset
MAC_GATE_HOST=merkur mg
if [ "$(cat "$tmp/mg.rc")" = 16 ] && [ "$(mgroute)" = "route       : host=merkur reason=explicit:merkur waited=0s" ] \
   && [ "$(mgsum)" = "mac-gate SUMMARY: legs=full | route=0 mount=16 host=merkur mountguard=enforced | exit=16" ] \
   && ! grep -v ' d="\$HOME/build\| bash -s$' "$stub/ssh.log" | grep -q .; then
  ok mg-explicit "named host: its lock, its probe, and a mount guard that did not answer ends the run before any host write: $(mgsum)"
else
  bad mg-explicit "rc=$(cat "$tmp/mg.rc") route='$(mgroute)' sum='$(mgsum)' ssh=$(tr '\n' ';' < "$stub/ssh.log")"
fi

mg_reset; echo 12 > "$stub/merkur.build"
MAC_GATE_HOST=merkur mg
if [ "$(cat "$tmp/mg.rc")" = 17 ] && grep -q 'route       : REFUSED merkur below the disk floor (build=12G need 15G, home=40G need 11G)' "$tmp/mg.out" \
   && [ "$(mgsum)" = "mac-gate SUMMARY: legs=full | route=17 | exit=17" ]; then
  ok mg-explicit-floor "a named host under the floor refuses with 17 and both numbers: $(mgsum)"
else
  bad mg-explicit-floor "rc=$(cat "$tmp/mg.rc") $(grep REFUSED "$tmp/mg.out") sum='$(mgsum)'"
fi

mg_reset; touch "$stub/merkur.down"
MAC_GATE_HOST=merkur mg
case "$(cat "$tmp/mg.rc"):$(mgsum)" in "15:mac-gate SUMMARY: legs=full | route=15 | exit=15") ok mg-explicit-down "$(grep REFUSED "$tmp/mg.out")" ;;
  *) bad mg-explicit-down "rc=$(cat "$tmp/mg.rc") sum='$(mgsum)'" ;; esac

mg_reset; busy merkur
MAC_GATE_HOST=merkur MAC_GATE_LOCK_WAIT=1 mg
case "$(cat "$tmp/mg.rc"):$(mgsum)" in "3:mac-gate SUMMARY: legs=full | lock-wait=3 | exit=3")
  grep -q 'merkur is busy' "$tmp/mg.out" && ok mg-explicit-busy "a held lock is waited for up to MAC_GATE_LOCK_WAIT, never broken: $(mgsum)" || bad mg-explicit-busy "no busy line" ;;
  *) bad mg-explicit-busy "rc=$(cat "$tmp/mg.rc") sum='$(mgsum)'" ;; esac

mg_reset
MAC_GATE_HOST=venus mg
if [ "$(cat "$tmp/mg.rc")" = 15 ] && [ ! -s "$stub/ssh.log" ]; then ok mg-unknown "$(grep REFUSED "$tmp/mg.out") — no ssh at all"
else bad mg-unknown "rc=$(cat "$tmp/mg.rc") ssh=$(cat "$stub/ssh.log" 2>/dev/null)"; fi

mg_reset; busy merkur
MAC_GATE_HOST=auto mg
case "$(mgroute)" in "route       : host=mars reason=free:mars (merkur held) waited="*) ok mg-auto "$(mgroute)" ;; *) bad mg-auto "$(mgroute) $(mgsum)" ;; esac

# The queue's hand-over: a descriptor whose open file holds the lock is taken as it is...
mg_reset
( exec 7>>"$tmp/merkur.lock"; flock 7; cd "$repo" && MAC_GATE_HOST=merkur MAC_GATE_HOST_LOCK_FD=7 MAC_GATE_LOCK_WAIT=1 \
    MAC_GATE_ARTIFACTS="$tmp/art" bin/mac-gate.sh > "$tmp/mg.out" 2>&1; echo "$?" > "$tmp/mg.rc" )
case "$(mgroute)" in "route       : host=merkur reason=explicit:merkur (lock held by the caller) waited=0s") ok mg-handover "$(mgroute)" ;; *) bad mg-handover "$(mgroute) $(mgsum)" ;; esac
# ...one whose lock is somebody else's is refused, never waited for.
mg_reset; busy merkur
( exec 7>>"$tmp/merkur.lock"; cd "$repo" && MAC_GATE_HOST=merkur MAC_GATE_HOST_LOCK_FD=7 \
    MAC_GATE_ARTIFACTS="$tmp/art" bin/mac-gate.sh > "$tmp/mg.out" 2>&1; echo "$?" > "$tmp/mg.rc" )
case "$(cat "$tmp/mg.rc"):$(grep REFUSED "$tmp/mg.out")" in "15:route       : REFUSED MAC_GATE_HOST_LOCK_FD 7 does not hold"*) ok mg-handover-foreign "$(grep REFUSED "$tmp/mg.out")" ;;
  *) bad mg-handover-foreign "rc=$(cat "$tmp/mg.rc") $(mgsum)" ;; esac

# An accepted mount answer lets the run on to the host (here: the branch lock, which the stub fails).
mg_reset; ok_answer merkur
MAC_GATE_HOST=merkur mg
case "$(mgsum)" in "mac-gate SUMMARY: legs=full | route=0 mount=0 lock-wait=0 lock=1 lock-release=0 host=merkur mountguard=enforced | exit=1") ok mg-mount-ok "$(mgsum)" ;;
  *) bad mg-mount-ok "$(mgsum)" ;; esac
# A third line, even a blank one, is not an answer.
mg_reset; ok_answer merkur; echo >> "$stub/merkur.bash-s.1"
MAC_GATE_HOST=merkur mg
case "$(mgsum)" in *"mount=16 host=merkur mountguard=enforced | exit=16") ok mg-mount-3lines "$(mgsum)" ;; *) bad mg-mount-3lines "$(mgsum)" ;; esac

# An outer `flock <lock> bin/mac-gate.sh` wrapper is adopted, not waited on (the run would wait on itself).
mg_reset
( cd "$repo" && MAC_GATE_HOST=merkur MAC_GATE_LOCK_WAIT=2 MAC_GATE_ARTIFACTS="$tmp/art" \
    flock "$tmp/merkur.lock" bin/mac-gate.sh > "$tmp/mg.out" 2>&1; echo "$?" > "$tmp/mg.rc" )
case "$(mgroute)" in "route       : host=merkur reason=explicit:merkur (lock held by the caller) waited=0s") ok mg-outer-flock "$(mgroute)" ;; *) bad mg-outer-flock "$(mgroute) $(mgsum)" ;; esac

# auto with a lock handed in (even naming a closed descriptor) is refused before any lock or probe:
# routing may pick the other host. A caller holding a lock names its host (mg-outer-flock).
mg_reset
MAC_GATE_HOST=auto MAC_GATE_HOST_LOCK_FD=7 mg
case "$(cat "$tmp/mg.rc"):$(grep REFUSED "$tmp/mg.out")" in "15:route       : REFUSED MAC_GATE_HOST=auto cannot be combined with an inherited host lock"*)
  [ ! -s "$stub/ssh.log" ] && ok mg-auto-fd-var "$(grep REFUSED "$tmp/mg.out")" || bad mg-auto-fd-var "ssh ran: $(cat "$stub/ssh.log")" ;;
  *) bad mg-auto-fd-var "rc=$(cat "$tmp/mg.rc") $(mgroute) $(mgsum)" ;; esac


[ "$fail" -eq 0 ] && echo "gate-route-test: ALL PASS" || echo "gate-route-test: FAILURES"
exit "$fail"
