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
# --- IMGMGR-399: the mirror carries what git TRACKS, so the two manifest halves compare like
# with like. The mirror's file selection is driven by `git ls-files` itself — the manifest's own
# source — so no second matcher can drift from it (round-3 review, B4).
mfail() { echo "FAIL $1: $2"; fail=1; }
mok() { echo "PASS $1: $2"; }
mkdir -p "$tmp/wt/docs/session-reviews" "$tmp/wt/ignored" "$tmp/wt/build" "$tmp/wt/sub/nested-ignored"
cd "$tmp/wt"
git init -q .
git config user.email test@example.invalid
git config user.name "gate-lib test"
# The four shapes that decide the rule order: an ignored dir holding a FORCE-ADDED tracked file,
# a negation, a plain ignored file, and a nested .gitignore.
printf 'ignored/\n*.tmpjunk\ndocs/session-reviews/\n.phase-ledger.md\nbuild/\nkeep.*\n!keep.me\n' > .gitignore
printf 'nested-ignored/\n' > sub/.gitignore
printf 'let a = 1\n' > App.swift
printf '# notes\n' > docs/notes.md
printf 'k\n' > sub/lib.swift
printf 'force added under an ignored dir\n' > build/keep.txt
printf 'negated back in\n' > keep.me
git add -A
git add -f build/keep.txt
git commit -qm init
# untracked working files that must never reach the mirror
printf 'review\n' > docs/session-reviews/r.md
printf 'junk\n' > ignored/x.txt
printf 'junk\n' > scratch.tmpjunk
printf 'ledger\n' > .phase-ledger.md
printf 'obj\n' > build/junk.o
printf 'n\n' > sub/nested-ignored/x.txt
if [ -z "$(git status --porcelain)" ] && [ -n "$(git status --porcelain --ignored)" ] \
   && git ls-files | grep -qx 'build/keep.txt' && git ls-files | grep -qx 'keep.me'; then
  mok m-setup "clean to git status, carries ignored extras, and tracks build/keep.txt (force-added) + keep.me (negated)"
else
  mfail m-setup "porcelain='$(git status --porcelain)' tracked=$(git ls-files | tr '\n' ' ')"
fi

list="$tmp/tracked.list"
gate_mirror_include_list "$list"
mirror_args=()
while IFS= read -r a; do mirror_args+=("$a"); done < <(gate_mirror_filters "$list")
printf 'rule order: %s\n' "${mirror_args[*]}"
rsync -a --delete "${mirror_args[@]}" ./ "$tmp/mirror/" > "$tmp/rsync.log" 2>&1
rsrc=$?
local_m="$(gate_local_manifest)"
mirror_m="$(gate_mirror_manifest "$tmp/mirror")"

if [ "$rsrc" -eq 0 ] && [ -f "$tmp/mirror/build/keep.txt" ] && [ -f "$tmp/mirror/keep.me" ]; then
  mok m-tracked-wins "a force-added file under an ignored directory and a negated file both reached the mirror"
else
  mfail m-tracked-wins "rc=$rsrc build/keep.txt=$([ -f "$tmp/mirror/build/keep.txt" ] && echo yes || echo MISSING) keep.me=$([ -f "$tmp/mirror/keep.me" ] && echo yes || echo MISSING)"
fi
if [ ! -e "$tmp/mirror/ignored" ] && [ ! -e "$tmp/mirror/docs/session-reviews" ] \
   && [ ! -e "$tmp/mirror/scratch.tmpjunk" ] && [ ! -e "$tmp/mirror/.phase-ledger.md" ] \
   && [ ! -e "$tmp/mirror/build/junk.o" ] && [ ! -e "$tmp/mirror/sub/nested-ignored" ] \
   && [ ! -e "$tmp/mirror/.git" ] && [ -f "$tmp/mirror/docs/notes.md" ] \
   && [ -f "$tmp/mirror/sub/lib.swift" ]; then
  mok m-mirror "no untracked or ignored file reached the mirror (nested .gitignore included), tracked ones did"
else
  mfail m-mirror "mirror: $(cd "$tmp/mirror" 2>/dev/null && find . | sort | tr '\n' ' ')"
fi
if [ -n "$local_m" ] && [ "$local_m" = "$mirror_m" ]; then
  mok m-manifest "the mirror manifest equals the tracked-file manifest ($(printf '%s\n' "$local_m" | grep -c .) files)"
else
  mfail m-manifest "$(diff <(printf '%s\n' "$local_m") <(printf '%s\n' "$mirror_m") | head -10 | tr '\n' ' ')"
fi

# A FAITHFUL prior-run mirror: what a real gate left on the Mac — every tracked file INCLUDING
# the .gitignore files, stale untracked-ignored leftovers at the root and in a subdirectory, and
# a DerivedData cache that lives only there. The stale files must be swept (or the manifest leg
# still fails on the existing mirrors) and the cache must survive.
stale="$tmp/mirror-stale"
rsync -a "${mirror_args[@]}" ./ "$stale/" >> "$tmp/rsync.log" 2>&1
mkdir -p "$stale/docs/session-reviews" "$stale/ignored" "$stale/DerivedData"
printf 'stale review\n' > "$stale/docs/session-reviews/old.md"
printf 'stale ignored\n' > "$stale/ignored/old.txt"
printf 'build cache\n' > "$stale/DerivedData/x.o"
rsync -a --delete "${mirror_args[@]}" ./ "$stale/" >> "$tmp/rsync.log" 2>&1
stale_rc=$?
if [ "$stale_rc" -eq 0 ] && [ ! -e "$stale/docs/session-reviews/old.md" ] \
   && [ ! -e "$stale/ignored/old.txt" ] && [ -f "$stale/DerivedData/x.o" ] \
   && [ -f "$stale/.gitignore" ] && [ "$(gate_mirror_manifest "$stale")" = "$local_m" ]; then
  mok m-stale "a prior-run mirror carrying .gitignore lost both stale leftovers, kept DerivedData, and matches the manifest"
else
  mfail m-stale "rc=$stale_rc root-stale=$([ -e "$stale/docs/session-reviews/old.md" ] && echo SURVIVES || echo gone) sub-stale=$([ -e "$stale/ignored/old.txt" ] && echo SURVIVES || echo gone) cache=$([ -f "$stale/DerivedData/x.o" ] && echo kept || echo LOST)"
fi

# Control: the fixed exclude list alone (no tracked include list, no catch-all) lets the ignored
# extras through — the equality above is evidence only because this half can go red.
plain_args=()
while IFS= read -r a; do plain_args+=("$a"); done < <(gate_mirror_filters "$list" | grep -E '^--exclude=')
rsync -a --delete "${plain_args[@]}" ./ "$tmp/mirror-fixed-only/" >> "$tmp/rsync.log" 2>&1
fixed_only_m="$(gate_mirror_manifest "$tmp/mirror-fixed-only")"
if [ "$local_m" != "$fixed_only_m" ] && printf '%s\n' "$fixed_only_m" | grep -q 'session-reviews' \
   && [ ! -e "$tmp/mirror-fixed-only/.phase-ledger.md" ]; then
  mok m-control "with the fixed exclude list alone the ignored extras reach the mirror and the manifests differ (the fixed list still holds .phase-ledger.md back)"
else
  mfail m-control "the control did not differ: $(printf '%s\n' "$fixed_only_m" | head -5 | tr '\n' ' ')"
fi

# --- R3: the include list feeds rsync PATTERNS, not plain paths. A tracked `a[1].png` is a
# character class that does not match itself but DOES match `a1.png`; `b*.txt` and `c?.md` match
# whatever the wildcard covers. Each such name gets a decoy that a raw pattern would swallow.
printf 'a1.png\nbXY.txt\ncZ.md\n' >> .gitignore
printf 'class\n' > 'a[1].png'
printf 'star\n' > 'b*.txt'
printf 'query\n' > 'c?.md'
git add -A
git commit -qm wildcards
printf 'decoy\n' > a1.png
printf 'decoy\n' > bXY.txt
printf 'decoy\n' > cZ.md
gate_mirror_include_list "$list"
wild_args=()
while IFS= read -r a; do wild_args+=("$a"); done < <(gate_mirror_filters "$list")
rsync -a --delete "${wild_args[@]}" ./ "$tmp/mirror-wild/" >> "$tmp/rsync.log" 2>&1
wild_rc=$?
wild_local="$(gate_local_manifest)"
if [ "$wild_rc" -eq 0 ] && [ -f "$tmp/mirror-wild/a[1].png" ] && [ -f "$tmp/mirror-wild/b*.txt" ] \
   && [ -f "$tmp/mirror-wild/c?.md" ]; then
  mok m-wild-tracked "tracked names holding rsync wildcards (a[1].png, b*.txt, c?.md) reached the mirror as themselves"
else
  mfail m-wild-tracked "rc=$wild_rc present: $(cd "$tmp/mirror-wild" 2>/dev/null && ls | tr '\n' ' ')"
fi
if [ ! -e "$tmp/mirror-wild/a1.png" ] && [ ! -e "$tmp/mirror-wild/bXY.txt" ] \
   && [ ! -e "$tmp/mirror-wild/cZ.md" ] && [ "$(gate_mirror_manifest "$tmp/mirror-wild")" = "$wild_local" ]; then
  mok m-wild-nomatch "no decoy the raw patterns would have matched (a1.png, bXY.txt, cZ.md) reached the mirror, and the manifest still matches"
else
  mfail m-wild-nomatch "decoys: $(cd "$tmp/mirror-wild" 2>/dev/null && ls | tr '\n' ' ') diff: $(diff <(printf '%s\n' "$wild_local") <(gate_mirror_manifest "$tmp/mirror-wild") | head -6 | tr '\n' ' ')"
fi

# --- A2: the mirror walker prunes the same nine names the rsync excludes do — including the two
# that are files by contract, so a directory of that name cannot smuggle content past it.
mkdir -p "$tmp/mirror-wild/signing.local.yml" "$tmp/mirror-wild/.phase-ledger.md" "$tmp/mirror-wild/.tools"
printf 'x\n' > "$tmp/mirror-wild/signing.local.yml/leak.txt"
printf 'x\n' > "$tmp/mirror-wild/.phase-ledger.md/leak.txt"
printf 'x\n' > "$tmp/mirror-wild/.tools/leak.txt"
if [ "$(gate_mirror_manifest "$tmp/mirror-wild")" = "$wild_local" ]; then
  mok m-walker-prune "the walker prunes all nine excluded names, directories of a file-by-contract name included"
