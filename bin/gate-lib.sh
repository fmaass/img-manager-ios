#!/usr/bin/env bash
# gate-lib.sh — helpers shared by the mac-gate absence-grep legs (IMGMGR-346).
#
# Sourced by bin/mac-gate.sh on this machine, by the remote build and manifest scripts on the
# Mac (the mirror carries this file) and by bin/gate-lib-test.sh locally. bash 3.2 compatible:
# no arrays, no mapfile.
#
# It also owns the MIRROR CONTRACT (IMGMGR-399): the rsync filters that decide what reaches the
# Mac, and both halves of the content manifest that asserts the mirror equals this checkout's
# tracked files. All three live here precisely because two of them run on the other side of an
# ssh call — a file-selection rule that drifts between the local and the remote half turns into
# a MANIFEST FAIL nobody can read.
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

# --- The mirror contract (IMGMGR-399) ----------------------------------------------------
#
# gate_mirror_include_list FILE — write, NUL-separated, one root-anchored `/path` per file that
# git TRACKS. Run from the checkout root: this is the mirror's file selection, and it is
# literally `git ls-files` — the same source gate_local_manifest hashes, so the mirror's contents
# and the manifest it is compared against cannot drift apart.
# Entries are rsync PATTERNS, not plain paths, so a name carrying a wildcard character has to be
# escaped or it matches the wrong thing — a tracked `icon[1].png` is a character class that does
# not match itself and does match `icon1.png` (round-4 review, R3). `man rsync` (3.4.1, INCLUDE/
# EXCLUDE PATTERN RULES): "Rsync chooses between doing a simple string match and wildcard matching
# by checking if the pattern contains one of these three wildcard characters: '*', '?', and '['"
# — so a name without any of the three is left exactly as it is, and only a name that contains one
# becomes a wildcard pattern that needs escaping. The same section: "a backslash can be used to
# escape a wildcard character, but it is only interpreted as an escape character if at least one
# wildcard character is present in the match pattern. For instance, the pattern "foo\bar" matches
# that single backslash literally, while the pattern "foo\bar*" would need to be changed to
# "foo\\bar*"" — which is why backslashes are doubled ONLY in the escaped branch, and why
# escaping a name that holds none of the three would BREAK it. `]` needs no escape: with every `[`
# escaped there is no character class for it to close.
gate_mirror_include_list() {
  local f esc tmp rc
  tmp="$(mktemp)" || return 1
  # `git ls-files` failing (not a repository, a broken index) must fail the list rather than
  # write a short one that would silently mirror a subset (round-4 review, A3).
  git ls-files -z > "$tmp"
  rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return "$rc"; fi
  : > "$1" || { rm -f "$tmp"; return 1; }
  while IFS= read -r -d '' f; do
    esc="$f"
    case "$f" in
      *'*'*|*'?'*|*'['*)
        esc="${esc//\\/\\\\}"
        esc="${esc//\*/\\*}"
        esc="${esc//\?/\\?}"
        esc="${esc//\[/\\[}"
        ;;
    esac
    printf '/%s\0' "$esc"
  done < "$tmp" >> "$1"
  rm -f "$tmp"
}

