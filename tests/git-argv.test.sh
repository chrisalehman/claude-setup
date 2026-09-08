#!/bin/bash
# Tests for scripts/lib/git-argv.sh — the shared "read a Bash command the way
# git reads it" library, and the two walls that source it.
#
# Four subjects, in the order a reader needs them:
#
#   Section 1  the library itself: segmentation, quoting, heredoc-body removal,
#              global-option skipping, refspec destination parsing (spec R-3).
#   Section 2  FAIL-CLOSED SOURCING (AC-12): a copy of the shipped tree with the
#              library renamed away must make BOTH hooks refuse, not allow. Run
#              in both real layouts — the installed plugin (hooks/ and scripts/
#              as siblings) and this repo (payload/hooks -> ../hooks symlink,
#              library under payload/scripts/lib/).
#   Section 3  every `source`/`.` line in the hooks directory names a file that
#              exists in the shipped library directory (AC-12, second half).
#   Section 4  the evidence gate's command reading (AC-11) — it fires on the
#              git global-option commit spellings and stays silent on prose and
#              heredoc bodies. It lives here, not in the evidence-gate suite,
#              because the behaviour under test is this library.
#
# Usage: bash tests/git-argv.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

US=$'\037'

# ---------- locating the library the same way a hook does ----------
# The hooks try two candidates because the shipped tree has two real shapes:
# the installed plugin root (<root>/hooks + <root>/scripts) and this checkout
# (<repo>/hooks is the physical directory, <repo>/payload/scripts holds the
# library, and <repo>/payload/hooks is a symlink to the former). Resolving the
# library here the same way keeps the suite honest against either.
LIB=""
for cand in "${BIONIC_HOOKS_DIR}/../scripts/lib/git-argv.sh" \
            "${BIONIC_HOOKS_DIR}/../payload/scripts/lib/git-argv.sh"; do
  if [ -r "$cand" ]; then LIB="$cand"; break; fi
done
LIBDIR=""
[ -n "$LIB" ] && LIBDIR="$(cd "$(dirname "$LIB")" && pwd -P)"

if [ -z "$LIB" ]; then
  echo "FAIL: scripts/lib/git-argv.sh not found from ${BIONIC_HOOKS_DIR}"
  echo ""
  echo "========================================"
  echo "Results: 0/1 passed, 1 failed"
  echo "========================================"
  exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

PROTECT_MAIN="${BIONIC_HOOKS_DIR}/protect-main.sh"
EVIDENCE_GATE="${BIONIC_HOOKS_DIR}/canonical-sdlc-evidence-gate.sh"

cleanup_dirs=()
cleanup() {
  local d
  for d in ${cleanup_dirs[@]+"${cleanup_dirs[@]}"}; do rm -rf "$d"; done
}
trap cleanup EXIT

# ---------- assertion helpers ----------
#
# ok/no are the framework's (tests/lib/assert.sh); the private counters and
# ok()/no() definitions that used to live here are gone (AC-12, S6). `eq` is a
# local convenience wrapper, not one of the framework's owned names — it stays
# local per the migration brief, built on the framework's own ok/no exactly as
# expect_eq is.
eq() {  # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi
}

# Renders the library's segment/token output in a readable form: one segment
# per line, tokens joined by `|`.
segs() { git_argv_segments "$1" | tr "$US" '|'; }

# Parses the FIRST git segment of a whole command line — over the EXPANDED
# segment list, which is what both hooks read: the segments of the line plus
# the segments of any `sh -c`/`eval` string inside it (R-12).
parse_cmd() {
  local line
  GIT_SUB=""; GIT_ARGS=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if git_argv_parse "$line"; then return 0; fi
  done <<< "$(git_argv_expand "$1")"
  return 1
}

# ============================================================
# Section 1: the library
# ============================================================

section "Section 1: segmentation, quoting, heredoc bodies"

eq "plain command tokenises" \
   "git|push|origin|main" "$(segs 'git push origin main')"

eq "double quotes are honoured, not dropped" \
   "git|push|origin|main" "$(segs 'git push origin "main"')"

eq "single quotes are honoured, not dropped" \
   "git|push|origin|main" "$(segs "git push origin 'main'")"

eq "a quoted span with spaces stays ONE token" \
   "echo|git push origin main" "$(segs "echo 'git push origin main'")"

eq "operators are segment boundaries" \
   "$(printf 'a\nb|x\nc\nd|y')" "$(segs 'a && b x ; c || d y')"

eq "a pipe is a segment boundary" \
   "$(printf 'cat|f\ngrep|x')" "$(segs 'cat f | grep x')"

