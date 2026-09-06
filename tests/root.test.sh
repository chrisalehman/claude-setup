#!/bin/bash
# tests/root.test.sh — payload/scripts/lib/root.sh, the ONE reader for "which
# project root is this cwd in". bionic 1.4.0, wave-bionic-1.4.0-update slice
# L-ROOT, spec AC-10 (design-ledger S3 + C2).
#
# WHAT IS UNDER TEST. Two functions, sourced from the library:
#
#   project_root [cwd]             one absolute path on stdout, exit 0
#   project_root_candidates [cwd]  one line per considered path:
#                                  <path>TAB<tag>, tag drawn from
#                                  chosen | candidate | skipped-symlink |
#                                  above-home | git-toplevel-fallback |
#                                  cwd-fallback
#
# WHY IT EXISTS. Eight byte-identical `resolve_project_root` copies in hooks/
# ask git FIRST and walk for a `.bionic` ancestor only when no repository
# exists at all, so a git repo nested inside a plain `.bionic` workspace always
# resolves to itself — the split that R2 names (handoff §2.2). The library
# inverts it: the nearest ancestor holding a REAL `.bionic/` directory wins,
# wherever the git root is; a linked worktree is mapped onto its main
# repository before the walk begins; `$HOME` and everything above it are never
# candidates; a `.bionic` that is a symlink is never a root (C2).
#
# SIX TOPOLOGIES, BUILT FOR REAL — no mocked filesystem, no stubbed git. Every
# fixture below is `mkdir`, `git init`, `git worktree add` and `ln -s` under one
# `mktemp -d`, because the whole subject of this library is what is actually on
# disk. §1 nested repo under a non-git `.bionic` workspace; §2 linked worktree;
# §3 phantom nested `.bionic`; §4 symlinked `.bionic` with a real one above;
# §5 `.bionic` only inside an overridden `$HOME`; §6 unrelated repo with no
# `.bionic` at all. §7 adds the seventh shape the tag vocabulary needs — no git,
# no `.bionic` — because `cwd-fallback` is otherwise never exercised.
#
# ANTI-VACUITY BY DIFFERENTIAL CONTROL, not by mutation of the library
# (memory/no-vacuous-tests-at-authoring). A positive answer alone cannot tell a
# rule from a coincidence: §3 could pass because the phantom won OR because the
# walk never looked below the repo root and landed somewhere that happens to
# share the name. So each rule-bearing fixture is run TWICE, once with the
# feature and once with the feature removed, and the answer must MOVE:
#
#   §2b  the worktree gains its own real `.bionic`  → answer must still be main
#   §3b  the phantom `.bionic` is deleted           → answer must climb to proj
#   §4b  the symlink becomes a real directory       → answer must fall to repo
#   §5b  `$HOME` is moved out of the way            → the ignored dir must win
#
# A test that cannot go red for the right reason is not evidence, and each
# control is the same assertion run against a filesystem that differs in
# exactly the one bit the rule is about.
#
# HERMETIC. One `mktemp -d`, removed on exit; `HOME`, `GIT_CONFIG_GLOBAL` and
# `GIT_CONFIG_NOSYSTEM` overridden for every git call and every library call, so
# neither the machine's git config nor the maintainer's real home can reach any
# assertion. Nothing is written outside the sandbox.
#
# Usage: bash tests/root.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$REPO_ROOT/payload/scripts/lib/root.sh"
RUNNER="$REPO_ROOT/tests/run.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/root-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

TAB="$(printf '\t')"

# tags seen across the whole run, for the vocabulary-coverage assertion at the end
TAGS_SEEN="$SANDBOX/.tags-seen"
: > "$TAGS_SEEN"

section "0 — the library is on disk and parses"
if [ -f "$LIB" ]; then
  ok "payload/scripts/lib/root.sh is on disk"
else
  no "payload/scripts/lib/root.sh is on disk" "$LIB"
  echo "root.test.sh: no library at $LIB — every assertion below would pass over nothing."
  finish
fi

if bash -n "$LIB" 2>"$SANDBOX/.syn"; then
  ok "the library parses (bash -n)"
else
  no "the library parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi

