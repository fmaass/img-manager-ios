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
GATE_LEGS_ALL='mirror manifest api-nullable-tests xcodegen build widget-embed test-iphone test-ipad idiom-grep no-c-shortcut-grep ui-orientation-base-grep no-custom-glass-grep lint pins'

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

# gate_export_screenshots LEG BUNDLE — WP28 P1 (IMGMGR-448): export every attachment of a UI
# leg's result bundle into .gate-artifacts/screenshots/LEG/, which the controller's existing
# copy-back brings home, so a reviewer on jupiter can see what the UI tests rendered. The bundle
# itself lives under DerivedData — never in .gate-artifacts (it would ride the copy-back) — and
# stays out of the mirror (`--exclude=*.xcresult`, gate_mirror_filters).
#
# Prints ONE line, `screenshots LEG exit=RC files=N`, and returns RC: 3 when there is no bundle
# (the test step never produced one), 4 when the output directory cannot be made, otherwise the
# export tool's own exit code — a failed export is a red result, never a swallowed one. The
# directory is emptied first, so a count never includes a previous run's files. GATE_XCRESULTTOOL
# replaces the tool (bin/gate-lib-test.sh); it is word-split on purpose.
gate_export_screenshots() {
  _ss_dir=".gate-artifacts/screenshots/$1"
  _ss_log=".gate-artifacts/screenshots-$1.log"
  if ! { rm -rf "$_ss_dir" && mkdir -p "$_ss_dir"; }; then
    echo "screenshots $1 exit=4 files=0 (cannot create $_ss_dir)"
    return 4
  fi
  if [ ! -d "$2" ]; then
    echo "no result bundle at $2" > "$_ss_log"
    echo "screenshots $1 exit=3 files=0 (no result bundle at $2)"
    return 3
  fi
  ${GATE_XCRESULTTOOL:-xcrun xcresulttool} export attachments \
    --path "$2" --output-path "$_ss_dir" > "$_ss_log" 2>&1
  _ss_rc=$?
  _ss_n="$(find "$_ss_dir" -type f ! -name manifest.json | wc -l | tr -d ' ')"
  echo "screenshots $1 exit=$_ss_rc files=$_ss_n"
  return "$_ss_rc"
}

# --- WP28 P4 (IMGMGR-451): the no-custom-glass leg ------------------------------------------
#
# ADR-N1: glass comes from system components only. The leg fails on any direct glass API call in
# a file the APP or WIDGET target compiles, and on the one Info.plist key that would opt the app
# out of the iOS 26 design. What the targets compile is read from project.yml — never a
# hand-kept list beside it — so a new source path is scanned the moment a target names it.

# The custom-glass spellings. `glassEffect` with any suffix (`glassEffectID`, `…Union`,
# `…Transition`) followed by optional whitespace and the call's parenthesis — a space or a tab
# before `(` still compiles, so it must still match. The two button styles are matched both as
# the `.glass…` member and as the explicit type.
GATE_CUSTOM_GLASS_PATTERN='glassEffect[[:alnum:]]*[[:space:]]*\(|GlassEffectContainer|buttonStyle[[:space:]]*\([[:space:]]*\.glass|Glass(Prominent)?ButtonStyle'