else
  mfail m-walker-prune "$(diff <(printf '%s\n' "$wild_local") <(gate_mirror_manifest "$tmp/mirror-wild") | head -6 | tr '\n' ' ')"
fi

# --- A3: `git ls-files` failing must fail the list, not write a short one.
if ( cd "$tmp" && gate_mirror_include_list "$tmp/outside.list" ) 2>/dev/null; then
  mfail m-lsfiles-rc "gate_mirror_include_list returned 0 outside a git repository"
else
  mok m-lsfiles-rc "gate_mirror_include_list fails when git ls-files does (outside a repository)"
fi

# Control that rsync really parses rule modifiers rather than ignoring them: an unknown one must
# be an error, so the sender-only catch-all being accepted is evidence that it took effect.
if rsync -a --delete --filter='-z *' ./ "$tmp/mirror-bogus/" > "$tmp/bogus.log" 2>&1; then
  mfail m-modifier "rsync accepted the bogus modifier '-z' — modifier parsing is not strict"
else
  mok m-modifier "rsync rejects an unknown filter modifier ('-z'), so the accepted '-s' is a real rule: $(head -1 "$tmp/bogus.log")"
fi

# --- IMGMGR-408: the manifest halves survive exotic tracked paths. A path with a SPACE, one
# with a NEWLINE and tracked SYMLINKS: the mirror selection already handled them (NUL-delimited
# since round 3), the two manifest halves did not. Each case carries a control that turns the
# comparison RED, so the equality above it is evidence and not a coincidence.
xfail() { echo "FAIL $1: $2"; fail=1; }
xok() { echo "PASS $1: $2"; }
cd "$tmp/wt"
nl_name="$(printf 'nl\nname.txt')"
printf 'spaced\n' > 'a file with spaces.txt'
printf 'newlined\n' > "$nl_name"
ln -s App.swift link-to-app.swift
ln -s 'a file with spaces.txt' 'link with spaces.swift'
chmod +x sub/lib.swift
git add -A
git commit -qm exotic
if [ "$(git ls-files -z | tr '\0' '\n' | grep -c ' ')" -ge 2 ] \
   && [ "$(git ls-files -s | awk '$1=="120000"' | wc -l)" -eq 2 ] \
   && [ "$(git ls-files -s | awk '$1=="100755"' | wc -l)" -eq 1 ] \
   && git ls-files -z | tr '\0' '\n' | grep -qx 'name.txt'; then
  xok x-setup "git tracks 2 paths with spaces, a path with a newline (its tail sorts as a line of its own), 2 symlinks (mode 120000) and 1 executable (100755)"
else
  xfail x-setup "tracked: $(git ls-files -s | tr '\n' '|')"
fi
gate_mirror_include_list "$list"
x_args=()
while IFS= read -r a; do x_args+=("$a"); done < <(gate_mirror_filters "$list")
xmirror="$tmp/mirror-exotic"
rsync -a --delete "${x_args[@]}" ./ "$xmirror/" >> "$tmp/rsync.log" 2>&1
xrc=$?
x_local="$(gate_local_manifest)"
x_remote="$(gate_mirror_manifest "$xmirror")"
if [ "$xrc" -eq 0 ] && [ -f "$xmirror/a file with spaces.txt" ] && [ -f "$xmirror/$nl_name" ] \
   && [ -L "$xmirror/link-to-app.swift" ] && [ -L "$xmirror/link with spaces.swift" ]; then
  xok x-mirror "all four exotic paths reached the mirror, the symlinks AS symlinks"
else
  xfail x-mirror "rc=$xrc $(cd "$xmirror" 2>/dev/null && ls -l | tr '\n' '|')"
fi
if [ -n "$x_local" ] && [ "$x_local" = "$x_remote" ]; then
  xok x-manifest "both manifest halves agree over spaces, a newline and symlinks ($(printf '%s\n' "$x_local" | grep -c .) records)"
else
  xfail x-manifest "$(diff <(printf '%s\n' "$x_local") <(printf '%s\n' "$x_remote") | head -12 | tr '\n' '|')"
fi
# A symlink is recorded the way `git ls-files -s` records it: mode 120000, blob = the LINK
# TARGET, computed here independently of either half.
want_blob="$(printf 'App.swift' | git hash-object --stdin)"
if printf '%s\n' "$x_local" | grep -qx "120000 $want_blob link-to-app.swift" \
   && printf '%s\n' "$x_remote" | grep -qx "120000 $want_blob link-to-app.swift"; then
  xok x-symlink "both halves hash the symlink as git does — 120000 $want_blob (the blob of its target string)"
else
  xfail x-symlink "local=$(printf '%s\n' "$x_local" | grep 'link-to-app') remote=$(printf '%s\n' "$x_remote" | grep 'link-to-app')"
fi
if [ "$(printf '%s\n' "$x_local" | grep -c 'nl\\nname\.txt$')" -eq 1 ] \
   && [ "$(printf '%s\n' "$x_local" | grep -c 'a file with spaces\.txt$')" -eq 1 ]; then
  xok x-encoding "the newline path is ONE record with its newline escaped, and the spaced path is not truncated"
else
  xfail x-encoding "$(printf '%s\n' "$x_local" | grep -n 'nl\|spaces' | tr '\n' '|')"
fi
if printf '%s\n' "$x_local" | grep -qx "100755 .* sub/lib\.swift" \
   && printf '%s\n' "$x_remote" | grep -qx "100755 .* sub/lib\.swift"; then
  xok x-mode "both halves carry the file mode, so an executable bit lost in transit is a red leg"
else
  xfail x-mode "local=$(printf '%s\n' "$x_local" | grep 'sub/lib') remote=$(printf '%s\n' "$x_remote" | grep 'sub/lib')"
fi
# Controls: each exotic shape can turn the comparison RED on its own.
printf 'tampered\n' > "$xmirror/a file with spaces.txt"
if [ "$(gate_mirror_manifest "$xmirror")" != "$x_local" ]; then
  xok x-control-space "editing the mirror's spaced path is DETECTED (it is really compared, not truncated at the space)"
else
  xfail x-control-space "the spaced path was not compared"
fi
cp -p "$xmirror/../mirror-exotic/a file with spaces.txt" /dev/null 2>/dev/null
printf 'spaced\n' > "$xmirror/a file with spaces.txt"
printf 'tampered\n' > "$xmirror/$nl_name"
if [ "$(gate_mirror_manifest "$xmirror")" != "$x_local" ]; then
  xok x-control-newline "editing the mirror's newline path is DETECTED"
else
  xfail x-control-newline "the newline path was not compared"
fi
printf 'newlined\n' > "$xmirror/$nl_name"
rm "$xmirror/link-to-app.swift"
printf 'App.swift' > "$xmirror/link-to-app.swift"
if [ "$(gate_mirror_manifest "$xmirror")" != "$x_local" ]; then
  xok x-control-symlink "a symlink replaced by a REGULAR FILE holding the same bytes is DETECTED — that is what the mode column is for"
else
  xfail x-control-symlink "a symlink-to-file swap passed as identical"
fi
rm -f "$xmirror/link-to-app.swift"; ln -s App.swift "$xmirror/link-to-app.swift"
chmod -x "$xmirror/sub/lib.swift"
if [ "$(gate_mirror_manifest "$xmirror")" != "$x_local" ]; then
  xok x-control-mode "an executable bit lost on the mirror is DETECTED"
else
  xfail x-control-mode "the mode was not compared"
fi
chmod +x "$xmirror/sub/lib.swift"
if [ "$(gate_mirror_manifest "$xmirror")" = "$x_local" ]; then
  xok x-restored "with every tamper undone the halves agree again (the controls proved the comparison, not a permanent mismatch)"
else
  xfail x-restored "$(diff <(printf '%s\n' "$x_local") <(gate_mirror_manifest "$xmirror") | head -8 | tr '\n' '|')"
fi

# --- IMGMGR-410: the leg registry. Mac-free proof of the SELECTION LOGIC — what a run would do,
# decided entirely on this machine. The real subset run on the Mac is the orchestrator's.
lfail() { echo "FAIL $1: $2"; fail=1; }
lok() { echo "PASS $1: $2"; }
full="$GATE_LEGS_ALL"
got="$(gate_legs_resolve "")"
if [ "$got" = "$full" ] && [ "$(gate_legs_field "$got")" = "legs=full" ]; then
  lok l-full "an empty selection is a FULL gate ($(printf '%s' "$full" | wc -w) legs) and its field reads legs=full"
else
  lfail l-full "got '$got' field '$(gate_legs_field "$got")'"
fi
got="$(gate_legs_resolve "mirror,manifest,lint")"
if [ "$got" = "mirror manifest lint" ]; then
  lok l-subset "a named subset resolves to exactly those legs, in canonical order"
else
  lfail l-subset "got '$got'"
fi
case "$(gate_legs_field "mirror manifest lint")" in
  "legs=SUBSET(mirror,manifest,lint) — NOT a full gate")
    lok l-field "a subset names itself in the summary field, so it cannot be read as a full gate" ;;
  *) lfail l-field "got '$(gate_legs_field "mirror manifest lint")'" ;;
esac
got="$(gate_legs_resolve "lint,manifest,manifest")"
if [ "$got" = "mirror manifest lint" ]; then
  lok l-mandatory "the mandatory mirror leg joins a selection that omits it, duplicates collapse, order is canonical"
else
  lfail l-mandatory "got '$got'"
fi
got="$(gate_legs_resolve "mirror,bogus-leg" 2>"$tmp/legerr")"; lrc=$?
if [ "$lrc" -eq 2 ] && [ -z "$got" ] && grep -q "unknown leg 'bogus-leg'" "$tmp/legerr"; then
  lok l-unknown "an unknown leg name is refused (rc=2), prints nothing on stdout, and is named: $(cat "$tmp/legerr")"
else
  lfail l-unknown "rc=$lrc out='$got' err='$(cat "$tmp/legerr")'"
fi
got="$(gate_legs_resolve "mirror,,lint" 2>"$tmp/legerr")"; lrc=$?
if [ "$lrc" -eq 2 ] && [ -z "$got" ]; then
  lok l-empty "an empty leg name is refused (rc=2): $(cat "$tmp/legerr")"
