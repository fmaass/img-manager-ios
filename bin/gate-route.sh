#!/usr/bin/env bash
# gate-route.sh — which Mac build host a gate run takes, and the lock that says it is taken
# (IMGMGR-576). Sourced by bin/mac-gate.sh and bin/gate-queue.sh on the CONTROLLER only (jupiter
# or the lane container, bash 5); the Mac never sources it.
#
# The estate convention it keeps: every Mac has ONE jupiter-side kernel flock that every repo's
# gate holds for a whole run on that host — merkur's is .wp13-gate.lock, mars's .mars-gate.lock
# (memos-ng-ios docs/gate/host-routing.md). Holding the file IS "this host is taken", which is how
# memos-ng's `auto` sees img-manager's runs and the other way round. The routing below is a port of
# memos-ng-ios bin/mac-gate.sh gate_route_auto (MEMNG-824) minus its warm-lane preference (this
# repo keeps no lane-host marker), plus a disk floor in the probe.
#
#   MAC_GATE_HOSTS        the hosts a run may take, in preference order (default: merkur mars)
#   MAC_GATE_HOST_LOCKS   name=lock,name=lock — the lock of each host (default: the estate's two)
#   MAC_GATE_FLOOR_BUILD_G / MAC_GATE_FLOOR_HOME_G
#                         GiB that must be free on the gate root's volume (15) and on $HOME (11,
#                         where CoreSimulator keeps its devices); on mars these are two volumes
#   MAC_GATE_PROBE_TIMEOUT seconds one probe may take (30)
#
# Every refusal here is rc 15 (17 for an explicitly named host under the floor), before any lock
# is touched or, in routing, with every lock it touched let go again.

GATE_ROUTE_KNOWN="merkur mars"
GATE_ROUTE_DEFAULT_LOCKS="merkur=/home/fabian/projects/worktrees/.wp13-gate.lock,mars=/home/fabian/projects/worktrees/.mars-gate.lock"
GATE_ROUTE_NAMES=()
GATE_ROUTE_LOCKS=()
GATE_ROUTE_HOST=""
GATE_ROUTE_REASON=""
GATE_ROUTE_WHY=""
GATE_ROUTE_PROBE_WHY=""

# gate_route_config — fills GATE_ROUTE_NAMES/LOCKS from the two variables; 15 + GATE_ROUTE_WHY
# on a host this gate has no profile for, a duplicate, a malformed entry or a host without a lock.
gate_route_config() {
  local hosts="${MAC_GATE_HOSTS:-merkur mars}" map="${MAC_GATE_HOST_LOCKS:-$GATE_ROUTE_DEFAULT_LOCKS}"
  local entry name path h found i
  local -a entries=() mnames=() mlocks=()
  GATE_ROUTE_NAMES=(); GATE_ROUTE_LOCKS=(); GATE_ROUTE_WHY=""
  IFS=, read -r -a entries <<< "$map"
  for entry in "${entries[@]}"; do
    name="${entry%%=*}"; path="${entry#*=}"
    if [ "$entry" = "$name" ] || [ -z "$name" ] || [ -z "$path" ]; then
      GATE_ROUTE_WHY="MAC_GATE_HOST_LOCKS entry '$entry' is not name=lock"; return 15
    fi
    case " $GATE_ROUTE_KNOWN " in *" $name "*) ;; *)
      GATE_ROUTE_WHY="MAC_GATE_HOST_LOCKS names $name, which is not a build host this gate knows ($GATE_ROUTE_KNOWN)"; return 15 ;;
    esac
    case " ${mnames[*]} " in *" $name "*) GATE_ROUTE_WHY="MAC_GATE_HOST_LOCKS names $name twice"; return 15 ;; esac
    mnames+=("$name"); mlocks+=("$path")
  done
  for h in $hosts; do
    case " $GATE_ROUTE_KNOWN " in *" $h "*) ;; *)
      GATE_ROUTE_WHY="MAC_GATE_HOSTS names $h, which is not a build host this gate knows ($GATE_ROUTE_KNOWN)"; return 15 ;;
    esac
    case " ${GATE_ROUTE_NAMES[*]} " in *" $h "*) GATE_ROUTE_WHY="MAC_GATE_HOSTS names $h twice"; return 15 ;; esac
    found=""
    for i in "${!mnames[@]}"; do [ "${mnames[$i]}" = "$h" ] && found="${mlocks[$i]}"; done
    [ -n "$found" ] || { GATE_ROUTE_WHY="MAC_GATE_HOST_LOCKS has no lock for $h"; return 15; }
    GATE_ROUTE_NAMES+=("$h"); GATE_ROUTE_LOCKS+=("$found")
  done
  [ "${#GATE_ROUTE_NAMES[@]}" -gt 0 ] || { GATE_ROUTE_WHY="MAC_GATE_HOSTS names no host"; return 15; }
  return 0
}

