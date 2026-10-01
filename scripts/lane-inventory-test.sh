#!/usr/bin/env bash
# lane-inventory-test.sh — fixture test for scripts/lane-inventory.sh and scripts/lane-remove.sh.
#
# Builds, in a temp dir, a fake build-host home (`~/build/img-manager-ios/gate/...`) and REAL git
# fixtures: a bare origin, the main clone and the lane clone, a host worktree, a lane-clone
# worktree listed under the fake `<projects>/<repo>-wt` prefix whose directory exists only under
# the fake container root (the translation the inventory must make), and a worktree of a clone
# neither list names, present only under the container root. show-ref's exit 1, ls-remote's empty
# answer and the container-path translation are git's own; only the build host (a local runner),
# the tmux reader, chain.log and the ticket reader are stand-ins. Nothing outside the temp dir is read
# or written.
#
# Run bare: the suite runs against this directory's scripts and must pass, then each mutant is a
# sed'd copy of the scripts that must make the suite fail. Exit 0 only when the suite passes and
# every mutant is killed; a mutant whose sed changed nothing or whose copy does not parse is VOID
# and fails the run. `--suite` runs the suite alone against $LANE_TEST_SCRIPTS_DIR.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# --------------------------------------------------------------------------------------------------
suite() {
  local S="$1" T P C H G now old young
  T="$(mktemp -d "${TMPDIR:-/tmp}/lane-inventory-test.XXXXXX")" || { echo "FAIL mktemp"; return 1; }
  P="$T/projects"            # stands in for /home/fabian/projects
  C="$T/container/projects"  # stands in for /srv/appdata/pfadfinder-lane/home/projects
  H="$T/home"                # the build host's $HOME
  G="$H/build/img-manager-ios/gate"
  mkdir -p "$P" "$C/img-manager-ios-lane-wt" "$G"
  now="$(date +%s)"
  old=$((now - 3 * 86400))
  young=$((now - 3600))

  local fails=0 checks=0
  check() { # <name> <condition result: 0 pass> <detail>
    checks=$((checks + 1))
    if [ "$2" -ne 0 ]; then
      fails=$((fails + 1))
      printf 'FAIL %s: %s\n' "$1" "$3"
    fi
  }
  eq() { [ "$2" = "$3" ]; check "$1" $? "expected [$3] got [$2]"; }

  # --- git fixtures (no user or system config reaches them) ----------------------------------
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  local g="git -c init.defaultBranch=main -c advice.detachedHead=false"
  $g init -q --bare "$P/origin.git"
  $g clone -q "$P/origin.git" "$T/seed" 2>/dev/null
  $g -C "$T/seed" commit -q --allow-empty -m seed
  $g -C "$T/seed" push -q origin main
  $g -C "$T/seed" push -q origin main:refs/heads/feature/wp605-originonly
  $g clone -q "$P/origin.git" "$P/img-manager-ios"
  $g clone -q "$P/origin.git" "$P/img-manager-ios-lane"
  $g -C "$P/img-manager-ios-lane" branch -q feature/wp604-laneonly
  $g -C "$P/img-manager-ios" worktree add -q -b feature/wp701-host-wt "$P/img-manager-ios-wt/wp701" 2>/dev/null
  $g -C "$P/img-manager-ios-lane" worktree add -q -b feature/wp702-lanewt "$P/img-manager-ios-lane-wt/wp702" 2>/dev/null
  mv "$P/img-manager-ios-lane-wt/wp702" "$C/img-manager-ios-lane-wt/wp702"
  rmdir "$P/img-manager-ios-lane-wt"
  $g clone -q "$P/origin.git" "$C/other-clone"
  $g -C "$C/other-clone" worktree add -q -b feature/wp703-container-only "$C/img-manager-ios-lane-wt/wp703" 2>/dev/null
  # A hidden worktree directory under a root, and a branch whose name a tag shares (rev-parse
  # --abbrev-ref answers `heads/feature/wp705-tagged` there); neither named clone lists either.
  $g -C "$C/other-clone" worktree add -q -b feature/wp704-hidden "$P/img-manager-ios-wt/.retained" 2>/dev/null
  $g -C "$C/other-clone" worktree add -q -b feature/wp705-tagged "$C/img-manager-ios-lane-wt/wp705" 2>/dev/null
  $g -C "$C/other-clone" tag feature/wp705-tagged
  # A worktree directory whose name holds a newline, next to plain files named after its two
  # halves: a newline-split listing would see only those files and never probe the worktree.
  $g -C "$C/other-clone" worktree add -q -b feature/wp707-newline "$P/img-manager-ios-wt/active"$'\n'"copy" 2>/dev/null
  printf 'f\n' >"$P/img-manager-ios-wt/active" && printf 'f\n' >"$P/img-manager-ios-wt/copy"
  [ -d "$P/img-manager-ios-wt/active"$'\n'"copy" ]
  check fixture-newline-wt $? "git did not create the newline-named worktree"
  [ -d "$C/img-manager-ios-lane-wt/wp703" ] && [ -d "$P/img-manager-ios-wt/wp701" ] && [ -d "$P/img-manager-ios-wt/.retained" ] \
    && [ "$(git -C "$C/img-manager-ios-lane-wt/wp705" rev-parse --abbrev-ref HEAD)" = heads/feature/wp705-tagged ]
  check fixture-git $? "git fixtures not built"

  # --- the fake build host ---------------------------------------------------------------------
  mk_lane() { # <dir under gate> <lane epoch> <work epoch> [holder|NOHOLDER]
    local d="${MK_G:-$G}/$1"
    mkdir -p "$d/work/sub"
    head -c 6000 /dev/zero >"$d/work/sub/blob"
    printf 'x\n' >"$d/.gate-run.log"
    if [ "${4:-}" = NOHOLDER ]; then
      mkdir "$d/.lock"
    elif [ -n "${4:-}" ]; then
      mkdir "$d/.lock"
      printf '%s\n' "$4" >"$d/.lock/holder"
    fi
    touch -d "@$3" "$d/work/sub" "$d/work"
    touch -d "@$2" "$d"
  }
  mk_lane feature/wp700-live "$old" "$old"
  mk_lane fix/wp709-chainlive "$old" "$old"
  mk_lane fix/wp600-dead "$old" "$old"
  mk_lane fix/wp601-locked "$old" "$old" "gate-x 123"
  mk_lane fix/wp602-young "$young" "$young"
  mk_lane fix/wp603-nohold "$old" "$old" NOHOLDER
  mk_lane feature/wp604-laneonly "$old" "$old"
  mk_lane feature/wp605-originonly "$old" "$old"
  mk_lane feature/wp701-host-wt "$old" "$old"
  mk_lane feature/wp702-lanewt "$old" "$old"
  mk_lane feature/wp703-container-only "$old" "$old"
  mk_lane "fix/it's-wp607" "$old" "$old"
  mk_lane fix/wp7000-notlive "$old" "$old"
  mk_lane fix/wp610-edge $((now - 86400 + 120)) $((now - 86400 + 120))
  mk_lane fix/wp611-workyoung "$old" "$young"
  mk_lane fix/wp608-nest "$old" "$old"
  mkdir -p "$G/fix/wp608-nest/inner/work"
  touch -d "@$old" "$G/fix/wp608-nest"
  mk_lane ".reaping-fix%2Fwp606-old-20260901T000000Z" "$old" "$old"
  mk_lane feature/wp704-hidden "$old" "$old"
  mk_lane feature/wp705-tagged "$old" "$old"
  mk_lane feature/wp707-newline "$old" "$old"
  mk_lane fix/wp612-24h-exact $((now - 86400)) $((now - 86400))
  mkdir -p "$G/.reaping-fix%2Fwp613-nowork-20260901T000000Z" && printf 'x\n' >"$G/.reaping-fix%2Fwp613-nowork-20260901T000000Z/f"
  touch -d "@$old" "$G/.reaping-fix%2Fwp613-nowork-20260901T000000Z"
  mkdir -p "$G/.host.lock" && printf 'gate-host 1\n' >"$G/.host.lock/holder"
  mkdir -p "$H/build/repaso-es-ios/work.noindex/pf367-int-tmp" && head -c 4096 /dev/zero >"$H/build/repaso-es-ios/work.noindex/pf367-int-tmp/f"

  cat >"$T/fake-host" <<'EOF'
#!/usr/bin/env bash
step="$(printf '%s' "$1" | grep -o 'lane-remove:[a-z-]*' | head -n 1)"
step="${step#lane-remove:}"
step="${step:-list}"
printf '%s\n' "$step" >>"$FAKE_HOST_LOG"
if [ "${FAKE_HOST_FAIL:-}" = "$step" ] || [ "${FAKE_HOST_FAIL:-}" = all ]; then exit 255; fi
G="$FAKE_HOME/build/img-manager-ios/gate"
if [ "$step" = holder-readback ] && [ -n "${FAKE_INTRUDE:-}" ]; then
  printf 'intruder\n' >"$G/$FAKE_INTRUDE/.lock/holder"
fi
if [ "$step" = rm ]; then
  if [ -n "${FAKE_WATCH:-}" ]; then
    e=0; [ -e "$G/$FAKE_WATCH" ] && e=1
    n="$(find "$G" -maxdepth 1 -name '.reaping-*' | wc -l | tr -d ' ')"
    printf 'PRE-RM live_exists=%s reaping=%s\n' "$e" "$n" >>"$FAKE_HOST_LOG.snap"
  fi
  if [ -n "${FAKE_RECREATE:-}" ]; then
    mkdir -p "$G/$FAKE_RECREATE/work" && mkdir "$G/$FAKE_RECREATE/.lock" && printf 'gate-new\n' >"$G/$FAKE_RECREATE/.lock/holder"
  fi
fi
HOME="$FAKE_HOME" PATH="$FAKE_SHIM_DIR:$PATH" exec bash -c "$1"
EOF
  chmod +x "$T/fake-host"
  # `mv` on the fake host: a rename INTO gate/.reaping-* first runs $FAKE_MV_PRE (after every
  # check the step makes before its mv) and then $FAKE_MV_POST (after the rename, before the
  # step's own post-rename checks) — a gate acting at exactly those instants. Any other mv
  # (the move back) is the real one, untouched.
  mkdir -p "$T/shim"
  cat >"$T/shim/mv" <<EOF2
#!/usr/bin/env bash
case "\${2:-}" in
  */.reaping-*)
    [ -z "\${FAKE_MV_PRE:-}" ] || bash -c "\$FAKE_MV_PRE"
    $(command -v mv) "\$@"; rc=\$?
    [ -z "\${FAKE_MV_POST:-}" ] || bash -c "\$FAKE_MV_POST"
    exit \$rc
    ;;