# SOURCING IS SILENT AND SIDE-EFFECT FREE. Every hook in the spine sources this
# file before doing anything; a single stray `echo` at load time would land in a
# hook's stdout, which for a PreToolUse hook is protocol, not noise.
src_out="$(cd "$SANDBOX" && HOME="$SANDBOX/home" bash -c '. "$1" || exit 3; printf READY' _ "$LIB" 2>&1)"
expect_eq "sourcing the library prints nothing (stdout+stderr are exactly the caller's own token)" "READY" "$src_out"

fn_kinds="$(cd "$SANDBOX" && HOME="$SANDBOX/home" bash -c '. "$1"; printf "%s,%s" "$(type -t project_root)" "$(type -t project_root_candidates)"' _ "$LIB" 2>&1)"
expect_eq "both functions are defined by sourcing" "function,function" "$fn_kinds"

# ---------- drivers ----------

# HERMETIC ENV for every library call: the fake HOME under test, no global or
# system git config, no terminal prompt.
mkdir -p "$SANDBOX/home"
: > "$SANDBOX/gitconfig"

# root_at <cwd> <home> -> project_root's answer, called with NO argument from
# inside <cwd> (exercises the `[cwd]` default).
root_at() {
  ( cd "$1" 2>/dev/null || { echo "root_at: no such dir $1"; exit 1; }
    HOME="$2"; export HOME
    GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"; GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
    . "$LIB" || exit 1
    project_root )
}

# root_arg <cwd> <home> -> project_root's answer, called with <cwd> as the
# ARGUMENT from an unrelated cwd. Must equal root_at for the same pair.
root_arg() {
  ( cd "$SANDBOX/home" 2>/dev/null || exit 1
    HOME="$2"; export HOME
    GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"; GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
    . "$LIB" || exit 1
    project_root "$1" )
}

# cands_at <cwd> <home> -> the candidates report
cands_at() {
  ( cd "$1" 2>/dev/null || { echo "cands_at: no such dir $1"; exit 1; }
    HOME="$2"; export HOME
    GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"; GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
    . "$LIB" || exit 1
    project_root_candidates )
}

# tag_of <report> <path> -> the tag this report gave that path (empty if the
# path was never considered)
tag_of() {
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$1 == p { print $2; found = 1; exit } END { if (!found) print "" }'
}

# record every tag a report emitted, for the coverage assertion
record_tags() { printf '%s\n' "$1" | awk -F'\t' 'NF == 2 { print $2 }' >> "$TAGS_SEEN"; }

# the two functions may never disagree: the LAST line of the report is the
# terminal line, and its path is the answer. Asserted for every topology.
assert_agrees() {  # $1=label $2=cwd $3=home
  local rep ans last
  rep="$(cands_at "$2" "$3")"
  ans="$(root_at "$2" "$3")"
  last="$(printf '%s\n' "$rep" | tail -1 | awk -F'\t' '{ print $1 }')"
  expect_eq "$1: the report's last line names exactly what project_root answers" "$ans" "$last"
  expect_eq "$1: the argument form and the cwd form agree" "$ans" "$(root_arg "$2" "$3")"
  record_tags "$rep"
}

gitinit() { git -c init.defaultBranch=main init -q "$1"; }
gitcommit() {
  ( cd "$1" && : > .keep && git add .keep >/dev/null 2>&1 &&
    git -c user.name=t -c user.email=t@example.invalid commit -q -m init >/dev/null 2>&1 )
}

export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0

HOME_DEFAULT="$SANDBOX/home"

# ============================================================
section "1 — a git repo nested under a NON-GIT workspace holding .bionic"
# ============================================================
# The bug this library exists to kill (handoff §2.2): the old resolvers ask git
# first, so the nested repo always answered itself and the workspace's plans
# tree — the one carrying the active run — was invisible.
mkdir -p "$SANDBOX/t1/ws/.bionic/docs/plans"
gitinit "$SANDBOX/t1/ws/repo"
mkdir -p "$SANDBOX/t1/ws/repo/src"
T1_WS="$SANDBOX/t1/ws"

expect_eq "1: from the nested repo's src/, the workspace above the git root wins" \
  "$T1_WS" "$(root_at "$SANDBOX/t1/ws/repo/src" "$HOME_DEFAULT")"
expect_ne "1: the answer is NOT the git root (the split R2 names)" \
  "$SANDBOX/t1/ws/repo" "$(root_at "$SANDBOX/t1/ws/repo/src" "$HOME_DEFAULT")"

