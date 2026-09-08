#!/bin/bash
# Tests for protect-main.sh Claude Code hook.
# Runs the hook against a matrix of push commands x branch states,
# verifying that pushes to main/master are always blocked and
# pushes to feature branches are allowed.
#
# Usage: bash tests/protect-main.test.sh

set -euo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

HOOK="${BIONIC_HOOKS_DIR}/protect-main.sh"

# ---------- helpers ----------

run_hook() {
  # Feeds a simulated tool_input to the hook on stdin.
  #
  # The payload is built with `jq -n --arg`, not string interpolation: the
  # AC-9/AC-10 cases below carry double quotes and newlines (a heredoc), and
  # hand-built JSON mangles both. Same idiom as
  # tests/canonical-sdlc-evidence-gate.test.sh:run_hook.
  local cmd="$1"
  pm_payload "$ENGAGED_REPO" "$cmd" \
    | env CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= bash "$HOOK" 2>/dev/null
}

# ---------- the engaged fixture (task-engaged-session, AC-20) ----------
#
# Since 2026-09-03 this wall only speaks in a session that invoked the canonical-sdlc
# skill (Chris: "Nothing should apply until bionic is triggered"). The marker recording
# the invocation is `.bionic/tmp/engaged-<sid>.state` under the payload's project root,
# so every arm below runs from a repo that has one — the world in which "does this wall
# still refuse a push to main" is the question anyone means. The unengaged world is the
# section at the bottom, driven on the same commands.
#
# THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does: lib/session.sh
# takes the env value as primary and the payload as a witness, so a driver that left the
# RUNNER's own session id in the environment would have the hook looking for a marker
# this fixture never wrote, and every row would pass for the wrong reason.
PM_SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pmain.XXXXXX")" && pwd -P)"
SID="7a6b5c4d-3e2f-4109-8877-665544332211"
ENGAGED_REPO="$PM_SANDBOX/engaged"
PLAIN_REPO="$PM_SANDBOX/plain"
mkdir -p "$ENGAGED_REPO/.bionic/tmp" "$PLAIN_REPO/.bionic/tmp" "$PM_SANDBOX/home"
: > "$ENGAGED_REPO/.bionic/tmp/engaged-$SID.state"
export HOME="$PM_SANDBOX/home"

pm_payload() {  # <cwd> <command>
  jq -n --arg s "$SID" --arg c "$1" --arg cmd "$2" \
    '{session_id:$s, cwd:$c, hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:{command:$cmd}}'
}

expect_block() {
  local label="$1"
  local cmd="$2"
  if run_hook "$cmd"; then
    no "$label" "expected BLOCK, got ALLOW"
  else
    ok "$label"
  fi
}

expect_allow() {
  local label="$1"
  local cmd="$2"
  if run_hook "$cmd"; then
    ok "$label"
  else
    no "$label" "expected ALLOW, got BLOCK"
  fi
}

# ---------- setup: fake git that reports a controllable branch ----------

FAKE_BIN=$(mktemp -d)
cat > "$FAKE_BIN/git" << 'FAKEGIT'
#!/bin/bash
# Intercept "git symbolic-ref --short HEAD" and return $FAKE_BRANCH.
# Pass everything else through to real git.
if [[ "$*" == "symbolic-ref --short HEAD" ]]; then
  echo "${FAKE_BRANCH:-main}"
  exit 0
fi
# Fall through to real git for any other sub-command
REAL_GIT=$(which -a git | grep -v "$FAKE_BIN" | head -1)
exec "$REAL_GIT" "$@"
FAKEGIT
chmod +x "$FAKE_BIN/git"

export PATH="$FAKE_BIN:$PATH"

cleanup() { rm -rf "$FAKE_BIN"; }
trap cleanup EXIT

# ============================================================
# SECTION 1: On main branch — every push must be blocked
# ============================================================

section "Section 1: On 'main' branch (all pushes must be BLOCKED)"
export FAKE_BRANCH="main"