gate_route_lock_of() { # HOST — its lock on stdout; 1 when the configuration does not name it
  local i
  for i in "${!GATE_ROUTE_NAMES[@]}"; do
    [ "${GATE_ROUTE_NAMES[$i]}" = "$1" ] || continue
    printf '%s\n' "${GATE_ROUTE_LOCKS[$i]}"; return 0
  done
  return 1
}

# The host half of the probe: free GiB of the gate root's volume (its nearest existing ancestor —
# the root may not exist yet on a host that never ran this repo) and of $HOME. One line or nothing.
GATE_ROUTE_FLOOR_SCRIPT='d="$HOME/build/img-manager-ios/gate"; while [ ! -e "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done; b="$(df -g "$d" 2>/dev/null | awk '"'"'NR==2 { print $4 }'"'"')"; h="$(df -g "$HOME" 2>/dev/null | awk '"'"'NR==2 { print $4 }'"'"')"; echo "FLOOR build=$b home=$h"'

# gate_route_probe HOST — 0 answering and above both floors, 1 not answering (or an answer that is
# not a reading: unmeasured is never a pass), 2 answering but under a floor. GATE_ROUTE_PROBE_WHY
# names the numbers. A free lock on a Mac that is off, or full, proves nothing.
gate_route_probe() {
  local out line b h fb="${MAC_GATE_FLOOR_BUILD_G:-15}" fh="${MAC_GATE_FLOOR_HOME_G:-11}"
  GATE_ROUTE_PROBE_WHY=""
  out="$(timeout "${MAC_GATE_PROBE_TIMEOUT:-30}" ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$1" "$GATE_ROUTE_FLOOR_SCRIPT" </dev/null 2>/dev/null 9>&-)" \
    || { GATE_ROUTE_PROBE_WHY="$1 unreachable"; return 1; }
  line="$(printf '%s\n' "$out" | grep -E '^FLOOR build=[0-9]+ home=[0-9]+$' | tail -1)"
  [ -n "$line" ] || { GATE_ROUTE_PROBE_WHY="$1 unreachable (no disk reading: '$(printf '%s' "$out" | head -1 | cut -c1-80)')"; return 1; }
  b="${line#FLOOR build=}"; b="${b%% *}"; h="${line##* home=}"
  if [ "$b" -lt "$fb" ] || [ "$h" -lt "$fh" ]; then
    GATE_ROUTE_PROBE_WHY="$1 below the disk floor (build=${b}G need ${fb}G, home=${h}G need ${fh}G)"
    return 2
  fi
  GATE_ROUTE_PROBE_WHY="$1 build=${b}G home=${h}G"
  return 0
}