t1_rep="$(cands_at "$SANDBOX/t1/ws/repo/src" "$HOME_DEFAULT")"
t1_head="$(printf '%s\n' "$t1_rep" | head -3)"
t1_want="$SANDBOX/t1/ws/repo/src${TAB}candidate
$SANDBOX/t1/ws/repo${TAB}candidate
$T1_WS${TAB}chosen"
expect_eq "1: the report walks src -> repo -> ws and stops at the chosen one" "$t1_want" "$t1_head"
expect_eq "1: the chosen line is the last line (the walk stops at the first hit)" \
  "$T1_WS${TAB}chosen" "$(printf '%s\n' "$t1_rep" | tail -1)"
assert_agrees "1" "$SANDBOX/t1/ws/repo/src" "$HOME_DEFAULT"

# ============================================================
section "2 — a LINKED WORKTREE maps onto its main repository"
# ============================================================
# AC-9's shape: a worktree cwd must answer the MAIN repo's address space, or the
# roster the writer appends and the roster the gate polls are two different files.
mkdir -p "$SANDBOX/t2"
gitinit "$SANDBOX/t2/main"
gitcommit "$SANDBOX/t2/main"
mkdir -p "$SANDBOX/t2/main/.bionic/docs"
git -C "$SANDBOX/t2/main" worktree add -q -b wt-a "$SANDBOX/t2/wt-a" >/dev/null 2>&1
mkdir -p "$SANDBOX/t2/wt-a/sub"
T2_MAIN="$SANDBOX/t2/main"

if [ -d "$SANDBOX/t2/wt-a/sub" ]; then ok "2: the worktree fixture built"; else
  no "2: the worktree fixture built" "git worktree add produced no $SANDBOX/t2/wt-a"
fi

expect_eq "2: from deep inside the linked worktree, the MAIN repo is the root" \
  "$T2_MAIN" "$(root_at "$SANDBOX/t2/wt-a/sub" "$HOME_DEFAULT")"

t2_rep="$(cands_at "$SANDBOX/t2/wt-a/sub" "$HOME_DEFAULT")"
expect_eq "2: the report BEGINS at the main repo — the walk never starts inside the worktree" \
  "$T2_MAIN${TAB}chosen" "$(printf '%s\n' "$t2_rep" | head -1)"
expect_eq "2: no worktree path appears anywhere in the report" \
  "" "$(printf '%s\n' "$t2_rep" | grep -F "$SANDBOX/t2/wt-a" || true)"
assert_agrees "2" "$SANDBOX/t2/wt-a/sub" "$HOME_DEFAULT"

# ---- 2b control: the mapping happens BEFORE the walk ----
# Give the worktree its own REAL .bionic. If the mapping were merely "walk from
# cwd and coincidentally find main", this would flip the answer to the worktree.
mkdir -p "$SANDBOX/t2/wt-a/.bionic/docs"
expect_eq "2b: a real .bionic INSIDE the worktree still loses — the map runs before the walk" \
  "$T2_MAIN" "$(root_at "$SANDBOX/t2/wt-a/sub" "$HOME_DEFAULT")"

# ============================================================
section "3 — a PHANTOM nested .bionic below the repo root: nearest wins"
# ============================================================
# design-ledger S3, verbatim: "Phantom nested .bionic = nearest wins, by rule."
# The git-root-privileged alternative was rejected there by name, so the git
# root is neither a floor nor a ceiling on the walk.
gitinit "$SANDBOX/t3/proj"
mkdir -p "$SANDBOX/t3/proj/.bionic/docs"
mkdir -p "$SANDBOX/t3/proj/apps/inner/.bionic/docs"
mkdir -p "$SANDBOX/t3/proj/apps/inner/src"
T3_INNER="$SANDBOX/t3/proj/apps/inner"

expect_eq "3: the nearest .bionic wins even though it sits BELOW the git root" \
  "$T3_INNER" "$(root_at "$SANDBOX/t3/proj/apps/inner/src" "$HOME_DEFAULT")"

t3_rep="$(cands_at "$SANDBOX/t3/proj/apps/inner/src" "$HOME_DEFAULT")"
expect_eq "3: src is considered and rejected before the phantom is chosen" \
  "candidate" "$(tag_of "$t3_rep" "$SANDBOX/t3/proj/apps/inner/src")"