# gate_glass_scan PATTERN PATH... — the source half of the leg, MULTI-LINE: each file is read
# whole (perl slurp), so `[[:space:]]*` crosses newlines and a call split before its `(` —
# `.glassEffect` on one line, `(.regular)` on the next — is still a hit. Walks each directory
# like `grep -rI` (skips `.build` and binary files) and prints `file:line:match` per hit.
# Exit: 0 a hit, 1 none, 2 a path that does not exist, a directory it cannot traverse, a file it
# cannot open, read or close, any warning raised while walking, or a bad pattern — the grep contract `scan`/`absence_leg` read, so a scan error is a red leg.
gate_glass_scan() {
  ${GATE_PERL:-perl} -e '
    use strict; use warnings; use File::Find;
    my $re = shift @ARGV;
    my $rx = eval { qr/$re/ } or do { print STDERR "gate-lib: bad pattern: $@"; exit 2 };
    my ($hit, $err, @files) = (0, 0);
    # Any warning (File::Find cannot open or stat a directory, an I/O warning) is a scan error.
    local $SIG{__WARN__} = sub { print STDERR "gate-lib: $_[0]"; $err = 1 };
    for my $p (@ARGV) {
      if (-f $p) { push @files, $p; next }
      unless (-d $p) { print STDERR "gate-lib: no such path $p\n"; $err = 1; next }
      find({ no_chdir => 1, wanted => sub {
        if (-d $_) {
          if ($_ ne $p && m{(^|/)\.build$}) { $File::Find::prune = 1; return }
          unless (-r $_ && -x $_) { print STDERR "gate-lib: cannot read $_\n"; $err = 1 }
          return;
        }
        push @files, $_ if -f $_;
      } }, $p);
    }
    for my $f (sort @files) {
      next if -s $f && -B $f;
      open(my $fh, "<:raw", $f) or do { print STDERR "gate-lib: cannot read $f: $!\n"; $err = 1; next };
      my $size = (-s $fh) || 0;
      my $text = do { local $/; <$fh> };
      unless (defined $text) { print STDERR "gate-lib: cannot read $f: $!\n"; $err = 1; close $fh; next }
      # A short read (an I/O error part-way) must not pass as a smaller, clean file.
      unless (length($text) == $size) {
        print STDERR "gate-lib: short read of $f: " . length($text) . " of $size bytes\n";
        $err = 1; close $fh; next;
      }
      unless (close $fh) { print STDERR "gate-lib: cannot close $f: $!\n"; $err = 1; next }
      while ($text =~ /$rx/g) {
        my $line = 1 + (substr($text, 0, $-[0]) =~ tr/\n//);
        (my $m = substr($text, $-[0], $+[0] - $-[0])) =~ s/\s+/ /g;
        print "$f:$line:$m\n";
        $hit = 1;
      }
    }
    exit 2 if $err;
    exit($hit ? 0 : 1);
  ' "$@"
}

# gate_compiled_source_paths YML — print, one per line and without duplicates, every `sources:`
# path of each target whose `type:` is `application` or `app-extension`, then every local
# package path (a local package is compiled into the app). Returns 2, printing nothing, when YML
# is unreadable, awk fails, or not one path is found: an empty list would scan nothing and pass.
gate_compiled_source_paths() {
  [ -r "$1" ] || { echo "gate-lib: cannot read $1" >&2; return 2; }
  _gcsp_out="$(awk '
    function clean(v) { sub(/[ \t]+#.*$/, "", v); gsub(/"/, "", v); sub(/[ \t]+$/, "", v); return v }
    function emit(v) { if (v != "" && !(v in seen)) { seen[v] = 1; print v } }
    function flush(  i) {
      if (ttype == "application" || ttype == "app-extension") for (i = 1; i <= n; i++) emit(buf[i])
      n = 0; ttype = ""; sec = ""
    }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    /^[^ ]/ { flush(); top = $1; next }
    top == "packages:" && /^    path:/ { v = $0; sub(/^    path:[ \t]*/, "", v); emit(clean(v)); next }
    top != "targets:" { next }
    /^  [^ ]/ { flush(); next }
    /^    [^ -]/ { sec = $1; if ($1 == "type:") ttype = clean($2); next }
    sec == "sources:" && /^      - / {
      v = $0; sub(/^      - [ \t]*/, "", v); sub(/^path:[ \t]*/, "", v); buf[++n] = clean(v); next
    }
    END { flush() }
  ' "$1")" || { echo "gate-lib: awk failed on $1" >&2; return 2; }
  [ -n "$_gcsp_out" ] || { echo "gate-lib: no compiled source path found in $1" >&2; return 2; }
  printf '%s\n' "$_gcsp_out"
}

# gate_design_config_files — print the files the UIDesignRequiresCompatibility scan reads: every
# root-level *.yml (project.yml and the specs it includes) and every *.plist in the tree outside
# the caches (the generated Support/*.plist included once xcodegen has run). Returns find's own
# status, so a traversal error is not read as "no plist".
gate_design_config_files() {
  for _gdcf in *.yml; do [ -f "$_gdcf" ] && printf '%s\n' "$_gdcf"; done
  find . \( -name .git -o -name DerivedData -o -name .build -o -name .gate-artifacts \
    -o -name '*.xcodeproj' -o -name '*.xcresult' -o -name .tools \) -prune \
    -o -type f -name '*.plist' -print
}

# The two ways an absence leg combines two scans. Hits: any scan error is 2, else any match is 0.
# Controls: any scan error is 2, else BOTH must have matched for 0.
gate_rc_any_hit() {
  if [ "$1" -ge 2 ] || [ "$2" -ge 2 ]; then echo 2
  elif [ "$1" -eq 0 ] || [ "$2" -eq 0 ]; then echo 0
  else echo 1; fi
}
gate_rc_all_found() {
  if [ "$1" -ge 2 ] || [ "$2" -ge 2 ]; then echo 2
  elif [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; then echo 0
  else echo 1; fi
}

# gate_no_custom_glass_leg — the `no-custom-glass-grep` leg, run from the checkout root, in the
# scan/absence_leg shape of every other absence leg: grep's own exit status is kept (a scan error
# is rc 2, a red leg), and a positive control — a SwiftUI import in the scanned sources AND the
# deploymentTarget line of project.yml — proves both halves read real content. There is no
# exclusion list: a comment or string that spells a glass call is a hit too.
gate_no_custom_glass_leg() {
  _ncg_paths="$(gate_compiled_source_paths project.yml 2>>.gate-artifacts/scan-errors.log)"
  _ncg_paths_rc=$?
  if [ "$_ncg_paths_rc" -ne 0 ]; then
    absence_leg no-custom-glass-grep "custom-glass hits (no compiled source path read from project.yml)" \
      "" 2 "compiled source paths from project.yml" "" 2
    return 0
  fi
  _ncg_cfg="$(gate_design_config_files 2>>.gate-artifacts/scan-errors.log)"
  _ncg_cfg_rc=$?
  _ncg_ifs=$IFS
  IFS='
'
  scan gate_glass_scan "$GATE_CUSTOM_GLASS_PATTERN" $_ncg_paths
  _ncg_src=$scan_out; _ncg_src_rc=$scan_rc
  scan grep -rlI --include='*.swift' 'import SwiftUI' $_ncg_paths
  _ncg_ctl=$scan_out; _ncg_ctl_rc=$scan_rc
  scan grep -nIH 'UIDesignRequiresCompatibility' $_ncg_cfg
  _ncg_opt=$scan_out; _ncg_opt_rc=$scan_rc
  IFS=$_ncg_ifs
  [ "$_ncg_cfg_rc" -eq 0 ] || _ncg_opt_rc=2
  scan grep -nH 'deploymentTarget' project.yml
  _ncg_hits_rc="$(gate_rc_any_hit "$_ncg_src_rc" "$_ncg_opt_rc")"
  _ncg_ctl_all_rc="$(gate_rc_all_found "$_ncg_ctl_rc" "$scan_rc")"
  absence_leg no-custom-glass-grep \
    "custom-glass calls in the compiled sources ($(printf '%s' "$_ncg_paths" | tr '\n' ' ')) and UIDesignRequiresCompatibility in the yml/plists" \
    "$_ncg_src$_ncg_opt" "$_ncg_hits_rc" \
    "SwiftUI imports in the compiled sources, and project.yml's deploymentTarget" \
    "$_ncg_ctl
$scan_out" "$_ncg_ctl_all_rc"
}

# --- WP28 P4 (IMGMGR-451): the materials screenshot matrix under REAL accessibility settings ---
#
# The default mode's screenshots come from the UI leg itself (the suite is part of it). Each
# extra mode then sets the real simulator setting on THAT leg's own simulator — never another
# one, never `simctl … all` — and re-runs ONLY the materials suite without rebuilding. The suite
# reads the setting back in the app (`materialsSettingsProbe`) before every capture and captures
# nothing when it does not read back. GATE_XCRUN and GATE_XCODEBUILD replace the tools in
# bin/gate-lib-test.sh; they are word-split on purpose, like GATE_XCRESULTTOOL.
GATE_MATERIALS_SUITE='ImgManagerUITests/MaterialsScreenshotUITests'
GATE_MATERIALS_MODES='reduce-transparency increase-contrast'
GATE_MATERIALS_MANIFEST='Tests/ImgManagerUITests/MaterialsScreenshotManifest.txt'

# gate_materials_set UDID MODE on|off|notify — one setting on one simulator. `notify` is the
# plan's pivot for Reduce Transparency: the accessibility cache's own change notification.
gate_materials_set() {
  case "$2:$3" in
    # Two keys: the Settings switch is stored as EnhancedBackgroundContrastEnabled (what
    # UIAccessibility reads), ReduceTransparencyEnabled is the plan's name for it. Fold round 1:
    # the plan's key alone never read back on iOS 26.5 (gate on 832e6f1), so both are written.
    reduce-transparency:on)
      ${GATE_XCRUN:-xcrun} simctl spawn "$1" defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool true \
        && ${GATE_XCRUN:-xcrun} simctl spawn "$1" defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool true ;;
    reduce-transparency:off)
      ${GATE_XCRUN:-xcrun} simctl spawn "$1" defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool false \
        && ${GATE_XCRUN:-xcrun} simctl spawn "$1" defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool false \
        && gate_materials_set "$1" reduce-transparency notify ;;
    reduce-transparency:notify)
      ${GATE_XCRUN:-xcrun} simctl spawn "$1" notifyutil -p com.apple.accessibility.cache.reduce.transparency \
        && ${GATE_XCRUN:-xcrun} simctl spawn "$1" notifyutil -p com.apple.accessibility.cache.enhance.background.contrast ;;
    increase-contrast:on) ${GATE_XCRUN:-xcrun} simctl ui "$1" increase_contrast enabled ;;
    increase-contrast:off) ${GATE_XCRUN:-xcrun} simctl ui "$1" increase_contrast disabled ;;
    *) echo "gate-lib: unknown materials setting '$2:$3'" >&2; return 64 ;;
  esac
}

