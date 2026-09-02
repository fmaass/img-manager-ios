#!/usr/bin/env bash
# gate-lib.sh — helpers shared by the mac-gate absence-grep legs (IMGMGR-346).
#
# Sourced by the remote build script on the Mac (the mirror carries this file) and by
# bin/gate-lib-test.sh locally. bash 3.2 compatible: no arrays, no mapfile.
#
# The problem it fixes: every absence leg used to run its scan as `"$(grep … || true)"`,
# which discards grep's own exit status. grep exits 1 for "no match" (the expected path)
# but 2 for a scan ERROR — an unreadable directory, a bad pattern — and with `|| true` a
# partial traversal produced an empty hit list plus a found control, so the leg recorded
# `=0` (green) on a scan that never finished. A zero-hit result is only evidence once the
# scan is known to have completed.

# scan CMD ARGS… — run one grep invocation, keep its stdout in $scan_out and its exit
# status in $scan_rc (0 = matched, 1 = no match, >=2 = the scan itself failed). Its stderr
# is appended to .gate-artifacts/scan-errors.log so a red leg can be diagnosed.
scan() {
  scan_out="$("$@" 2>>.gate-artifacts/scan-errors.log)"
  scan_rc=$?
}

# absence_leg NAME HITS_LABEL HITS HITS_RC CONTROL_LABEL CONTROL CONTROL_RC
# Records leg NAME: 0 when the scan completed with no hits AND the positive control was
# found; 1 when a hit exists or the control is missing; 2 when either grep reported a scan
# error. Writes the evidence file, appends to $summary, prints the leg line the remote
# summary parser expects, and tails the evidence on any non-zero result.
absence_leg() {
  local name="$1" hits_label="$2" hits="$3" hits_rc="$4" control_label="$5" control="$6" control_rc="$7" rc
  {
    echo "$hits_label (expect 0):"
    echo "$hits"
    echo "positive control — $control_label (expect >=1, proves the grep runs over real content):"
    echo "$control"
    echo "grep exit codes: hits=$hits_rc control=$control_rc (0 matched, 1 none, >=2 scan error)"
  } > ".gate-artifacts/$name.log"
  if [ "$hits_rc" -ge 2 ] || [ "$control_rc" -ge 2 ]; then
    rc=2
  elif [ "$hits_rc" -eq 1 ] && [ "$control_rc" -eq 0 ]; then
    rc=0
  else
    rc=1
  fi
  echo "$name exit=$rc"
  summary="$summary $name=$rc"
  [ "$rc" -eq 0 ] || tail -20 ".gate-artifacts/$name.log"
  return 0
}
