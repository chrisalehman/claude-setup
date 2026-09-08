#!/bin/bash
# tests/cmd-class.test.sh — payload/scripts/lib/cmd-class.sh and the two hooks that read it.
#
# THE DEFECT THIS SUITE EXISTS FOR (B-5, wave-bionic-1.3.2). farm-out-reminder.sh used to
# grep one flattened string for tier-1 tokens with mid-string anchors, so `make( +[^ ]+)?`
# after any space denied `git commit -m "make the row green"` as class=build, and a heredoc
# body carrying `bash tests/run.sh` denied as class=suite. Research measured both
# (record/wave-bionic-1.3.2-dogfood-fixes/research-b3-b5-b9-cmd-parsing.md §2). The cure is
# to read argv POSITIONS instead of substrings: prose, quoted strings and heredoc bodies
# are never argv[0] of anything, so they never classify.
#
# AND THE ARM B-9 ADDS. hooks/background-suite-guard.sh refuses a subagent's
# `run_in_background: true` Bash call when the same reader says the command is suite-class,
# so a suite's evidence cannot be produced where no one is reading the output.
#
# HERMETIC. Every payload is crafted and piped into a hook; nothing dispatches a real tool
# call, reads the operator's ~/.claude, or depends on a live wave. Repos are throwaway git
# inits under a mktemp'd sandbox, HOME is redirected.
#
# FIXTURE FIDELITY (declared, per .claude memory fixtures-can-pin-away-the-test):
#   * PreToolUse|Bash payload envelope — the shape tests/protect-main.test.sh already pipes
#     into a live Bash hook, plus the two fields these arms turn on: a top-level `agent_id`
#     (measured present in an agent context / absent on the main thread,
#     record/w3-slice1-posttooluse-probe.md §3) and `tool_input.run_in_background`.
#   * `run_in_background` — declared OPTIONAL on the Bash tool input by the shipped CLI
#     schema (@anthropic-ai/claude-code 2.1.251, sdk-tools.d.ts:722). ABSENT, never
#     `false`, when the caller did not set it — which is why the arm tests `== true`.
#     NOT YET OBSERVED in a captured PreToolUse|Bash hook payload (A-3, s5-report.md):
#     these cases prove the hook's logic against the documented shape, not the transport.
#   * roster stamp, attestation, session ids — SYNTHESIZED, the same schema
#     tests/agent-context-guard.test.sh writes.
#
# Usage: bash tests/cmd-class.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/roster-row.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# THE TWO SPELLINGS OF ONE DIRECTORY. payload/hooks is a symlink to <repo>/hooks, so a hook
# is reached BOTH as <repo>/payload/hooks/x.sh (what ${CLAUDE_PLUGIN_ROOT} renders) and as
# <repo>/hooks/x.sh (what tests/lib/resolve-roots.sh renders). `$0` is textual, so
# "$(dirname "$0")/../scripts/lib" resolves only under the first. Both are driven below.
PAYLOAD_HOOKS="$REPO_ROOT/payload/hooks"
PLAIN_HOOKS="${BIONIC_HOOKS_DIR}"
LIB="$REPO_ROOT/payload/scripts/lib/cmd-class.sh"
FARM_OUT="$PAYLOAD_HOOKS/farm-out-reminder.sh"
BG_GUARD="$PAYLOAD_HOOKS/background-suite-guard.sh"
CTX_GUARD="$PAYLOAD_HOOKS/agent-context-guard.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cmd-class-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

SID="7b2ae913-0c4f-4d21-9a55-13e0c7ab4d10"
AGENT_ID="as5class-91ab3cd7e5f20114"

FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME/.claude/projects/-sandbox"
: > "$FAKE_HOME/.claude/projects/-sandbox/$SID.jsonl"

section "C0 — the library and both hooks exist and parse"
if [ -f "$LIB" ]; then ok "payload/scripts/lib/cmd-class.sh is on disk"; else
  no "payload/scripts/lib/cmd-class.sh is on disk" "$LIB"
fi
if bash -n "$LIB" 2>"$SANDBOX/.syn"; then ok "the library parses (bash -n)"; else
  no "the library parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi
if bash -n "$BG_GUARD" 2>"$SANDBOX/.syn"; then ok "background-suite-guard.sh parses (bash -n)"; else
  no "background-suite-guard.sh parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi
if bash -n "$FARM_OUT" 2>"$SANDBOX/.syn"; then ok "farm-out-reminder.sh parses (bash -n)"; else
  no "farm-out-reminder.sh parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi

section "C1 — the library reads argv positions, never prose"
# Driven through a child bash that sources the library, so a `set -e`/`set -u` collision or
# a stray write to the caller's shell shows up here rather than corrupting the suite.
class_of() {  # <command> -> the library's verdict
  printf '%s' "$1" | bash -c '
    set -uo pipefail
    . "$1" || { echo "SOURCE-FAILED"; exit 1; }
    cmd_class "$(cat)"
  ' _ "$LIB" 2>&1
}

case_is() {  # <expected class> <command> [label]
  local want="$1" cmd="$2" got
  got=$(class_of "$cmd")
  expect_eq "${3:-$want: $cmd}" "$want" "$got"
}

# --- the classes that must still be caught (AC-16 at the library level) ---
case_is suite 'bash tests/run.sh'
case_is suite 'bash tests/run.sh --serial'
case_is suite 'bash tests/cmd-class.test.sh'
case_is suite 'bash test.sh'
case_is suite 'pytest'
case_is suite 'pytest tests/'
case_is suite 'npm test'
case_is suite 'pnpm test'
case_is suite 'yarn test'
case_is suite 'go test ./...'
case_is suite 'cargo test'
case_is suite 'make test'
case_is suite 'make check'
case_is suite 'cd /tmp/x && bash tests/run.sh'
case_is suite 'FOO=1 bash tests/run.sh'
case_is suite 'cd x && FARM_OUT_ALLOW= bash tests/run.sh'
case_is suite 'bash tests/run.sh 2>&1 | tee /tmp/evidence.log'
case_is suite 'env nohup timeout 30 bash tests/run.sh'
case_is suite "bash -c 'bash tests/run.sh'"
case_is suite '/usr/local/bin/pytest tests/'

case_is build 'make'
case_is build 'make widget'
case_is build 'npm run build'
case_is build 'cargo build'
case_is build 'go build ./...'
case_is build 'docker build .'

case_is install 'npm install'
case_is install 'pnpm add left-pad'
case_is install 'pip3 install requests'
case_is install 'uv sync'
case_is install 'brew install jq'

