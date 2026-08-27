#!/usr/bin/env bash
# check-nullable-survival.sh — the exact checker used to produce greps.txt.
#
# Usage: check-nullable-survival.sh <Types.swift-path> <failing-field-list.txt-path>
#
# For each `<Schema>/<property>` line in the target list, checks whether the generated
# file contains that property's exact provenance comment
# ("- Remark: Generated from `#/components/schemas/<Schema>/<property>`."). Prints one
# SURVIVED/DROPPED line per target and a final SURVIVED: n/N summary. Exit 0 always (this
# is a report, not a gate condition by itself — the gate's own pass/fail bar is "0 dropped
# in the bridged run", asserted by the caller, e.g. greps.txt's own recorded exit checks).
set -euo pipefail
types_file="${1:?usage: check-nullable-survival.sh <Types.swift> <failing-field-list.txt>}"
targets_file="${2:?usage: check-nullable-survival.sh <Types.swift> <failing-field-list.txt>}"
[ -f "$types_file" ] || { echo "no such file: $types_file" >&2; exit 2; }
[ -f "$targets_file" ] || { echo "no such file: $targets_file" >&2; exit 2; }

survived=0
total=0
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  total=$((total + 1))
  marker="#/components/schemas/${line}\`"
  if grep -qF -- "$marker" "$types_file"; then
    echo "SURVIVED $line"
    survived=$((survived + 1))
  else
    echo "DROPPED  $line"
  fi
done < "$targets_file"

echo "SURVIVED: $survived/$total"