eq "an operator inside quotes is NOT a boundary" \
   "echo|a && b" "$(segs 'echo "a && b"')"

# The heredoc body is removed BEFORE tokenising: a push line inside a body is
# text the shell writes to a file, not a command it runs. This is the AC-10
# false-positive the old newline-is-a-boundary split produced.
HD_PUSH=$(printf 'cat > /tmp/n.txt <<%sNOTE%s\ngit push origin main\nNOTE\n' "'" "'")
eq "heredoc body is removed (push)" \
   "$(printf 'cat|/tmp/n.txt')" "$(segs "$HD_PUSH")"

HD_COMMIT=$(printf 'cat > /tmp/n.txt <<%sNOTE%s\ngit commit -m x\nNOTE\n' "'" "'")
eq "heredoc body is removed (commit)" \
   "$(printf 'cat|/tmp/n.txt')" "$(segs "$HD_COMMIT")"

HD_TABS=$(printf 'cat <<-EOF\n\tgit commit -m x\n\tEOF\n')
eq "heredoc body is removed (<<- with tab-indented terminator)" \
   "cat" "$(segs "$HD_TABS")"

HD_AFTER=$(printf 'cat > /tmp/n.txt <<%sNOTE%s\ngit commit -m x\nNOTE\ngit status\n' "'" "'")
eq "the command AFTER a heredoc still parses" \
   "$(printf 'cat|/tmp/n.txt\ngit|status')" "$(segs "$HD_AFTER")"

# `<<<` is a here-STRING: no body, no terminator, and its operand is an
# ordinary word on that line. What matters is that it does not open a body and
# swallow the command on the next line.
eq "a here-string is not a heredoc opener" \
   "$(printf 'grep|x|y\ngit|status')" "$(segs "$(printf 'grep x <<< y\ngit status\n')")"

# --- B-1 (review-b): a QUOTED <<WORD is text, not a redirection ---
# The heredoc scan had no quote state, so `echo "see <<EOF for the format"`
# opened a phantom body that swallowed every line after it — including a real
# push on the next line, which 22493c8 blocked and f15641f allowed. cmd-class.sh
# has been quote-aware from the start; this is the two libraries agreeing.
HD_QUOTED=$(printf 'echo "see <<EOF for the heredoc format"\ngit push origin main\n')
eq "a quoted <<WORD opens no heredoc (the next line still parses)" \
   "$(printf 'echo|see <<EOF for the heredoc format\ngit|push|origin|main')" "$(segs "$HD_QUOTED")"

HD_SQ=$(printf "echo 'run <<EOF to open a heredoc'\ngit push origin main\n")
eq "…single quotes too" \
   "$(printf 'echo|run <<EOF to open a heredoc\ngit|push|origin|main')" "$(segs "$HD_SQ")"

# PAIRED POSITIVE, so the fix above is not just "never open a heredoc": a REAL
# unquoted opener still swallows its body.
HD_REAL=$(printf 'cat > /tmp/n.txt <<EOF\ngit push origin main\nEOF\n')
eq "an UNQUOTED opener still removes its body" \
   "$(printf 'cat|/tmp/n.txt')" "$(segs "$HD_REAL")"

section "Section 1d: the two libraries agree about heredocs (review-b B-1)"
#
# ONE READING, TWO RENDERINGS. git-argv.sh and cmd-class.sh each carry the
# quote-aware heredoc pass in their own awk program (see the report's A-2 for
# why not a third shared file). What makes that safe is this arm: the same
# fixtures go through BOTH, and both must agree on which lines survive as
# commands. A drift in either shows up here rather than in the field.
CC_LIB=""
for cand in "${BIONIC_HOOKS_DIR}/../scripts/lib/cmd-class.sh" \
            "${BIONIC_HOOKS_DIR}/../payload/scripts/lib/cmd-class.sh"; do
  if [ -r "$cand" ]; then CC_LIB="$cand"; break; fi
done
if [ -z "$CC_LIB" ]; then
  no "cmd-class.sh is reachable for the agreement arm" "not found from ${BIONIC_HOOKS_DIR}"
else
  ok "cmd-class.sh is reachable for the agreement arm"
  # Does the sibling library keep the push line as live text?
  cc_keeps() {
    bash -c '. "$1" || exit 1
      out=$(cmd_strip_heredocs "$2")
      case "$out" in *"git push origin main"*) echo yes ;; *) echo no ;; esac' \
      _ "$CC_LIB" "$1" 2>/dev/null
  }
  # Does ours?
  ga_keeps() { if git_argv_has_sub "$1" push; then echo yes; else echo no; fi; }

  for pair in "quoted-double:$HD_QUOTED" "quoted-single:$HD_SQ" "real-heredoc:$HD_REAL"; do
    lbl="${pair%%:*}"; fx="${pair#*:}"
    eq "agreement [$lbl]: git-argv and cmd-class read the same lines as live" \
       "$(cc_keeps "$fx")" "$(ga_keeps "$fx")"
  done