expect_eq "3: the phantom carries the chosen tag" "chosen" "$(tag_of "$t3_rep" "$T3_INNER")"
expect_eq "3: the walk stops there — the repo root is never considered" \
  "" "$(tag_of "$t3_rep" "$SANDBOX/t3/proj")"
assert_agrees "3" "$SANDBOX/t3/proj/apps/inner/src" "$HOME_DEFAULT"

# ---- 3b control: remove the phantom, the answer must climb ----
rm -rf "$SANDBOX/t3/proj/apps/inner/.bionic"
expect_eq "3b: with the phantom deleted the same cwd climbs to the repo root" \
  "$SANDBOX/t3/proj" "$(root_at "$SANDBOX/t3/proj/apps/inner/src" "$HOME_DEFAULT")"

# ============================================================
section "4 — a SYMLINKED .bionic is never a root (C2)"
# ============================================================
# spawn-worktree.sh used to plant <wt>/.bionic -> <main>/.bionic. C2 retired it
# and made the skip a rule of the resolver, so a legacy link left on disk is
# stepped over rather than followed to a second path to the same state.
mkdir -p "$SANDBOX/t4/ws/.bionic/docs"
gitinit "$SANDBOX/t4/ws/repo"
ln -s "$SANDBOX/t4/ws/.bionic" "$SANDBOX/t4/ws/repo/.bionic"
T4_WS="$SANDBOX/t4/ws"

if [ -L "$SANDBOX/t4/ws/repo/.bionic" ] && [ -d "$SANDBOX/t4/ws/repo/.bionic" ]; then
  ok "4: the fixture link is a symlink that also passes -d (the trap this rule is about)"
else
  no "4: the fixture link is a symlink that also passes -d" "ln -s did not produce a dir-like link"
fi

expect_eq "4: the symlinked .bionic is skipped and the real one above is chosen" \
  "$T4_WS" "$(root_at "$SANDBOX/t4/ws/repo" "$HOME_DEFAULT")"

t4_rep="$(cands_at "$SANDBOX/t4/ws/repo" "$HOME_DEFAULT")"
expect_eq "4: the link's directory is tagged skipped-symlink, not candidate" \
  "skipped-symlink" "$(tag_of "$t4_rep" "$SANDBOX/t4/ws/repo")"
expect_eq "4: the real .bionic above carries the chosen tag" "chosen" "$(tag_of "$t4_rep" "$T4_WS")"
assert_agrees "4" "$SANDBOX/t4/ws/repo" "$HOME_DEFAULT"

# ---- 4b control: make the same path a REAL directory, the answer must fall ----
rm -f "$SANDBOX/t4/ws/repo/.bionic"
mkdir -p "$SANDBOX/t4/ws/repo/.bionic/docs"
expect_eq "4b: the same path as a real directory is chosen — the skip was about the symlink" \
  "$SANDBOX/t4/ws/repo" "$(root_at "$SANDBOX/t4/ws/repo" "$HOME_DEFAULT")"

# ============================================================
section "5 — a .bionic inside \$HOME is never a candidate"
# ============================================================
# A stray ~/.bionic would otherwise become every project's root the moment a
# repo lived under it, which is every repo on a developer machine.
mkdir -p "$SANDBOX/t5/home/.bionic/docs"
gitinit "$SANDBOX/t5/home/proj"
mkdir -p "$SANDBOX/t5/home/proj/deep"
T5_HOME="$SANDBOX/t5/home"

expect_eq "5: with HOME holding the only .bionic, the git toplevel answers instead" \
  "$SANDBOX/t5/home/proj" "$(root_at "$SANDBOX/t5/home/proj/deep" "$T5_HOME")"

t5_rep="$(cands_at "$SANDBOX/t5/home/proj/deep" "$T5_HOME")"
expect_eq "5: HOME itself is tagged above-home, never chosen" \
  "above-home" "$(tag_of "$t5_rep" "$T5_HOME")"
expect_eq "5: HOME's own parent is above-home too" \
  "above-home" "$(tag_of "$t5_rep" "$SANDBOX/t5")"
expect_eq "5: the terminal line is the git-toplevel fallback" \
  "$SANDBOX/t5/home/proj${TAB}git-toplevel-fallback" "$(printf '%s\n' "$t5_rep" | tail -1)"
expect_eq "5: no line in the report is tagged chosen" \
  "0" "$(printf '%s\n' "$t5_rep" | awk -F'\t' '$2 == "chosen"' | wc -l | tr -d ' ')"