expect_block "explicit: push origin main"            "git push origin main"
expect_block "explicit: push upstream main"           "git push upstream main"
expect_block "explicit: push origin master"           "git push origin master"
expect_block "bare push"                              "git push"
expect_block "push origin (implicit branch)"          "git push origin"
expect_block "push origin HEAD"                       "git push origin HEAD"
expect_block "push -u origin main"                    "git push -u origin main"
expect_block "push --set-upstream origin main"        "git push --set-upstream origin main"
expect_block "push origin HEAD:main"                  "git push origin HEAD:main"
expect_block "push origin HEAD:refs/heads/main"       "git push origin HEAD:refs/heads/main"
expect_block "force push -f"                          "git push -f origin main"
expect_block "force push --force"                     "git push --force origin main"
expect_block "force push --force-with-lease"          "git push --force-with-lease origin main"
expect_block "push in compound command"               "cd /tmp && git push origin"
expect_block "push with env prefix"                   "GIT_SSH_COMMAND=ssh git push origin main"
expect_block "compound with ||"                       "false || git push origin main"
expect_block "force push flag at end"                 "git push origin main -f"
expect_block "force push --force at end"              "git push origin feat/x --force"
expect_block "refspec push HEAD:main"                 "git push origin HEAD:main"

# ============================================================
# SECTION 2: On master branch — every push must be blocked
# ============================================================

section "Section 2: On 'master' branch (all pushes must be BLOCKED)"
export FAKE_BRANCH="master"

expect_block "master: bare push"                      "git push"
expect_block "master: push origin"                    "git push origin"
expect_block "master: push origin HEAD"               "git push origin HEAD"
expect_block "master: push origin master"             "git push origin master"

# ============================================================
# SECTION 3: On feature branch — non-main pushes must be allowed
# ============================================================

section "Section 3: On feature branch (safe pushes must be ALLOWED)"
export FAKE_BRANCH="feat/cool-thing"

expect_allow "feature: push origin feat/cool-thing"   "git push origin feat/cool-thing"
expect_allow "feature: push -u origin feat/cool-thing" "git push -u origin feat/cool-thing"
expect_allow "feature: bare push"                     "git push"
expect_allow "feature: push origin"                   "git push origin"
expect_allow "feature: push origin HEAD"              "git push origin HEAD"

# Even from a feature branch, explicit main/master must be blocked
expect_block "feature: push origin main (explicit)"   "git push origin main"
expect_block "feature: push origin master (explicit)"  "git push origin master"

# Force pushes always blocked regardless of branch
expect_block "feature: force push -f"                 "git push -f origin feat/cool-thing"
expect_block "feature: force push --force"            "git push --force origin feat/cool-thing"
expect_block "feature: force push --force-with-lease"  "git push --force-with-lease origin feat/cool-thing"

# Branch names containing "main" as substring should be allowed
expect_allow "feature: push branch with main substring" "git push origin feat/maintain-state"
expect_allow "feature: push domain-main branch"        "git push origin domain-main-fix"

# ============================================================
# SECTION 4: Non-push commands must always pass through
# ============================================================

section "Section 4: Non-push commands (must be ALLOWED)"
export FAKE_BRANCH="main"

expect_allow "git status"                             "git status"
expect_allow "git log"                                "git log --oneline -5"
expect_allow "git diff"                               "git diff HEAD~1"
expect_allow "git commit"                             "git commit -m 'test'"
expect_allow "git pull"                               "git pull origin main"
expect_allow "git fetch"                              "git fetch origin"
expect_allow "git branch"                             "git branch -a"
expect_allow "echo with push in string"               "echo 'not a git push'"
expect_allow "commit message mentioning push"          "git commit -m 'fix: close git push gaps in hook'"
expect_allow "ls command"                             "ls -la"
expect_allow "grep mentioning git push"               "grep 'git push' README.md"
expect_allow "cat file with push content"             "cat deploy.sh"

# Regression: commands with GIT_ env var prefix that are NOT pushes must pass.
# Previously the ^GIT_ alternative in the segment regex caught any command
# starting with GIT_, even git commit with a GIT_AUTHOR_DATE prefix.
expect_allow "GIT_AUTHOR_DATE prefix on commit"       "GIT_AUTHOR_DATE='2026-04-11' git commit -m 'test'"
expect_allow "GIT_COMMITTER_DATE prefix on commit"    "GIT_COMMITTER_DATE='2026-04-11' git commit -m 'test'"
expect_allow "env GIT_AUTHOR_DATE on commit"          "env GIT_AUTHOR_DATE='2026-04-11' git commit -m 'test'"

# But GIT_ env var prefix on an actual push MUST still be caught by the
# downstream "git push anywhere in segment" check.
expect_block "GIT_SSH_COMMAND prefix on push"         "GIT_SSH_COMMAND=ssh git push origin main"
expect_block "GIT_ASKPASS prefix on push"             "GIT_ASKPASS=cat git push origin main"

