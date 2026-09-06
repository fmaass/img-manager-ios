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

# THE MANIFEST LINE PROTOCOL (IMGMGR-408). Both halves emit one LINE per tracked file:
#
#     <mode> SP <blob sha> SP <escaped path>
#
# and the caller compares the two sorted lists byte for byte. Three properties make that faithful
# for any path git can track, which the previous `awk '{print $2, $4}'` / newline-joined walk was
# not (found by the Codex round-3 review of IMGMGR-398/-399; the rsync SELECTION already survived
# these paths, only the manifest did not):
#
#   * NUL end to end on the way IN — `git ls-files -s -z` on this side, `find -print0` and
#     `xargs -0` on the mirror side. Nothing is ever split on whitespace, so a path holding a
#     SPACE is carried whole, and `-z` also stops `git ls-files` from C-QUOTING an exotic name
#     into something the other half would never produce.
#   * an injective escape on the way OUT: `\` becomes `\\` and a NEWLINE becomes `\n`. The
#     records have to be lines — a NUL cannot survive the command substitution the comparison
#     runs through, and `sort` is line-oriented — so the one byte that would break the line
#     protocol is the one that gets escaped, and the escape of the escape keeps it reversible:
#     two different paths cannot render as the same record. The path is everything after the
#     second space and the two fields before it are fixed-width, so spaces need no escape.
#   * the MODE is compared, not just the content. `find -type f` used to skip symlinks
#     altogether; both halves now record a tracked symlink the way `git ls-files -s` does —
#     mode 120000, blob = the hash of the LINK TARGET STRING, never of what it points at — and
#     carrying 100644/100755 alongside means a symlink swapped for a regular file holding the
#     same bytes, or an executable bit lost in transit, is a red manifest leg instead of an
#     invisible difference.
#
# Both halves sort under LC_ALL=C so the two machines' locales cannot order the same records
# differently; bin/mac-gate.sh re-sorts the mirror's reply the same way.