else
  lfail l-empty "rc=$lrc out='$got'"
fi
got="$(gate_legs_resolve "build" 2>"$tmp/legerr")"; lrc=$?
if [ "$lrc" -eq 2 ] && [ -z "$got" ] && grep -q "needs 'xcodegen'" "$tmp/legerr"; then
  lok l-prereq "'build' without 'xcodegen' is refused rather than silently completed or dropped: $(cat "$tmp/legerr")"
else
  lfail l-prereq "rc=$lrc out='$got' err='$(cat "$tmp/legerr")'"
fi
got="$(gate_legs_resolve "xcodegen,widget-embed" 2>"$tmp/legerr")"; lrc=$?
if [ "$lrc" -eq 2 ] && grep -q "needs 'build'" "$tmp/legerr"; then
  lok l-prereq-chain "'widget-embed' is refused without the 'build' whose bundle it reads"
else
  lfail l-prereq-chain "rc=$lrc err='$(cat "$tmp/legerr")'"
fi
got="$(gate_legs_resolve "xcodegen,build,widget-embed")"; lrc=$?
if [ "$lrc" -eq 0 ] && [ "$got" = "mirror xcodegen build widget-embed" ]; then
  lok l-prereq-ok "the same selection with its prerequisites resolves (positive control): $got"
else
  lfail l-prereq-ok "rc=$lrc got='$got'"
fi
if gate_leg_wanted lint "mirror manifest lint" && ! gate_leg_wanted build "mirror manifest lint"; then
  lok l-wanted "gate_leg_wanted answers for a selected and an unselected leg (the remote half's own test)"
else
  lfail l-wanted "gate_leg_wanted disagreed with the resolved list"
fi
# The proof runs through bin/mac-gate.sh itself, with MAC_GATE_HOST deliberately UNSET: the list
# mode must decide and exit before anything reaches for the Mac, so a run that touched ssh would
# refuse here instead of printing a list.
mg="$here/mac-gate.sh"
( cd "$here/.." && env -u MAC_GATE_HOST "$mg" --legs manifest,lint --list-legs ) > "$tmp/ll.out" 2>"$tmp/ll.err"
lrc=$?
if [ "$lrc" -eq 0 ] \
   && [ "$(head -1 "$tmp/ll.out")" = "legs=SUBSET(mirror,manifest,lint) — NOT a full gate" ] \
   && [ "$(sed -n '2,$p' "$tmp/ll.out" | tr '\n' ' ')" = "mirror manifest lint " ]; then
  lok l-listmode "mac-gate --list-legs printed the legs that WOULD run, with no MAC_GATE_HOST and no Mac: $(head -1 "$tmp/ll.out")"
else
  lfail l-listmode "rc=$lrc out='$(cat "$tmp/ll.out")' err='$(cat "$tmp/ll.err")'"
fi
( cd "$here/.." && env -u MAC_GATE_HOST "$mg" --list-legs ) > "$tmp/llf.out" 2>&1
lrc=$?
if [ "$lrc" -eq 0 ] && [ "$(head -1 "$tmp/llf.out")" = "legs=full" ] \
   && [ "$(sed -n '2,$p' "$tmp/llf.out" | tr '\n' ' ')" = "$full " ]; then
  lok l-listmode-full "mac-gate --list-legs with no selection lists every leg and says legs=full"
else
  lfail l-listmode-full "rc=$lrc out='$(cat "$tmp/llf.out")'"
fi
( cd "$here/.." && env -u MAC_GATE_HOST "$mg" --legs mirror,nope --list-legs ) > "$tmp/llb.out" 2>&1
lrc=$?
if [ "$lrc" -eq 2 ] && grep -q "unknown leg 'nope'" "$tmp/llb.out"; then
  lok l-listmode-refuse "mac-gate refuses an unknown leg name (rc=2) before it does anything at all"
else
  lfail l-listmode-refuse "rc=$lrc out='$(cat "$tmp/llb.out")'"
fi

# --- round-1 review, finding 2: registry membership is EXACT. The registry is a space-joined
# string, so a substring test accepted the single token `xcodegen build` — two adjacent entries —
# as one known leg. A token carrying whitespace is a malformed list, not a leg name.
got="$(gate_legs_resolve "mirror,xcodegen build" 2>"$tmp/legerr")"; lrc=$?
if [ "$lrc" -eq 2 ] && [ -z "$got" ] && grep -q 'whitespace' "$tmp/legerr"; then
  lok l-whitespace-adjacent "the token 'xcodegen build' — two adjacent registry entries — is refused, not resolved: $(cat "$tmp/legerr")"
else
  lfail l-whitespace-adjacent "rc=$lrc out='$got' err='$(cat "$tmp/legerr")'"
fi
got="$(gate_legs_resolve "manifest api-nullable-tests" 2>"$tmp/legerr")"; lrc=$?
if [ "$lrc" -eq 2 ] && [ -z "$got" ]; then
  lok l-whitespace-only "a whole selection given with spaces instead of commas is refused: $(cat "$tmp/legerr")"
else
  lfail l-whitespace-only "rc=$lrc out='$got'"
fi
got="$(gate_legs_resolve "manifest,api-nullable-tests")"; lrc=$?
if [ "$lrc" -eq 0 ] && [ "$got" = "mirror manifest api-nullable-tests" ]; then
  lok l-whitespace-control "the SAME two legs comma-separated still resolve (positive control): $got"
else
  lfail l-whitespace-control "rc=$lrc got='$got'"
fi
( cd "$here/.." && env -u MAC_GATE_HOST "$mg" --legs 'xcodegen build' --list-legs ) > "$tmp/ws.out" 2>&1
lrc=$?
if [ "$lrc" -eq 2 ]; then
  lok l-whitespace-macgate "bin/mac-gate.sh refuses it too (rc=2), before anything runs"
else
  lfail l-whitespace-macgate "rc=$lrc out='$(cat "$tmp/ws.out")'"
fi

# --- round-1 review, finding 4: the REAL summary line. `--dry-run` runs the gate's own
# summary_and_exit with every selected leg recorded as `dry-run` — Mac-free, but printed by the
# same code a real run prints, so the marker that tells a subset from a full gate cannot vanish
# from it while these tests stay green. MAC_GATE_ARTIFACTS is redirected so the test never
# truncates the worktree's own gate log.
dryrun() { ( cd "$here/.." && env -u MAC_GATE_HOST MAC_GATE_ARTIFACTS="$tmp/dryart" "$mg" "$@" ); }
dryrun --legs mirror,manifest,lint --dry-run > "$tmp/dr1.out" 2>&1; lrc=$?
sline="$(grep '^mac-gate SUMMARY:' "$tmp/dr1.out" | tail -1)"
if [ "$lrc" -eq 0 ] \
   && [ "$sline" = "mac-gate SUMMARY: legs=SUBSET(mirror,manifest,lint) — NOT a full gate | mirror=dry-run manifest=dry-run lint=dry-run | exit=0" ]; then
  lok s-summary-subset "the real SUMMARY line of a subset run names the subset and denies being a full gate: $sline"
else
  lfail s-summary-subset "rc=$lrc line='$sline'"
fi
if grep -qF "$sline" "$tmp/dryart/mac-gate.log"; then
  lok s-summary-logged "that same line was written to the run log, so it went through summary_and_exit's own tee and not past it"
else
  lfail s-summary-logged "not in $tmp/dryart/mac-gate.log: $(cat "$tmp/dryart/mac-gate.log" 2>&1)"
fi
dryrun --dry-run > "$tmp/dr2.out" 2>&1; lrc=$?
sline="$(grep '^mac-gate SUMMARY:' "$tmp/dr2.out" | tail -1)"
missing=""
for leg in $GATE_LEGS_ALL; do
  case "$sline" in *" $leg=dry-run"*) ;; *) missing="$missing $leg" ;; esac
done
case "$sline" in
  "mac-gate SUMMARY: legs=full |"*" | exit=0") full_shape=1 ;;
  *) full_shape=0 ;;
esac
if [ "$lrc" -eq 0 ] && [ "$full_shape" -eq 1 ] && [ -z "$missing" ]; then
  lok s-summary-full "a full run says legs=full and its line carries every one of the $(printf '%s' "$GATE_LEGS_ALL" | wc -w) registry legs"
else
  lfail s-summary-full "rc=$lrc shape=$full_shape missing='$missing' line='$sline'"
fi
dryrun --legs bogus-leg --dry-run > "$tmp/dr3.out" 2>&1; lrc=$?
sline="$(grep '^mac-gate SUMMARY:' "$tmp/dr3.out" | tail -1)"
case "$sline" in
  "mac-gate SUMMARY: legs=REFUSED("*") — NOT a full gate | | exit=2") refused_shape=1 ;;
  *) refused_shape=0 ;;
esac
if [ "$lrc" -eq 2 ] && [ "$refused_shape" -eq 1 ] && printf '%s' "$sline" | grep -q "bogus-leg"; then
  lok s-summary-refused "a refusal prints a summary line of its own, naming the reason, so the queue has something to copy and a reader can tell it from a crash: $sline"
else
  lfail s-summary-refused "rc=$lrc shape=$refused_shape line='$sline'"
fi
if [ "$(gate_summary_line 'legs=full' ' a=0 b=1' 1)" = "mac-gate SUMMARY: legs=full | a=0 b=1 | exit=1" ]; then
  lok s-summary-fn "gate_summary_line composes the line from a fabricated leg-result set — one definition, used by the real run"
else
  lfail s-summary-fn "got '$(gate_summary_line 'legs=full' ' a=0 b=1' 1)'"
fi