fi

section "Section 1b: git global options and the subcommand"

parse_cmd 'git -C /tmp/r push origin main' && eq "-C <dir> is skipped with its value" "push" "$GIT_SUB" \
  || no "-C <dir> is skipped with its value" "no git segment parsed"
parse_cmd 'git -c user.name=x push origin main' && eq "-c <cfg> is skipped with its value" "push" "$GIT_SUB" \
  || no "-c <cfg> is skipped with its value" "no git segment parsed"
parse_cmd 'git --no-pager commit -m x' && eq "--no-pager (bare global) is skipped" "commit" "$GIT_SUB" \
  || no "--no-pager (bare global) is skipped" "no git segment parsed"
parse_cmd 'git --git-dir=/tmp/r/.git commit -m x' && eq "--git-dir=<v> consumes no extra word" "commit" "$GIT_SUB" \
  || no "--git-dir=<v> consumes no extra word" "no git segment parsed"
parse_cmd 'GIT_SSH_COMMAND=ssh git push origin main' && eq "leading VAR=value assignment is skipped" "push" "$GIT_SUB" \
  || no "leading VAR=value assignment is skipped" "no git segment parsed"
parse_cmd "env GIT_AUTHOR_DATE='2026-04-11' git commit -m x" && eq "env prefix is skipped" "commit" "$GIT_SUB" \
  || no "env prefix is skipped" "no git segment parsed"
parse_cmd '/usr/bin/git commit -m x' && eq "an absolute git path still parses" "commit" "$GIT_SUB" \
  || no "an absolute git path still parses" "no git segment parsed"

if parse_cmd "echo 'git push origin main'"; then
  no "quoted prose is not a git command" "parsed as git ${GIT_SUB}"
else
  ok "quoted prose is not a git command"
fi
if parse_cmd "grep 'git push' README.md"; then
  no "grep over a file naming a push is not a git command" "parsed as git ${GIT_SUB}"
else
  ok "grep over a file naming a push is not a git command"
fi
if parse_cmd "$HD_PUSH"; then
  no "a heredoc body is not a git command" "parsed as git ${GIT_SUB}"
else
  ok "a heredoc body is not a git command"
fi

section "Section 1c: git_push_targets — destinations and force"

dests_of() {  # <command> -> destinations joined by `|`
  parse_cmd "$1" || { echo "<not-a-git-command>"; return 0; }
  git_push_targets
  printf '%s' "$GIT_DESTS" | tr "$US" '|'
}
force_of() {
  parse_cmd "$1" || { echo "?"; return 0; }
  git_push_targets
  printf '%s' "$GIT_FORCE"
}

eq "plain refspec"                 "origin|main"        "$(dests_of 'git push origin main')"
eq "refs/heads/ prefix is stripped" "origin|main"       "$(dests_of 'git push origin refs/heads/main')"
eq "HEAD:refs/heads/main -> main"  "origin|main"        "$(dests_of 'git push origin HEAD:refs/heads/main')"
eq "feature:refs/heads/main -> main" "origin|main"      "$(dests_of 'git push origin feature:refs/heads/main')"
eq "HEAD:refs/heads/feature/main -> feature/main" "origin|feature/main" \
   "$(dests_of 'git push origin HEAD:refs/heads/feature/main')"
eq "delete refspec :main -> main"  "origin|main"        "$(dests_of 'git push origin :main')"
eq "leading + is stripped"         "origin|main"        "$(dests_of 'git push origin +main')"
eq "topic/main is its own branch"  "origin|topic/main"  "$(dests_of 'git push origin topic/main')"
eq "main-fixes is its own branch"  "origin|main-fixes"  "$(dests_of 'git push origin main-fixes')"
eq "-u is not a destination"       "origin|main"        "$(dests_of 'git push -u origin main')"

eq "no force by default"           "0" "$(force_of 'git push origin main')"
eq "-f sets force"                 "1" "$(force_of 'git push -f origin feature')"
eq "--force sets force"            "1" "$(force_of 'git push --force origin feature')"
eq "--force-with-lease sets force" "1" "$(force_of 'git push --force-with-lease origin feature')"
eq "--force-with-lease=<ref> sets force" "1" "$(force_of 'git push --force-with-lease=main origin feature')"
eq "a leading + sets force"        "1" "$(force_of 'git push origin +main')"
eq "-C <dir> does not hide --force" "1" "$(force_of 'git -C /tmp/r push --force origin feature')"