esac
exec $(command -v mv) "\$@"
EOF2
  chmod +x "$T/shim/mv"
  printf '%s\n' "$now LAUNCH milestone 700 x" "$now CHAIN EXIT rc=0" "$now LAUNCH milestone 709 \"y\" in tmux session wp709" >"$T/chain.log"
  cat >"$T/ticket.json" <<'EOF'
{"key":"ARCH-1064","description":"mirrors `~/build/repaso-es-ios/work.noindex/pf367-int-tmp` (12.1 GB) and `gate.noindex/pf367-int-tmp` (0.3 GB). Also ~/build/x$(touch $HOME/PWNED) and ~/build/../etc."}
EOF

  export FAKE_HOME="$H" FAKE_HOST_LOG="$T/host.log" FAKE_SHIM_DIR="$T/shim"
  export LANE_HOST_RUN="$T/fake-host" LANE_DF_PATH=/ LANE_NOW="$now"
  export LANE_MAIN_CLONE="$P/img-manager-ios" LANE_LANE_CLONE="$P/img-manager-ios-lane"
  export LANE_HOST_PROJECTS="$P" LANE_CONTAINER_PROJECTS="$C"
  export LANE_WT_ROOTS="$C/img-manager-ios-lane-wt $P/img-manager-ios-wt"
  export LANE_TMUX_LS="printf 'reprobe\n' >>\"$T/host.log\"; printf 'pf-1: 1 windows\nwp700: 1 windows (created x)\n'"
  export LANE_CHAIN_LOG="$T/chain.log" LANE_TICKET_READER="cat '$T/ticket.json'"
  export LANE_REAPS_TSV="$T/gate-reaps.tsv"
  unset LANE_GATE_ROOT LANE_GATE_ROOT_FIXTURE LANE_MIN_AGE_S LANE_GIT_TIMEOUT FAKE_HOST_FAIL FAKE_INTRUDE FAKE_WATCH FAKE_RECREATE \
    FAKE_MV_PRE FAKE_MV_POST

  local out rc
  verdict() { printf '%s\n' "$out" | awk -F'\t' -v b="$1" '$3 == b { print $13 }'; }
  col() { printf '%s\n' "$out" | awk -F'\t' -v b="$1" -v c="$2" '$3 == b { print $c }'; }

  # --- A: everything measurable ------------------------------------------------------------------
  out="$(bash "$S/lane-inventory.sh")"
  rc=$?
  eq A-exit "$rc" 0
  eq A-live "$(verdict feature/wp700-live)" "KEEP live wp700"
  eq A-chainlog-live "$(verdict fix/wp709-chainlive)" "KEEP live wp709"
  eq A-dead "$(verdict fix/wp600-dead)" CANDIDATE
  eq A-locked "$(verdict fix/wp601-locked)" "KEEP locked"
  eq A-locked-holder "$(col fix/wp601-locked 7)" "LOCKED by gate-x 123"
  eq A-young "$(verdict fix/wp602-young)" "KEEP young(lane)"
  eq A-unmeasured-lock "$(verdict fix/wp603-nohold)" "UNMEASURED lock"
  eq A-lane-clone-only "$(verdict feature/wp604-laneonly)" "KEEP present:lane-clone"
  eq A-origin-only "$(verdict feature/wp605-originonly)" "KEEP present:origin"
  eq A-host-wt "$(verdict feature/wp701-host-wt)" "KEEP present:main-clone,worktree"
  eq A-translated-wt "$(verdict feature/wp702-lanewt)" "KEEP present:lane-clone,worktree"
  eq A-container-wt-only "$(verdict feature/wp703-container-only)" "KEEP present:worktree"
  eq A-escaped "$(verdict "fix/it's-wp607")" CANDIDATE
  eq A-digit-bounded-live "$(verdict fix/wp7000-notlive)" CANDIDATE
  eq A-edge-23h58 "$(verdict fix/wp610-edge)" "KEEP young(lane)"
  eq A-work-young "$(verdict fix/wp611-workyoung)" "KEEP young(work)"
  eq A-nested "$(verdict fix/wp608-nest)" "UNMEASURED layout(nested)"
  eq A-hidden-root-wt "$(verdict feature/wp704-hidden)" "KEEP present:worktree"
  eq A-tag-same-name "$(verdict feature/wp705-tagged)" "KEEP present:worktree"
  eq A-newline-named-wt "$(verdict feature/wp707-newline)" "KEEP present:worktree"
  eq A-edge-24h-exact "$(verdict fix/wp612-24h-exact)" "KEEP young(lane)"
  eq A-reaping-no-work "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "fix/wp613-nowork" { print $6 "|" $13 }')" "-|UNMEASURED mtime"
  eq A-reaping "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "reaping" && $3 == "fix/wp606-old" { print $3 "|" $13 }')" "fix/wp606-old|CANDIDATE"
  eq A-candidates "$(printf '%s\n' "$out" | awk -F'\t' '$13 == "CANDIDATE" { print $3 }' | sort | tr '\n' ' ')" \
    "fix/it's-wp607 fix/wp600-dead fix/wp606-old fix/wp7000-notlive "
  local sum
  sum="$(printf '%s\n' "$out" | awk -F'\t' '$13 == "CANDIDATE" { s += $4 } END { print s + 0 }')"
  eq A-total "$(printf '%s\n' "$out" | grep '^TOTAL')" "$(printf 'TOTAL\tcandidates=4\tcandidate_kb=%s' "$sum")"
  printf '%s\n' "$out" | grep -q $'^DF\t/\tavail_kb=[0-9][0-9]*\tfree_gib=[0-9.]*\t'
  check A-df $? "no DF line with avail_kb and free_gib"
  printf '%s\n' "$out" | grep -q 'host\.lock'
  [ $? -eq 1 ]; check A-host-lock-not-a-lane $? ".host.lock appears in the inventory"
  eq A-scratch-present "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "~/build/repaso-es-ios/work.noindex/pf367-int-tmp" { print $13 }')" \
    "KEEP scratch (ARCH-1064, not an img-manager lane; lane-remove never takes it)"
  eq A-scratch-absent "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "~/build/repaso-es-ios/gate.noindex/pf367-int-tmp" { print $13 }')" \
    "KEEP absent-on-host (ARCH-1064 scratch)"
  [ ! -e "$H/PWNED" ] && [ ! -e "$T/PWNED" ]
  check A-ticket-text-inert $? "ticket text ran on the host"
  eq A-rows "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "lane" || $1 == "reaping"' | wc -l | tr -d ' ')" 22

  # --- B: the live probe cannot answer -> no candidate, and it is said so ---------------------
  out="$(LANE_TMUX_LS='echo "Error response from daemon: No such container" >&2; exit 1' bash "$S/lane-inventory.sh")"
  eq B-exit "$?" 0
  eq B-dead "$(verdict fix/wp600-dead)" "UNMEASURED live(tmux)"
  eq B-candidates "$(printf '%s\n' "$out" | grep '^TOTAL')" $'TOTAL\tcandidates=0\tcandidate_kb=0'
  out="$(LANE_TMUX_LS='echo "no server running on /tmp/tmux-1000/default" >&2; exit 1' bash "$S/lane-inventory.sh")"
  eq B-no-tmux-server-is-an-answer "$(verdict fix/wp600-dead)" CANDIDATE
  out="$(LANE_CHAIN_LOG="$T/absent.log" bash "$S/lane-inventory.sh")"
  eq B-chainlog-missing "$(verdict fix/wp600-dead)" "UNMEASURED live(chain-log)"

  # --- C: a worktree root missing, a listed container path with no translation -----------------
  out="$(LANE_WT_ROOTS="$C/img-manager-ios-lane-wt $P/absent-wt" bash "$S/lane-inventory.sh")"
  eq C-root-missing "$(verdict fix/wp600-dead)" "UNMEASURED worktree(wt-root:$P/absent-wt)"
  eq C-root-missing-present-still-keep "$(verdict feature/wp604-laneonly)" "KEEP present:lane-clone"
  mkdir -p "$T/empty-container"
  out="$(LANE_CONTAINER_PROJECTS="$T/empty-container" LANE_WT_ROOTS="$P/img-manager-ios-wt" bash "$S/lane-inventory.sh")"
  eq C-translation-missing "$(verdict fix/wp600-dead)" "UNMEASURED worktree(wt-missing:$P/img-manager-ios-lane-wt/wp702)"
  out="$(LANE_LANE_CLONE="$P/absent-clone" bash "$S/lane-inventory.sh")"
  case "$(verdict fix/wp600-dead)" in "UNMEASURED lane-clone worktree(wt-list:$P/absent-clone"*) r=0 ;; *) r=1 ;; esac
  check C-clone-missing $r "got [$(verdict fix/wp600-dead)]"

  # --- C2: a chain.log path that passes -r but cannot be read (a directory) -> live UNMEASURED ----
  out="$(LANE_CHAIN_LOG="$T" bash "$S/lane-inventory.sh")"
  eq C2-chainlog-read-fails "$(verdict fix/wp600-dead)" "UNMEASURED live(chain-log)"

  # --- C3: a worktree root that exists but cannot be listed is UNMEASURED; an empty one is not ----
  mkdir -p "$T/emptyroot" "$T/lockedroot"
  out="$(LANE_WT_ROOTS="$C/img-manager-ios-lane-wt $P/img-manager-ios-wt $T/emptyroot" bash "$S/lane-inventory.sh")"
  eq C3-empty-root-is-an-answer "$(verdict fix/wp600-dead)" CANDIDATE
  if [ "$(id -u)" -eq 0 ]; then
    echo "NOTE C3-unlistable-root skipped: running as root, chmod 000 does not stop root"
  else
    chmod 000 "$T/lockedroot"
    out="$(LANE_WT_ROOTS="$C/img-manager-ios-lane-wt $P/img-manager-ios-wt $T/lockedroot" bash "$S/lane-inventory.sh")"
    eq C3-unlistable-root "$(verdict fix/wp600-dead)" "UNMEASURED worktree(wt-root-unreadable:$T/lockedroot)"
    chmod 755 "$T/lockedroot"
  fi

  # --- X: a lane-clone path is read at its container counterpart, never at the same-named host
  # path. The lane clone records <projects>/img-manager-ios-lane-wt/w1 (container view). On the
  # host side that path is a main-clone worktree on feature/wp802-host; the container counterpart
  # is a third clone's worktree on feature/wp801-ctr, outside every worktree root. Only reading the
  # counterpart sees wp801.
  local X="$T/x" XP="$T/x/projects" XC="$T/x/container/projects"
  mkdir -p "$XP/img-manager-ios-wt" "$XC/img-manager-ios-lane-wt" "$X/home/build/img-manager-ios/gate"
  $g clone -q "$P/origin.git" "$XP/img-manager-ios"
  $g clone -q "$P/origin.git" "$XP/img-manager-ios-lane"
  $g clone -q "$P/origin.git" "$X/third"
  $g -C "$XP/img-manager-ios-lane" worktree add -q --detach "$XP/img-manager-ios-lane-wt/w1" 2>/dev/null
  rm -rf "$XP/img-manager-ios-lane-wt/w1"
  $g -C "$XP/img-manager-ios" worktree add -q -b feature/wp802-host "$XP/img-manager-ios-lane-wt/w1" 2>/dev/null
  $g -C "$X/third" worktree add -q -b feature/wp801-ctr "$XC/img-manager-ios-lane-wt/w1" 2>/dev/null
  MK_G="$X/home/build/img-manager-ios/gate" mk_lane feature/wp801-ctr "$old" "$old"
  git -C "$XP/img-manager-ios-lane" worktree list --porcelain | grep -qx "worktree $XP/img-manager-ios-lane-wt/w1"
  check X-fixture $? "lane clone does not list the container-view path"
  xinv() { FAKE_HOME="$X/home" LANE_MAIN_CLONE="$XP/img-manager-ios" LANE_LANE_CLONE="$XP/img-manager-ios-lane" \
    LANE_HOST_PROJECTS="$XP" LANE_WT_ROOTS="$XP/img-manager-ios-wt" bash "$S/lane-inventory.sh"; }
  out="$(LANE_CONTAINER_PROJECTS="$XC" xinv)"
  eq X-container-counterpart-decides "$(verdict feature/wp801-ctr)" "KEEP present:worktree"
  out="$(LANE_CONTAINER_PROJECTS="$X/nowhere" xinv)"
  eq X-counterpart-missing-unmeasured "$(verdict feature/wp801-ctr)" \
    "UNMEASURED worktree(wt-missing:$XP/img-manager-ios-lane-wt/w1)"

  # --- G: only the production gate root, unless a fixture says otherwise ------------------------
  out="$(LANE_GATE_ROOT='$HOME/build/elsewhere/gate' bash "$S/lane-inventory.sh" 2>&1)"
  eq G-inventory-other-root-refused "$?" 2
  out="$(LANE_GATE_ROOT='$HOME/build/elsewhere/gate' LANE_GATE_ROOT_FIXTURE=1 bash "$S/lane-inventory.sh")"
  eq G-inventory-fixture-root-allowed "$?" 0
  : >"$T/host.log"
  LANE_GATE_ROOT='$HOME/build/img-manager-ios/gate/fix' bash "$S/lane-remove.sh" wp600-dead >/dev/null 2>&1
  eq G-remove-other-root-refused "$?" 2
  eq G-remove-other-root-no-host-step "$(tr '\n' ' ' <"$T/host.log")" ""
  [ -d "$G/fix/wp600-dead/work" ]; check G-remove-other-root-lane-intact $? "lane touched"

  # --- D: origin unreachable -> UNMEASURED, never absent ----------------------------------------
  mv "$P/origin.git" "$P/origin.git.away"
  out="$(bash "$S/lane-inventory.sh")"
  mv "$P/origin.git.away" "$P/origin.git"
  eq D-origin-unreachable "$(verdict fix/wp600-dead)" "UNMEASURED origin"
  eq D-origin-only-not-candidate "$(verdict feature/wp605-originonly)" "UNMEASURED origin"

  # --- E: the host cannot be read -> exit 3, no lane rows, no candidates --------------------------
  out="$(FAKE_HOST_FAIL=list bash "$S/lane-inventory.sh")"
  eq E-exit "$?" 3
  eq E-total "$(printf '%s\n' "$out" | grep '^TOTAL')" $'TOTAL\tcandidates=0\tcandidate_kb=0'
  eq E-no-rows "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "lane"' | wc -l | tr -d ' ')" 0

  # --- F: an empty gate root, and none at all ---------------------------------------------------
  out="$(FAKE_HOME="$T/emptyhome" bash -c 'mkdir -p "$FAKE_HOME/build/img-manager-ios/gate"; bash "$1/lane-inventory.sh"' _ "$S")"
  eq F-empty-exit "$?" 0
  eq F-empty-total "$(printf '%s\n' "$out" | grep '^TOTAL')" $'TOTAL\tcandidates=0\tcandidate_kb=0'
  out="$(FAKE_HOME="$T/nohome" bash "$S/lane-inventory.sh")"
  printf '%s\n' "$out" | grep -q 'gate root absent'
  check F-no-root $? "no 'gate root absent' line"

  # --- R: lane-remove.sh ----------------------------------------------------------------------
  rlog() { tr '\n' ' ' <"$T/host.log"; }
  : >"$T/host.log"
  out="$(FAKE_WATCH=fix/wp600-dead bash "$S/lane-remove.sh" fix/wp600-dead)"
  eq R1-exit "$?" 0
  eq R1-sequence "$(rlog)" "mkdir-lock holder-readback reprobe mv rm df "
  eq R1-pre-rm "$(cat "$T/host.log.snap" 2>/dev/null)" "PRE-RM live_exists=0 reaping=3"
  [ ! -e "$G/fix/wp600-dead" ]; check R1-lane-gone $? "gate/fix/wp600-dead still there"
  eq R1-no-leftover "$(find "$G" -maxdepth 1 -name '.reaping-fix%2Fwp600-dead-*' | wc -l | tr -d ' ')" 0
  eq R1-tsv-header "$(head -n 1 "$T/gate-reaps.tsv" 2>/dev/null)" $'utc\tbranch\tremoved_kb\tfree_before_gib\tfree_after_gib\trenamed_path'
  awk -F'\t' 'NR == 2 && $2 == "fix/wp600-dead" && $3 ~ /^[0-9]+$/ && $3 > 0 && $4 ~ /^[0-9.]+$/ && $5 ~ /^[0-9.]+$/ && $6 ~ /^gate\/\.reaping-fix%2Fwp600-dead-[0-9]{8}T[0-9]{6}Z$/' "$T/gate-reaps.tsv" | grep -q .
  check R1-tsv-row $? "row 2 of gate-reaps.tsv is [$(sed -n 2p "$T/gate-reaps.tsv" 2>/dev/null)]"
  case "$out" in "lane-remove: REMOVED fix/wp600-dead removed_kb="*) r=0 ;; *) r=1 ;; esac
  check R1-says-removed $r "output [$out]"
  eq R1-others-intact "$(find "$G" -name work -type d | wc -l | tr -d ' ')" 21

  : >"$T/host.log"
  out="$(bash "$S/lane-remove.sh" fix/wp601-locked)"
  eq R2-exit "$?" 0
  eq R2-skip "$out" "lane-remove: SKIP locked by gate-x 123"
  eq R2-sequence "$(rlog)" "mkdir-lock "
  eq R2-holder-intact "$(cat "$G/fix/wp601-locked/.lock/holder")" "gate-x 123"
  [ -d "$G/fix/wp601-locked/work" ]; check R2-lane-intact $? "locked lane touched"

  : >"$T/host.log"
  out="$(bash "$S/lane-remove.sh" feature/wp604-laneonly)"
  eq R3-exit "$?" 0
  case "$out" in "lane-remove: SKIP KEEP present:lane-clone "*) r=0 ;; *) r=1 ;; esac
  check R3-skip $r "output [$out]"
  eq R3-sequence "$(rlog)" "mkdir-lock holder-readback reprobe release "
  [ -d "$G/feature/wp604-laneonly/work" ] && [ ! -e "$G/feature/wp604-laneonly/.lock" ]
  check R3-released-intact $? "lane not intact or lock not released"

  : >"$T/host.log"
  out="$(bash "$S/lane-remove.sh" feature/wp703-container-only)"
  case "$out" in "lane-remove: SKIP KEEP present:worktree "*) r=0 ;; *) r=1 ;; esac
  check R3b-container-wt-skip $r "output [$out]"

  : >"$T/host.log"
  out="$(bash "$S/lane-remove.sh" "fix/it's-wp607")"
  eq R4-exit "$?" 0
  [ ! -e "$G/fix/it's-wp607" ]; check R4-escaped-gone $? "escaped lane still there"
  case "$out" in "lane-remove: REMOVED fix/it's-wp607 "*) r=0 ;; *) r=1 ;; esac
  check R4-says-removed $r "output [$out]"

  : >"$T/host.log"
  rm -f "$T/host.log.snap"
  out="$(FAKE_RECREATE=fix/wp7000-notlive bash "$S/lane-remove.sh" fix/wp7000-notlive)"
  eq R5-exit "$?" 0
  eq R5-recreated-lane-kept "$(cat "$G/fix/wp7000-notlive/.lock/holder" 2>/dev/null)" gate-new
  eq R5-quarantine-gone "$(find "$G" -maxdepth 1 -name '.reaping-fix%2Fwp7000-notlive-*' | wc -l | tr -d ' ')" 0

  mk_lane fix/wp620-hostfail "$old" "$old"
  : >"$T/host.log"
  out="$(FAKE_HOST_FAIL=mkdir-lock bash "$S/lane-remove.sh" fix/wp620-hostfail)"
  eq R6-exit "$?" 1
  case "$out" in "lane-remove: FAIL mkdir-lock rc=255 "*) r=0 ;; *) r=1 ;; esac
  check R6-fail $r "output [$out]"

  bash "$S/lane-remove.sh" .host.lock >/dev/null 2>&1
  eq R7-host-lock-refused "$?" 2
  bash "$S/lane-remove.sh" ../memos-ng-ios >/dev/null 2>&1
  eq R7-dotdot-refused "$?" 2
  [ -d "$G/.host.lock" ]; check R7-host-lock-intact $? ".host.lock gone"

  mk_lane fix/wp621-intrude "$old" "$old"
  : >"$T/host.log"
  out="$(FAKE_INTRUDE=fix/wp621-intrude bash "$S/lane-remove.sh" fix/wp621-intrude)"
  eq R8-exit "$?" 0
  case "$out" in "lane-remove: SKIP holder read-back mismatch"*) r=0 ;; *) r=1 ;; esac
  check R8-skip $r "output [$out]"
  eq R8-foreign-holder-kept "$(cat "$G/fix/wp621-intrude/.lock/holder" 2>/dev/null)" intruder
  [ -d "$G/fix/wp621-intrude/work" ]; check R8-lane-intact $? "lane touched"

  mk_lane fix/wp622-unmeasured "$old" "$old"
  : >"$T/host.log"
  out="$(LANE_TMUX_LS='exit 1' bash "$S/lane-remove.sh" fix/wp622-unmeasured)"
  case "$out" in "lane-remove: SKIP UNMEASURED live(tmux)"*) r=0 ;; *) r=1 ;; esac
  check R9-unmeasured-skip $r "output [$out]"
  [ -d "$G/fix/wp622-unmeasured/work" ] && [ ! -e "$G/fix/wp622-unmeasured/.lock" ]
  check R9-released-intact $? "lane not intact or lock left"

  : >"$T/host.log"
  out="$(bash "$S/lane-remove.sh" fix/wp608-nest)"
  eq R10-nested-skip "$out" "lane-remove: SKIP gate/fix/wp608-nest holds inner — another lane may live inside it"
  [ -d "$G/fix/wp608-nest/inner/work" ] && [ ! -e "$G/fix/wp608-nest/.lock" ]
  check R10-inner-intact $? "nested lane touched or lock left"

  # R11: a gate for a DESCENDANT branch creates its lane inside this one after every check the
  # remover makes before the rename (the mv shim's PRE hook). The post-rename scan finds it, the
  # tree goes back to its name, our lock is released, and both lanes and the child's holder survive.
  mk_lane fix/wp624-desc "$old" "$old"
  : >"$T/host.log"
  out="$(FAKE_MV_PRE="mkdir -p '$G/fix/wp624-desc/y/work' && mkdir '$G/fix/wp624-desc/y/.lock' && printf 'gate-child 9\n' >'$G/fix/wp624-desc/y/.lock/holder'" \
    bash "$S/lane-remove.sh" fix/wp624-desc)"
  eq R11-exit "$?" 0
  case "$out" in "lane-remove: SKIP nested lane appeared gate/fix/wp624-desc/y "*) r=0 ;; *) r=1 ;; esac
  check R11-skip $r "output [$out]"
  eq R11-child-holder-intact "$(cat "$G/fix/wp624-desc/y/.lock/holder" 2>/dev/null)" "gate-child 9"
  [ -d "$G/fix/wp624-desc/work/sub" ] && [ ! -e "$G/fix/wp624-desc/.lock" ]
  check R11-parent-back-released $? "parent lane not back at its name, or our lock left"
  eq R11-no-quarantine "$(find "$G" -maxdepth 1 -name '.reaping-fix%2Fwp624-desc-*' | wc -l | tr -d ' ')" 0

  # R12: as R11, and a fresh gate re-creates gate/<branch> right after the rename (POST hook):
  # the tree cannot go back, so it stays renamed with our lock inside, nothing is removed or
  # released, and the run exits non-zero.
  mk_lane fix/wp625-taken "$old" "$old"
  : >"$T/host.log"
  out="$(FAKE_MV_PRE="mkdir -p '$G/fix/wp625-taken/y/work' && mkdir '$G/fix/wp625-taken/y/.lock' && printf 'gate-child 9\n' >'$G/fix/wp625-taken/y/.lock/holder'" \
    FAKE_MV_POST="mkdir -p '$G/fix/wp625-taken/work' && mkdir '$G/fix/wp625-taken/.lock' && printf 'gate-fresh\n' >'$G/fix/wp625-taken/.lock/holder'" \
    bash "$S/lane-remove.sh" fix/wp625-taken)"
  eq R12-exit "$?" 1
  case "$out" in "lane-remove: SKIP nested lane appeared gate/.reaping-fix%2Fwp625-taken-"*"/y "*) r=0 ;; *) r=1 ;; esac
  check R12-skip $r "output [$out]"
  local q
  q="$(find "$G" -maxdepth 1 -name '.reaping-fix%2Fwp625-taken-*' | head -n 1)"
  eq R12-child-holder-intact "$(cat "$q/y/.lock/holder" 2>/dev/null)" "gate-child 9"
  case "$(cat "$q/.lock/holder" 2>/dev/null)" in "lane-remove "*) r=0 ;; *) r=1 ;; esac
  check R12-own-lock-not-released $r "holder inside the quarantine is [$(cat "$q/.lock/holder" 2>/dev/null)]"
  eq R12-fresh-lane-intact "$(cat "$G/fix/wp625-taken/.lock/holder" 2>/dev/null)" gate-fresh

  # R13: the holder changes AFTER the initial read-back and after the mv step's own pre-rename
  # check (PRE hook): only the post-rename holder check sees it — nothing is removed.
  mk_lane fix/wp626-late "$old" "$old"
  : >"$T/host.log"
  out="$(FAKE_MV_PRE="printf 'intruder-late\n' >'$G/fix/wp626-late/.lock/holder'" bash "$S/lane-remove.sh" fix/wp626-late)"
  eq R13-exit "$?" 1
  case "$out" in "lane-remove: FAIL renamed to gate/.reaping-fix%2Fwp626-late-"*) r=0 ;; *) r=1 ;; esac
  check R13-fail $r "output [$out]"
  q="$(find "$G" -maxdepth 1 -name '.reaping-fix%2Fwp626-late-*' | head -n 1)"
  [ -n "$q" ] && [ -d "$q/work/sub" ] && [ "$(cat "$q/.lock/holder" 2>/dev/null)" = intruder-late ]
  check R13-nothing-removed $? "renamed tree [$q] missing, emptied, or its holder changed"
  eq R13-sequence "$(rlog)" "mkdir-lock holder-readback reprobe mv "

  # R17: the descendant is `<branch>/work` — its lane is gate/<branch>/work/{work,.lock}, i.e.
  # INSIDE this lane's own work/, under the very name the scan lets through at the top level.
  mk_lane fix/wp628-w "$old" "$old"
  out="$(FAKE_MV_PRE="mkdir -p '$G/fix/wp628-w/work/work' && mkdir '$G/fix/wp628-w/work/.lock' && printf 'gate-child 9\n' >'$G/fix/wp628-w/work/.lock/holder'" \
    bash "$S/lane-remove.sh" fix/wp628-w)"
  eq R17-exit "$?" 0
  case "$out" in "lane-remove: SKIP nested lane appeared gate/fix/wp628-w/work/"*) r=0 ;; *) r=1 ;; esac
  check R17-skip $r "output [$out]"
  eq R17-child-holder-intact "$(cat "$G/fix/wp628-w/work/.lock/holder" 2>/dev/null)" "gate-child 9"

  # R18: the remover shares both probes: an unreadable chain.log, an unlistable root -> SKIP.
  mk_lane fix/wp629-probe "$old" "$old"
  out="$(LANE_CHAIN_LOG="$T" bash "$S/lane-remove.sh" fix/wp629-probe)"
  case "$out" in "lane-remove: SKIP UNMEASURED live(chain-log)"*) r=0 ;; *) r=1 ;; esac
  check R18-chainlog-read-fails-skip $r "output [$out]"
  if [ "$(id -u)" -ne 0 ]; then
    touch -d "@$old" "$G/fix/wp629-probe" # the first run's lock/release bumped the lane mtime
    chmod 000 "$T/lockedroot"
    out="$(LANE_WT_ROOTS="$C/img-manager-ios-lane-wt $P/img-manager-ios-wt $T/lockedroot" bash "$S/lane-remove.sh" fix/wp629-probe)"
    chmod 755 "$T/lockedroot"
    case "$out" in "lane-remove: SKIP UNMEASURED worktree(wt-root-unreadable:$T/lockedroot)"*) r=0 ;; *) r=1 ;; esac
    check R18-unlistable-root-skip $r "output [$out]"
  fi
  [ -d "$G/fix/wp629-probe/work" ] && [ ! -e "$G/fix/wp629-probe/.lock" ]
  check R18-intact-released $? "lane touched or lock left"

  # R20: the newline-named worktree protects its branch in the remover's re-probe as well.
  out="$(bash "$S/lane-remove.sh" feature/wp707-newline)"
  case "$out" in "lane-remove: SKIP KEEP present:worktree "*) r=0 ;; *) r=1 ;; esac
  check R20-newline-named-wt-skip $r "output [$out]"
  [ -d "$G/feature/wp707-newline/work" ]; check R20-lane-intact $? "lane touched"
  # R19: a SKIP whose release cannot be confirmed is a failure that names the lock it leaves.
  out="$(FAKE_HOST_FAIL=release bash "$S/lane-remove.sh" feature/wp605-originonly)"
  eq R19-exit "$?" 1
  printf '%s\n' "$out" | grep -q "^lane-remove: FAIL release rc=255 .*gate/feature/wp605-originonly/\.lock"
  check R19-says-lock-left $? "output [$out]"
  case "$(cat "$G/feature/wp605-originonly/.lock/holder" 2>/dev/null)" in "lane-remove "*) r=0 ;; *) r=1 ;; esac
  check R19-lock-really-left $r "holder [$(cat "$G/feature/wp605-originonly/.lock/holder" 2>/dev/null)]"
  rm -rf "$G/feature/wp605-originonly/.lock"
  # A foreign holder is still never deleted, and that SKIP stays exit 0 (R8).

  # R14: a young lane, and one exactly 24 h old, are refused before any lock is taken.
  : >"$T/host.log"
  out="$(bash "$S/lane-remove.sh" fix/wp602-young)"
  eq R14-exit "$?" 0
  case "$out" in "lane-remove: SKIP young 3600s"*) r=0 ;; *) r=1 ;; esac
  check R14-skip-young $r "output [$out]"
  eq R14-sequence "$(rlog)" "mkdir-lock "
  [ -d "$G/fix/wp602-young/work" ] && [ ! -e "$G/fix/wp602-young/.lock" ]
  check R14-intact-no-lock $? "young lane touched or a lock left"
  out="$(bash "$S/lane-remove.sh" fix/wp612-24h-exact)"
  case "$out" in "lane-remove: SKIP young 86400s"*) r=0 ;; *) r=1 ;; esac
  check R14-exactly-24h-is-young $r "output [$out]"
  [ -d "$G/fix/wp612-24h-exact/work" ]; check R14-24h-intact $? "24 h lane touched"
  out="$(bash "$S/lane-remove.sh" fix/wp611-workyoung)"
  case "$out" in "lane-remove: SKIP young 3600s (work)"*) r=0 ;; *) r=1 ;; esac
  check R14-work-young $r "output [$out]"

  # R15: the audit row cannot be appended: the lane IS gone, the run says so and exits non-zero.
  mk_lane fix/wp627-audit "$old" "$old"
  out="$(LANE_REAPS_TSV="$T/no-such-dir/gate-reaps.tsv" bash "$S/lane-remove.sh" fix/wp627-audit 2>/dev/null)"
  eq R15-exit "$?" 1
  printf '%s\n' "$out" | grep -qx "lane-remove: AUDIT-WRITE-FAILED $T/no-such-dir/gate-reaps.tsv .*"
  check R15-audit-write-failed $? "output [$out]"
  [ ! -e "$G/fix/wp627-audit" ]; check R15-lane-removed $? "lane still there"

  # R16: a symlink between the gate root and the lane: refused, the directory it points into intact.
  mkdir -p "$T/elsewhere/wp630-sym/work" && touch -d "@$old" "$T/elsewhere/wp630-sym/work" "$T/elsewhere/wp630-sym"
  ln -s "$T/elsewhere" "$G/symfix"
  out="$(bash "$S/lane-remove.sh" symfix/wp630-sym 2>&1)"
  eq R16-exit "$?" 2
  case "$out" in *"REFUSED: symlink in the lane path: "*"/gate/symfix"*) r=0 ;; *) r=1 ;; esac
  check R16-refused $r "output [$out]"
  [ -d "$T/elsewhere/wp630-sym/work" ] && [ ! -e "$T/elsewhere/wp630-sym/.lock" ]
  check R16-target-intact $? "the symlinked lane was touched"

  rm -rf "$T"

  printf 'PASS %s checks, %s failed\n' "$checks" "$fails"
  [ "$fails" -eq 0 ]
}