# gate_mirror_filters LISTFILE — print, one argument per line, the rsync arguments that decide
# what the Mac mirror carries, in the order rsync applies them. `man rsync` (3.4.1, FILTER
# RULES): "The order of the rules is important because the first rule that matches is the one
# that takes effect.  Thus, if an early rule excludes a file, no include rule that comes after it
# can have any effect." So, in order:
#
#   1. the fixed exclude list — first, and deliberately two-sided: an exclude is "both a hide and
#      a protect", and that receiver-side protection is what stops --delete from wiping the
#      caches that live only on the Mac (DerivedData, .build, .gate-artifacts, .tools). Nothing
#      git tracks may match these; if something ever does, it will be missing from the mirror and
#      the manifest leg names it (0 such paths in this repo today).
#   2. `--include-from=LISTFILE` (with `--from0`): every tracked path, root-anchored. TRACKED
#      FILES WIN over everything below (round-3 review, B4). A force-added file under an ignored
#      directory and a `!negation` are both simply in `git ls-files`, so no ignore-pattern
#      matcher is re-implemented here and none can disagree with the manifest.
#   3. `--include='*/'`, so every directory is traversed: "the include/exclude rules are applied
#      to every file and directory that the sender is recursing into … if you want a particular
#      deep file to be included, you have to make sure that none of the directories that must be
#      traversed on the way down to that file are excluded". It comes after 1 and 2, so the
#      caches stay pruned and protected and tracked files are already decided. `*/` is an
#      include, and an include is "both a show and a risk", i.e. it does NOT protect directories
#      on the receiver — so a directory that only ever held ignored files is deleted there rather
#      than lingering. `--prune-empty-dirs` keeps the transfer from re-creating such shells: git
#      cannot track an empty directory, so a directory with no tracked file has no business in a
#      mirror of the tracked tree.
#   4. a SENDER-ONLY catch-all, `--filter='-s *'`: nothing else is transferred, and because the
#      rule is sender-only it protects nothing on the receiver — so --delete sweeps the
#      gitignored leftovers an earlier run left in the mirror, which is what kept the manifest
#      leg red on 2026-09-05 (IMGMGR-399). `man rsync` (FILTER RULE MODIFIERS): "An s is used to
#      indicate that the rule applies to the sending side. … The default is for a rule to affect
#      both sides", and of the receiving side: "When a rule affects the receiving side, it
#      prevents files from being deleted."
#
# The repo's .gitignore is deliberately NOT merged in any more (it was, in round 2): behind an
# explicit tracked include list and a catch-all it can only disagree with `git ls-files`, and
# disagreeing with `git ls-files` is the one thing this contract must never do. An untracked file
# that is not ignored no longer reaches the mirror either — bin/gate-queue.sh and bin/mac-gate.sh
# refuse such a tree before the gate starts (exit 97 / REFUSED), so it is a refusal, not a
# manifest mismatch.
gate_mirror_filters() {
  printf '%s\n' \
    '--from0' \
    '--exclude=.git' \
    '--exclude=signing.local.yml' \
    '--exclude=.build' \
    '--exclude=DerivedData' \
    '--exclude=*.xcodeproj' \
    '--exclude=*.xcresult' \
    '--exclude=.gate-artifacts' \
    '--exclude=.tools' \
    '--exclude=.phase-ledger.md' \
    "--include-from=$1" \
    '--include=*/' \
    '--prune-empty-dirs' \
    '--filter=-s *'
}

# gate_local_manifest — "<blob sha> <path>" for every file git tracks, sorted. Run in the
# checkout; the caller has already refused a dirty tree, so the index is HEAD.
gate_local_manifest() {
  git ls-files -s | awk '{print $2, $4}' | sort
}

# gate_mirror_manifest [DIR] — the same shape over a mirrored tree that has no .git at all:
# `git hash-object` is a plain blob hash and needs no repository, so the two halves are
# comparable. Prune, don't filter: `-not -path` still stat-walks every file under
# .build/DerivedData (129 s over 9k files, 2026-08-30), and one batched hash-object spawn
# replaces one fork per file. The prune list is exactly the nine names gate_mirror_filters
# excludes, `signing.local.yml` and `.phase-ledger.md` included: pruning a name covers the file
# AND a directory of that name, so nothing can be smuggled past the walk under a file-by-contract
# name (round-4 review, A2). Those two ARE files by contract — a directory of either name is
# outside this contract and is pruned rather than described.
#
# KNOWN LIMITATION (pre-dates this branch; the coordinator is ticketing it): both halves split on
# whitespace — gate_local_manifest takes `awk '{print $2, $4}'` and this walk pastes a
# newline-separated path list — so a tracked path containing a SPACE or a NEWLINE is not compared
# faithfully, and `find -type f` skips symlinks that `git ls-files` reports. The repo has none of
# the three today; do not read a green manifest leg as evidence about such paths.
gate_mirror_manifest() {
  local dir="${1:-.}" tmp rc
  tmp="$(mktemp -d)" || return 1
  (
    cd "$dir" || exit 1
    find . \( -name .git -o -name .build -o -name DerivedData -o -name '*.xcodeproj' -o -name '*.xcresult' -o -name .gate-artifacts -o -name .tools -o -name signing.local.yml -o -name .phase-ledger.md \) -prune \
      -o -type f -print \
      | sed 's|^\./||' | sort > "$tmp/f"
    tr '\n' '\0' < "$tmp/f" | xargs -0 git hash-object > "$tmp/h"
  )
  rc=$?
  [ "$rc" -ne 0 ] || paste -d' ' "$tmp/h" "$tmp/f" | sort
  rm -rf "$tmp"
  return "$rc"
}