# ============================================================
# Section 2: fail-closed sourcing (AC-12)
# ============================================================
#
# Chris's D1 ruling: a wall that cannot load its library REFUSES. The proof is
# a copy of the shipped tree with the library renamed away — each hook must
# exit non-zero on a command it would otherwise wave through.

section "Section 2: a hook whose library is missing REFUSES"

# HERMETIC, and since bionic 1.4.0 that is load-bearing rather than tidy. The loader
# these hooks share HEALS before it fails: when the library is not beside the hook it
# consults the CLI's plugin registry and the plugin cache, so a copied tree whose
# library has been renamed away still finds THIS machine's installed bionic and loads
# it. The refusal arm below would then test nothing at all. HOME and
# BIONIC_PLUGINS_DIR are the only doors to those candidates, and both are pointed
# into an empty sandbox here, so "renamed away" means what the section says it means.
GA_SANDBOX=$(mktemp -d); cleanup_dirs+=("$GA_SANDBOX")
mkdir -p "$GA_SANDBOX/home" "$GA_SANDBOX/plugins"

# THE PAYLOAD NAMES AN ENGAGED PROJECT (task-engaged-session, 2026-09-03). Both hooks
# driven here ask whether the session invoked the canonical-sdlc skill before they read a
# command for meaning, so a payload with no cwd and no session key exercises the guard
# rather than the library resolution this section is about.
GA_SID="6d5c4b3a-2019-4f8e-9d7c-6b5a49382716"
GA_REPO="$GA_SANDBOX/repo"
mkdir -p "$GA_REPO/.bionic/tmp"
: > "$GA_REPO/.bionic/tmp/engaged-$GA_SID.state"

run_hook_at() {  # <hook path> <command> -> sets RC, ERRTXT and (on a refusal) VERRTXT
  local hook="$1" cmd="$2" input tmp_err
  input=$(jq -n --arg c "$cmd" --arg d "$GA_REPO" --arg s "$GA_SID" \
            '{session_id: $s, cwd: $d, tool_input: {command: $c}}')
  tmp_err=$(mktemp)
  if printf '%s' "$input" | env HOME="$GA_SANDBOX/home" \
       BIONIC_PLUGINS_DIR="$GA_SANDBOX/plugins" \
       CLAUDE_CODE_SESSION_ID="$GA_SID" CLAUDE_PROJECT_DIR= \
       bash "$hook" >/dev/null 2>"$tmp_err"; then RC=0; else RC=$?; fi
  ERRTXT=$(cat "$tmp_err"); rm -f "$tmp_err"
  # THE DETAIL, ON A SECOND DRIVE, AND ONLY AFTER A REFUSAL (slice 13, ruling D-1). A
  # refusal now puts ONE line on the user stream — `bionic: load refused — <hook> cannot
  # load the bionic library (run /bionic:doctor)` — and the library it wanted, the
  # candidates it tried and the repair commands it still permits are `detail`, emitted
  # only under BIONIC_WALL_VERBOSE=1. A row that wants the PATH out of a refusal reads
  # $VERRTXT; reading it off $ERRTXT would now be asserting that the wall leaks it.
  # The loader wall exits before it sources anything, so a second drive doubles nothing.
  VERRTXT=""
  if [ "$RC" -ne 0 ]; then
    tmp_err=$(mktemp)
    printf '%s' "$input" | env HOME="$GA_SANDBOX/home" \
       BIONIC_PLUGINS_DIR="$GA_SANDBOX/plugins" \
       CLAUDE_CODE_SESSION_ID="$GA_SID" CLAUDE_PROJECT_DIR= BIONIC_WALL_VERBOSE=1 \
       bash "$hook" >/dev/null 2>"$tmp_err"
    VERRTXT=$(cat "$tmp_err"); rm -f "$tmp_err"
  fi
}

# THE FIXTURE LIBRARY IS THE ONE THE HOOKS ASK FOR, read out of the hooks themselves. The
# loader qualifies a candidate directory only when it holds EVERY basename in that hook's
# BIONIC_LIB_WANT, so a hand-kept list here goes stale the moment a hook wants one more
# file — and it did: wave-01 slice 13 added refuse.sh to the BIONIC_LIB_WANT of eleven of
# the twenty-one hooks, these two among them, and this section's
# POSITIVE controls then failed with "cannot load the bionic library", which reads as a
# broken hook and was really a fixture that never built a whole library.
GA_WANT=$(/usr/bin/grep -h '^BIONIC_LIB_WANT=' "$PROTECT_MAIN" "$EVIDENCE_GATE" \
          | sed -e 's/^BIONIC_LIB_WANT="//' -e 's/"[[:space:]]*$//' \
          | tr ' ' '\n' | sort -u)