# gate_materials_reset UDID — both settings off on that one simulator; returns the first failure.
# Called after every mode AND from the UI legs' EXIT trap (bin/mac-gate.sh cleanup_sims), so a
# run that dies mid-mode does not leave the setting behind.
gate_materials_reset() {
  [ -n "$1" ] || return 0
  gate_materials_set "$1" reduce-transparency off; _gmr_a=$?
  gate_materials_set "$1" increase-contrast off; _gmr_b=$?
  [ "$_gmr_a" -eq 0 ] || return "$_gmr_a"
  return "$_gmr_b"
}

# gate_materials_mode_run LEG UDID MODE DERIVED — one extra mode on LEG's own simulator: boot
# status, set, run the materials suite alone (test-without-building, -only-testing), reset,
# export. When the app does not read Reduce Transparency back the suite prints a line
# `MATERIALS-UNRESOLVED dest=… mode=… run=…` and SKIPS its captures (plan Phase 4 fallback
# rule: an UNRESOLVED mode is not a red leg). Only a run that exited 0 with that line triggers
# the plan's one pivot — the cache notification, then ONE more run, a cold launch — so a retry
# never replaces a failed run: a non-zero run is final. Any other read-back mismatch is a red
# suite. Each run gets a fresh token (TEST_RUNNER_IMG_MATERIALS_RUN), recorded in
# `.gate-artifacts/materials-LEG-MODE.run`; the suite writes it into its marker, which is how the
# manifest check knows a marker came from THIS run. Prints `materials-LEG-MODE exit=RC (…)`,
# plus ` UNRESOLVED …` when the last run still did not read back, and returns RC: the first
# non-zero of set, run, reset and export, so a reset or export failure is never swallowed.
gate_materials_mode_run() {
  _gm_name="materials-$1-$3"
  _gm_log=".gate-artifacts/$_gm_name.log"
  _gm_bundle="$4/Results/$_gm_name.xcresult"
  _gm_runfile=".gate-artifacts/$_gm_name.run"
  : > "$_gm_log"
  rm -f "$_gm_runfile"
  ${GATE_XCRUN:-xcrun} simctl bootstatus "$2" -b >> "$_gm_log" 2>&1
  _gm_rc=$?
  if [ "$_gm_rc" -eq 0 ]; then
    gate_materials_set "$2" "$3" on >> "$_gm_log" 2>&1
    _gm_rc=$?
  fi
  _gm_try=0
  while [ "$_gm_rc" -eq 0 ] && [ "$_gm_try" -lt 2 ]; do
    _gm_try=$((_gm_try + 1))
    rm -rf "$_gm_bundle"; mkdir -p "$4/Results"
    echo "--- materials $3 run $_gm_try ---" >> "$_gm_log"
    _gm_nonce="$1-$3-$$-$_gm_try-$(date +%s)"
    printf '%s\n' "$_gm_nonce" > "$_gm_runfile"
    env TEST_RUNNER_IMG_MATERIALS_MODE="$3" TEST_RUNNER_IMG_MATERIALS_RUN="$_gm_nonce" \
      ${GATE_XCODEBUILD:-xcodebuild} test-without-building \
      -project ImgManager.xcodeproj -scheme ImgManager \
      -destination "id=$2" \
      -derivedDataPath "$4" \
      -resultBundlePath "$_gm_bundle" \
      -only-testing:"$GATE_MATERIALS_SUITE" \
      -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile >> "$_gm_log" 2>&1
    _gm_run=$?
    if [ "$_gm_run" -eq 0 ] && [ "$_gm_try" -eq 1 ] && [ "$3" = reduce-transparency ] \
      && grep -q "^MATERIALS-UNRESOLVED .* run=$_gm_nonce " "$_gm_log"; then
      echo "PIVOT: $3 did not read back after defaults write; posting the cache notification" >> "$_gm_log"
      gate_materials_set "$2" "$3" notify >> "$_gm_log" 2>&1 || { _gm_rc=$?; break; }
      continue
    fi
    _gm_rc=$_gm_run
    break
  done
  gate_materials_set "$2" "$3" off >> "$_gm_log" 2>&1
  _gm_reset=$?
  gate_export_screenshots "$_gm_name" "$_gm_bundle" >> "$_gm_log"
  _gm_export=$?
  [ "$_gm_rc" -ne 0 ] || _gm_rc=$_gm_reset
  [ "$_gm_rc" -ne 0 ] || _gm_rc=$_gm_export
  _gm_unresolved=""
  # Only the LAST run's section counts: a pivot that took leaves run 1's line behind.
  if [ "$_gm_rc" -eq 0 ] && [ "$3" = reduce-transparency ] && sed -n "/^--- materials $3 run $_gm_try ---\$/,\$p" "$_gm_log" \
    | grep -q "^MATERIALS-UNRESOLVED .* run=$_gm_nonce "; then
    _gm_unresolved=" UNRESOLVED: the setting did not read back after the pivot; nothing captured"
  fi
  echo "$_gm_name exit=$_gm_rc (runs=$_gm_try reset=$_gm_reset export=$_gm_export)$_gm_unresolved"
  return "$_gm_rc"
}