# --- IMGMGR-412: a drifted Package.resolved makes the pins leg RED even when the resolution
# command itself exited 0. The block is lifted verbatim from the REMOTE script, so the shipped
# lines run here — `want`/`step` are stubbed to the rc under test and the drift is induced by
# rewriting the resolved file from inside the stubbed step, exactly where resolution would.
pfail() { echo "FAIL $1: $2"; fail=1; }
pok() { echo "PASS $1: $2"; }
pins_block="$(sed -n '/^  if want pins; then$/,/^  fi$/p' "$mg")"
run_pins() { # $1=step-rc $2=drift(0|1); prints the summary the block leaves behind
  (
    cd "$tmp" && rm -rf pinscase && mkdir -p pinscase/.gate-artifacts && cd pinscase || exit 9
    printf 'pinned\n' > Package.resolved
    want() { [ "$1" = pins ]; }
    step() { summary="$summary $1=$STEP_RC"; if [ "$DRIFT" = 1 ]; then printf 'moved\n' > Package.resolved; fi; return 0; }
    summary=" build=0"; STEP_RC="$1"; DRIFT="$2"
    eval "$pins_block" > pins.out
    printf '%s' "$summary"
  )
}
if [ -z "$pins_block" ] || ! printf '%s' "$pins_block" | grep -q 'PINS FAIL'; then
  pfail p-extract "the pins block was not found in $mg"
else
  s0="$(run_pins 0 0)"
  case "$s0" in *" pins=0"*) pok p-clean "no drift keeps the leg green:$s0" ;; *) pfail p-clean "summary '$s0'" ;; esac
  s1="$(run_pins 0 1)"
  case "$s1" in *" pins=1"*) pok p-drift "drift with rc 0 records pins=1:$s1" ;; *) pfail p-drift "summary '$s1' (PINS FAIL printed but the leg stayed green)" ;; esac
  s2="$(run_pins 65 1)"
  case "$s2" in *" pins=65"*) pok p-drift-rc "a real non-zero rc is kept, not masked:$s2" ;; *) pfail p-drift-rc "summary '$s2'" ;; esac
fi

# --- WP28 P1 (IMGMGR-448): the UI legs' screenshot export. The function runs against a stub in
# place of xcresulttool (GATE_XCRESULTTOOL) — a success that writes two attachments and a
# manifest, and a refusal — and the wiring is read from the REMOTE script itself, by the exact
# argument text, so a comment mentioning the flag cannot satisfy it.
sfail() { echo "FAIL $1: $2"; fail=1; }
sok() { echo "PASS $1: $2"; }
cat > "$tmp/stub-xcresulttool" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in --output-path) out="$2"; shift 2 ;; *) shift ;; esac
done
if [ "${STUB_RC:-0}" -ne 0 ]; then echo "stub refusal" >&2; exit "$STUB_RC"; fi
printf 'png' > "$out/a.png"; printf 'png' > "$out/b.png"; printf '{}' > "$out/manifest.json"
STUB
chmod +x "$tmp/stub-xcresulttool"
rm -rf "$tmp/sscase" && mkdir -p "$tmp/sscase/.gate-artifacts" "$tmp/sscase/bundle.xcresult"
cd "$tmp/sscase" || exit 9
if ! command -v gate_export_screenshots >/dev/null 2>&1; then
  sfail ss-defined "gate_export_screenshots is not defined by gate-lib.sh"
else
  mkdir -p .gate-artifacts/screenshots/test-iphone
  printf 'old' > .gate-artifacts/screenshots/test-iphone/stale.png
  line="$(GATE_XCRESULTTOOL="$tmp/stub-xcresulttool" STUB_RC=0 gate_export_screenshots test-iphone "$PWD/bundle.xcresult")"; rc=$?
  case "$rc|$line" in
    "0|screenshots test-iphone exit=0 files=2") sok ss-export "$line" ;;
    *) sfail ss-export "rc=$rc line='$line'" ;;
  esac
  if [ -f .gate-artifacts/screenshots/test-iphone/a.png ] && [ ! -e .gate-artifacts/screenshots/test-iphone/stale.png ]; then
    sok ss-fresh "the export lands in screenshots/<leg>/ and a previous run's file is gone"
  else
    sfail ss-fresh "a.png missing or stale.png survived: $(ls .gate-artifacts/screenshots/test-iphone 2>&1 | tr '\n' ' ')"
  fi
  line="$(GATE_XCRESULTTOOL="$tmp/stub-xcresulttool" STUB_RC=65 gate_export_screenshots test-ipad "$PWD/bundle.xcresult")"; rc=$?
  case "$rc|$line" in
    "65|screenshots test-ipad exit=65 "*) sok ss-refused "the tool's own refusal is returned: $line" ;;
    *) sfail ss-refused "rc=$rc line='$line' (a failed export must not read as green)" ;;
  esac
  line="$(GATE_XCRESULTTOOL="$tmp/stub-xcresulttool" STUB_RC=0 gate_export_screenshots test-ipad "$PWD/absent.xcresult")"; rc=$?
  case "$rc|$line" in
    "3|screenshots test-ipad exit=3 files=0"*) sok ss-no-bundle "$line" ;;
    *) sfail ss-no-bundle "rc=$rc line='$line'" ;;
  esac
fi
for leg in test-iphone test-ipad; do
  n_bundle="$(grep -cF -- "-resultBundlePath \"\$derived/Results/$leg.xcresult\"" "$mg")"
  n_export="$(grep -cF -- "gate_export_screenshots $leg \"\$derived/Results/$leg.xcresult\"" "$mg")"
  n_record="$(grep -cF -- "summary=\"\$summary screenshots-$leg=\$?\"" "$mg")"
  if [ "$n_bundle" = 1 ] && [ "$n_export" = 1 ] && [ "$n_record" = 1 ]; then
    sok "ss-wiring-$leg" "result bundle, export and recorded result each wired once"
  else
    sfail "ss-wiring-$leg" "bundle=$n_bundle export=$n_export record=$n_record in $mg"
  fi
done
if grep -qF -- "'--exclude=*.xcresult'" "$here/gate-lib.sh" && grep -qF -- "'--exclude=DerivedData'" "$here/gate-lib.sh"; then
  sok ss-mirror "the bundle stays out of the mirror (*.xcresult and DerivedData excluded)"
else
  sfail ss-mirror "the mirror filters no longer exclude *.xcresult or DerivedData"
fi

cd "$tmp"

# --- WP28 P4 (IMGMGR-451): the no-custom-glass-grep leg, on fixture trees. Every case runs the
# leg's REAL function (gate_no_custom_glass_leg) — the one bin/mac-gate.sh calls — so no copy of
# the scan can drift from what the gate runs.
gfail() { echo "FAIL $1: $2"; fail=1; }
gok() { echo "PASS $1: $2"; }
glass_fixture() {
  chmod -R u+rwx "$tmp/glass" 2>/dev/null; rm -rf "$tmp/glass"
  mkdir -p "$tmp/glass/.gate-artifacts" "$tmp/glass/Sources/App/Shell" "$tmp/glass/Sources/Widget" \
    "$tmp/glass/Sources/Shared" "$tmp/glass/Tests/UI" "$tmp/glass/Packages/API/Sources" "$tmp/glass/Support"
  cat > "$tmp/glass/project.yml" <<'YML'
name: Fixture
options:
  deploymentTarget:
    iOS: "26.0"
packages:
  API:
    path: Packages/API
targets:
  # a comment at target indentation
  App:
    type: application
    deploymentTarget: "26.0"
    sources:
      - path: Sources/App
    info:
      path: Support/Info.plist
  Widget:
    sources:
      - path: Sources/Widget
      - path: Sources/Shared/Model.swift   # the widget compiles this ONE shared file
    type: app-extension
  AppTests:
    type: bundle.unit-test
    sources:
      - path: Tests/UI
YML
  printf 'import SwiftUI\n/// custom `glassEffect` — the chrome is the system'"'"'s.\nstruct A: View { var body: some View { Text("a").background(.bar) } }\n' > "$tmp/glass/Sources/App/Shell/A.swift"
  printf 'import SwiftUI\nstruct W {}\n' > "$tmp/glass/Sources/Widget/W.swift"
  printf 'struct Model {}\n' > "$tmp/glass/Sources/Shared/Model.swift"
  printf 'struct Other {}\n' > "$tmp/glass/Sources/Shared/Other.swift"
  printf 'let api = 1\n' > "$tmp/glass/Packages/API/Sources/API.swift"
  printf 'let t = 1\n' > "$tmp/glass/Tests/UI/T.swift"
  printf '<plist><dict><key>CFBundleName</key><string>x</string></dict></plist>\n' > "$tmp/glass/Support/Info.plist"
}
glass_line() {
  ( cd "$tmp/glass" && summary="" && gate_no_custom_glass_leg ) > "$tmp/glass.out" 2>&1
  grep -m1 '^no-custom-glass-grep exit=' "$tmp/glass.out"
}
glass_case() { # $1=case $2=expected rc $3=file $4=content (appended)
  glass_fixture
  printf '%s\n' "$4" >> "$tmp/glass/$3"
  check "$1" "$2" "$(glass_line)"
}
glass_fixture
check g-clean 0 "$(glass_line)"
paths="$(cd "$tmp/glass" && gate_compiled_source_paths project.yml | tr '\n' ' ')"
if [ "$paths" = "Packages/API Sources/App Sources/Widget Sources/Shared/Model.swift " ]; then
  gok g-paths "app + widget sources and the local package, test target excluded: $paths"
else
  gfail g-paths "got '$paths'"
fi
glass_case g-call 1 Sources/App/Shell/A.swift 'let v = Text("x").glassEffect()'
glass_case g-space 1 Sources/App/Shell/A.swift 'let v = Text("x").glassEffect (.regular)'
glass_case g-tab 1 Sources/App/Shell/A.swift "$(printf 'let v = Text("x").glassEffect\t(in: .capsule)')"
# Codex P4 r1 blocker 1: the call split before its `(` across a newline is a hit — the scan reads
# each file whole, not line by line.
glass_case g-newline 1 Sources/App/Shell/A.swift "$(printf 'let v = Text("x").glassEffect\n    (.regular)')"
glass_case g-newline-crlf 1 Sources/App/Shell/A.swift "$(printf 'let v = Text("x").glassEffect\r\n\t(.regular)')"
glass_case g-newline-button 1 Sources/Widget/W.swift "$(printf 'let b = Button("b") {}.buttonStyle(\n  .glass)')"
glass_case g-newline-line 1 Sources/App/Shell/A.swift "$(printf 'let a = 1\nlet v = Text("x")\n  .glassEffect\n  (.regular)')"
if grep -q '^Sources/App/Shell/A.swift:6:glassEffect (' "$tmp/glass/.gate-artifacts/no-custom-glass-grep.log"; then
  gok g-newline-evidence "the hit names the file and the line the call starts on"