assert_agrees "5" "$SANDBOX/t5/home/proj/deep" "$T5_HOME"

# ---- 5b control: move HOME away, the ignored .bionic must win ----
expect_eq "5b: with HOME elsewhere the same directory becomes the root — the skip was about HOME" \
  "$T5_HOME" "$(root_at "$SANDBOX/t5/home/proj/deep" "$HOME_DEFAULT")"

# ============================================================
section "6 — an unrelated repo with no .bionic anywhere"
# ============================================================
gitinit "$SANDBOX/t6/repo"
mkdir -p "$SANDBOX/t6/repo/deep/er"

expect_eq "6: the git toplevel answers" \
  "$SANDBOX/t6/repo" "$(root_at "$SANDBOX/t6/repo/deep/er" "$HOME_DEFAULT")"

t6_rep="$(cands_at "$SANDBOX/t6/repo/deep/er" "$HOME_DEFAULT")"
expect_eq "6: the terminal line carries git-toplevel-fallback" \
  "$SANDBOX/t6/repo${TAB}git-toplevel-fallback" "$(printf '%s\n' "$t6_rep" | tail -1)"
expect_eq "6: every directory between cwd and the sandbox is reported as a candidate" \
  "candidate candidate candidate" \
  "$(printf '%s %s %s' "$(tag_of "$t6_rep" "$SANDBOX/t6/repo/deep/er")" "$(tag_of "$t6_rep" "$SANDBOX/t6/repo/deep")" "$(tag_of "$t6_rep" "$SANDBOX/t6/repo")")"
assert_agrees "6" "$SANDBOX/t6/repo/deep/er" "$HOME_DEFAULT"

# ============================================================
section "7 — no git, no .bionic: the cwd answers"
# ============================================================
# The seventh shape the six topologies do not reach. Without it `cwd-fallback`
# is a tag no fixture ever produces, and a resolver that could never emit it
# would still pass every assertion above.
mkdir -p "$SANDBOX/t7/plain/deep"

expect_eq "7: outside any repo, with no .bionic above, project_root answers the cwd" \
  "$SANDBOX/t7/plain/deep" "$(root_at "$SANDBOX/t7/plain/deep" "$HOME_DEFAULT")"

t7_rep="$(cands_at "$SANDBOX/t7/plain/deep" "$HOME_DEFAULT")"
expect_eq "7: the terminal line carries cwd-fallback" \
  "$SANDBOX/t7/plain/deep${TAB}cwd-fallback" "$(printf '%s\n' "$t7_rep" | tail -1)"
assert_agrees "7" "$SANDBOX/t7/plain/deep" "$HOME_DEFAULT"

# ============================================================
section "8 — a WORKTREE OF A BARE REPOSITORY: the checkout is the only working tree"
# ============================================================
# critic-findings.md issue 2 (MEDIUM). Rule 1 maps a linked worktree onto
# dirname(--git-common-dir); for a worktree of a NON-bare repo that is the main
# working root, but for a worktree of a BARE repo --git-common-dir is the bare
# repo's own directory (…/bare.git), and dirname() of THAT is just the folder
# holding bare.git — a path with no relationship to the checkout. The checkout's
# own .bionic was never a candidate, so a bare-repo worktree walk landed on
# cwd-fallback (or worse, adopted an unrelated sibling .bionic beside bare.git),
# tripping session-poker.sh's `TICK_ROOT_TAG = chosen`-only QUIET guard and
# reproducing the tick-#1 REFUSED wall AC-38 exists to prevent.
gitinit_bare() { git -c init.defaultBranch=main init -q --bare "$1"; }

mkdir -p "$SANDBOX/t8"
gitinit_bare "$SANDBOX/t8/bare.git"
git -C "$SANDBOX/t8/bare.git" worktree add -q -b t8-wt "$SANDBOX/t8/wt-of-bare" >/dev/null 2>&1
mkdir -p "$SANDBOX/t8/wt-of-bare/.bionic/docs"
mkdir -p "$SANDBOX/t8/wt-of-bare/sub"
T8_WT="$SANDBOX/t8/wt-of-bare"

if [ -d "$T8_WT" ]; then ok "8: the bare-repo worktree fixture built"; else
  no "8: the bare-repo worktree fixture built" "git worktree add produced no $T8_WT"
