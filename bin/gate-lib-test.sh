#!/usr/bin/env bash
# gate-lib-test.sh — proves bin/gate-lib.sh's leg verdicts on a disposable tree (IMGMGR-346):
# a clean scan is green, a hit is red, and a scan ERROR (unreadable directory) is red with
# rc 2 instead of reading as a green zero-hit. Runs locally; needs no Mac.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
cd "$tmp"
mkdir -p .gate-artifacts src/ok
printf 'let x = NavigationSplitView()\n' > src/ok/Control.swift
. "$here/gate-lib.sh"
fail=0
check() { # $1=case $2=expected-rc $3=actual-line
  case "$3" in
    *"exit=$2") echo "PASS $1: $3" ;;
    *) echo "FAIL $1: expected exit=$2, got: $3"; fail=1 ;;
  esac
}
summary=""
scan grep -rnI 'userInterfaceIdiom' src/; hits=$scan_out; hits_rc=$scan_rc
scan grep -rlI 'NavigationSplitView' src/; ctl=$scan_out; ctl_rc=$scan_rc
absence_leg t-clean "hits" "$hits" "$hits_rc" "control" "$ctl" "$ctl_rc" > out.txt; check clean 0 "$(head -1 out.txt)"

printf 'if traitCollection.userInterfaceIdiom == .pad {}\n' > src/ok/Hit.swift
scan grep -rnI 'userInterfaceIdiom' src/; hits=$scan_out; hits_rc=$scan_rc
absence_leg t-hit "hits" "$hits" "$hits_rc" "control" "$ctl" "$ctl_rc" > out.txt; check hit 1 "$(head -1 out.txt)"
rm src/ok/Hit.swift

scan grep -rnI 'userInterfaceIdiom' src/; hits=$scan_out; hits_rc=$scan_rc
absence_leg t-noctl "hits" "$hits" "$hits_rc" "control" "" 1 > out.txt; check missing-control 1 "$(head -1 out.txt)"

if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP scan-error: running as root, an unreadable directory cannot be induced"
else
  mkdir src/locked; printf 'x\n' > src/locked/a.swift; chmod 000 src/locked
  scan grep -rnI 'userInterfaceIdiom' src/; hits=$scan_out; hits_rc=$scan_rc
  absence_leg t-err "hits" "$hits" "$hits_rc" "control" "$ctl" "$ctl_rc" > out.txt; check scan-error 2 "$(head -1 out.txt)"
  chmod 755 src/locked
fi
case "$summary" in *"t-clean=0"*"t-hit=1"*"t-noctl=1"*) echo "PASS summary: $summary" ;; *) echo "FAIL summary: $summary"; fail=1 ;; esac
[ "$fail" -eq 0 ] && echo "gate-lib-test: ALL PASS" || echo "gate-lib-test: FAILURES"
exit "$fail"