# gate_check_materials_manifest DEST LEG [MANIFEST] — resolve every manifest name for DEST
# (`<dest>-<surface>-<mode>.png`) out of the exported manifest.json files of LEG and its extra
# modes (matched by the attachment's name), copy each to .gate-artifacts/screenshots/materials/
# under its manifest name for the owner, and fail when one is MISSING, EMPTY, or byte-IDENTICAL
# to its default-mode sibling (a setting that changed nothing is not evidence).
#
# The ONE escape (plan Phase 4 fallback rule): Reduce Transparency's names may ALL be absent for
# DEST when that mode is UNRESOLVED — the suite recorded `materials-unresolved-DEST-reduce-
# transparency` (an attachment in THAT mode's own export; or, when none was exported, the
# `MATERIALS-UNRESOLVED` line of that mode's LAST run in its log) naming DEST, the mode, the
# run's token from `.gate-artifacts/materials-LEG-reduce-transparency.run` and a reading of
# `"reduceTransparency": "0"`. Each name prints `UNRESOLVED <name>` and the marker is copied
# beside the shots. BADMARKER (a failure): a marker for any other mode, one outside its mode's
# export, one without this run's token (stale or copied in), one whose reading is not the
# unread default. MIXED (a failure): a marker AND any captured shot of that mode.
#
# Prints one line `materials-manifest LEG exit=RC named=N[ unresolved=M]` and returns RC: 0 all
# present and distinct (or UNRESOLVED as above), 1 a name failed, 2 a manifest.json could not be
# read, 3 no manifest line for DEST, and the resolver's own code otherwise (127: no python3).
# GATE_PYTHON replaces the interpreter in the test.
gate_check_materials_manifest() {
  _cm_manifest="${3:-$GATE_MATERIALS_MANIFEST}"
  _cm_out=".gate-artifacts/screenshots/materials"
  _cm_log=".gate-artifacts/materials-manifest-$2.log"
  mkdir -p "$_cm_out" || { echo "materials-manifest $2 exit=4 named=0"; return 4; }
  _cm_dirs=".gate-artifacts/screenshots/$2"
  for _cm_mode in $GATE_MATERIALS_MODES; do
    _cm_dirs="$_cm_dirs .gate-artifacts/screenshots/materials-$2-$_cm_mode"
  done
  # shellcheck disable=SC2086 # the directory list is word-split on purpose (no spaces in it)
  ${GATE_PYTHON:-python3} - "$1" "$2" "$_cm_manifest" "$_cm_out" $_cm_dirs > "$_cm_log" 2>&1 <<'PY'
import json, os, shutil, sys
dest, leg, manifest, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dirs = sys.argv[5:]
MODES = ("default", "reduce-transparency", "increase-contrast")
UNRESOLVABLE = ("reduce-transparency",)
def matches(human, stem):
    return human == stem or human.startswith(stem + "_") or human.startswith(stem + ".")
def dir_mode(d):
    base = os.path.basename(d.rstrip("/"))
    prefix = "materials-%s-" % leg
    return base[len(prefix):] if base.startswith(prefix) else "default"
def run_token(mode):
    path = os.path.join(".gate-artifacts", "materials-%s-%s.run" % (leg, mode))
    if not os.path.isfile(path):
        return None
    with open(path) as fh:
        token = fh.read().strip()
    return token or None
def mode_of(stem):
    for mode in MODES:
        if stem.endswith("-" + mode):
            return mode
    return None
names = []
with open(manifest) as fh:
    for raw in fh:
        line = raw.strip()
        if line and not line.startswith("#") and line.startswith(dest + "-"):
            names.append(line)
if not names:
    print("NO-LINES no manifest line for %s in %s" % (dest, manifest))
    sys.exit(3)
found = {}
markers = {}
def walk(node, base):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node, base
        for value in node.values():
            for hit in walk(value, base):
                yield hit
    elif isinstance(node, list):
        for value in node:
            for hit in walk(value, base):
                yield hit
unreadable = False
for d in dirs:
    path = os.path.join(d, "manifest.json")
    if not os.path.isfile(path):
        print("NO-MANIFEST %s" % path)
        continue
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception as exc:
        print("UNREADABLE %s: %s" % (path, exc))
        unreadable = True
        continue
    for att, base in walk(data, d):
        human = str(att.get("suggestedHumanReadableName") or att.get("name") or "")
        for name in names:
            stem = name[:-4] if name.endswith(".png") else name
            if matches(human, stem):
                found.setdefault(name, []).append(os.path.join(base, att["exportedFileName"]))
        for mode in MODES:
            if matches(human, "materials-unresolved-%s-%s" % (dest, mode)):
                path = os.path.join(base, att["exportedFileName"])
                markers.setdefault(mode, []).append((dir_mode(d), path))
bad = 0
for stale in os.listdir(out):
    if stale.startswith("materials-unresolved-%s-" % dest):
        os.remove(os.path.join(out, stale))
# The log fallback: the LAST run's section of each extra mode's own log, and only when that log
# has a run header at all.
for mode in MODES[1:]:
    if mode in markers:
        continue
    path = os.path.join(".gate-artifacts", "materials-%s-%s.log" % (leg, mode))
    if not os.path.isfile(path):
        continue
    with open(path, errors="replace") as fh:
        lines = fh.read().splitlines()
    starts = [i for i, l in enumerate(lines) if l.startswith("--- materials %s run " % mode)]
    if not starts:
        continue
    want = "MATERIALS-UNRESOLVED dest=%s mode=%s " % (dest, mode)
    hit = [l for l in lines[starts[-1]:] if l.startswith(want)]
    if hit:
        markers[mode] = [(mode, ("log", hit[-1]))]
unresolved = set()
for mode, hits in sorted(markers.items()):
    marker = "materials-unresolved-%s-%s" % (dest, mode)
    if mode not in UNRESOLVABLE:
        print("BADMARKER %s (only reduce-transparency may be UNRESOLVED; %s has no escape)" % (marker, mode))
        bad += 1
        continue
    origin_mode, src = hits[-1]
    if len(hits) > 1 or origin_mode != mode:
        print("BADMARKER %s (%d marker(s); found in the %s export, not only in its own mode's)" % (marker, len(hits), origin_mode))
        bad += 1
        continue
    if isinstance(src, tuple):
        text, origin = src[1], "the mode's last-run log line"
    elif os.path.isfile(src):
        with open(src, errors="replace") as fh:
            text = fh.read()
        origin = "the suite's attachment"
    else:
        print("BADMARKER %s (its attachment file %s is missing)" % (marker, src))
        bad += 1
        continue
    token = run_token(mode)
    if token is None:
        print("BADMARKER %s (no run record materials-%s-%s.run: not from this gate's run)" % (marker, leg, mode))
        bad += 1
        continue
    if ("dest=%s mode=%s run=%s " % (dest, mode, token)) not in text + " ":
        print("BADMARKER %s (does not carry this run's token %s: stale or copied in)" % (marker, token))
        bad += 1
        continue
    if '"reduceTransparency": "0"' not in text or '"reduceTransparency": "1"' in text:
        print("BADMARKER %s (its reading is not the unread default: %s)" % (marker, text.strip()[:200]))
        bad += 1
        continue
    captured = [n for n in names if mode_of(n[:-4] if n.endswith(".png") else n) == mode and found.get(n)]
    if captured:
        print("MIXED %s: %d shot(s) of the mode were captured (%s); a mode is wholly captured or wholly UNRESOLVED" % (marker, len(captured), ", ".join(captured)))
        bad += 1
        continue
    with open(os.path.join(out, marker + ".txt"), "w") as fh:
        fh.write(text.rstrip("\n") + "\n")
    unresolved.add(mode)
    print("MARKER %s.txt from %s (run %s)" % (marker, origin, token))
for name in names:
    hits = found.get(name, [])
    target = os.path.join(out, name)
    if os.path.exists(target):
        os.remove(target)
    if not hits or not os.path.isfile(hits[-1]):
        mode = mode_of(name[:-4] if name.endswith(".png") else name)
        if not hits and mode in unresolved:
            print("UNRESOLVED %s (the setting did not read back; materials-unresolved-%s-%s.txt)" % (name, dest, mode))
            continue
        print("MISSING %s" % name); bad += 1; continue
    if len(hits) > 1:
        print("DUPLICATE %s x%d (the last one is used)" % (name, len(hits)))
    shutil.copyfile(hits[-1], target)
    if os.path.getsize(target) == 0:
        print("EMPTY %s" % name); bad += 1; continue
    print("OK %s %d bytes" % (name, os.path.getsize(target)))
for name in names:
    stem = name[:-4] if name.endswith(".png") else name
    if stem.endswith("-default"):
        continue
    sibling = None
    for mode in ("-reduce-transparency", "-increase-contrast"):
        if stem.endswith(mode):
            sibling = os.path.join(out, stem[: -len(mode)] + "-default.png")
    if sibling is None:
        print("BADNAME %s (mode is not default, reduce-transparency or increase-contrast)" % name)
        bad += 1
        continue
    target = os.path.join(out, name)
    if os.path.isfile(target) and os.path.getsize(target) > 0 and os.path.isfile(sibling):
        with open(target, "rb") as a, open(sibling, "rb") as b:
            if a.read() == b.read():
                print("IDENTICAL %s == %s" % (name, os.path.basename(sibling))); bad += 1
if unreadable:
    sys.exit(2)
sys.exit(1 if bad else 0)
PY
  _cm_rc=$?
  _cm_n="$(grep -c '^OK ' "$_cm_log" 2>/dev/null || true)"
  _cm_u="$(grep -c '^UNRESOLVED ' "$_cm_log" 2>/dev/null || true)"
  _cm_uline=""
  [ "${_cm_u:-0}" -eq 0 ] || _cm_uline=" unresolved=$_cm_u"
  echo "materials-manifest $2 exit=$_cm_rc named=${_cm_n:-0}$_cm_uline"
  if [ "$_cm_rc" -ne 0 ]; then
    grep -v '^OK ' "$_cm_log" | head -24
  elif [ -n "$_cm_uline" ]; then
    grep '^UNRESOLVED \|^MARKER ' "$_cm_log" | head -24
  fi
  return "$_cm_rc"
}
