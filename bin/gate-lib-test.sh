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

cd "$tmp"

case "$summary" in *"t-clean=0"*"t-hit=1"*"t-noctl=1"*) echo "PASS summary: $summary" ;; *) echo "FAIL summary: $summary"; fail=1 ;; esac
[ "$fail" -eq 0 ] && echo "gate-lib-test: ALL PASS" || echo "gate-lib-test: FAILURES"
exit "$fail"