else
  gfail g-newline-evidence "$(grep -m3 'glassEffect' "$tmp/glass/.gate-artifacts/no-custom-glass-grep.log" | tr '\n' '|')"
fi
glass_fixture
check g-no-perl 2 "$(GATE_PERL=/nonexistent/perl glass_line)"
glass_case g-suffix 1 Sources/App/Shell/A.swift 'let v = Text("x").glassEffectID("a", in: ns)'
glass_case g-container 1 Sources/App/Shell/A.swift 'let c = GlassEffectContainer { EmptyView() }'
glass_case g-button 1 Sources/App/Shell/A.swift 'let b = Button("b") {}.buttonStyle(.glass)'
glass_case g-button-space 1 Sources/App/Shell/A.swift 'let b = Button("b") {}.buttonStyle( .glassProminent )'
glass_case g-button-type 1 Sources/App/Shell/A.swift 'let b = Button("b") {}.buttonStyle(GlassButtonStyle())'
# Comments are blanked (one space, their newlines kept) before matching, as Swift's lexer treats
# them: a comment between the tokens of a real call hides nothing, and a call spelled only inside
# a comment draws nothing, so it is green. String literals are scanned VERBATIM: a mention inside
# one stays red (it may be interpolated code, and a lexer mistake there can then only add a hit,
# never hide one) — reword the string.
glass_case g-comment 0 Sources/App/Shell/A.swift '// never: .glassEffect(.clear) — a comment spelling the call draws nothing'
glass_case g-block-comment-only 0 Sources/App/Shell/A.swift '/* .glassEffect(.clear), .buttonStyle(.glass), GlassButtonStyle() */ let a = 1'
glass_case g-doc-comment-only 0 Sources/App/Shell/A.swift "$(printf '/// Never `.glassEffect(.regular)`:\n/// the bars are the system%ss.\nlet a = 1' "'")"
glass_case g-string 1 Sources/App/Shell/A.swift 'let s = "glassEffect("'
glass_case g-comment-button 1 Sources/App/Shell/A.swift 'let b = Button("b") {}.buttonStyle(/* note */ .glass)'
glass_case g-comment-call 1 Sources/App/Shell/A.swift 'let v = Text("x").glassEffect /* note */ (.regular)'
glass_case g-comment-nested 1 Sources/App/Shell/A.swift 'let v = Text("x").glassEffect /* a /* nested */ b */ (.regular)'
glass_case g-comment-newline 1 Sources/App/Shell/A.swift "$(printf 'let v = Text("x").glassEffect // note\n  (.regular)')"
glass_case g-comment-button-newline 1 Sources/Widget/W.swift "$(printf 'let b = Button("b") {}.buttonStyle( // note\n  /* more */ .glass)')"
# A "//" or "/*" inside a literal is not a comment: the real call after it is still a hit.
glass_case g-url-string 1 Sources/App/Shell/A.swift 'let u = "https://example.com"; let v = Text("x").glassEffect()'
glass_case g-open-in-string 1 Sources/App/Shell/A.swift 'let s = "/*"; let v = Text("x").glassEffect(); let t = "*/"'
glass_case g-escaped-quote 1 Sources/App/Shell/A.swift 'let s = "a\"//"; let v = Text("x").glassEffect()'
glass_case g-raw-string 1 Sources/App/Shell/A.swift 'let s = #"a"b//"#; let v = Text("x").glassEffect()'
glass_case g-interpolation 1 Sources/App/Shell/A.swift 'let s = "\("//")"; let v = Text("x").glassEffect()'
glass_case g-multiline-string 1 Sources/App/Shell/A.swift "$(printf '%s\n' 'let s = """' '  a "q" // /* not comments' '  """' 'let v = Text("x").glassEffect()')"
glass_case g-multiline-quote 1 Sources/App/Shell/A.swift "$(printf '%s\n' 'let s = """' '  a " b' '  """; let v = Text("x").glassEffect /* n */ (.regular)')"
glass_case g-regex-extended 1 Sources/App/Shell/A.swift 'let r = #/a//b/#; let v = Text("x").glassEffect()'
glass_case g-regex-quote 1 Sources/App/Shell/A.swift 'let r = /"/; let u = "http://x"; let v = Text("x").glassEffect()'
glass_case g-regex-escaped-slash 1 Sources/App/Shell/A.swift 'let r = /a\//; let v = Text("x").glassEffect()'
glass_case g-raw-identifier 1 Sources/App/Shell/A.swift 'func `a//b`() {}; let v = Text("x").glassEffect()'
# A file the lexer cannot close cleanly (an unterminated comment or string, which Swift refuses)
# is scanned raw as well: a lexer mistake widens the scan, it never narrows it.
glass_case g-unclean-lex 1 Sources/App/Shell/A.swift "$(printf '/* never closed\nlet v = Text("x").glassEffect()')"
glass_fixture
printf '%s\n' 'let a = 1 /* one' 'two */' 'let v = Text("x")' '  .glassEffect /* x */ (.regular)' >> "$tmp/glass/Sources/App/Shell/A.swift"
check g-comment-line-number 1 "$(glass_line)"
if grep -q '^Sources/App/Shell/A.swift:7:glassEffect ($' "$tmp/glass/.gate-artifacts/no-custom-glass-grep.log"; then
  gok g-comment-line-evidence "a blanked comment keeps its newlines: the hit names the call's own line"
else
  gfail g-comment-line-evidence "$(grep -m3 'glassEffect' "$tmp/glass/.gate-artifacts/no-custom-glass-grep.log" | tr '\n' '|')"
fi
glass_case g-widget-file 1 Sources/Shared/Model.swift 'let v = Text("x").glassEffect()'
glass_case g-widget-dir 1 Sources/Widget/W.swift 'let v = GlassEffectContainer {}'
glass_case g-package 1 Packages/API/Sources/API.swift 'let v = Text("x").glassEffect()'
glass_case g-not-compiled 0 Sources/Shared/Other.swift 'let v = Text("x").glassEffect()'
glass_case g-test-target 0 Tests/UI/T.swift 'let v = Text("x").glassEffect()'
glass_case g-plist 1 Support/Info.plist '<!-- <key>UIDesignRequiresCompatibility</key><true/> -->'
glass_case g-yml 1 project.yml '# INFOPLIST_KEY_UIDesignRequiresCompatibility: YES'
glass_fixture
printf 'name: X\noptions:\n  deploymentTarget:\n    iOS: "26.0"\ntargets:\n  T:\n    type: bundle.unit-test\n    sources:\n      - path: Sources/App\n' > "$tmp/glass/project.yml"
check g-no-paths 2 "$(glass_line)"
glass_fixture
sed -i.bak 's#- path: Sources/Widget$#- path: Sources/Gone#' "$tmp/glass/project.yml" && rm -f "$tmp/glass/project.yml.bak"
check g-missing-path 2 "$(glass_line)"
glass_fixture
sed -i.bak 's/import SwiftUI/import Foundation/' "$tmp/glass/Sources/App/Shell/A.swift" "$tmp/glass/Sources/Widget/W.swift" && rm -f "$tmp/glass/Sources/App/Shell/A.swift.bak" "$tmp/glass/Sources/Widget/W.swift.bak"
check g-no-control 1 "$(glass_line)"
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP g-scan-error: running as root, an unreadable directory cannot be induced"
else
  glass_fixture
  mkdir "$tmp/glass/Sources/App/Locked"; printf 'x\n' > "$tmp/glass/Sources/App/Locked/L.swift"
  chmod 000 "$tmp/glass/Sources/App/Locked"
  check g-scan-error 2 "$(glass_line)"
  chmod 755 "$tmp/glass/Sources/App/Locked"
  # Fold round 2 (Codex d2, D5): a FILE the scan cannot read is a scan error too, never "no hit".
  glass_fixture
  printf 'let v = Text("x").glassEffect()\n' > "$tmp/glass/Sources/App/Shell/Locked.swift"
  chmod 000 "$tmp/glass/Sources/App/Shell/Locked.swift"
  check g-unreadable-file 2 "$(glass_line)"
  chmod 644 "$tmp/glass/Sources/App/Shell/Locked.swift"
  glass_fixture
  printf 'let v = 1\n' > "$tmp/glass/Sources/App/Shell/Quiet.swift"
  chmod 000 "$tmp/glass/Sources/App/Shell/Quiet.swift"
  check g-unreadable-clean-file 2 "$(glass_line)"
  chmod 644 "$tmp/glass/Sources/App/Shell/Quiet.swift"
fi
# A read or a close that fails AFTER the open succeeded (an I/O error on this host cannot be
# induced, so perl's own readline/close are overridden): still a scan error, never "no hit".
mkdir -p "$tmp/perlfail"
printf 'package ReadFail;\nBEGIN { *CORE::GLOBAL::readline = sub { $! = 5; return undef } }\n1;\n' \
  > "$tmp/perlfail/ReadFail.pm"
printf 'package CloseFail;\nBEGIN { *CORE::GLOBAL::close = sub (;*) { CORE::close($_[0]); $! = 5; 0 } }\n1;\n' \
  > "$tmp/perlfail/CloseFail.pm"
glass_fixture
check g-read-error 2 "$(PERL5LIB="$tmp/perlfail" PERL5OPT=-MReadFail glass_line)"
glass_fixture
check g-close-error 2 "$(PERL5LIB="$tmp/perlfail" PERL5OPT=-MCloseFail glass_line)"
# A read that returns only part of the file (the rest lost to an I/O error): a scan error too.
printf 'package ShortRead;\nBEGIN { *CORE::GLOBAL::readline = sub { my $t = CORE::readline($_[0]); defined $t ? substr($t, 0, int(length($t) / 2)) : $t } }\n1;\n' \
  > "$tmp/perlfail/ShortRead.pm"