# ============================================================
# SECTION 5: spellings git honours and the old string match missed (AC-9)
# ============================================================
#
# Every case below is a real push whose destination is main. The pre-1.3.2 hook
# read the command as text — `git push` had to be two adjacent words, quotes
# were deleted wholesale, and a refspec was matched with a regex — so a global
# option, a quoted branch name or a refs/heads/ spelling walked straight past
# it (research-b3-b5-b9-cmd-parsing.md §2). The branch is a feature branch here
# so Block 3 (any push while on main) cannot mask the result: what these pin is
# the destination reading, nothing else.

section "Section 5: git spellings that reach main (all BLOCKED)"
export FAKE_BRANCH="feat/cool-thing"

expect_block "AC-9 -C <dir> global option"        "git -C /tmp/r push origin main"
expect_block "AC-9 -c <cfg> global option"        "git -c user.name=x push origin main"
expect_block "AC-9 HEAD:refs/heads/main"          "git push origin HEAD:refs/heads/main"
expect_block "AC-9 delete refspec :main"          "git push origin :main"
expect_block "AC-9 force refspec +main"           "git push origin +main"
expect_block "AC-9 double-quoted main"            'git push origin "main"'
expect_block "AC-9 single-quoted main"            "git push origin 'main'"
expect_block "AC-9 refs/heads/main"               "git push origin refs/heads/main"
expect_block "AC-9 feature:refs/heads/main"       "git push origin feature:refs/heads/main"
expect_block "AC-9 force-with-lease onto main"    "git push --force-with-lease origin main"
expect_block "AC-9 -C <dir> force push of main"   "git -C /tmp/r push --force origin main"

# The force wall is a wall wherever the flag sits, including behind a global
# option — research measured `git -C /tmp/r push --force origin feature` as a
# clean miss.
expect_block "AC-9 -C <dir> force push of a feature branch" \
                                                  "git -C /tmp/r push --force origin feature"

# ============================================================
# SECTION 6: spellings that only LOOK like a main push (AC-10)
# ============================================================
#
# The mirror image. `topic/main` and `main-fixes` are ordinary branches;
# `echo` and a heredoc body are text the shell prints or writes, not a push it
# runs. The heredoc case is the one the old hook got backwards: it split
# segments on newlines, so every line of a body became a candidate command and
# a document that MENTIONED a main push was refused as if it were one.

section "Section 6: near-misses and prose (all ALLOWED)"
export FAKE_BRANCH="feat/cool-thing"

expect_allow "AC-10 topic/main is its own branch"  "git push origin topic/main"
expect_allow "AC-10 main-fixes is its own branch"  "git push origin main-fixes"
expect_allow "AC-10 HEAD:refs/heads/feature/main"  "git push origin HEAD:refs/heads/feature/main"
expect_allow "AC-10 echo of a push line"           "echo 'git push origin main'"

HEREDOC_PUSH=$(printf 'cat > /tmp/note.txt <<%sNOTE%s\ngit push origin main\nNOTE\n' "'" "'")
expect_allow "AC-10 heredoc body containing a push line" "$HEREDOC_PUSH"

# A heredoc must not swallow the command that follows it either.
HEREDOC_THEN_PUSH=$(printf 'cat > /tmp/note.txt <<%sNOTE%s\nnothing to see\nNOTE\ngit push origin main\n' "'" "'")
expect_block "after a heredoc, a real main push is still blocked" "$HEREDOC_THEN_PUSH"

# ============================================================
# SECTION 7: shell constructs and command-taking prefixes (AC-9, R-12)
# ============================================================
#
# THE REGRESSION THIS SECTION EXISTS FOR (critic C-1, 2026-08-30). The 1.3.2
# rewrite reads argv[0] of a segment split on `; && || | &`. The 1.3.1 hook it
# replaced matched `(^|[[:space:]])git[[:space:]]+push` — the token after ANY
# whitespace. So every construct that starts a new command WITHOUT one of those
# separators (`(`, `{`, `then`, `do`), and every command that takes another
# command as its argument (`sudo`, `time`, `xargs`, `find -exec`, `ssh`), put
# `git` at argv[1..n] where the new reader does not look. Nine spellings 1.3.1
# refused walked through 1.3.2 (critic-step6.md §C-1 Repro 1). R-12 makes the
# argv reading a SUPERSET: openers are skipped before argv[0] is read, prefixes
# are skipped with their own options, and `sh -c`/`eval` strings are re-read.
#
# Feature branch again, so Block 3 cannot mask the result.