expect_contains "the fixture reads the two hooks' own BIONIC_LIB_WANT" "git-argv.sh" "$GA_WANT"

make_layout() {  # <style: installed|payload> -> echoes the tree root
  local style="$1" root libdir
  root=$(mktemp -d); cleanup_dirs+=("$root")
  mkdir -p "$root/hooks"
  cp "$PROTECT_MAIN" "$root/hooks/protect-main.sh"
  cp "$EVIDENCE_GATE" "$root/hooks/canonical-sdlc-evidence-gate.sh"
  if [ "$style" = "installed" ]; then
    libdir="$root/scripts/lib"
  else
    libdir="$root/payload/scripts/lib"
    mkdir -p "$root/payload"
    ln -s ../hooks "$root/payload/hooks"
  fi
  mkdir -p "$libdir"
  cp "$LIB" "$libdir/git-argv.sh"
  # Every other basename the two hooks want, from beside the library under test. The
  # per-style completeness check in the loop below is what makes a copy that did not land
  # a named failure instead of a mysterious refusal.
  for _ga_extra in $GA_WANT; do
    cp "$(dirname "$LIB")/$_ga_extra" "$libdir/$_ga_extra" 2>/dev/null || true
  done
  echo "$root"
}

for style in installed payload; do
  root=$(make_layout "$style")
  if [ "$style" = "installed" ]; then hookdir="$root/hooks"; else hookdir="$root/payload/hooks"; fi
  if [ "$style" = "installed" ]; then galib="$root/scripts/lib"; else galib="$root/payload/scripts/lib"; fi

  # THE FIXTURE'S OWN PRECONDITION, asserted before the hooks are driven: the copied
  # library holds every basename they ask for. Without this row a missing file shows up
  # only as the positive control refusing, which reads as a defect in the hook.
  ga_missing=""
  for ga_f in $GA_WANT; do
    [ -r "$galib/$ga_f" ] || ga_missing="$ga_missing $ga_f"
  done
  expect_eq "$style layout: the fixture built the whole library the hooks want" "" "$ga_missing"

  # Positive control first — the copied tree WORKS, so a later refusal is the
  # missing library and not a broken fixture.
  run_hook_at "$hookdir/protect-main.sh" "ls -la"
  if [ "$RC" -eq 0 ]; then ok "$style layout: protect-main loads its library and allows 'ls -la'"
  else no "$style layout: protect-main loads its library and allows 'ls -la'" "rc=$RC err='$ERRTXT'"; fi

  run_hook_at "$hookdir/canonical-sdlc-evidence-gate.sh" "ls -la"
  if [ "$RC" -eq 0 ]; then ok "$style layout: evidence gate loads its library and allows 'ls -la'"
  else no "$style layout: evidence gate loads its library and allows 'ls -la'" "rc=$RC err='$ERRTXT'"; fi

  # And it still reads commands correctly through this layout.
  run_hook_at "$hookdir/protect-main.sh" 'git push origin main'
  if [ "$RC" -ne 0 ]; then ok "$style layout: protect-main still blocks an explicit main push"
  else no "$style layout: protect-main still blocks an explicit main push" "rc=0"; fi

  # Now rename the library away.
  libfile="$galib/git-argv.sh"
  mv "$libfile" "$libfile.renamed"

  # THE REFUSAL IS READ IN TWO PLACES, because ruling D-1 put it in two: the one line the
  # reader is interrupted by, and the path in the detail behind BIONIC_WALL_VERBOSE=1.
  run_hook_at "$hookdir/protect-main.sh" "ls -la"
  if [ "$RC" -ne 0 ] && printf '%s' "$ERRTXT" | grep -q 'cannot load the bionic library'; then
    ok "$style layout: protect-main REFUSES with the library renamed away, in the ruled one line"
  else
    no "$style layout: protect-main REFUSES with the library renamed away, in the ruled one line" "rc=$RC err='$ERRTXT'"
  fi
  if printf '%s' "$VERRTXT" | grep -q 'git-argv.sh'; then
    ok "$style layout: protect-main REFUSES with the library renamed away, naming the path"
  else
    no "$style layout: protect-main REFUSES with the library renamed away, naming the path" "detail='$VERRTXT'"
  fi

  run_hook_at "$hookdir/canonical-sdlc-evidence-gate.sh" "ls -la"
  if [ "$RC" -ne 0 ] && printf '%s' "$ERRTXT" | grep -q 'cannot load the bionic library'; then
    ok "$style layout: evidence gate REFUSES with the library renamed away, in the ruled one line"
  else
    no "$style layout: evidence gate REFUSES with the library renamed away, in the ruled one line" "rc=$RC err='$ERRTXT'"
  fi
  if printf '%s' "$VERRTXT" | grep -q 'git-argv.sh'; then
    ok "$style layout: evidence gate REFUSES with the library renamed away, naming the path"
  else
    no "$style layout: evidence gate REFUSES with the library renamed away, naming the path" "detail='$VERRTXT'"
  fi