# gate_local_manifest — the manifest of every file git tracks, sorted. Run in the checkout; the
# caller has already refused a dirty tree, so the index is HEAD. `git ls-files -s -z` emits
# "<mode> <object> <stage>\t<path>\0"; the split is by parameter expansion, so no subprocess is
# forked per file.
gate_local_manifest() {
  local tmp rc rec meta path mode rest blob esc
  tmp="$(mktemp)" || return 1
  # A failing `git ls-files` must fail the manifest rather than return a short one that would
  # compare as a missing-files diff nobody can read (same reasoning as gate_mirror_include_list).
  git ls-files -s -z > "$tmp"
  rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return "$rc"; fi
  while IFS= read -r -d '' rec; do
    meta="${rec%%$'\t'*}"
    path="${rec#*$'\t'}"
    mode="${meta%% *}"; rest="${meta#* }"; blob="${rest%% *}"
    esc="${path//\\/\\\\}"; esc="${esc//$'\n'/\\n}"
    printf '%s %s %s\n' "$mode" "$blob" "$esc"
  done < "$tmp" | LC_ALL=C sort
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# gate_mirror_manifest [DIR] — the same shape over a mirrored tree that has no .git at all:
# `git hash-object` is a plain blob hash and needs no repository, so the two halves are
# comparable. Prune, don't filter: `-not -path` still stat-walks every file under
# .build/DerivedData (129 s over 9k files, 2026-08-30), and one batched hash-object spawn
# replaces one fork per file — which is why the regular files are hashed through a single
# `xargs -0` over a NUL list and their modes and display paths are built in a fork-free bash
# loop beside it, in the same order, for `paste` to join. Symlinks take one fork each: they are
# hashed from their target string, and a tree has few of them (this one has none today).
# The prune list is exactly the nine names gate_mirror_filters excludes, `signing.local.yml` and
# `.phase-ledger.md` included: pruning a name covers the file AND a directory of that name, so
# nothing can be smuggled past the walk under a file-by-contract name (round-4 review, A2).
# Those two ARE files by contract — a directory of either name is outside this contract and is
# pruned rather than described.
gate_mirror_manifest() {
  local dir="${1:-.}" tmp rc
  tmp="$(mktemp -d)" || return 1
  (
    cd "$dir" || exit 1
    find . \( -name .git -o -name .build -o -name DerivedData -o -name '*.xcodeproj' -o -name '*.xcresult' -o -name .gate-artifacts -o -name .tools -o -name signing.local.yml -o -name .phase-ledger.md \) -prune \
      -o \( -type f -o -type l \) -print0 > "$tmp/raw" || exit 1
    : > "$tmp/reg"; : > "$tmp/modes"; : > "$tmp/paths"; : > "$tmp/links"
    while IFS= read -r -d '' p; do
      d="${p#./}"
      esc="${d//\\/\\\\}"; esc="${esc//$'\n'/\\n}"
      if [ -L "$p" ]; then
        # The blob git records for a symlink is the hash of its TARGET STRING. `readlink -n`
        # keeps the exact bytes (no trailing newline); the path always begins `./`, so it can
        # never be read as an option.
        printf '120000 %s %s\n' "$(readlink -n "$p" | git hash-object --stdin)" "$esc" >> "$tmp/links" || exit 1
      else
        printf '%s\0' "$p" >> "$tmp/reg"
        if [ -x "$p" ]; then printf '100755\n' >> "$tmp/modes"; else printf '100644\n' >> "$tmp/modes"; fi
        printf '%s\n' "$esc" >> "$tmp/paths"
      fi
    done < "$tmp/raw"
    # GNU xargs runs the command once even on empty input (BSD's does not); an empty tree must
    # not become `git hash-object --` with no operands.
    if [ -s "$tmp/reg" ]; then
      xargs -0 git hash-object -- < "$tmp/reg" > "$tmp/h" || exit 1
    else
      : > "$tmp/h"
    fi
    paste -d' ' "$tmp/modes" "$tmp/h" "$tmp/paths" > "$tmp/out" || exit 1
    cat "$tmp/links" >> "$tmp/out" || exit 1
  )
  rc=$?
  [ "$rc" -ne 0 ] || LC_ALL=C sort "$tmp/out"
  rm -rf "$tmp"
  return "$rc"
}

# --- The leg registry (IMGMGR-410) -------------------------------------------------------
#
# WHY: a change that touches only these scripts used to need a FULL gate — xcodegen, build,
# widget-embed and two UI-test destinations, ~50 minutes — to prove a mirror or manifest fix.
# Four such runs were spent on the IMGMGR-398/-399 branch in one day (2026-09-06). A named
# subset lets a script-only change be gated in minutes.
#
# The registry lives HERE, beside the mirror contract, for the same reason that does: the
# controller half (bin/mac-gate.sh, which validates the selection and prints it) and the remote
# half (the build script on the Mac, which decides leg by leg what to run) both source this file
# out of the same mirror, so the two cannot disagree about what a leg name means.
#
# CANONICAL ORDER — the order the legs really run in. gate_legs_resolve always prints in it, so
# a resolved list is comparable to GATE_LEGS_ALL by plain string equality (that is what tells a
# full gate from a subset) and a `legs=` field reads the same for the same selection.
#
# `mirror` names the rsync mirror step; the step RECORDS itself as the `rsync` leg, the name
# every gate summary in this estate's evidence already carries. One name for the selection, the
# other for the record, and both are documented rather than reconciled — renaming the recorded
# leg would invalidate the citations.
GATE_LEGS_ALL='mirror manifest api-nullable-tests xcodegen build widget-embed test-iphone test-ipad idiom-grep no-c-shortcut-grep ui-orientation-base-grep lint pins'

# MANDATORY legs are in every selection whether they are named or not. Only `mirror` is: it is
# not really a check, it is the transport — nothing can run on the Mac that was not copied there
# first. `manifest` is deliberately NOT mandatory even though it is what proves the mirror equals
# this HEAD: the ticket's own example names it, so it stays selectable, and a selection that
# drops it produces leg results whose provenance is not proven. The `legs=SUBSET(…)` field on the
# summary line is what keeps that from being read as a full gate.
GATE_LEGS_MANDATORY='mirror'

# PREREQUISITES, as `<leg>:<leg it needs in the same run>`. These are not conveniences to be
# auto-added: a selection that names `build` without `xcodegen` is refused, because silently
# adding xcodegen would turn a 3-minute subset into a 20-minute one the caller did not ask for,
# and silently DROPPING build would report a green leg that never ran. Refusing says which.
GATE_LEGS_REQUIRES='build:xcodegen widget-embed:build test-iphone:xcodegen test-ipad:xcodegen pins:xcodegen'

# gate_legs_resolve [SELECTION] — print the effective leg list, space-separated, in canonical
# order, for a comma-separated SELECTION. An empty or absent SELECTION is a FULL gate and prints
# GATE_LEGS_ALL. Duplicates collapse and order in the SELECTION is irrelevant.
#
# Returns 2 and prints NOTHING on stdout (the reason goes to stderr) for an empty leg name, an
# unknown one, or a leg whose prerequisite is not also selected — so a caller may use the output
# only after checking the status, and an unknown name is refused before anything runs.
# bash 3.2: no arrays, no mapfile; the split is by parameter expansion, not IFS.
gate_legs_resolve() {
  local sel_in="${1:-}" rest name leg pair req sel="" out=""
  if [ -z "$sel_in" ]; then printf '%s\n' "$GATE_LEGS_ALL"; return 0; fi
  case ",$sel_in," in
    *,,*) printf 'gate-lib: empty leg name in the selection %s\n' "'$sel_in'" >&2; return 2 ;;
  esac
  rest="$sel_in"
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*) name="${rest%%,*}"; rest="${rest#*,}" ;;
      *)   name="$rest"; rest="" ;;
    esac
    # A token carrying WHITESPACE is refused before membership is even asked (round-1 review,
    # finding 2). The registry is a space-joined string, so `case " $GATE_LEGS_ALL " in *" $tok "*`
    # is a substring test: the single token `xcodegen build` matches the two adjacent entries and
    # was accepted as one known leg. Legs are separated by COMMAS; a space inside a token is a
    # malformed list, not a leg name, and saying so is better than resolving it by accident.
    case "$name" in
      *[[:space:]]*)
        printf 'gate-lib: leg name %s contains whitespace — legs are separated by commas, not spaces\n' \
          "'$name'" >&2; return 2 ;;
    esac
    case " $GATE_LEGS_ALL " in
      *" $name "*) ;;
      *) printf 'gate-lib: unknown leg %s (known legs: %s)\n' "'$name'" "$GATE_LEGS_ALL" >&2; return 2 ;;
    esac
    case " $sel " in *" $name "*) ;; *) sel="$sel $name" ;; esac
  done
  for leg in $GATE_LEGS_MANDATORY; do
    case " $sel " in *" $leg "*) ;; *) sel="$sel $leg" ;; esac
  done
  for pair in $GATE_LEGS_REQUIRES; do
    name="${pair%%:*}"; req="${pair#*:}"
    case " $sel " in *" $name "*) ;; *) continue ;; esac
    case " $sel " in
      *" $req "*) ;;
      *) printf 'gate-lib: leg %s needs %s in the same run — add it, or drop %s\n' \
           "'$name'" "'$req'" "'$name'" >&2; return 2 ;;
    esac
  done
  for leg in $GATE_LEGS_ALL; do
    case " $sel " in *" $leg "*) out="$out $leg" ;; esac
  done
  printf '%s\n' "${out# }"
}