case_is bootstrap 'bash claude-bootstrap.sh'
case_is bootstrap './claude-bootstrap.sh'

# --- R-12: the reading is a SUPERSET of the 1.3.1 string match (critic C-1) ---
# A suite reached through a shell construct or a command-taking prefix lands at
# argv[1..n], where the 1.3.2 reader did not look, so `sudo bash tests/run.sh`
# and `( bash tests/run.sh )` walked past both the farm-out wall and the new
# B-9 background wall that 1.3.1's `(^|[;&| ])bash +tests/run\.sh` refused.
case_is suite 'sudo bash tests/run.sh'
case_is suite 'sudo -u ci bash tests/run.sh'
case_is suite '( bash tests/run.sh )'
case_is suite '(bash tests/run.sh)'
case_is suite '{ bash tests/run.sh; }'
case_is suite 'if true; then bash tests/run.sh; fi'
case_is suite 'for i in 1; do bash tests/run.sh; done'
case_is suite '! bash tests/run.sh'
case_is suite 'xargs bash tests/run.sh'
case_is suite 'xargs -I{} bash tests/run.sh'
case_is suite 'nice -n 10 bash tests/run.sh'
case_is suite 'exec bash tests/run.sh'
case_is suite 'ssh box bash tests/run.sh'
case_is suite 'find . -exec bash tests/run.sh \;'
case_is suite 'true & bash tests/run.sh'
case_is suite 'eval "bash tests/run.sh"'
case_is suite "sh -c 'sudo bash tests/run.sh'"

# --- C-2: a DIRECTLY EXECUTED suite is a suite ---
# tests/run.sh is -rwxr-xr-x with a bash shebang, so `./tests/run.sh` is an
# ordinary invocation; classify_argv only reached the suite arm when argv[0]
# was bash/sh/zsh, so a script at argv[0] fell through every arm to `none`.
# And the `bash run.sh` arm required a `/` in the name, which is exactly the
# shape `cd <worktree>/tests && bash run.sh` does not have.
case_is suite './tests/run.sh'
case_is suite 'tests/run.sh'
case_is suite './tests/run.sh --serial'
case_is suite './tests/cmd-class.test.sh'
case_is suite 'tests/cmd-class.test.sh'
case_is suite './test.sh'
case_is suite 'cd tests && bash run.sh'
case_is suite '(cd tests; bash run.sh)'
case_is suite 'cd tests && bash run.sh 2>&1 | tee /tmp/e.log'
case_is suite 'bash -c "./tests/run.sh"'
case_is suite 'sudo ./tests/run.sh'

# --- and the negatives the superset must NOT swallow ---
case_is none 'ls tests/run.sh'
case_is none 'cat ./tests/run.sh'
case_is none 'echo "sudo bash tests/run.sh"'
case_is none "echo '( bash tests/run.sh )'"
case_is none 'vim tests/run.sh'
case_is none 'git add tests/run.sh'
case_is none 'find . -name run.sh'
case_is none 'bash run.sh'
case_is none 'run.sh'
case_is none 'sudo git status'

# --- cmd_unwrap_head: the reduction farm-out's tier-2 matcher reads (B-4a) ---
# It replaced two sed twins in farm-out-reminder.sh whose rule set was smaller
# than the library's, so `sudo npx x` and `FOO=1 npx x` never reached tier-2.
head_of() { bash -c '. "$1" || exit 1; cmd_unwrap_head "$2"' _ "$LIB" "$2" 2>&1; }
expect_eq "head: a bare command is unchanged"      'npx create-thing' "$(head_of _ 'npx create-thing')"
expect_eq "head: env prefix comes off"             'npx create-thing' "$(head_of _ 'env npx create-thing')"
expect_eq "head: an ordinary assignment comes off" 'npx create-thing' "$(head_of _ 'FOO=1 npx create-thing')"
expect_eq "head: sudo comes off"                   'npx create-thing' "$(head_of _ 'sudo npx create-thing')"
expect_eq "head: timeout <n> comes off"            'npx create-thing' "$(head_of _ 'timeout 60 npx create-thing')"
expect_eq "head: nohup comes off"                  'npx create-thing' "$(head_of _ 'nohup npx create-thing')"
expect_eq "head: one sh -c wrapper comes off"      'npx create-thing' "$(head_of _ "sh -c 'npx create-thing'")"
expect_eq "head: eval comes off"                   'npx create-thing' "$(head_of _ 'eval "npx create-thing"')"
expect_eq "head: bash <(cat F) collapses to the script" 'bash tests/run.sh' "$(head_of _ 'bash <(cat tests/run.sh)')"
expect_eq "head: prose is left alone"              'echo make sure the row is green' \
  "$(head_of _ 'echo make sure the row is green')"

# --- prose, quoted strings and heredoc bodies NEVER classify (AC-15, B-5) ---
case_is none 'git commit -m "make the row green"'
case_is none 'echo "npm install done"'
case_is none "echo 'make sure the row is green'"
case_is none 'git commit -m "run npm install first"'
case_is none 'ls claude-bootstrap.sh'
case_is none 'make clean'
case_is none 'echo remake'
case_is none 'echo make sure the row is green'   # the UNQUOTED prose the old `make( +[^ ]+)?` denied
case_is none 'cat notes.md | grep make'
case_is none 'grep -n "bash tests/run.sh" notes.md'

HEREDOC_CMD="python3 - <<'EOF'
pytest tests/policies
152 passed
bash tests/run.sh
make sure the row is green
npm install first
EOF"
case_is none "$HEREDOC_CMD" "none: a heredoc body carrying suite/build/install words"

HEREDOC_DASH="cat <<-END > /tmp/notes.txt
	make the row green
	END"
case_is none "$HEREDOC_DASH" "none: a <<- heredoc body with a tab-indented terminator"

# A heredoc that OPENS a real suite command after the terminator still classifies.
HEREDOC_THEN_SUITE="cat <<'EOF' > /tmp/n.txt
make the row green
EOF
bash tests/run.sh"
case_is suite "$HEREDOC_THEN_SUITE" "suite: a real command AFTER a heredoc still classifies"