done

# ============================================================
# Section 3: every source line resolves inside the shipped tree
# ============================================================

section "Section 3: hook source lines name shipped library files"

# Two halves, because a hook's `source` names a VARIABLE and the path it holds
# is written elsewhere:
#   (a) every hook that loads a library at all — the `.`/`source` command, not
#       a mention in a comment;
#   (b) every literal library path expression in the hooks. Each must live
#       under scripts/lib/, must be relative to the hook's own directory
#       (never absolute, never $HOME, never ~), and must name a file that
#       exists in the shipped library directory.
# Section 2 proves the runtime half — that those expressions actually resolve
# through both real tree shapes, and that a hook refuses when they do not.

SOURCERS=0
for hook in "${BIONIC_HOOKS_DIR}"/*.sh; do
  n=$(grep -cE '(^|[[:space:]]|;)(\.|source)[[:space:]]+["$/]' "$hook" || true)
  if [ "${n:-0}" -gt 0 ]; then SOURCERS=$((SOURCERS + 1)); fi
done

if [ "$SOURCERS" -ge 2 ]; then
  ok "at least two hooks load a library (found $SOURCERS)"
else
  no "at least two hooks load a library (found $SOURCERS)" \
     "protect-main.sh and canonical-sdlc-evidence-gate.sh must each source git-argv.sh"
fi

LIB_REFS=0
BAD_SOURCE=""
for hook in "${BIONIC_HOOKS_DIR}"/*.sh; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    LIB_REFS=$((LIB_REFS + 1))
    case "$ref" in
      /*|'~'*|*'$HOME'*|*'${HOME}'*)
        BAD_SOURCE="$BAD_SOURCE$(basename "$hook"): $ref (not hook-relative)"$'\n' ;;
    esac
    base="${ref##*/}"
    if [ ! -f "$LIBDIR/$base" ]; then
      BAD_SOURCE="$BAD_SOURCE$(basename "$hook"): $ref (no $base in $LIBDIR)"$'\n'
    fi
  done <<< "$(grep -ohE '[^ "'"'"']*scripts/lib/[A-Za-z0-9._-]+\.sh' "$hook" || true)"
done

if [ "$LIB_REFS" -ge 2 ]; then
  ok "the hooks name at least two library paths (found $LIB_REFS)"
else
  no "the hooks name at least two library paths (found $LIB_REFS)" "expected the git-argv.sh candidates"
fi

if [ -z "$BAD_SOURCE" ]; then
  ok "every library path a hook names is hook-relative and exists in the shipped tree"
else
  no "every library path a hook names is hook-relative and exists in the shipped tree" "$BAD_SOURCE"
fi

# ============================================================
# Section 4: the evidence gate's command reading (AC-11)
# ============================================================

section "Section 4: evidence gate fires on git global-option commit forms"

FM='---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
intent: build
rigor: tested
scale: wave
deploy_target: none
use_worktree: false
has_ui: false
---'

EG_HOME=$(mktemp -d); cleanup_dirs+=("$EG_HOME")
mkdir -p "$EG_HOME/.claude/plans" "$EG_HOME/.bionic/docs/plans" "$EG_HOME/.bionic/tmp"
# THE FIXTURE IS AN ENGAGED SESSION (task-engaged-session, 2026-09-03). This gate asks
# whether the session invoked the canonical-sdlc skill before it reads a plan at all, so
# without the marker every row below would be silent for a reason that has nothing to do
# with how a git command line is parsed — which is the whole subject of this section.
EG_SID="2b7c9d10-4e5f-4a6b-8c9d-0e1f2a3b4c5d"
: > "$EG_HOME/.bionic/tmp/engaged-$EG_SID.state"
printf '%s\n' "$FM
## SDLC State
current: 5
Step 5: TODO" > "$EG_HOME/.bionic/docs/plans/active.md"