section "Section 7: openers, prefixes and runner strings (all BLOCKED)"
export FAKE_BRANCH="feat/cool-thing"

# --- shell constructs that open a command without a separator ---
expect_block "AC-9 subshell ( … )"                "( git push origin main )"
expect_block "AC-9 subshell without spaces"       "(git push origin main)"
expect_block "AC-9 group { …; }"                  "{ git push origin main; }"
expect_block "AC-9 if/then"                       "if true; then git push origin main; fi"
expect_block "AC-9 if <command> directly"         "if git push origin main; then echo ok; fi"
expect_block "AC-9 for/do"                        "for i in 1; do git push origin main; done"
expect_block "AC-9 while/do"                      "while false; do git push origin main; done"
expect_block "AC-9 else branch"                   "if false; then true; else git push origin main; fi"
expect_block "AC-9 negation !"                    "! git push origin main"
expect_block "AC-9 background & is a separator"   "true & git push origin main"

# --- commands whose argument is another command ---
expect_block "AC-9 sudo"                          "sudo git push origin main"
expect_block "AC-9 sudo -u <user>"                "sudo -u ci git push origin main"
expect_block "AC-9 sudo --"                       "sudo -- git push origin main"
expect_block "AC-9 time"                          "time git push origin main"
expect_block "AC-9 time -p"                       "time -p git push origin main"
expect_block "AC-9 nice -n <N>"                   "nice -n 10 git push origin main"
expect_block "AC-9 nice (bare)"                   "nice git push origin main"
expect_block "AC-9 timeout <N>"                   "timeout 60 git push origin main"
expect_block "AC-9 gtimeout <N>"                  "gtimeout 60 git push origin main"
expect_block "AC-9 timeout -s KILL <N>"           "timeout -s KILL 60 git push origin main"
expect_block "AC-9 timeout 30s (suffixed)"        "timeout 30s git push origin main"
expect_block "AC-9 nohup"                         "nohup git push origin main"
expect_block "AC-9 exec"                          "exec git push origin main"
expect_block "AC-9 command"                       "command git push origin main"
expect_block "AC-9 env VAR=v"                     "env GIT_ASKPASS=cat git push origin main"
expect_block "AC-9 xargs"                         "xargs git push origin main"
expect_block "AC-9 xargs -I{}"                    "xargs -I{} git push origin main"
expect_block "AC-9 xargs -I {} (separate value)"  "xargs -I {} git push origin main"
expect_block "AC-9 xargs -n 1 -0"                 "xargs -n 1 -0 git push origin main"
expect_block "AC-9 find … -exec … \\;"            "find . -exec git push origin main \\;"
expect_block "AC-9 find … -execdir … \\;"         "find . -execdir git push origin main \\;"
expect_block "AC-9 ssh <host>"                    "ssh box git push origin main"
expect_block "AC-9 ssh -p <port> <host>"          "ssh -p 22 box git push origin main"

# --- runner strings: one level of re-reading (C-5) ---
expect_block "AC-9 sh -c '<string>'"              "sh -c 'git push origin main'"
expect_block "AC-9 bash -c \"<string>\""          'bash -c "git push origin main"'
expect_block "AC-9 zsh -c '<string>'"             "zsh -c 'git push origin main'"
expect_block "AC-9 dash -c '<string>'"            "dash -c 'git push origin main'"
expect_block "AC-9 eval \"<string>\""             'eval "git push origin main"'
expect_block "AC-9 eval '<string>'"               "eval 'git push origin main'"
expect_block "AC-9 sh -c over a construct"        "sh -c '( git push origin main )'"

# --- stacked: a prefix in front of a construct, and vice versa ---
expect_block "AC-9 then + sudo"                   "if true; then sudo git push origin main; fi"
expect_block "AC-9 subshell + time"               "( time git push origin main )"