section "C2/C3 — farm-out-reminder through the library (AC-15, AC-16)"
# ---------- engagement (task-engaged-session, AC-6 / AC-20) ----------
#
# Since 2026-09-03 both hooks this section drives ask one question before any other: did
# this session invoke the canonical-sdlc skill? (Chris: "all guardrails imposed by bionic
# should only apply when exercising bionic. Nothing should apply until bionic is
# triggered.") hooks/engage.sh answers it by writing `.bionic/tmp/engaged-<sid>.state`
# under the project root, creating the directory where there is none.
#
# EVERY FIXTURE BELOW IS ENGAGED, including the negative controls — otherwise the run
# predicate and the classifier, which are what those controls are about, would never be
# reached and each would pass for the wrong reason. §C6 at the bottom is the unengaged
# world, and it is the only place the marker is absent.
engage()   { mkdir -p "$1/.bionic/tmp" && : > "$1/.bionic/tmp/engaged-$SID.state"; }
unengage() { rm -f "$1/.bionic/tmp/engaged-$SID.state"; }

FARM_REPO="$SANDBOX/farm/repo"
mkdir -p "$FARM_REPO/.bionic/tmp" "$FARM_REPO/.bionic/docs/plans"
engage "$FARM_REPO"
# THE WALL IS RUN-SCOPED SINCE bionic 1.4.0 (slice ADOPT, spec AC-7). The hook is
# registered always-on now, so what scopes it is an on-disk fact rather than an armed
# skill: `active_run` under the payload's project root. Every AC-16 arm below asks
# whether the wall still refuses the real thing, and none of them would be asking
# anything without an OPEN run here. The negative control is FARM_NORUN, further down.
cat > "$FARM_REPO/.bionic/docs/plans/wave-01.plan.md" <<'FARMPLAN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: implementation
FARMPLAN

mk_bash_payload() {  # <cwd> <command> [agent_id] [run_in_background:true|false|omit]
  local bg="${4:-omit}"
  jq -n --arg s "$SID" --arg c "$1" --arg cmd "$2" --arg a "${3:-}" \
        --arg bg "$bg" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      permission_mode:"bypassPermissions",
      hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:({command:$cmd}
                  + (if $bg == "omit" then {} else {run_in_background: ($bg == "true")} end)),
      tool_use_id:"toolu_01cmdclass"}
     + (if $a == "" then {} else {agent_id:$a} end)'
}