run_gate() {  # <command>
  local input tmp_err
  input=$(jq -n --arg c "$1" --arg cwd "$EG_HOME" --arg s "$EG_SID" \
            '{session_id: $s, tool_input: {command: $c}, cwd: $cwd}')
  tmp_err=$(mktemp)
  if HOME="$EG_HOME" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="$EG_SID" bash "$EVIDENCE_GATE" <<< "$input" >/dev/null 2>"$tmp_err"; then
    RC=0
  else
    RC=$?
  fi
  ERRTXT=$(cat "$tmp_err"); rm -f "$tmp_err"
}

gate_fires() {
  local label="$1" cmd="$2"
  run_gate "$cmd"
  if [ "$RC" -eq 2 ]; then ok "$label"; else no "$label" "rc=$RC err='$ERRTXT'"; fi
}
gate_silent() {
  local label="$1" cmd="$2"
  run_gate "$cmd"
  if [ "$RC" -eq 0 ] && [ -z "$ERRTXT" ]; then ok "$label"; else no "$label" "rc=$RC err='$ERRTXT'"; fi
}

# Positive control: the fixture blocks a plain commit, so a silence below is
# the command reading and not an inert plan.
gate_fires  "plain git commit blocks (positive control)" 'git commit -m x'
gate_fires  "git -C <dir> commit blocks"                 'git -C /tmp/r commit -m x'
gate_fires  "git -c <cfg> commit blocks"                 'git -c user.name=x commit -m x'
gate_fires  "git --no-pager commit blocks"               'git --no-pager commit -m x'
gate_silent "echo naming a commit is silent"             'echo "we will git commit later"'
gate_silent "a heredoc body naming a commit is silent"   "$HD_COMMIT"
gate_silent "git status is silent"                       'git status'
gate_silent "a push is not a commit"                     'git push origin feature'

# R-12 (critic C-1): the same superset the push wall gets. A commit wrapped in
# a subshell, a group, an `if`, a `for`, behind `sudo`, or inside a `sh -c`
# string bypassed the gate entirely — matrix, ledger, walk artifact and all —
# because `git` landed at argv[1..n] of the segment.
gate_fires  "R-12 ( git commit ) blocks"                 '( git commit -m x )'
gate_fires  "R-12 (git commit) unspaced blocks"          '(git commit -m x)'
gate_fires  "R-12 { git commit; } blocks"                '{ git commit -m x; }'
gate_fires  "R-12 if/then git commit blocks"             'if true; then git commit -m x; fi'
gate_fires  "R-12 for/do git commit blocks"              'for i in 1; do git commit -m x; done'
gate_fires  "R-12 sudo git commit blocks"                'sudo git commit -m x'
gate_fires  "R-12 time git commit blocks"                'time git commit -m x'
gate_fires  "R-12 xargs -I{} git commit blocks"          'xargs -I{} git commit -m x'
gate_fires  "R-12 find -exec git commit blocks"          'find . -exec git commit -m x \;'
gate_fires  "R-12 ssh <host> git commit blocks"          'ssh box git commit -m x'
gate_fires  "R-12 sh -c git commit blocks"               "sh -c 'git commit -m x'"
gate_fires  "R-12 bash -c git commit blocks"             'bash -c "git commit -m x"'
gate_fires  "R-12 eval git commit blocks"                'eval "git commit -m x"'
gate_fires  "R-12 true & git commit blocks"              'true & git commit -m x'
gate_fires  "R-12 exec git commit blocks"                'exec git commit -m x'
gate_fires  "R-12 nice git commit blocks"                'nice git commit -m x'
gate_fires  "R-12 timeout N git commit blocks"           'timeout 60 git commit -m x'
gate_fires  "R-12 gtimeout N git commit blocks"          'gtimeout 60 git commit -m x'
gate_fires  "R-12 timeout -s KILL N git commit blocks"   'timeout -s KILL 60 git commit -m x'
gate_fires  "R-12 { git commit; } after a cd blocks"     'cd /tmp && { git commit -m x; }'
gate_fires  "R-12 while/do git commit blocks"            'while false; do git commit -m x; done'
gate_silent "R-12 echo of a sudo commit is silent"       'echo "sudo git commit -m x"'
gate_silent "R-12 echo of a timeout commit is silent"    'echo "timeout 60 git commit -m x"'
gate_silent "R-12 find with no -exec is silent"          "find . -name 'git commit'"
gate_silent "R-12 sudo of a non-commit is silent"        'sudo git status'

# --- the library-level reading behind those gate answers (AC-11, R-12) ---
section "Section 4b: git_argv_expand reads openers, prefixes and -c strings"