# --------------------------------------------------------------------------------------------------
if [ "${1:-}" = --suite ]; then
  suite "${LANE_TEST_SCRIPTS_DIR:-$here}"
  exit $?
fi

suite "$here"
base=$?
echo "baseline suite exit=$base"
[ "$base" -eq 0 ] || { echo "LANE-INVENTORY-TEST: FAIL (baseline suite)"; exit 1; }

overall=0
mutants=0
mutant() { # <name> <file> <sed expression>
  local name="$1" file="$2" expr="$3" dir rc
  mutants=$((mutants + 1))
  dir="$(mktemp -d "${TMPDIR:-/tmp}/lane-inventory-mutant.XXXXXX")"
  cp "$here/lane-inventory.sh" "$here/lane-remove.sh" "$dir/"
  sed -i "$expr" "$dir/$file"
  if cmp -s "$here/$file" "$dir/$file"; then
    echo "mutant $name: VOID (sed changed nothing)"; overall=1; rm -rf "$dir"; return
  fi
  if ! bash -n "$dir/$file"; then
    echo "mutant $name: VOID (mutant does not parse)"; overall=1; rm -rf "$dir"; return
  fi
  LANE_TEST_SCRIPTS_DIR="$dir" bash "$0" --suite >"$dir/suite.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "mutant $name: KILLED rc=$rc ($(grep -c '^FAIL' "$dir/suite.log") failing checks, first: $(grep -m1 '^FAIL' "$dir/suite.log"))"
  else
    echo "mutant $name: SURVIVED rc=$rc"; overall=1
  fi
  rm -rf "$dir"
}