OUT=""; ERR=""; ST=0
run_hook() {  # <payload> <hook> [args...]
  local payload="$1"; shift
  # BIONIC_PLUGINS_DIR is pointed at an empty sandbox for the same reason HOME is:
  # since bionic 1.4.0 the loader HEALS before it fails, consulting the CLI's plugin
  # registry and cache when the library is not beside the hook. Without this door
  # closed, §C5's "library moved aside" fixture would quietly load THIS machine's
  # installed bionic and prove nothing.
  # THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does (A-probe-2).
  # hooks/agent-context-guard.sh builds the roster filename from lib/session.sh's answer,
  # where the ENV value is primary — so a driver that left the runner's own session id in
  # the environment would have the guard looking for a roster this fixture never wrote,
  # and every wall behind it would read "unarmed".
  local _sid; _sid=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  OUT=$(printf '%s' "$payload" | env HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" \
          BIONIC_PLUGINS_DIR="$SANDBOX/no-plugins" CLAUDE_CODE_SESSION_ID="$_sid" \
          CLAUDE_PROJECT_DIR= bash "$@" 2>"$SANDBOX/.err")
  ST=$?
  ERR=$(cat "$SANDBOX/.err")
  return 0
}

farm_decision() {  # <command> -> "" when silent, else the deny/nudge class
  run_hook "$(mk_bash_payload "$FARM_REPO" "$1")" "$FARM_OUT"
  printf '%s' "$OUT"
}

# --- AC-6/R-1: the nudge is PLAN-FREE — engagement alone scopes it ---
#
# THE DEFECT (step-6 review R-1). Until this fix the hook carried
# `active_run "$ROOT" >/dev/null || exit 0` below its engagement guard, so an engaged
# session that had not yet written a plan — the whole of Step 0 through Step 3 — ran its
# suites with no nudge at all. The ratified design says otherwise: engagement decides
# WHETHER a bionic wall speaks, and the farm-out nudge needs no plan to know that a suite
# command belongs in a subagent. The run predicate stayed behind after the 1.4.0 guard
# landed above it; it is gone now.
#
# THE PAIR. Two fixtures with NO plan on disk, differing only in the engagement marker.
# Engaged → the same suite command that denies above denies here. Unengaged → silence on
# both channels. Neither row can pass on a hook that had simply stopped working, because
# the other row proves it still fires.
FARM_NORUN="$SANDBOX/farm/norun"
mkdir -p "$FARM_NORUN"
engage "$FARM_NORUN"
run_hook "$(mk_bash_payload "$FARM_NORUN" 'bash tests/run.sh')" "$FARM_OUT"
expect_contains "R-1 farm-out DENIES a suite command with NO plan on disk (nudge is plan-free)" \
  '"deny"' "$OUT"
expect_eq "R-1 …exiting 0" "0" "$ST"

# The tier-2 nudge, same world: no plan, engaged, still spoken.
run_hook "$(mk_bash_payload "$FARM_NORUN" 'npx create-react-app x')" "$FARM_OUT"
expect_contains "R-1 …the tier-2 nudge also fires with no plan on disk" \
  'additionalContext' "$OUT"

# THE PAIRED SILENCE: same tree, same commands, marker removed.
unengage "$FARM_NORUN"
run_hook "$(mk_bash_payload "$FARM_NORUN" 'bash tests/run.sh')" "$FARM_OUT"
expect_empty "R-1 …and with no marker and no plan it is SILENT on stdout" "$OUT"
expect_empty "R-1 …and silent on stderr" "$ERR"
expect_eq "R-1 …exiting 0" "0" "$ST"
engage "$FARM_NORUN"

FARM_CLOSED="$SANDBOX/farm/closed"
mkdir -p "$FARM_CLOSED/.bionic/docs/plans"
engage "$FARM_CLOSED"
cat > "$FARM_CLOSED/.bionic/docs/plans/wave-01.plan.md" <<'CLOSEDPLAN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 9

- Step 9: delivered: record/x.md
CLOSEDPLAN
run_hook "$(mk_bash_payload "$FARM_CLOSED" 'bash tests/run.sh')" "$FARM_OUT"
expect_contains "R-1 …a CLOSED run does not silence it either (current: 9)" '"deny"' "$OUT"
expect_eq "R-1 …exiting 0" "0" "$ST"

# --- AC-15: silent on prose, quoted strings and heredoc bodies ---
expect_empty "AC-15 farm-out is SILENT on git commit -m \"make the row green\"" \
  "$(farm_decision 'git commit -m "make the row green"')"
expect_empty "AC-15 …silent on a heredoc body carrying pytest/bash tests/run.sh" \
  "$(farm_decision "$HEREDOC_CMD")"
expect_empty "AC-15 …silent on echo \"npm install done\"" \
  "$(farm_decision 'echo "npm install done"')"
# THE UNQUOTED SHAPE, which is the one that was measurably RED (research-b3 §2: the quote
# in `echo 'make sure…'` blocked the space anchor by luck, so only the unquoted spelling and
# the heredoc body reproduced the field DENY).
# SINGLE-quoted labels, deliberately. These two carried backticks inside DOUBLE
# quotes until 2026-08-30, so the suite ran `make` and `npm install` for real on
# every invocation — writing a package-lock.json into the repo root and a log
# into ~/.npm/_logs (auditor-step5.md F-3). A test suite must not execute the
# commands it is describing.
expect_empty 'AC-15 …silent on unquoted prose carrying `make <word>`' \
  "$(farm_decision 'echo make sure the row is green')"
expect_empty 'AC-15 …silent on unquoted prose carrying `npm install`' \
  "$(farm_decision 'echo run npm install first')"

# --- AC-16: still a wall on the real thing ---
D=$(farm_decision 'bash tests/run.sh --serial')
expect_contains "AC-16 farm-out still DENIES bash tests/run.sh --serial" '"deny"' "$D"
expect_contains "AC-16 …as class suite, redirected to test-runner" 'test-runner' "$D"
D=$(farm_decision 'cd x && FARM_OUT_ALLOW= bash tests/run.sh')
expect_contains "AC-16 …DENIES cd x && FARM_OUT_ALLOW= bash tests/run.sh (empty is not the override)" \
  '"deny"' "$D"
expect_contains "AC-16 …DENIES pytest tests/" '"deny"' "$(farm_decision 'pytest tests/')"
expect_contains "AC-16 …DENIES npm test" '"deny"' "$(farm_decision 'npm test')"
expect_contains "AC-16 …DENIES make test" '"deny"' "$(farm_decision 'make test')"

# --- AC-16 (R-12/C-2): the same wall through a construct, a prefix, or a
#     directly executed script. One list, driven through BOTH walls below. ---
SUPERSET_SUITES=(
  'sudo bash tests/run.sh'
  '( bash tests/run.sh )'
  'if true; then bash tests/run.sh; fi'
  'xargs bash tests/run.sh'
  './tests/run.sh'
  'tests/run.sh'
  'cd tests && bash run.sh'
  '(cd tests; bash run.sh)'
)
for sc in "${SUPERSET_SUITES[@]}"; do
  expect_contains "AC-16 farm-out DENIES [$sc]" '"deny"' "$(farm_decision "$sc")"
done

# --- behaviour the library must not have changed ---
expect_empty "the sanctioned override still silences the wall" \
  "$(farm_decision 'FARM_OUT_ALLOW=1 bash tests/run.sh')"
expect_empty "…including as an env prefix mid-chain" \
  "$(farm_decision 'cd x && FARM_OUT_ALLOW=1 bash tests/run.sh')"
expect_empty "a subagent payload leaves farm-out silent (agent_type non-empty)" \
  "$(printf '%s' "$(mk_bash_payload "$FARM_REPO" 'bash tests/run.sh')" \
     | jq '. + {agent_type:"general-purpose"}' \
     | env HOME="$FAKE_HOME" bash "$FARM_OUT" 2>/dev/null)"
D=$(farm_decision 'npm install')
expect_contains "an install-class command still denies" '"deny"' "$D"
D=$(farm_decision 'make widget')
expect_contains "a build-class command still denies" '"deny"' "$D"
expect_empty "make clean stays silent" "$(farm_decision 'make clean')"
expect_empty "ls claude-bootstrap.sh stays silent (reading a script is not running it)" \
  "$(farm_decision 'ls claude-bootstrap.sh')"
D=$(farm_decision 'bash claude-bootstrap.sh')
expect_contains "a bootstrap-class command still denies" '"deny"' "$D"

# --- B-4a: tier-2 reads the library, so its wrappers come off too ---
# `npx`/`uvx`/`git clone`/`docker run` are the NUDGE tier. Before the sed twins
# were deleted, only env/nohup/timeout/FARM_OUT_*= came off, so a sudo- or
# assignment-wrapped tier-2 command reached the matcher with the wrapper still
# at argv[0] and nudged nobody.
expect_contains "B-4a tier-2 still nudges a bare npx" 'additionalContext' \
  "$(farm_decision 'npx create-thing')"
# A DIFFERENT class, because nudge_once suppresses a repeat of the same one.
expect_contains "B-4a …and now through sudo" 'additionalContext' \
  "$(farm_decision 'sudo git clone https://example.invalid/r.git')"
expect_empty "B-4a …but prose naming npx still says nothing" \
  "$(farm_decision 'echo run npx create-thing first')"

# --- advisory mode still downgrades a deny to a nudge ---
printf 'farm-out-mode: advisory\n' > "$FARM_REPO/.bionic/config.yaml"
D=$(farm_decision 'bash tests/run.sh')
expect_contains "advisory mode downgrades the suite deny to a nudge" 'additionalContext' "$D"
rm -f "$FARM_REPO/.bionic/config.yaml"

section "C4 — background-suite-guard behind agent-context-guard (AC-23, AC-24)"
make_repo() {  # <name> -> an armed repo of an ENGAGED session
  local repo="$SANDBOX/$1/repo"
  mkdir -p "$repo/.bionic/tmp"
  # ENGAGED: hooks/agent-context-guard.sh in front, and the wall behind it, both step
  # aside for a session that never invoked the skill. The arming roster below is a
  # different fact and the cells here are about that one.
  : > "$repo/.bionic/tmp/engaged-$SID.state"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name "T"
  echo seed > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed 2>/dev/null
  {
    roster_header
    # THE ROW CARRIES THE FULL-TREE BUDGET, and it has to (S13, spec AC-21). Every cell in
    # C4 drives `bash tests/run.sh` from an agent context, and since the budget arm shipped
    # a full-tree run is refused unless this agent`s own row allows it — so a header-only
    # roster would put the BUDGET arm under test in the cells that exist to test the
    # BACKGROUND one, and the three "must stay silent" cells would have gone red for a
    # wall they never meant to reach. The unbudgeted world is
    # tests/background-suite-guard.test.sh`s.
    roster_row_fixture "session=$SID" name=guarded "agent_id=$AGENT_ID" \
      suites_allowed=run.sh suites_source=declared files=
  } > "$repo/.bionic/tmp/roster-$SID.state"
  chmod 600 "$repo/.bionic/tmp/roster-$SID.state"
  printf '%s' "$repo"
}
GREPO=$(make_repo guarded)

run_guarded() {  # <payload> — through agent-context-guard, as hooks.json registers it
  run_hook "$1" "$CTX_GUARD" "$BG_GUARD"
}

# THE SAME PAIR WITH THE DETAIL KNOB ON (slice 13, ruling D-1). A refusal puts ONE line on
# the user stream — `bionic: <verb> refused — <fact> (<fix>)` — and everything else it has
# to say is `detail`, which is emitted only under BIONIC_WALL_VERBOSE=1. A row that needs a
# value out of a refusal drives the call a second time through this and asserts on $VERR;
# asserting that value on $ERR would now be asserting that the wall leaks it.
VERR=""
run_guarded_verbose() {  # <payload> -> sets VERR
  local payload="$1"
  local _sid; _sid=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  printf '%s' "$payload" | env HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" \
      BIONIC_PLUGINS_DIR="$SANDBOX/no-plugins" CLAUDE_CODE_SESSION_ID="$_sid" \
      CLAUDE_PROJECT_DIR= BIONIC_WALL_VERBOSE=1 bash "$CTX_GUARD" "$BG_GUARD" \
      >/dev/null 2>"$SANDBOX/.verr"
  VERR=$(cat "$SANDBOX/.verr")
  return 0
}

# --- AC-23: agent context + armed + run_in_background true + suite-class -> REFUSED
run_guarded "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" true)"
expect_eq "AC-23 a backgrounded suite in an agent context of an armed session is REFUSED" 2 "$ST"
expect_contains "AC-23 …in the ruled one line, and it is the BACKGROUND arm's" \
  "suite-run refused — a backgrounded suite's result is never read" "$ERR"