has_push() {  # <command> -> yes|no
  if git_argv_has_sub "$1" push; then echo yes; else echo no; fi
}

eq "R-12 subshell"          "yes" "$(has_push '( git push origin main )')"
eq "R-12 subshell unspaced" "yes" "$(has_push '(git push origin main)')"
eq "R-12 brace group"       "yes" "$(has_push '{ git push origin main; }')"
eq "R-12 then"              "yes" "$(has_push 'if true; then git push origin main; fi')"
eq "R-12 do"                "yes" "$(has_push 'for i in 1; do git push origin main; done')"
eq "R-12 sudo"              "yes" "$(has_push 'sudo git push origin main')"
eq "R-12 sudo -u <user>"    "yes" "$(has_push 'sudo -u ci git push origin main')"
eq "R-12 time"              "yes" "$(has_push 'time git push origin main')"
eq "R-12 nice -n"           "yes" "$(has_push 'nice -n 10 git push origin main')"
eq "R-12 xargs"             "yes" "$(has_push 'xargs git push origin main')"
eq "R-12 xargs -I{}"        "yes" "$(has_push 'xargs -I{} git push origin main')"
eq "R-12 find -exec"        "yes" "$(has_push 'find . -exec git push origin main \;')"
eq "R-12 ssh <host>"        "yes" "$(has_push 'ssh box git push origin main')"
eq "R-12 sh -c"             "yes" "$(has_push "sh -c 'git push origin main'")"
eq "R-12 eval"              "yes" "$(has_push 'eval "git push origin main"')"
eq "R-12 bare & separator"  "yes" "$(has_push 'true & git push origin main')"

# The destination reading must survive the skip: a prefix must not swallow the
# refspec, and it must not invent one.
eq "R-12 sudo push keeps its destinations"  "origin|main" "$(dests_of 'sudo git push origin main')"
eq "R-12 subshell push keeps its dests"     "origin|main" "$(dests_of '( git push origin main )')"
eq "R-12 sh -c push keeps its dests"        "origin|main" "$(dests_of "sh -c 'git push origin main'")"
eq "R-12 find -exec push keeps main"        "origin|main|;" "$(dests_of 'find . -exec git push origin main \;')"

eq "R-12 prose is still not a push"         "no"  "$(has_push 'echo "sudo git push origin main"')"
eq "R-12 find without -exec is not a push"  "no"  "$(has_push "find . -name 'git'")"
eq "R-12 a heredoc body is still not a push" "no" "$(has_push "$HD_PUSH")"
eq "R-12 command substitution stays OUT of scope" "no" "$(has_push 'echo $(git push origin main)')"

# ============================================================
# Section 5: git_branch_protected — ONE list of protected branches (F1)
# ============================================================
#
# Two walls refuse writes to the same branches: hooks/protect-main.sh over a
# `git push`, and payload/scripts/lib/worktree.sh's `land` over a `git merge`
# into the main checkout. Naming `main` and `master` in each of them is how two
# walls come to disagree about which branch is the branch, so the list lives
# here and both walls ask it.

section "Section 5: git_branch_protected"

protected_says() { if git_branch_protected "${1:-}"; then echo yes; else echo no; fi; }

eq "main is protected"    "yes" "$(protected_says main)"
eq "master is protected"  "yes" "$(protected_says master)"

# WHOLE NAME, never a prefix or a substring: each of these is somebody's own
# branch and landing onto it is ordinary work.
eq "topic/main is not protected"   "no" "$(protected_says topic/main)"
eq "main-fixes is not protected"   "no" "$(protected_says main-fixes)"
eq "mastermind is not protected"   "no" "$(protected_says mastermind)"
eq "remotes/origin/main is not it" "no" "$(protected_says remotes/origin/main)"
eq "a wave branch is not protected" "no" "$(protected_says wave/bionic-1.4.0-update)"
eq "the empty name is not protected" "no" "$(protected_says '')"
eq "no argument at all is not protected" "no" "$(protected_says)"

# The wall that already had these two words must now be reading THIS list and
# not a second copy of it. Both spellings protect-main.sh checks — the push
# destination and the branch it is standing on — go through the predicate.
eq "protect-main.sh asks the library, at both of its checks" "1" \
  "$([ "$(grep -c 'git_branch_protected' "$PROTECT_MAIN")" -ge 2 ] && echo 1 || echo 0)"
# ...and no longer compares a branch name against a quoted literal of its own.
# The words may still appear in its prose; a TEST against them may not.
eq "protect-main.sh compares against no quoted branch literal" "0" \
  "$(grep -c '= "main"\|= "master"' "$PROTECT_MAIN")"

finish