fi

expect_eq "8: from inside the checkout, the checkout's OWN .bionic is the root" \
  "$T8_WT" "$(root_at "$SANDBOX/t8/wt-of-bare/sub" "$HOME_DEFAULT")"

t8_rep="$(cands_at "$SANDBOX/t8/wt-of-bare/sub" "$HOME_DEFAULT")"
expect_eq "8: the report BEGINS at the checkout, not at dirname(bare.git)" \
  "$SANDBOX/t8/wt-of-bare/sub${TAB}candidate" "$(printf '%s\n' "$t8_rep" | head -1)"
expect_eq "8: the checkout itself carries the chosen tag" "chosen" "$(tag_of "$t8_rep" "$T8_WT")"
expect_eq "8: dirname(bare.git) — the folder holding the bare repo — is never even considered" \
  "" "$(tag_of "$t8_rep" "$SANDBOX/t8")"
assert_agrees "8" "$SANDBOX/t8/wt-of-bare/sub" "$HOME_DEFAULT"

# ---- 8b differential: a sibling .bionic beside bare.git must NOT win ----
# The nearest-.bionic rule still applies once the walk starts in the right place: a real
# .bionic that happens to sit beside bare.git (same shape as an ordinary sibling workspace)
# is farther away than the checkout's own and must lose to it.
mkdir -p "$SANDBOX/t8/.bionic/docs"
expect_eq "8b: a sibling .bionic beside bare.git does not win — the checkout's own is nearer" \
  "$T8_WT" "$(root_at "$SANDBOX/t8/wt-of-bare/sub" "$HOME_DEFAULT")"
t8b_rep="$(cands_at "$SANDBOX/t8/wt-of-bare/sub" "$HOME_DEFAULT")"
expect_eq "8b: the sibling directory is never reached — the walk already stopped at the checkout" \
  "" "$(tag_of "$t8b_rep" "$SANDBOX/t8")"

# ---- 8b-2: remove the checkout's own .bionic, the sibling beside bare.git must now win ----
# Proves the fix genuinely WALKS upward from the checkout (nearest-.bionic still governs)
# rather than hard-pinning the answer to cwd unconditionally.
rm -rf "$SANDBOX/t8/wt-of-bare/.bionic"
expect_eq "8b-2: with the checkout's own .bionic gone, the sibling beside bare.git is chosen" \
  "$SANDBOX/t8" "$(root_at "$SANDBOX/t8/wt-of-bare/sub" "$HOME_DEFAULT")"
mkdir -p "$SANDBOX/t8/wt-of-bare/.bionic/docs"  # restore for tidiness; not reused below

# ---- 8c control: the NON-bare linked-worktree case (§2) is unaffected by the bare check ----
mkdir -p "$SANDBOX/t8c"
gitinit "$SANDBOX/t8c/main"
gitcommit "$SANDBOX/t8c/main"
mkdir -p "$SANDBOX/t8c/main/.bionic/docs"
git -C "$SANDBOX/t8c/main" worktree add -q -b t8c-wt "$SANDBOX/t8c/wt" >/dev/null 2>&1
mkdir -p "$SANDBOX/t8c/wt/sub"
expect_eq "8c: a worktree of a NON-bare main repo still maps onto the main working root" \
  "$SANDBOX/t8c/main" "$(root_at "$SANDBOX/t8c/wt/sub" "$HOME_DEFAULT")"
t8c_rep="$(cands_at "$SANDBOX/t8c/wt/sub" "$HOME_DEFAULT")"
expect_eq "8c: the report still begins at the main repo, not the worktree cwd" \
  "$SANDBOX/t8c/main${TAB}chosen" "$(printf '%s\n' "$t8c_rep" | head -1)"

# ============================================================
section "9 — the tag vocabulary is closed, and every tag in it is reachable"
# ============================================================
# Two halves of one claim: the reports emitted nothing outside the vocabulary
# (a typo'd tag is a silent contract break for the tick's listing, 2.4), and no
# tag in the vocabulary is dead letter.
VOCAB="above-home candidate chosen cwd-fallback git-toplevel-fallback skipped-symlink"
seen="$(sort -u "$TAGS_SEEN" | tr '\n' ' ' | sed 's/ *$//')"
expect_eq "8: the tags emitted across all seven topologies are exactly the vocabulary" "$VOCAB" "$seen"

finish