glass_fixture
check g-short-read 2 "$(PERL5LIB="$tmp/perlfail" PERL5OPT=-MShortRead glass_line)"
# The real tree: this repo's own project.yml, sources and package, copied (the leg writes its
# evidence into .gate-artifacts/, which must not land in the checkout) — green, with the widget's
# listed files among the scanned paths.
rm -rf "$tmp/realtree"; mkdir -p "$tmp/realtree/.gate-artifacts"
cp "$here/../project.yml" "$here/../signing.default.yml" "$tmp/realtree/"
cp -R "$here/../Sources" "$here/../Packages" "$tmp/realtree/"
real_line="$( (cd "$tmp/realtree" && summary="" && gate_no_custom_glass_leg) 2>&1 | grep -m1 '^no-custom-glass-grep exit=')"
real_paths="$(cd "$tmp/realtree" && gate_compiled_source_paths project.yml | tr '\n' ' ')"
case "$real_line|$real_paths" in
  "no-custom-glass-grep exit=0|"*"Sources/ImgManager "*"Sources/ImgManagerWidget "*"Sources/ImgManager/Queue/QueueModels.swift "*)
    gok g-real-tree "this repo is green and the widget's own files are scanned: $real_paths" ;;
  *) gfail g-real-tree "line='$real_line' paths='$real_paths'" ;;
esac
mg_legs="$(sed -n 's/^    for leg in \(xcodegen .*\); do$/\1/p' "$mg")"
case " $GATE_LEGS_ALL " in *" ui-orientation-base-grep no-custom-glass-grep lint "*) reg=1 ;; *) reg=0 ;; esac
n_call="$(grep -c '^  gate_no_custom_glass_leg$' "$mg")"
n_want="$(grep -c '^if want no-custom-glass-grep; then$' "$mg")"
case " $mg_legs " in *" no-custom-glass-grep "*) ff=1 ;; *) ff=0 ;; esac
if [ "$reg" = 1 ] && [ "$n_call" = 1 ] && [ "$n_want" = 1 ] && [ "$ff" = 1 ]; then
  gok g-wiring "registered after ui-orientation-base-grep, one guarded call in the remote script, in the fail-fast skip list"
else
  gfail g-wiring "registry=$reg call=$n_call guard=$n_want failfast=$ff"
fi

# --- WP28 P4 (IMGMGR-451): the materials matrix. The manifest's own shape, the check over
# exported attachments (stub manifest.json files), and the mode runner against stub tools.
# WP30 P1 (IMGMGR-456) added the loupe to both destinations: 21 per destination, 42 names.
# WP30 P3 (IMGMGR-458) added Compare on the iPad only: 21 iPhone + 24 iPad, 45 names.
# R3-18 (IMGMGR-550) removed search-active on both destinations: 18 iPhone + 21 iPad, 39 names.
man="$here/../Tests/ImgManagerUITests/MaterialsScreenshotManifest.txt"
man_shape=1
[ "$(grep -c '^iphone-.*\.png$' "$man")" = 18 ] || man_shape=0
[ "$(grep -c '^ipad-.*\.png$' "$man")" = 21 ] || man_shape=0
for s in shoots-home library grid-pushed inspector-sheet summary-sheet loupe; do
  for m in default reduce-transparency increase-contrast; do grep -qx "iphone-$s-$m.png" "$man" || man_shape=0; done
done
for s in regular3-collapsed regular3-inspector regular2-grid summary-sheet select-bar \
  regular2-loupe regular2-compare; do
  for m in default reduce-transparency increase-contrast; do grep -qx "ipad-$s-$m.png" "$man" || man_shape=0; done
done
[ "$(grep -vc '^#' "$man")" = 39 ] || man_shape=0
if [ "$man_shape" = 1 ]; then gok ms-manifest "39 names, 18 iPhone + 21 iPad, every surface in all three modes"; else gfail ms-manifest "the manifest is not the plan's 39-name matrix"; fi
ms_fixture() {
  rm -rf "$tmp/ms"; mkdir -p "$tmp/ms/.gate-artifacts/screenshots/test-iphone" \
    "$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-reduce-transparency" \
    "$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-increase-contrast"
  printf '# fixture\niphone-home-default.png\niphone-home-reduce-transparency.png\niphone-home-increase-contrast.png\niphone-grid-default.png\niphone-grid-reduce-transparency.png\niphone-grid-increase-contrast.png\n' > "$tmp/ms/manifest.txt"
  ms_dir() { # $1 dir suffix, $2 mode
    d="$tmp/ms/.gate-artifacts/screenshots/$1"
    printf '[{"testIdentifier":"M/t()","attachments":[' > "$d/manifest.json"
    printf '{"exportedFileName":"U1-%s.png","suggestedHumanReadableName":"iphone-home-%s_0_ABCD.png"},' "$2" "$2" >> "$d/manifest.json"
    printf '{"exportedFileName":"U2-%s.png","suggestedHumanReadableName":"iphone-grid-%s_0_EF01.png"},' "$2" "$2" >> "$d/manifest.json"
    printf '{"exportedFileName":"U3.png","suggestedHumanReadableName":"IMGMGR-450-other_0_1.png"}]}]' >> "$d/manifest.json"
    printf 'home-%s' "$2" > "$d/U1-$2.png"; printf 'grid-%s' "$2" > "$d/U2-$2.png"; printf 'x' > "$d/U3.png"
  }
  ms_dir test-iphone default
  ms_dir materials-test-iphone-reduce-transparency reduce-transparency
  ms_dir materials-test-iphone-increase-contrast increase-contrast
}
ms_line() { (cd "$tmp/ms" && gate_check_materials_manifest "${1:-iphone}" test-iphone manifest.txt) 2>&1 | grep -m1 '^materials-manifest '; }
ms_fixture
line="$(ms_line)"
if [ "$line" = "materials-manifest test-iphone exit=0 named=6" ] \
  && [ "$(cat "$tmp/ms/.gate-artifacts/screenshots/materials/iphone-grid-increase-contrast.png")" = grid-increase-contrast ]; then
  gok ms-green "every name resolved from its attachment and copied under its manifest name: $line"
else
  gfail ms-green "line='$line'"
fi
ms_fixture; rm "$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-reduce-transparency/U2-reduce-transparency.png"
check ms-missing-file 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; rm -rf "$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-increase-contrast"
check ms-missing-mode 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; : > "$tmp/ms/.gate-artifacts/screenshots/test-iphone/U1-default.png"
check ms-empty 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; printf 'home-default' > "$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-reduce-transparency/U1-reduce-transparency.png"
check ms-identical 1 "$(ms_line | sed 's/ named=.*//')"
if grep -q '^IDENTICAL iphone-home-reduce-transparency.png == iphone-home-default.png' "$tmp/ms/.gate-artifacts/materials-manifest-test-iphone.log"; then
  gok ms-identical-names "the identical pair is named in the log"
else
  gfail ms-identical-names "no IDENTICAL line for the pair"
fi
ms_fixture; printf '{not json' > "$tmp/ms/.gate-artifacts/screenshots/test-iphone/manifest.json"
check ms-bad-json 2 "$(ms_line | sed 's/ named=.*//')"
ms_fixture
check ms-no-lines 3 "$(ms_line ipad | sed 's/ named=.*//')"
ms_fixture
line="$( (cd "$tmp/ms" && GATE_PYTHON="$tmp/no-such-python" gate_check_materials_manifest iphone test-iphone manifest.txt) 2>&1 | grep -m1 '^materials-manifest ')"
case "$line" in "materials-manifest test-iphone exit=0 "*|"") gfail ms-no-python "line='$line'" ;; *) gok ms-no-python "a missing interpreter is red: $line" ;; esac

# Fold round 1 (gate on 832e6f1, G1): the plan's fallback rule. A Reduce Transparency run that
# does not read back records a marker and captures nothing; the check lets THAT mode's names be
# absent for THAT destination only, and nothing else.
ms_rt="$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-reduce-transparency"
ms_runfile="$tmp/ms/.gate-artifacts/materials-test-iphone-reduce-transparency.run"
ms_reading='["reduceTransparency": "0", "envReduceTransparency": "0", "darkerSystemColors": "0", "envIncreasedContrast": "0"]'
# $1 = marker attachment stem ('' for none), $2 = the marker's content (default: this run's token,
# the unread reading). The run record says TOK-1. The RT shots are removed from the export.
ms_unresolved_rt() {
  printf 'TOK-1\n' > "$ms_runfile"
  printf '[{"testIdentifier":"M/t()","attachments":[' > "$ms_rt/manifest.json"
  if [ -n "$1" ]; then
    printf '{"exportedFileName":"UM.txt","suggestedHumanReadableName":"%s_0_9A9A.txt"}' "$1" >> "$ms_rt/manifest.json"
    printf '%s' "${2-dest=iphone mode=reduce-transparency run=TOK-1 surface=shoots-home reading=$ms_reading}" > "$ms_rt/UM.txt"
  fi
  printf ']}]' >> "$ms_rt/manifest.json"
  rm -f "$ms_rt"/U1-* "$ms_rt"/U2-*
}
ms_log="$tmp/ms/.gate-artifacts/materials-manifest-test-iphone.log"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency
line="$(ms_line)"
if [ "$line" = "materials-manifest test-iphone exit=0 named=4 unresolved=2" ] \
  && grep -q '^UNRESOLVED iphone-home-reduce-transparency.png ' "$ms_log" \
  && grep -q '^UNRESOLVED iphone-grid-reduce-transparency.png ' "$ms_log" \
  && grep -q 'run=TOK-1' "$tmp/ms/.gate-artifacts/screenshots/materials/materials-unresolved-iphone-reduce-transparency.txt"; then
  gok ms-unresolved-marker "this run's RT marker lets ALL the RT names be absent, each printed UNRESOLVED, marker kept: $line"
else
  gfail ms-unresolved-marker "line='$line' log: $(tr '\n' '|' < "$ms_log")"
fi
ms_fixture; ms_unresolved_rt ''
check ms-unresolved-no-marker 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-ipad-reduce-transparency
check ms-unresolved-other-dest 1 "$(ms_line | sed 's/ named=.*//')"
# Fold round 2 (Codex d2, D4): provenance and all-or-nothing.
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency; printf 'TOK-2\n' > "$ms_runfile"
check ms-stale-marker 1 "$(ms_line | sed 's/ named=.*//')"
if grep -q '^BADMARKER materials-unresolved-iphone-reduce-transparency (does not carry this run' "$ms_log"; then
  gok ms-stale-marker-named "a marker from another run (token TOK-1, run record TOK-2) is BADMARKER"
else
  gfail ms-stale-marker-named "log: $(tr '\n' '|' < "$ms_log")"