# gate_route_auto [pick-only] — picks a host and leaves its lock held on fd 9:
#   (a) each host in order: flock -n; free and probing well -> taken; free but not -> unusable;
#       held -> busy;
#   (b) nothing taken: the busy hosts are probed into a wait set; empty -> 15, naming every state;
#   (c) a blocking flock on the first of the set, one re-probe after it; a host that failed it is
#       let go, dropped, and the choice made again (each host once, so this ends).
# pick-only (bin/gate-queue.sh): (a) lets the lock go again and (c) does not wait — the queue then
# waits on that lock in its own flock(1), the process its drop proof is built on.
gate_route_auto() {
  local mode="${1:-}" i h l pick kept="" busy="" unusable="" lost="" states n_busy=0
  local -a state=() waitset=() rest=()
  GATE_ROUTE_HOST=""; GATE_ROUTE_REASON=""; GATE_ROUTE_WHY=""
  for i in "${!GATE_ROUTE_NAMES[@]}"; do
    h="${GATE_ROUTE_NAMES[$i]}"; l="${GATE_ROUTE_LOCKS[$i]}"
    { exec 9>>"$l"; } 2>/dev/null || { GATE_ROUTE_WHY="cannot open the lock $l of $h"; return 15; }
    if flock -n 9; then
      if gate_route_probe "$h"; then kept="$h"; [ "$mode" != pick-only ] || exec 9>&-; break; fi
      exec 9>&-
      state[$i]=unusable; unusable="$unusable${unusable:+, }$GATE_ROUTE_PROBE_WHY"
    else
      exec 9>&-
      state[$i]=busy; busy="$busy${busy:+,}$h"; n_busy=$((n_busy + 1))
    fi
  done
  if [ -n "$kept" ]; then
    GATE_ROUTE_HOST="$kept"
    states="$busy"; [ -z "$states" ] || states="${states//,/ held, } held"
    [ -z "$unusable" ] || states="$states${states:+, }$unusable"
    GATE_ROUTE_REASON="free:$kept${states:+ ($states)}"
    return 0
  fi
  for i in "${!GATE_ROUTE_NAMES[@]}"; do
    [ "${state[$i]:-}" = busy ] || continue
    if gate_route_probe "${GATE_ROUTE_NAMES[$i]}"; then waitset+=("$i")
    else state[$i]=busy-unusable; unusable="$unusable${unusable:+, }$GATE_ROUTE_PROBE_WHY"; fi
  done
  while :; do
    if [ "${#waitset[@]}" -eq 0 ]; then
      states=""
      for i in "${!GATE_ROUTE_NAMES[@]}"; do states="$states ${GATE_ROUTE_NAMES[$i]}=${state[$i]:-unprobed}"; done
      GATE_ROUTE_WHY="no build host can take this run:$states${unusable:+ ($unusable)}"
      return 15
    fi
    pick="${waitset[0]}"; h="${GATE_ROUTE_NAMES[$pick]}"; l="${GATE_ROUTE_LOCKS[$pick]}"
    [ "$mode" = pick-only ] && break
    printf 'mac-gate: every build host is busy; waiting for %s (first in order)\n' "$h" >&2
    { exec 9>>"$l"; } 2>/dev/null || { GATE_ROUTE_WHY="cannot open the lock $l of $h"; return 15; }
    flock 9 || { exec 9>&-; GATE_ROUTE_WHY="cannot take the lock $l of $h"; return 15; }
    gate_route_probe "$h" && break
    exec 9>&-
    state[$pick]=unusable-after-wait; lost="$lost${lost:+, }$GATE_ROUTE_PROBE_WHY after the wait"
    rest=()
    for i in "${waitset[@]}"; do [ "$i" = "$pick" ] || rest+=("$i"); done
    waitset=("${rest[@]+"${rest[@]}"}")
  done
  GATE_ROUTE_HOST="$h"
  [ "$n_busy" -lt 2 ] || [ "$n_busy" -ne "${#GATE_ROUTE_NAMES[@]}" ] || busy=both
  states="$unusable"; [ -z "$lost" ] || states="$states${states:+, }$lost"
  if [ "$mode" = pick-only ]; then
    GATE_ROUTE_REASON="busy:$busy${states:+ ($states)} -> waiting on $h (first in order)"
  else
    GATE_ROUTE_REASON="busy:$busy${states:+ ($states)} -> waited on $h (first in order)"
  fi
  return 0
}