mutant locked-as-candidate lane-inventory.sh 's/"LOCKED by "\*) echo "KEEP locked"; return ;;/"LOCKED by "*) ;;/'
mutant lane-clone-only-as-candidate lane-inventory.sh 's/P_LANE="$(probe_local "$LANE_LANE_CLONE" "$branch")"/P_LANE=no/'
mutant container-worktree-only-as-candidate lane-inventory.sh 's/for root in $LANE_WT_ROOTS; do/for root in ; do/'
mutant rename-skipped lane-remove.sh 's/^mv "$D" "$RP" || { echo MVFAIL; exit 1; }$/RP="$D"/; s/^rm -rf "$RP"$/rm -rf "$D"/'
mutant proceed-when-mkdir-lock-failed lane-remove.sh 's/if ! mkdir "$D\/.lock" 2>\/dev\/null; then/if ! mkdir -p "$D\/.lock" 2>\/dev\/null; then/'

# Pre-gate mutants, one per adversarial class (docs/agent-review-gate.md «Pre-gate case list»).
mutant pregate-boundary-live-id-substring lane-inventory.sh 's#grep -Eq "(^|.^0-9.)$id(.^0-9.|..)"#grep -q "$id"#'
mutant pregate-literal-quote-unescaped lane-inventory.sh "s/^sq() {.*/sq() { printf \"'%s'\" \"\$1\"; }/"
mutant pregate-error-origin-failure-as-absent lane-inventory.sh 's/\[ "$rc" -eq 0 \] || { echo UNMEASURED; return; }/[ "$rc" -eq 0 ] || { echo no; return; }/'
mutant pregate-scope-nested-lane-removed lane-remove.sh 's/\*) echo "NESTED ${c##\*\/}"; exit 0 ;;/*) ;;/; s/^\[ ! -d "$D\/work\/work" \] || .*$/:/'
mutant pregate-concurrency-readback-ignored lane-remove.sh 's/if \[ "$rc" -ne 0 \] || \[ "$out" != "$holder" \]; then/if false; then/'