run_guarded_verbose "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" true)"
expect_contains "AC-23 …and the refusal names the foreground tee form" "2>&1 | tee" "$VERR"
expect_contains "AC-23 …quoting the command it refused" "bash tests/run.sh" "$VERR"

# --- AC-24: the three cells that must stay silent ---
run_guarded "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" omit)"
expect_eq "AC-24 the same command with no run_in_background is ALLOWED" 0 "$ST"
expect_empty "AC-24 …silently" "$ERR$OUT"

run_guarded "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" false)"
expect_eq "AC-24 run_in_background false is ALLOWED" 0 "$ST"
expect_empty "AC-24 …silently" "$ERR$OUT"

run_guarded "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "" true)"
expect_eq "AC-24 a MAIN-THREAD payload (no agent_id) leaves the arm silent" 0 "$ST"
expect_empty "AC-24 …silently" "$ERR$OUT"

run_guarded "$(mk_bash_payload "$GREPO" 'git status --short' "$AGENT_ID" true)"
expect_eq "AC-24 a non-suite command backgrounded is ALLOWED" 0 "$ST"
expect_empty "AC-24 …silently" "$ERR$OUT"

run_guarded "$(mk_bash_payload "$GREPO" 'git commit -m "make the row green"' "$AGENT_ID" true)"
expect_eq "AC-24 …and B-5's prose case is not a suite either" 0 "$ST"

# --- AC-16 (R-12/C-2): the B-9 wall refuses the same superset ---
for sc in "${SUPERSET_SUITES[@]}"; do
  run_guarded "$(mk_bash_payload "$GREPO" "$sc" "$AGENT_ID" true)"
  expect_eq "AC-16 background-suite-guard REFUSES backgrounded [$sc]" 2 "$ST"
done
# NEGATIVE CONTROL on the same arm: prose that merely names a suite is not one.
run_guarded "$(mk_bash_payload "$GREPO" 'echo "sudo bash tests/run.sh"' "$AGENT_ID" true)"
expect_eq "AC-16 …but prose naming a suite is still ALLOWED" 0 "$ST"

# --- the guard's own partition still holds: an UNARMED session is silent ---
UREPO=$(make_repo unarmed)
rm -f "$UREPO/.bionic/tmp/roster-$SID.state"
run_guarded "$(mk_bash_payload "$UREPO" 'bash tests/run.sh' "$AGENT_ID" true)"
expect_eq "an unarmed session leaves the arm silent even for a backgrounded suite" 0 "$ST"
# POSITIVE CONTROL: the same payload straight into the wall must refuse, so the silence
# above is the guard's decision and not a dud fixture.
run_hook "$(mk_bash_payload "$UREPO" 'bash tests/run.sh' "$AGENT_ID" true)" "$BG_GUARD"
expect_eq "…positive control: that same payload refuses when driven straight into the wall" 2 "$ST"