fi
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency; printf 'TOK\n' > "$ms_runfile"
check ms-token-prefix 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency; rm -f "$ms_runfile"
check ms-no-run-record 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency ''
check ms-marker-empty 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency \
  'dest=iphone mode=reduce-transparency run=TOK-1 surface=shoots-home reading=["reduceTransparency": "1", "envReduceTransparency": "1"]'
check ms-marker-rt-true 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency
ms_dir materials-test-iphone-reduce-transparency reduce-transparency
sed 's/]}]$/,{"exportedFileName":"UM.txt","suggestedHumanReadableName":"materials-unresolved-iphone-reduce-transparency_0_1.txt"}]}]/' "$ms_rt/manifest.json" > "$ms_rt/m2" && mv "$ms_rt/m2" "$ms_rt/manifest.json"
check ms-mixed 1 "$(ms_line | sed 's/ named=.*//')"
if grep -q '^MIXED materials-unresolved-iphone-reduce-transparency: 2 shot' "$ms_log"; then
  gok ms-mixed-named "a marker beside a captured RT shot is MIXED, not a partial waiver"
else
  gfail ms-mixed-named "log: $(tr '\n' '|' < "$ms_log")"
fi
ms_fixture; ms_unresolved_rt ''
d0="$tmp/ms/.gate-artifacts/screenshots/test-iphone"
sed 's/]}]$/,{"exportedFileName":"UM.txt","suggestedHumanReadableName":"materials-unresolved-iphone-reduce-transparency_0_1.txt"}]}]/' "$d0/manifest.json" > "$d0/m2" && mv "$d0/m2" "$d0/manifest.json"
printf 'dest=iphone mode=reduce-transparency run=TOK-1 surface=x reading=%s' "$ms_reading" > "$d0/UM.txt"
check ms-marker-wrong-export 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt ''
printf -- '--- materials reduce-transparency run 1 ---\nMATERIALS-UNRESOLVED dest=iphone mode=reduce-transparency run=TOK-0 %s\nPIVOT\n--- materials reduce-transparency run 2 ---\nMATERIALS-UNRESOLVED dest=iphone mode=reduce-transparency run=TOK-1 %s\n' "$ms_reading" "$ms_reading" \
  > "$tmp/ms/.gate-artifacts/materials-test-iphone-reduce-transparency.log"
line="$(ms_line)"
if [ "$line" = "materials-manifest test-iphone exit=0 named=4 unresolved=2" ] \
  && grep -q "^MARKER materials-unresolved-iphone-reduce-transparency.txt from the mode's last-run log line (run TOK-1)" "$ms_log"; then
  gok ms-unresolved-log "no exported attachment: the last run's MATERIALS-UNRESOLVED line, with this run's token, is the marker: $line"
else
  gfail ms-unresolved-log "line='$line' log: $(tr '\n' '|' < "$ms_log")"
fi
ms_fixture; ms_unresolved_rt ''
printf -- '--- materials reduce-transparency run 1 ---\nMATERIALS-UNRESOLVED dest=iphone mode=reduce-transparency run=TOK-1 %s\nPIVOT\n--- materials reduce-transparency run 2 ---\nTest Suite passed\n' "$ms_reading" \
  > "$tmp/ms/.gate-artifacts/materials-test-iphone-reduce-transparency.log"
check ms-unresolved-log-stale 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt ''
printf -- 'MATERIALS-UNRESOLVED dest=iphone mode=reduce-transparency run=TOK-1 %s\n' "$ms_reading" \
  > "$tmp/ms/.gate-artifacts/materials-test-iphone-reduce-transparency.log"
check ms-unresolved-log-no-header 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt ''
printf -- '--- materials reduce-transparency run 1 ---\n  Skipped: MATERIALS-UNRESOLVED dest=iphone mode=reduce-transparency run=TOK-1 %s\n' "$ms_reading" \
  > "$tmp/ms/.gate-artifacts/materials-test-iphone-reduce-transparency.log"
check ms-unresolved-log-anchored 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency
: > "$tmp/ms/.gate-artifacts/screenshots/test-iphone/U2-default.png"
check ms-unresolved-still-empty 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture; ms_unresolved_rt materials-unresolved-iphone-reduce-transparency
rm "$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-increase-contrast/U1-increase-contrast.png"
check ms-unresolved-other-missing 1 "$(ms_line | sed 's/ named=.*//')"
# The escape is Reduce Transparency's alone: a marker for Increase Contrast or the default mode is
# red — by attachment or by log line — even when every shot is present.
ms_ic="$tmp/ms/.gate-artifacts/screenshots/materials-test-iphone-increase-contrast"
ms_fixture
printf '[{"testIdentifier":"M/t()","attachments":[{"exportedFileName":"UM.txt","suggestedHumanReadableName":"materials-unresolved-iphone-increase-contrast_0_1.txt"}]}]' > "$ms_ic/manifest.json"
printf 'darkerSystemColors=0' > "$ms_ic/UM.txt"
check ms-marker-ic 1 "$(ms_line | sed 's/ named=.*//')"
if grep -q '^BADMARKER materials-unresolved-iphone-increase-contrast ' "$ms_log" && ! grep -q '^UNRESOLVED ' "$ms_log"; then
  gok ms-marker-ic-named "an increase-contrast marker is BADMARKER and excuses nothing"
else
  gfail ms-marker-ic-named "log: $(tr '\n' '|' < "$ms_log")"
fi
ms_fixture
printf -- '--- materials increase-contrast run 1 ---\nMATERIALS-UNRESOLVED dest=iphone mode=increase-contrast ["darkerSystemColors": "0"]\n' \
  > "$tmp/ms/.gate-artifacts/materials-test-iphone-increase-contrast.log"
check ms-marker-ic-log 1 "$(ms_line | sed 's/ named=.*//')"
ms_fixture
d0="$tmp/ms/.gate-artifacts/screenshots/test-iphone"
sed 's/]}]$/,{"exportedFileName":"UM.txt","suggestedHumanReadableName":"materials-unresolved-iphone-default_0_1.txt"}]}]/' "$d0/manifest.json" > "$d0/m2" && mv "$d0/m2" "$d0/manifest.json"
printf 'reduceTransparency=0' > "$d0/UM.txt"
check ms-marker-default 1 "$(ms_line | sed 's/ named=.*//')"

# The mode runner, against stub xcrun/xcodebuild/xcresulttool that log every argument.
cat > "$tmp/stub-xcrun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in *"${STUB_XCRUN_FAIL:-no-such-args}"*) echo "stub xcrun refusal" >&2; exit 71 ;; esac
exit 0
STUB
cat > "$tmp/stub-xcodebuild" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
printf 'xcodebuild mode=%s %s\n' "${TEST_RUNNER_IMG_MATERIALS_MODE:-unset}" "$*" >> "$STUB_LOG"
bundle=""; while [ $# -gt 0 ]; do case "$1" in -resultBundlePath) bundle="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$bundle"
printf 'stub-run-token=%s\n' "${TEST_RUNNER_IMG_MATERIALS_RUN:-unset}" >> "$STUB_LOG"
if [ "$n" -le "${STUB_UNRESOLVED_RUNS:-0}" ]; then echo "MATERIALS-UNRESOLVED dest=stub mode=$TEST_RUNNER_IMG_MATERIALS_MODE run=$TEST_RUNNER_IMG_MATERIALS_RUN [\"reduceTransparency\": \"0\"]"; exit "${STUB_UNRESOLVED_RC:-0}"; fi
if [ "$n" -le "${STUB_MISMATCH_RUNS:-0}" ]; then echo "  error: MATERIALS-READBACK-MISMATCH mode=$TEST_RUNNER_IMG_MATERIALS_MODE"; exit 65; fi
exit "${STUB_XCODEBUILD_RC:-0}"
STUB
chmod +x "$tmp/stub-xcrun" "$tmp/stub-xcodebuild"
mr_run() { # $1 leg $2 udid $3 mode ; env STUB_* set by caller
  rm -f "$tmp/mr.count"
  (cd "$tmp/mr" && GATE_XCRUN="$tmp/stub-xcrun" GATE_XCODEBUILD="$tmp/stub-xcodebuild" \
    GATE_XCRESULTTOOL="$tmp/stub-xcresulttool" STUB_LOG="$tmp/mr.calls" STUB_COUNT="$tmp/mr.count" \
    gate_materials_mode_run "$1" "$2" "$3" "$tmp/mr/DerivedData")
}
rm -rf "$tmp/mr"; mkdir -p "$tmp/mr/.gate-artifacts"; : > "$tmp/mr.calls"
line="$(mr_run test-iphone UDID-A reduce-transparency)"; rc=$?
calls="$(cat "$tmp/mr.calls")"
case "$rc|$line" in
  "0|materials-test-iphone-reduce-transparency exit=0 (runs=1 reset=0 export=0)")
    if printf '%s\n' "$calls" | grep -qx 'simctl bootstatus UDID-A -b' \
      && printf '%s\n' "$calls" | grep -qx 'simctl spawn UDID-A defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool true' \
      && printf '%s\n' "$calls" | grep -qx 'simctl spawn UDID-A defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool true' \
      && printf '%s\n' "$calls" | grep -qx 'simctl spawn UDID-A defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool false' \
      && printf '%s\n' "$calls" | grep -q '^xcodebuild mode=reduce-transparency test-without-building .*-destination id=UDID-A .*-only-testing:ImgManagerUITests/MaterialsScreenshotUITests' \
      && printf '%s\n' "$calls" | grep -qx 'simctl spawn UDID-A defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool false' \
      && [ -f "$tmp/mr/.gate-artifacts/screenshots/materials-test-iphone-reduce-transparency/manifest.json" ]; then
      gok mr-green "set on UDID-A, suite alone with the mode in the runner env, reset, exported: $line"
    else
      gfail mr-green "calls: $(printf '%s' "$calls" | tr '\n' '|')"
    fi ;;
  *) gfail mr-green "rc=$rc line='$line'" ;;
esac
: > "$tmp/mr.calls"
line="$(STUB_XCODEBUILD_RC=65 mr_run test-iphone UDID-A increase-contrast)"; rc=$?
if [ "$rc" = 65 ] && grep -qx 'simctl ui UDID-A increase_contrast disabled' "$tmp/mr.calls"; then
  gok mr-fail-resets "a red suite is returned (65) and the setting is still reset: $line"
else
  gfail mr-fail-resets "rc=$rc line='$line' calls: $(tr '\n' '|' < "$tmp/mr.calls")"