# gate_legs_field RESOLVED — the one field that tells a full gate from a subset, for the summary
# line and for --list-legs. A subset says so in capitals AND lists exactly what ran: the merged-
# main gate evidence in this estate cites the full leg list, and a subset run must never be
# mistakable for one.
gate_legs_field() {
  if [ "$1" = "$GATE_LEGS_ALL" ]; then
    printf 'legs=full\n'
  else
    printf 'legs=SUBSET(%s) — NOT a full gate\n' "$(printf '%s' "$1" | tr ' ' ',')"
  fi
}

# gate_legs_field_refused REASON — the same field for a run that never started because its leg
# selection would not resolve. bin/mac-gate.sh's die_refuse prints this shape for every refusal,
# so bin/gate-queue.sh has a SUMMARY line to copy and a reader can tell a refusal from a crash.
gate_legs_field_refused() {
  printf 'legs=REFUSED(%s) — NOT a full gate\n' "$1"
}

# gate_summary_line LEGS_FIELD STEP_SUMMARY EXIT_CODE — the ONE definition of the gate's summary
# line. bin/mac-gate.sh's summary_and_exit prints exactly this and nothing else, so the marker
# that tells a subset from a full gate has one place to live and one place to be tested; the
# line is what bin/gate-queue.sh greps out of a run log into its summary file.
gate_summary_line() {
  printf 'mac-gate SUMMARY: %s |%s | exit=%s\n' "$1" "$2" "$3"
}

# gate_leg_wanted NAME RESOLVED — 0 when NAME is in the resolved list. Used by the remote build
# script leg by leg.
gate_leg_wanted() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