# --- and the negatives stay negative ---
expect_allow "AC-10 echo of a sudo push line"     'echo "sudo git push origin main"'
expect_allow "AC-10 echo of a subshell push line" "echo '( git push origin main )'"
expect_allow "AC-10 find with no -exec"           "find . -name 'git'"
expect_allow "AC-10 find -name git push"          "find . -name 'git push'"
expect_allow "AC-10 sudo of a non-push"           "sudo git status"
expect_allow "AC-10 xargs of a non-push"          "xargs git log"
expect_allow "AC-10 sudo push to a topic branch"  "sudo git push origin topic/main"
expect_allow "AC-10 then + push to a topic branch" "if true; then git push origin topic/main; fi"
expect_allow "AC-10 ssh to a host called main"    "ssh main ls"
expect_allow "AC-10 a heredoc body with a sudo push" \
  "$(printf 'cat > /tmp/note.txt <<%sNOTE%s\nsudo git push origin main\nNOTE\n' "'" "'")"
expect_allow "AC-10 echo of a timeout push line"  'echo "timeout 60 git push origin main"'

# --- B-1 (review-b): a QUOTED <<WORD must not open a phantom heredoc ---
# `echo "see <<EOF for the format"` had no quote state in the heredoc scan, so
# every following line was read as body — a real push on the next line walked
# through 1.3.2 and was blocked by 1.3.1.
expect_block "B-1 a quoted <<WORD does not swallow the next line" \
  "$(printf 'echo "see <<EOF for the heredoc format"\ngit push origin main\n')"
expect_block "B-1 …single-quoted too" \
  "$(printf "echo 'run <<EOF to open a heredoc'\ngit push origin main\n")"
# PAIRED POSITIVE: a real unquoted opener still hides its body.
expect_allow "B-1 an UNQUOTED heredoc body is still ignored" \
  "$(printf 'cat > /tmp/n.txt <<EOF\ngit push origin main\nEOF\n')"

# ============================================================
# The unengaged session: this wall is not there at all (AC-20)
# ============================================================
#
# THE PAIR, on the same commands every block row above refuses. Chris, 2026-09-03: "all
# guardrails imposed by bionic should only apply when exercising bionic. Nothing should
# apply until bionic is triggered." A session that never invoked the skill leaves no
# `.bionic/tmp/engaged-<sid>.state` and this wall says nothing at all: exit 0, empty
# stdout, empty stderr — not a quieter refusal, no refusal.
#
# The branch stays `main` throughout, so the third block (any push while ON main) is
# live for every row here and each one is a command that WOULD be refused two lines up.

section "the unengaged session: silent on the pushes every section above blocks"

export FAKE_BRANCH=main

pm_unengaged() {  # <label> <command> — expect exit 0, empty stdout, empty stderr
  local label="$1" cmd="$2" out err st=0
  out=$(pm_payload "$PLAIN_REPO" "$cmd" \
          | env CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= bash "$HOOK" 2>"$PM_SANDBOX/.err") || st=$?
  err=$(cat "$PM_SANDBOX/.err")
  if [ "$st" = "0" ] && [ -z "$out" ] && [ -z "$err" ]; then
    ok "$label"
  else
    no "$label" "exit=$st stdout=[$out] stderr=[$err]"
  fi
}

pm_unengaged "AC-20 a push to main passes an unengaged session"  "git push origin main"
pm_unengaged "AC-20 ...a FORCE push to main passes"              "git push --force origin main"
pm_unengaged "AC-20 ...a force push to a feature branch passes"  "git push --force origin feature/x"
pm_unengaged "AC-20 ...a bare push while ON main passes"         "git push"
pm_unengaged "AC-20 ...git -C <dir> push origin master passes"   "git -C /tmp/r push origin master"

# A SYMLINK AT THE MARKER PATH IS NOT A MARKER (lib/run.sh refuses `-L` before following
# it): the one shape that could otherwise open every wall on the machine from outside the
# repo it points into.
ln -s "$ENGAGED_REPO/.bionic/tmp/engaged-$SID.state" "$PLAIN_REPO/.bionic/tmp/engaged-$SID.state"
pm_unengaged "AC-20 ...a SYMLINK at the marker path is not engagement" "git push --force origin main"
rm -f "$PLAIN_REPO/.bionic/tmp/engaged-$SID.state"

# ...AND THE POSITIVE CONTROL FOR THIS SECTION'S OWN MACHINERY: the identical driver,
# pointed at the ENGAGED repo, still refuses. Without it every row above would also pass
# on a hook that had simply stopped working.
if pm_payload "$ENGAGED_REPO" "git push --force origin main" \
     | env CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= bash "$HOOK" >/dev/null 2>&1; then
  no "AC-20 control — the same driver on the ENGAGED repo still BLOCKS"
