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

cd "$tmp"

case "$summary" in *"t-clean=0"*"t-hit=1"*"t-noctl=1"*) echo "PASS summary: $summary" ;; *) echo "FAIL summary: $summary"; fail=1 ;; esac
[ "$fail" -eq 0 ] && echo "gate-lib-test: ALL PASS" || echo "gate-lib-test: FAILURES"
exit "$fail"