section "C5 — FAIL-CLOSED sourcing: no library, no pass (AC-12 shape, D1)"
# HERMETIC, AND THAT IS A CORRECTION. This section used to `mv` the SHIPPED library aside
# for its own length and restore it from a trap — a write outside its own mktemp root, and
# the one thing tests/run.sh's parallel mode assumes no suite does. Every sibling suite
# that reads payload/scripts/lib/cmd-class.sh (and since bionic 1.4.0 that is every suite
# driving farm-out-reminder or the background-suite guard) saw the library vanish for a
# few hundred milliseconds and went red for a reason that had nothing to do with it.
# Measured: `BIONIC_TEST_JOBS=18 bash tests/run.sh` with hook-adoption.test.sh on the
# roster, 13 failures here, zero when run alone.
#
# The copies live in a throwaway tree shaped like the shipped plugin — hooks/ beside
# scripts/lib/, with the classifier simply absent — so what is under test is the same
# resolution the shipped hooks perform, and nothing outside $SANDBOX is touched.
C5_TREE="$SANDBOX/no-classifier"
mkdir -p "$C5_TREE/hooks" "$C5_TREE/scripts/lib"
for _c5_lib in "$(dirname "$LIB")"/*.sh; do
  case "$(basename "$_c5_lib")" in cmd-class.sh) continue ;; esac
  cp "$_c5_lib" "$C5_TREE/scripts/lib/"
done
cp "$FARM_OUT" "$C5_TREE/hooks/farm-out-reminder.sh"
cp "$BG_GUARD" "$C5_TREE/hooks/background-suite-guard.sh"
C5_SAVED_FARM="$FARM_OUT"; C5_SAVED_BG="$BG_GUARD"
FARM_OUT="$C5_TREE/hooks/farm-out-reminder.sh"
BG_GUARD="$C5_TREE/hooks/background-suite-guard.sh"

# BOTH OF THESE STEP ASIDE NOW (bionic 1.4.0, design ledger S4). They refused until
# 1.4.0, on the reasoning the two irreversible-action walls still use — and that
# reasoning does not reach here. farm-out guards where a command RUNS; this guard
# prevents a suite whose output nobody reads. Both mistakes are reversible and cost a
# re-run; refusing every Bash call in every session on the machine because one file is
# missing is not. The direction is chosen by the cost of the mistake, per hook.
# Driven through run_hook rather than farm_decision: the latter runs the hook inside a
# command substitution, so $ST and $ERR would still describe whatever ran before it.
run_hook "$(mk_bash_payload "$FARM_REPO" 'bash tests/run.sh')" "$FARM_OUT"
expect_empty "C5 farm-out STEPS ASIDE when its classifier cannot load (fail open)" "$OUT"
expect_eq "C5 …exiting 0" "0" "$ST"
expect_contains "C5 …naming the file it could not load, once, on stderr" "cmd-class.sh" "$ERR"
expect_eq "C5 …in exactly one line" "1" "$(printf '%s\n' "$ERR" | /usr/bin/grep -c .)"
expect_contains "C5 …and pointing at the diagnosis" "/bionic:doctor" "$ERR"

run_guarded "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" true)"
expect_eq "C5 background-suite-guard STEPS ASIDE when its classifier cannot load" 0 "$ST"
expect_contains "C5 …naming the file it could not load" "cmd-class.sh" "$ERR"
expect_eq "C5 …in exactly one line" "1" "$(printf '%s\n' "$ERR" | /usr/bin/grep -c .)"

FARM_OUT="$C5_SAVED_FARM"; BG_GUARD="$C5_SAVED_BG"
# The shipped library was never touched, and everything after this line depends on that,
# so prove it rather than assume it.
expect_eq "C5 the library is back on disk" "suite" "$(class_of 'bash tests/run.sh')"

section "C6 — every source in payload/hooks/*.sh resolves inside payload/"
# A sourced library the installer misses is a silently inert wall (agent-context-guard.sh
# :106-108). The hooks are reachable under two spellings of one directory (see the header),
# so each literal is expanded under BOTH and the pin is: at least one expansion exists, and
# every expansion that exists lies under <repo>/payload/.
# Two literal shapes reach a sibling file from a hook: "$(dirname "$0")/<rel>.sh" (the
# handoff to a sibling SCRIPT) and "$(cd "$(dirname "$0")" … && pwd)/<name>.sh" (the
# sweeper handoff every stop hook uses).
#
# THE LIBRARY IS NO LONGER ONE OF THEM, and that is the bionic 1.4.0 change (slice
# ADOPT, spec AC-16): the two class-(1) candidate spellings live inside the shared
# loader block, computed from a variable, so no `$(dirname "$0")/...` literal names a
# library any more. They are collected here explicitly, from the block itself, so this
# section still covers the reference that matters most — and covers BOTH spellings,
# which the old extractor never did (it only ever saw whichever one a hook wrote first).
SRC_LITERALS=$( { /usr/bin/grep -hoE '\$\(dirname "\$0"\)/[^"]*\.sh' "$PAYLOAD_HOOKS"/*.sh \
                    | sed 's|^\$(dirname "\$0")||'
                  /usr/bin/grep -hoE '&& pwd\)/[^"]*\.sh' "$PAYLOAD_HOOKS"/*.sh \
                    | sed 's|^&& pwd)||'
                  # the loader's own class-(1) directories, one per wanted basename
                  for _c6_want in $(/usr/bin/grep -hoE '^BIONIC_LIB_WANT="[^"]*"' "$PAYLOAD_HOOKS"/*.sh \
                                      | sed -E 's/^BIONIC_LIB_WANT="//; s/"$//' | tr ' ' '\n' | sort -u); do
                    printf '/../scripts/lib/%s\n/../payload/scripts/lib/%s\n' "$_c6_want" "$_c6_want"
                  done
                } 2>/dev/null | sort -u)
if [ -n "$SRC_LITERALS" ]; then ok "payload/hooks reaches sibling files by relative path"; else
  no "payload/hooks reaches sibling files by relative path" "found none to check"
fi

# THREE READINGS OF ONE LITERAL, because the same file is reached three ways:
#   1. INSTALLED PLUGIN — payload/hooks is a real directory, `..` is lexical: the reading
#      that decides whether the shipped plugin can load the file at all.
#   2. ${CLAUDE_PLUGIN_ROOT} over this checkout — payload/hooks is a symlink, so the
#      kernel resolves `..` to <repo>, not to <repo>/payload.
#   3. tests/lib/resolve-roots.sh — <repo>/hooks directly.
# The pin: at least one reading finds the file (a reference nothing can resolve is the
# silently-inert-wall class, agent-context-guard.sh:106-108), and no reading escapes the
# checkout onto a path the plugin does not ship.
lexnorm() {  # lexical a/b/../c, no filesystem, no symlink following
  awk -v p="$1" 'BEGIN {
    n = split(p, a, "/"); k = 0
    for (i = 1; i <= n; i++) {
      if (a[i] == "" || a[i] == ".") continue
      if (a[i] == "..") { if (k > 0) k--; continue }
      st[++k] = a[i]
    }
    s = ""; for (i = 1; i <= k; i++) s = s "/" st[i]
    print (s == "" ? "/" : s)
  }'
}
SRC_BAD=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  found=0
  # `../payload/scripts/lib/...` is the REPO spelling of the same directory: it resolves
  # only when payload/hooks is a symlink to <repo>/hooks, so under the installed-plugin
  # reading it is expected to find nothing. Its twin covers that reading, and the pin
  # below is per-basename, not per-spelling.
  case "$rel" in /../payload/scripts/lib/*) continue ;; esac
  for cand in "$(lexnorm "$PAYLOAD_HOOKS$rel")" "$PAYLOAD_HOOKS$rel" "$PLAIN_HOOKS$rel"; do
    [ -f "$cand" ] || continue
    found=1
    phys="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
    case "$phys" in
      "$REPO_ROOT"/*) : ;;
      *) SRC_BAD="$SRC_BAD escapes-checkout:$rel($phys)" ;;
    esac
  done
  [ "$found" = 1 ] || SRC_BAD="$SRC_BAD unresolvable:$rel"
done <<EOF
$SRC_LITERALS
EOF
expect_eq "every relative sibling reference resolves, and never outside the checkout" "" "$SRC_BAD"
# The one that matters most, stated on its own: the shipped plugin — where payload/hooks is
# a real directory — can load the classifier from the primary spelling both hooks use.
expect_eq "the installed-plugin reading of the cmd-class source lands on the shipped library" \
  "$REPO_ROOT/payload/scripts/lib/cmd-class.sh" \
  "$(lexnorm "$PAYLOAD_HOOKS/../scripts/lib/cmd-class.sh")"
# ANTI-VACUITY: the extractor must actually see both shapes it claims to cover.
expect_contains "…and the extractor sees the cmd-class library (shape A)" "cmd-class.sh" "$SRC_LITERALS"
expect_contains "…and the sweeper handoff (shape B)" "session-sweeper.sh" "$SRC_LITERALS"

section "C6 — the session never invoked the skill: neither hook is there (AC-6, AC-20)"
#
# THE PAIRED WORLD for C2/C3 and C4. Chris, 2026-09-03: "all guardrails imposed by bionic
# should only apply when exercising bionic. Nothing should apply until bionic is
# triggered." Both hooks read `.bionic/tmp/engaged-<sid>.state` before anything else, so
# with the marker removed the suite commands every arm above denies pass in silence: exit
# 0, nothing on stdout, nothing on stderr.
#
# Each fixture here is one an arm above REFUSES, unengaged and then re-engaged, so no row
# can pass on a hook that had simply stopped working.

# --- farm-out-reminder: the deny and the nudge both go quiet (AC-6) ---
unengage "$FARM_REPO"
run_hook "$(mk_bash_payload "$FARM_REPO" 'bash tests/run.sh')" "$FARM_OUT"
expect_empty "AC-6 farm-out is SILENT on a suite command in an unengaged session" "$OUT"
expect_empty "AC-6 …and says nothing on stderr either" "$ERR"
expect_eq "AC-6 …exiting 0" "0" "$ST"

run_hook "$(mk_bash_payload "$FARM_REPO" 'npx create-react-app x')" "$FARM_OUT"
expect_empty "AC-6 …the tier-2 nudge is silent too" "$OUT$ERR"

# THE OVERRIDE IS NOT CONSULTED, because there is nothing to override: an audit line
# recording a bypass of a wall that was never going to fire is noise in the one stream
# that has to stay readable.
run_hook "$(mk_bash_payload "$FARM_REPO" 'FARM_OUT_ALLOW=1 bash tests/run.sh')" "$FARM_OUT"
expect_empty "AC-6 …and an explicit override is silent rather than audited" "$OUT$ERR"

# A SYMLINK at the marker path is not a marker (lib/run.sh refuses `-L` before following
# it), and neither is another session's.
ln -s "$FARM_CLOSED/.bionic/tmp" "$FARM_REPO/.bionic/tmp/engaged-$SID.state" 2>/dev/null
run_hook "$(mk_bash_payload "$FARM_REPO" 'bash tests/run.sh')" "$FARM_OUT"
expect_empty "AC-6 …a SYMLINK at the marker path is not engagement" "$OUT$ERR"
rm -f "$FARM_REPO/.bionic/tmp/engaged-$SID.state"
: > "$FARM_REPO/.bionic/tmp/engaged-00000000-1111-2222-3333-444444444444.state"
run_hook "$(mk_bash_payload "$FARM_REPO" 'bash tests/run.sh')" "$FARM_OUT"
expect_empty "AC-6 …another session's marker is not engagement" "$OUT$ERR"

# CONTROL: restore the marker and the identical command denies again.
engage "$FARM_REPO"
expect_contains "AC-6 control: with the marker back, the same suite command DENIES" \
  '"deny"' "$(farm_decision 'bash tests/run.sh')"

# --- background-suite-guard: the same, behind its own guard and driven straight (AC-20) ---
unengage "$GREPO"
run_guarded "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" true)"
expect_eq "AC-20 a backgrounded suite passes an unengaged session (through the guard)" "0" "$ST"
expect_empty "AC-20 …silently" "$OUT$ERR"

# STRAIGHT INTO THE WALL, bypassing hooks/agent-context-guard.sh entirely: the wall has
# its own scope and does not depend on the guard in front remembering to check.
run_hook "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" true)" "$BG_GUARD"
expect_eq "AC-20 …and driven straight into the wall, still exit 0" "0" "$ST"
expect_empty "AC-20 …still silently" "$OUT$ERR"

# CONTROL: the marker back, the same payload straight into the wall refuses again.
engage "$GREPO"
run_hook "$(mk_bash_payload "$GREPO" 'bash tests/run.sh' "$AGENT_ID" true)" "$BG_GUARD"
expect_eq "AC-20 control: with the marker back, the wall REFUSES again" "2" "$ST"

section "C7 — cmd_suite_targets: WHICH suite a command runs (S13, AC-21)"
# The budget arm cannot compare a command to a set of suite basenames without knowing which
# basenames the command names. That reading is here, beside the class, because it is the
# same reading: `cmd_class` and `cmd_suite_targets` answer off the same argv positions, and
# a second matcher outside this library would have to re-implement strip_leading,
# unwrap_runner and the quote-aware tokeniser to see them.
#
# MEASURED IN BOTH DIRECTIONS, per the library`s own superset note (:47-51: "Any new arm
# here is a wall — measure both directions"). Every spelling the class arm recognises must
# also NAME its suite, or the budget arm silently allows what the class arm caught; and no
# spelling the class arm rejects may name one, or the budget arm refuses prose.

targets_of() {  # <command> -> the library's targets, newline-joined
  printf '%s' "$1" | bash -c '
    set -uo pipefail
    . "$1" || { echo "SOURCE-FAILED"; exit 1; }
    cmd_suite_targets "$(cat)"
  ' _ "$LIB" 2>&1
}

targets_are() {  # <expected, newline-joined> <command>
  expect_eq "targets [$2]" "$1" "$(targets_of "$2")"
}

# --- direction 1: every suite-class spelling names the file it runs ---
targets_are 'run.sh'       'bash tests/run.sh'
targets_are 'run.sh'       'bash tests/run.sh --serial'
targets_are 'run.sh'       'bash -x tests/run.sh'
targets_are 'cmd-class.test.sh' 'bash tests/cmd-class.test.sh'
targets_are 'test.sh'      'bash test.sh'
targets_are 'run.sh'       './tests/run.sh'
targets_are 'run.sh'       'tests/run.sh'
targets_are 'run.sh'       'cd tests && bash run.sh'
targets_are 'run.sh'       '(cd tests; bash run.sh)'
targets_are 'run.sh'       'sudo bash tests/run.sh'
targets_are 'run.sh'       '( bash tests/run.sh )'
targets_are 'run.sh'       'if true; then bash tests/run.sh; fi'
targets_are 'run.sh'       'FARM_OUT_ALLOW=1 bash tests/run.sh'
targets_are 'run.sh'       'PIN=/tmp/p PATH=$PIN:$PATH bash tests/run.sh'
targets_are 'loader.test.sh' 'bash "$REPO/tests/loader.test.sh"'
targets_are 'width.test.sh' 'bash tests/width.test.sh 2>&1 | tee /tmp/w.log'

# THE WHOLE POINT OF THE SET: a chain names every suite in it, in position order.
targets_are 'a.test.sh
b.test.sh' 'bash tests/a.test.sh && bash tests/b.test.sh'
targets_are 'a.test.sh
run.sh' 'bash tests/a.test.sh; ./tests/run.sh'
# …and a suite named twice is one claim, not two.
targets_are 'a.test.sh' 'bash tests/a.test.sh && bash tests/a.test.sh'

# THE SUPERSET ARRAY ITSELF, so a spelling added to the class arm cannot be added without
# an answer here. Both halves asserted per spelling: it classifies AND it names a target.
for sc in "${SUPERSET_SUITES[@]}"; do
  expect_eq "C7 [$sc] is suite-class" "suite" "$(class_of "$sc")"
  expect_eq "C7 …and names its suite" "run.sh" "$(targets_of "$sc")"
done

# --- direction 2: nothing else names one ---
targets_are '' 'git status --short'
targets_are '' 'echo "bash tests/run.sh"'
targets_are '' 'echo run bash tests/run.sh first'
targets_are '' 'git commit -m "make the row green"'
targets_are '' 'ls tests/run.sh'
targets_are '' 'bash run.sh'
targets_are '' 'cat <<EOF
bash tests/run.sh
EOF'
# SUITE-CLASS BUT FILELESS. These run a suite and name no file this repo budgets by, so the
# budget arm has nothing to compare and stands aside — asserted rather than assumed,
# because a target invented for them would refuse a project bionic has no row about.
for fileless in 'pytest' 'npm test' 'go test ./...' 'make test' 'make check' 'cargo test'; do
  expect_eq "C7 [$fileless] is suite-class" "suite" "$(class_of "$fileless")"
  expect_eq "C7 …and names no suite FILE" "" "$(targets_of "$fileless")"
done


section "C8 — the SCOPED reading: which repo's suite, and a mode that runs nothing (K-2, A-7, A-36a)"
# THE DEFECT. `cmd_suite_targets` answered with a BASENAME and nothing else, so the budget
# arm judged any file on the machine named `*.test.sh` against THIS repository's roster.
# Three false refusals were hit without trying (critic K-2): a scratch probe at
# /tmp/critic-probe/probe2.test.sh, an unexpanded `$t.test.sh`, and `bash tests/run.sh
# --dry-run`, a mode whose whole documented behaviour is to run nothing (the walk, A-36a).
#
# THE CURE, in two halves. (a) An optional SECOND argument names the repository the answer
# is about; with it, a segment names a target only when the path it runs resolves to that
# repo's `tests/<basename>`. (b) A suite-class segment carrying `--dry-run` names no target
# at all — the runner's own "run nothing" mode is not an instrument spend.
#
# WHY SHAPE AND NOT EXISTENCE. The resolved path is compared to `<root>/tests/<basename>`;
# it is NOT stat'd. A hook that refused only files it could see would allow a suite the
# writer is about to create, and would make the wall's answer depend on the filesystem at
# hook time rather than on the command. The class this closes is "a path somewhere else",
# and the path says that on its own.

targets_of_in() {  # <repo root> <command> -> the library's targets, scoped to that root
  printf '%s' "$2" | bash -c '
    set -uo pipefail
    . "$1" || { echo "SOURCE-FAILED"; exit 1; }
    cmd_suite_targets "$(cat)" "$2"
  ' _ "$LIB" "$1" 2>&1
}

C8_ROOT="$SANDBOX/c8repo"
mkdir -p "$C8_ROOT/tests"

targets_in_are() {  # <expected> <command>
  expect_eq "C8 targets [$2] under the repo root" "$1" "$(targets_of_in "$C8_ROOT" "$2")"
}

# --- (a) this repo's tests/, and nothing else ---
targets_in_are 'run.sh'          'bash tests/run.sh'
targets_in_are 'run.sh'          './tests/run.sh'
targets_in_are 'alpha.test.sh'   'bash tests/alpha.test.sh'
targets_in_are 'alpha.test.sh'   "bash $C8_ROOT/tests/alpha.test.sh"
# …and the same basename anywhere else on the machine is NOT this row's business.
targets_in_are ''                'bash /tmp/critic-probe/probe2.test.sh'
targets_in_are ''                'bash /some/other/tree/tests/run.sh'
targets_in_are ''                'bash ../sibling/tests/alpha.test.sh'
targets_in_are ''                'bash scratch/alpha.test.sh'

# THE cd-LICENSED BASENAME FORM STAYS NAMED. `cd tests && bash run.sh` records no
# directory to resolve against, so the reading cannot say which tree it is in — and the
# full tree is the one act this arm fails CLOSED on. Named, therefore refusable.
targets_in_are 'run.sh'          'cd tests && bash run.sh'

# AN UNEXPANDED VARIABLE STAYS NAMED TOO, deliberately: the guard has a refusal written
# for exactly this state (C-5), and it can only give it if the reading hands the token up.
targets_in_are '$s.test.sh'      'bash "tests/$s.test.sh"'

# --- (b) --dry-run runs nothing, so it spends nothing ---
targets_in_are ''                'bash tests/run.sh --dry-run'
targets_in_are ''                'bash tests/run.sh --dry-run 2>&1 | tee /tmp/d.log'
expect_eq "C8 …and --dry-run is still suite-CLASS (the class arm is unchanged)" \
  "suite" "$(class_of 'bash tests/run.sh --dry-run')"
# The exemption is the flag, not the runner: a real run beside it is still named.
targets_in_are 'run.sh'          'bash tests/run.sh --serial'

# --- the unscoped call is unchanged: no root, the legacy basename answer ---
expect_eq "C8 with no root the answer is the bare basename, as before" \
  "probe2.test.sh" "$(targets_of 'bash /tmp/critic-probe/probe2.test.sh')"

finish