else
  ok "AC-20 control — the same driver on the ENGAGED repo still BLOCKS"
fi

# ============================================================
section "AC-E1.3/E1.5: every refusal is one line, in the criterion's shape"
# ============================================================
#
# fails-when: a refusal reaches the user as more than one line, or in any shape but
# `bionic: <verb> refused — <fact> (<fix ≤ 40 cols>)`. Each of this wall's three
# refusal sites is TRIPPED for real here — the stderr asserted is the one a live
# session would paint (e1-measurement.md §D-2 F-D2-3) — and each is checked against
# the criterion's own regex, then against the exact line the ruled wording table
# gives it (s12-refusal-wording-draft.md §1 rows 2, 3 and 4).

PM_LINE_RE='^bionic: [a-z-]+ refused — .+ \(.{1,40}\)$'
pm_stderr() {  # <branch> <command> -> the hook's stderr, verbatim
  FAKE_BRANCH="$1" pm_payload "$ENGAGED_REPO" "$2" \
    | env CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= FAKE_BRANCH="$1" \
        bash "$HOOK" 2>"$PM_SANDBOX/.err" >/dev/null
  cat "$PM_SANDBOX/.err"
}

pm_one_line() {  # <label> <branch> <command> <expected line>
  local _lbl="$1" _br="$2" _cmd="$3" _want="$4" _got _n
  _got="$(pm_stderr "$_br" "$_cmd")"
  _n="$(wc -l < "$PM_SANDBOX/.err" | tr -d ' ')"
  eq_or() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }
  eq_or "$_lbl: exactly one line on the user stream" "$_n" "1"
  if printf '%s' "$_got" | /usr/bin/grep -qE "$PM_LINE_RE"; then
    ok "$_lbl: in AC-E1.3's shape"
  else
    no "$_lbl: in AC-E1.3's shape" "line=[$_got]"
  fi
  eq_or "$_lbl: and it is the table's own wording" "$_got" "$_want"
}

pm_one_line "row 2 (a protected destination)" "feature/x" "git push origin main" \
  "bionic: push refused — main is a protected branch here (push from your own terminal)"
pm_one_line "row 3 (a force push)" "feature/x" "git push --force origin feature/x" \
  "bionic: push refused — this is a force push (push from your own terminal)"
pm_one_line "row 4 (pushing from a protected branch)" "main" "git push origin feature/x" \
  "bionic: push refused — the current branch is protected (switch to a feature branch)"

# THE DETAIL IS BEHIND THE KNOB, end to end through this real wall (AC-E1.5). The
# branch name is the value the one line had no room for, and the knob is where it
# lives — asserted absent without it and present with it, so neither half can pass
# over an empty stream.
PM_KNOB_OFF="$(pm_stderr "main" "git push origin feature/x")"
case "$PM_KNOB_OFF" in
  *"feature branch"*) ok "AC-E1.5 without the knob the user line carries no detail" ;;
  *) no "AC-E1.5 without the knob the user line carries no detail" ;;
esac
case "$PM_KNOB_OFF" in
  *'The current branch is'*) no "AC-E1.5 …the detail sentence is NOT on the user stream" ;;
  *) ok "AC-E1.5 …the detail sentence is NOT on the user stream" ;;
esac
pm_payload "$ENGAGED_REPO" "git push origin feature/x" \
  | env CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= FAKE_BRANCH="main" \
      BIONIC_WALL_VERBOSE=1 bash "$HOOK" 2>"$PM_SANDBOX/.errv" >/dev/null || true
PM_KNOB_ON="$(cat "$PM_SANDBOX/.errv")"
case "$PM_KNOB_ON" in
  *'The current branch is "main"'*) ok "AC-E1.5 with BIONIC_WALL_VERBOSE=1 the detail names the branch" ;;
  *) no "AC-E1.5 with BIONIC_WALL_VERBOSE=1 the detail names the branch" "got=[$PM_KNOB_ON]" ;;
esac
if printf '%s' "$PM_KNOB_ON" | head -1 | /usr/bin/grep -qE "$PM_LINE_RE"; then
  ok "AC-E1.5 …and the one line is still the first of it"
else
  no "AC-E1.5 …and the one line is still the first of it"
fi

rm -rf "$PM_SANDBOX"

finish