fi
: > "$tmp/mr.calls"
line="$(STUB_UNRESOLVED_RUNS=1 mr_run test-ipad UDID-B reduce-transparency)"; rc=$?
if [ "$rc" = 0 ] && grep -qx 'simctl spawn UDID-B notifyutil -p com.apple.accessibility.cache.reduce.transparency' "$tmp/mr.calls" \
  && [ "$line" = "materials-test-ipad-reduce-transparency exit=0 (runs=2 reset=0 export=0)" ] \
  && [ "$(grep -c '^xcodebuild ' "$tmp/mr.calls")" = 2 ] && grep -q '^PIVOT' "$tmp/mr/.gate-artifacts/materials-test-ipad-reduce-transparency.log"; then
  gok mr-pivot "an UNRESOLVED run posts the cache notification and runs ONCE more, which took: $line"
else
  gfail mr-pivot "rc=$rc line='$line' calls: $(tr '\n' '|' < "$tmp/mr.calls")"
fi
: > "$tmp/mr.calls"
line="$(STUB_UNRESOLVED_RUNS=2 mr_run test-ipad UDID-B reduce-transparency)"; rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c '^xcodebuild ' "$tmp/mr.calls")" = 2 ] \
  && [ "$line" = "materials-test-ipad-reduce-transparency exit=0 (runs=2 reset=0 export=0) UNRESOLVED: the setting did not read back after the pivot; nothing captured" ]; then
  gok mr-pivot-bounded "still UNRESOLVED after the pivot: exactly two runs, not a red leg, said so: $line"
else
  gfail mr-pivot-bounded "rc=$rc line='$line'"
fi
: > "$tmp/mr.calls"
line="$(STUB_UNRESOLVED_RUNS=1 mr_run test-ipad UDID-B increase-contrast)"; rc=$?
if [ "$line" = "materials-test-ipad-increase-contrast exit=0 (runs=1 reset=0 export=0)" ] \
  && [ "$(grep -c '^xcodebuild ' "$tmp/mr.calls")" = 1 ] && ! grep -q notifyutil "$tmp/mr.calls"; then
  gok mr-pivot-rt-only "the pivot and the UNRESOLVED note are Reduce Transparency's alone (the manifest check reds an IC marker): $line"
else
  gfail mr-pivot-rt-only "rc=$rc line='$line'"
fi
: > "$tmp/mr.calls"
line="$(STUB_UNRESOLVED_RUNS=1 STUB_UNRESOLVED_RC=65 mr_run test-ipad UDID-B reduce-transparency)"; rc=$?
if [ "$rc" = 65 ] && [ "$(grep -c '^xcodebuild mode=' "$tmp/mr.calls")" = 1 ] \
  && [ "$line" = "materials-test-ipad-reduce-transparency exit=65 (runs=1 reset=0 export=0)" ]; then
  gok mr-first-fails-stays-red "a run that failed beside an UNRESOLVED line is final: no pivot, no second run to erase it: $line"
else
  gfail mr-first-fails-stays-red "rc=$rc line='$line' calls: $(tr '\n' '|' < "$tmp/mr.calls")"
fi
: > "$tmp/mr.calls"
line="$(STUB_UNRESOLVED_RUNS=1 mr_run test-iphone UDID-A reduce-transparency)"; rc=$?
tok_file="$(cat "$tmp/mr/.gate-artifacts/materials-test-iphone-reduce-transparency.run" 2>/dev/null)"
tokens="$(sed -n 's/^stub-run-token=//p' "$tmp/mr.calls" | tr '\n' ' ')"
case "$tokens" in
  "test-iphone-reduce-transparency-"*"-1-"*" test-iphone-reduce-transparency-"*"-2-"*" ")
    if [ "$tokens" = "$(printf '%s ' "$(sed -n 's/^stub-run-token=//p' "$tmp/mr.calls" | head -1)" "$tok_file")" ]; then
      gok mr-token "each run gets its own token in the runner env; the run record holds the last one: $tok_file"
    else
      gfail mr-token "tokens='$tokens' record='$tok_file'"
    fi ;;
  *) gfail mr-token "tokens='$tokens' record='$tok_file'" ;;
esac
: > "$tmp/mr.calls"
line="$(STUB_MISMATCH_RUNS=1 mr_run test-ipad UDID-B reduce-transparency)"; rc=$?
if [ "$rc" = 65 ] && [ "$(grep -c '^xcodebuild mode=' "$tmp/mr.calls")" = 1 ] \
  && ! grep -q '^PIVOT' "$tmp/mr/.gate-artifacts/materials-test-ipad-reduce-transparency.log"; then
  gok mr-mismatch-no-pivot "any other read-back mismatch is a red suite and is not retried: $line"
else
  gfail mr-mismatch-no-pivot "rc=$rc line='$line'"
fi
: > "$tmp/mr.calls"
line="$(STUB_XCRUN_FAIL='increase_contrast enabled' mr_run test-iphone UDID-A increase-contrast)"; rc=$?
if [ "$rc" = 71 ] && ! grep -q '^xcodebuild ' "$tmp/mr.calls"; then
  gok mr-set-fails "a setting that cannot be applied is red and runs no suite: $line"
else
  gfail mr-set-fails "rc=$rc line='$line'"
fi
: > "$tmp/mr.calls"
line="$(STUB_XCRUN_FAIL='increase_contrast disabled' mr_run test-iphone UDID-A increase-contrast)"; rc=$?
case "$rc|$line" in
  "71|materials-test-iphone-increase-contrast exit=71 (runs=1 reset=71 export=0)") gok mr-reset-fails "a failed reset is red even after a green suite: $line" ;;
  *) gfail mr-reset-fails "rc=$rc line='$line' (a failed reset must not read as green)" ;;
esac
: > "$tmp/mr.calls"
line="$(STUB_RC=65 mr_run test-iphone UDID-A increase-contrast)"; rc=$?
case "$rc|$line" in
  "65|materials-test-iphone-increase-contrast exit=65 (runs=1 reset=0 export=65)") gok mr-export-fails "a failed export is red: $line" ;;
  *) gfail mr-export-fails "rc=$rc line='$line' (a failed export must not read as green)" ;;
esac
# Two legs, two simulators: every simctl call a leg makes names that leg's own device and no
# other, in every mode, pivot and reset included; each leg keeps its own log.
own_ok=1
for pair in test-iphone:UDID-A test-ipad:UDID-B; do
  leg="${pair%%:*}"; udid="${pair##*:}"
  : > "$tmp/mr.calls"
  STUB_UNRESOLVED_RUNS=1 mr_run "$leg" "$udid" reduce-transparency >/dev/null
  mr_run "$leg" "$udid" increase-contrast >/dev/null
  (cd "$tmp/mr" && GATE_XCRUN="$tmp/stub-xcrun" STUB_LOG="$tmp/mr.calls" gate_materials_reset "$udid")
  n_sim="$(grep -c '^simctl ' "$tmp/mr.calls")"
  foreign="$(grep '^simctl ' "$tmp/mr.calls" | grep -v "^simctl [a-z_]* $udid \|^simctl [a-z_]* $udid$" || true)"
  foreign_dest="$(grep '^xcodebuild ' "$tmp/mr.calls" | grep -v -- "-destination id=$udid " || true)"
  if [ "$n_sim" -lt 8 ] || [ -n "$foreign" ] || [ -n "$foreign_dest" ] \
    || [ ! -f "$tmp/mr/.gate-artifacts/materials-$leg-increase-contrast.log" ]; then
    own_ok=0
    gfail "mr-own-device-$leg" "simctl calls=$n_sim foreign: $(printf '%s' "$foreign$foreign_dest" | tr '\n' '|')"
  fi
done
[ "$own_ok" = 0 ] || gok mr-own-device "each leg's simctl calls (modes, pivot, resets) and its destination name only its own udid"
: > "$tmp/mr.calls"
(cd "$tmp/mr" && GATE_XCRUN="$tmp/stub-xcrun" STUB_LOG="$tmp/mr.calls" gate_materials_reset UDID-C); rc=$?
if [ "$rc" = 0 ] && grep -qx 'simctl ui UDID-C increase_contrast disabled' "$tmp/mr.calls" \
  && grep -qx 'simctl spawn UDID-C defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool false' "$tmp/mr.calls"; then
  gok mr-reset "the trap's reset turns both settings off on that one device"
else
  gfail mr-reset "rc=$rc calls: $(tr '\n' '|' < "$tmp/mr.calls")"
fi
# No fleet-wide simctl anywhere in the gate scripts (lane rule), and the remote script wires the
# modes, the manifest check and the trap's reset for BOTH legs by their exact call text.
if grep -nE 'simctl[^#]*[[:space:]]all([[:space:]]|$)' "$mg" "$here/gate-lib.sh" >/dev/null; then
  gfail mr-no-fleet "a fleet-wide simctl call: $(grep -nE 'simctl[^#]*[[:space:]]all([[:space:]]|$)' "$mg" "$here/gate-lib.sh" | head -3)"
else
  gok mr-no-fleet "no simctl call addresses all devices"
fi
for pair in test-iphone:iphone test-ipad:ipad; do
  leg="${pair%%:*}"; dest="${pair##*:}"
  n_mode="$(grep -cF -- "gate_materials_mode_run $leg \"\$${dest}_udid\" \"\$mode\" \"\$derived\"" "$mg")"
  n_check="$(grep -cF -- "gate_check_materials_manifest $dest $leg" "$mg")"
  n_reset="$(grep -cF -- "gate_materials_reset \"\$${dest}_udid\"" "$mg")"
  if [ "$n_mode" = 1 ] && [ "$n_check" = 1 ] && [ "$n_reset" = 1 ]; then
    gok "mr-wiring-$leg" "modes, manifest check and trap reset each wired once"
  else
    gfail "mr-wiring-$leg" "mode=$n_mode check=$n_check reset=$n_reset"
  fi
done
cd "$tmp"

case "$summary" in *"t-clean=0"*"t-hit=1"*"t-noctl=1"*) echo "PASS summary: $summary" ;; *) echo "FAIL summary: $summary"; fail=1 ;; esac
[ "$fail" -eq 0 ] && echo "gate-lib-test: ALL PASS" || echo "gate-lib-test: FAILURES"
exit "$fail"