# Codex premise gate p1-premise-r1 folds (B2, B3, A4-A7), one mutant per mechanism.
mutant b2-post-rename-scan-deleted lane-remove.sh 's/^n="$(nested_in "$RP")"$/n=""/'
mutant b3a-hidden-root-dirs-dropped lane-inventory.sh 's#^    for dir in "$root"/\* "$root"/\.\[!\.\]\* "$root"/\.\.?\*; do$#    for dir in "$root"/*; do#'
mutant b3b-rev-parse-abbrev-ref lane-inventory.sh 's#^  head="$(git -C "$dir" symbolic-ref -q HEAD 2>/dev/null)"$#  head="refs/heads/$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"#'
mutant b3c-host-path-preferred lane-inventory.sh 's#^  if \[ "$clone" = "$LANE_LANE_CLONE" \]; then$#  if [ "$clone" = "$LANE_LANE_CLONE" ] \&\& [ ! -d "$path" ]; then#'
mutant a4-audit-failure-ignored lane-remove.sh 's#^if ! append_audit 2>/dev/null; then$#if ! { append_audit 2>/dev/null; true; }; then#'
mutant a5-young-lane-removed lane-remove.sh 's/^\[ $((N - lm)) -gt "$A" \] || .*$/:/; s/^\[ $((N - wm)) -gt "$A" \] || .*$/:/'
mutant a5-mtime-read-after-mkdir lane-remove.sh 's#^lm="$(mt "$D")"; wm="$(mt "$D/work")"$#mkdir "$D/.lock" 2>/dev/null \&\& rmdir "$D/.lock"; lm="$(mt "$D")"; wm="$(mt "$D/work")"#'
mutant a5-inventory-24h-inclusive lane-inventory.sh 's/-le "$LANE_MIN_AGE_S"/-lt "$LANE_MIN_AGE_S"/g'
mutant a5-inventory-missing-work-qualifies lane-inventory.sh 's/^  case "$wmt" in /  [ "$wmt" != - ] || wmt=$lmt; case "$wmt" in /'
mutant a6-any-root-accepted lane-inventory.sh 's/^  \[ "$LANE_GATE_ROOT" = "$LANE_PROD_GATE_ROOT" \] || \[ "${LANE_GATE_ROOT_FIXTURE:-}" = 1 \]$/  return 0/'
mutant a6-symlink-ancestor-followed lane-remove.sh 's/^    if \[ -L "$p" \]; then printf "%s" "$p"; return 0; fi$/    :/'
mutant b2-scan-top-level-only lane-remove.sh 's/^  f="$(find "$t" -mindepth 2 .*$/  f=""/'
# Post-phase gate mq-p1-post folds (B1, B2, A3).
mutant b1-chainlog-read-failure-as-no-match lane-inventory.sh 's/^    \*) LIVE_STATE="UNMEASURED chain-log"; return ;;$/    *) last="" ;;/'
mutant b2-unlistable-root-as-empty lane-inventory.sh 's#|| { wt_unm "wt-root-unreadable:$root"; continue; }#|| continue#'
mutant a3-release-failure-swallowed lane-remove.sh '/^release() {/,/^}/ s/^  return 1$/  return 0/'
# Delta gate mq-p1-post-r2: enumeration split on newlines.
mutant r3-root-listing-split-on-newlines lane-inventory.sh 's|^    for dir in "$root"/\* "$root"/\.\[!\.\]\* "$root"/\.\.?\*; do$|    for dir in $(ls -A "$root" \| sed "s#^#$root/#"); do|'
mutant a7-post-mv-holder-check-deleted lane-remove.sh 's/^\[ "$h2" = "$H" \] || { echo "MOVED-LOCK-LOST $h2"; exit 1; }$/:/'

if [ "$overall" -eq 0 ]; then
  echo "LANE-INVENTORY-TEST: PASS (suite green, $mutants mutants killed)"
  exit 0
fi
echo "LANE-INVENTORY-TEST: FAIL (a mutant survived or was void)"
exit 1
