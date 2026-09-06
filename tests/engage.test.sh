#!/bin/bash
# tests/engage.test.sh — hooks/engage.sh, the ENGAGEMENT TRIGGER (task-engaged-session,
# task T1; matrix AC-1, AC-2, AC-3, AC-4, AC-17, AC-18).
#
# WHAT IT OWNS. The one act that puts a session inside bionic: invoking the
# canonical-sdlc skill. The hook fires on the two paths that invocation can take —
# a model-issued `Skill` tool call (PreToolUse, `tool_input.skill`) and a user-typed
# slash command (UserPromptExpansion, `command_name`) — and writes
# `<root>/.bionic/tmp/engaged-<sid>.state`. Every other bionic wall reads that file
# through `engaged_session` in payload/scripts/lib/run.sh and stays silent without it.
#
# THE FAIL DIRECTION IS INVERTED HERE and that is the whole reason this suite is
# adversarial about the negative arms. Everywhere else in this tree, an unreadable
# state CLOSES a wall; here PRESENCE opens them. So a false positive — a marker
# written for a skill that is not canonical-sdlc, for a foreign session id, for the
# `unknown` fallback two advisories use, or through a symlink somebody planted — arms
# every wall in the fleet against a session that never consented. Each negative below
# is therefore PAIRED with the positive on the SAME fixture, so a negative that passes
# because the hook is inert cannot pass at all.
#
# HERMETIC. Every project is a fixture under a mktemp sandbox; no real .bionic tree,
# no real plan, no ~/.claude read. The hook is driven as a subprocess with JSON on
# stdin, exactly as the harness delivers it.
#
# Usage: bash tests/engage.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$BIONIC_HOOKS_DIR/engage.sh"
LIB="$REPO_ROOT/payload/scripts/lib/run.sh"
BINDLIB="$REPO_ROOT/payload/scripts/lib/binding.sh"
LOADER_LIB="$REPO_ROOT/payload/scripts/lib/loader.sh"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
RUNNER="$REPO_ROOT/tests/run.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/engage-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

SID="e40aged1-2222-3333-4444-555555555555"
OTHER_SID="0ther999-8888-7777-6666-555555555555"

# ---------- fixture builders ----------

# A project with a .bionic tree and an OPEN plan. `project_root` answers at the
# nearest ancestor carrying `.bionic/`, which is this directory itself.
make_repo() {  # [name] -> project dir on stdout
  local dir
  dir="$(cd "$(mktemp -d "$SANDBOX/${1:-repo}.XXXXXX")" && pwd -P)"
  mkdir -p "$dir/.bionic/tmp" "$dir/.bionic/docs/plans"
  cat > "$dir/.bionic/docs/plans/wave-01.plan.md" <<'ENGPLAN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: slices in flight
ENGPLAN
  printf '%s' "$dir"
}

# A project with a .bionic tree and NO plan at all (AC-18's first half: Step 0 of a
# new run precedes its plan file).
make_repo_planless() {  # -> project dir on stdout
  local dir
  dir="$(cd "$(mktemp -d "$SANDBOX/planless.XXXXXX")" && pwd -P)"
  mkdir -p "$dir/.bionic/tmp"
  printf '%s' "$dir"
}

# A project with NO .bionic AT ALL (AC-18's second half). Nothing in the payload owns
# tree creation today, so a fresh project would otherwise engage and stay unwalled.
# git-init'd so `project_root` lands on this directory by the git-toplevel fallback
# rather than on whatever ancestor of $TMPDIR happens to exist.
make_repo_fresh() {  # -> project dir on stdout
  local dir
  dir="$(cd "$(mktemp -d "$SANDBOX/fresh.XXXXXX")" && pwd -P)"
  git -C "$dir" init -q 2>/dev/null
  printf '%s' "$dir"
}

marker_path() { printf '%s/.bionic/tmp/engaged-%s.state' "$1" "$2"; }

mode_of() {  # <file> -> octal permission bits
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null
}

# ---------- payload builders (field names: code.claude.com/docs/en/hooks) ----------

skill_payload() {  # <sid> <cwd> <skill>
  jq -nc --arg s "$1" --arg c "$2" --arg k "$3" \
    '{session_id:$s,prompt_id:"p-1",transcript_path:"/dev/null",cwd:$c,
      permission_mode:"default",hook_event_name:"PreToolUse",
      tool_name:"Skill",tool_input:{skill:$k},tool_use_id:"toolu_engage_test"}'
}

expansion_payload() {  # <sid> <cwd> <command_name>
  jq -nc --arg s "$1" --arg c "$2" --arg n "$3" \
    '{session_id:$s,prompt_id:"p-1",transcript_path:"/dev/null",cwd:$c,
      permission_mode:"default",hook_event_name:"UserPromptExpansion",
      expansion_type:"slash_command",command_name:$n,command_args:"",
      command_source:"plugin",prompt:"# Canonical SDLC"}'
}

# ---------- driving the hook ----------
#
# THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does. The hook
# takes its session key from lib/session.sh — env first, payload as witness — and the
# marker filename is built from the answer, so a driver that left the runner's own id
# in the environment would have the hook writing a file the assertions never look at.
# CLAUDE_PROJECT_DIR is removed so the payload's `cwd` is what resolves the root.
HOOK_OUT=""; HOOK_ERR=""; HOOK_RC=0
fire() {  # <sid> <json>
  HOOK_OUT=$(env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$1" \
    bash "$HOOK" <<< "$2" 2>"$SANDBOX/.err")
  HOOK_RC=$?
  HOOK_ERR=$(cat "$SANDBOX/.err" 2>/dev/null)
}

# ---------- driving the library predicate ----------

ES_ST=0
call_engaged() {  # <root> <sid> -> sets ES_ST
  bash -c '. "$1" || exit 9; engaged_session "$2" "$3"' _ "$LIB" "$1" "$2" >/dev/null 2>&1
  ES_ST=$?
}

# ---------- wave-session-bound-run: plan fixtures for the BINDING arms ----------
#
# `open_runs` decides membership, so these builders exist to move a fixture across
# that boundary and back: an OPEN plan is a member, a CLOSED one is not, and a
# markdown file with no flush-left `## SDLC State` is not a plan at all. Every
# negative arm below pairs with a positive built by the sibling function on the SAME
# root, so a refusal can never pass because the root was empty.

mk_open_plan() {  # <root> <relname> [mmddhhmm-ish touch stamp] -> abs path on stdout
  local p="$1/.bionic/docs/plans/$2"
  mkdir -p "$(dirname "$p")"
  cat > "$p" <<'MKOPEN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: slices in flight
MKOPEN
  [ -n "${3:-}" ] && touch -t "$3" "$p"
  printf '%s' "$p"
}

mk_closed_plan() {  # <root> <relname> [stamp] -> abs path on stdout
  local p="$1/.bionic/docs/plans/$2"
  mkdir -p "$(dirname "$p")"
  cat > "$p" <<'MKCLOSED'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 9

- Step 9: close-out — delivered: 2026-09-01
MKCLOSED
  [ -n "${3:-}" ] && touch -t "$3" "$p"
  printf '%s' "$p"
}

mk_nonplan() {  # <root> <relname> -> abs path on stdout
  local p="$1/.bionic/docs/plans/$2"
  mkdir -p "$(dirname "$p")"
  printf 'just notes, no SDLC State heading anywhere\n' > "$p"
  printf '%s' "$p"
}

plan_of()   { grep -m1 '^plan=' "$1" 2>/dev/null | sed 's/^plan=//'; }
engat_of()  { grep -m1 '^engaged_at=' "$1" 2>/dev/null | sed 's/^engaged_at=//'; }

# rel_stamp <seconds ago> -> a `touch -t` stamp for "seconds ago" from the REAL wall clock
# (BSD `date -r` first, GNU `date -d @…` second — both render LOCAL time, which is what
# `touch -t` reads). Used where a fixture needs one open plan OLDER than another WHILE BOTH
# STAY LIVE (wave-roster-lifecycle S2: `live_runs` filters real mtime against real "now" in
# every fixture below that does not pin `BIONIC_NOW_EPOCH`), rather than a fixed calendar
# date that drifts more than a `live-window:` out of date as real time passes it by.
rel_stamp() {
  local at=$(( $(date +%s) - $1 ))
  date -r "$at" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$at" +%Y%m%d%H%M.%S
}

# ---------- driving the binding writer ----------
#
# `set -u` inside the driver on purpose: every caller of bind_plan is a hook that runs
# under it, and an unbound-variable error there would be a silent exit 1 that reads as
# a refusal.
BIND_ST=0; BIND_OUT=""; BIND_ERR=""
call_bind() {  # <root> <sid> <plan|none> -> sets BIND_ST/BIND_OUT/BIND_ERR
  BIND_OUT=$(bash -c 'set -u; . "$1" || exit 9; . "$2" || exit 9; bind_plan "$3" "$4" "$5"' \
    _ "$LIB" "$BINDLIB" "$1" "$2" "$3" 2>"$SANDBOX/.berr")
  BIND_ST=$?
  BIND_ERR=$(cat "$SANDBOX/.berr" 2>/dev/null)
}

OR_OUT=""; OR_ST=0
call_open_runs() {  # <root> -> sets OR_OUT/OR_ST
  OR_OUT=$(bash -c 'set -u; . "$1" || exit 9; open_runs "$2"' _ "$LIB" "$1" 2>/dev/null)
  OR_ST=$?
}

# ============================================================
section "E0 — the hook exists, parses, and is executable"
# ============================================================

if [ -f "$HOOK" ]; then ok "hooks/engage.sh is on disk"; else no "hooks/engage.sh is on disk" "$HOOK"; fi
if bash -n "$HOOK" 2>"$SANDBOX/.syn"; then ok "engage.sh parses (bash -n)"; else
  no "engage.sh parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi
# §EXEC in hook-adoption pins this too; a hook that lost its bit is `Permission denied`
# on every event, and the trigger is silently gone.
if [ -x "$HOOK" ]; then ok "engage.sh carries the exec bit"; else no "engage.sh carries the exec bit"; fi

# ============================================================
section "E1 (AC-1) — a Skill call for canonical-sdlc engages the session"
# ============================================================

R1="$(make_repo e1)"
M1="$(marker_path "$R1" "$SID")"

fire "$SID" "$(skill_payload "$SID" "$R1" "bionic:canonical-sdlc")"
expect_eq "the plugin-qualified Skill call exits 0" "0" "$HOOK_RC"
expect_empty "…and prints nothing on stdout" "$HOOK_OUT"
if [ -f "$M1" ]; then ok "…and writes the engagement marker"; else
  no "…and writes the engagement marker" "no file at $M1"
fi
expect_contains "the marker names the open plan" \
  "plan=$R1/.bionic/docs/plans/wave-01.plan.md" "$(cat "$M1" 2>/dev/null)"
ENG_AT=$(grep '^engaged_at=' "$M1" 2>/dev/null | sed 's/^engaged_at=//')
if printf '%s' "$ENG_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  ok "…and an ISO-8601 UTC engaged_at stamp"
else
  no "…and an ISO-8601 UTC engaged_at stamp" "engaged_at was [$ENG_AT]"
fi
expect_eq "the marker is mode 0600" "600" "$(mode_of "$M1")"
expect_eq "the marker is exactly two lines" "2" "$(wc -l < "$M1" | tr -d ' ')"

# The bare (unqualified) spelling the Skill tool also emits.
rm -f "$M1"
fire "$SID" "$(skill_payload "$SID" "$R1" "canonical-sdlc")"
if [ -f "$M1" ]; then ok "the bare 'canonical-sdlc' Skill call engages too"; else
  no "the bare 'canonical-sdlc' Skill call engages too" "no file at $M1"
fi

# Overwrite is idempotent, not an error: a session may invoke the skill many times.
BEFORE=$(cat "$M1")
fire "$SID" "$(skill_payload "$SID" "$R1" "canonical-sdlc")"
expect_eq "a second invocation exits 0 (the write is idempotent)" "0" "$HOOK_RC"
expect_eq "…and the marker is still mode 0600 after the overwrite" "600" "$(mode_of "$M1")"
expect_contains "…and still names the plan" "plan=" "$(cat "$M1")"
[ -n "$BEFORE" ] || no "the first marker was non-empty (non-vacuity)" "empty"

# ============================================================
section "E2 (AC-2) — no other skill engages anything"
# ============================================================
#
# EACH NEGATIVE IS PAIRED WITH THE POSITIVE ON THE SAME FIXTURE. A negative arm that
# passed because the hook could not find the root, could not resolve the sid, or was
# not executable would be a vacuous pass, and this is the arm where a vacuous pass
# costs the most: it is the one asserting that bionic's walls stay off.

R2="$(make_repo e2)"
M2="$(marker_path "$R2" "$SID")"

for other in bionic:map-instrument-narrow bionic:doctor bionic:browser-verify bionic:help \
             bionic:setup bionic:remove humanizer map-instrument-narrow; do
  rm -f "$M2"
  fire "$SID" "$(skill_payload "$SID" "$R2" "$other")"
  expect_eq "Skill '$other' exits 0" "0" "$HOOK_RC"
  if [ -e "$M2" ]; then no "Skill '$other' writes NO marker" "marker appeared at $M2"; else
    ok "Skill '$other' writes NO marker"
  fi
  # the pair: the same fixture, the same driver, one skill name apart
  fire "$SID" "$(skill_payload "$SID" "$R2" "bionic:canonical-sdlc")"
  if [ -f "$M2" ]; then ok "…paired: canonical-sdlc on the same fixture DOES engage"; else
    no "…paired: canonical-sdlc on the same fixture DOES engage" "no file at $M2 — the negative above was vacuous"
  fi
done

# Near-misses on the name itself. `^(bionic:)?canonical-sdlc$` is anchored at both ends.
for near in canonical-sdlc-v2 xcanonical-sdlc bionic:canonical-sdlc-helper \
            other:canonical-sdlc "canonical-sdlc " ""; do
  rm -f "$M2"
  fire "$SID" "$(skill_payload "$SID" "$R2" "$near")"
  if [ -e "$M2" ]; then no "the near-miss skill name [$near] writes NO marker" "marker appeared"; else
    ok "the near-miss skill name [$near] writes NO marker"
  fi
done
rm -f "$M2"
fire "$SID" "$(skill_payload "$SID" "$R2" "canonical-sdlc")"
if [ -f "$M2" ]; then ok "…paired: the exact name on the same fixture still engages"; else
  no "…paired: the exact name on the same fixture still engages" "no file at $M2"
fi

# A PreToolUse for any OTHER tool is not the trigger, whatever its input carries.
rm -f "$M2"
OTHER_TOOL=$(jq -nc --arg s "$SID" --arg c "$R2" \
  '{session_id:$s,transcript_path:"/dev/null",cwd:$c,hook_event_name:"PreToolUse",
    tool_name:"Bash",tool_input:{command:"echo canonical-sdlc",skill:"bionic:canonical-sdlc"}}')
fire "$SID" "$OTHER_TOOL"
if [ -e "$M2" ]; then no "a Bash PreToolUse naming the skill writes NO marker" "marker appeared"; else
  ok "a Bash PreToolUse naming the skill writes NO marker"
fi

# An unrelated event is not the trigger either.
rm -f "$M2"
STOP_EV=$(jq -nc --arg s "$SID" --arg c "$R2" \
  '{session_id:$s,transcript_path:"/dev/null",cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')
fire "$SID" "$STOP_EV"
expect_eq "an unrelated event (Stop) exits 0" "0" "$HOOK_RC"
if [ -e "$M2" ]; then no "…and writes NO marker" "marker appeared"; else ok "…and writes NO marker"; fi

# ============================================================
section "E3 (AC-3) — the TYPED path: UserPromptExpansion by command name"
# ============================================================
#
# R-A §5.2 proved a typed /bionic:canonical-sdlc is NOT a Skill tool call and NOT a
# plain UserPromptSubmit prompt: it arrives as a command expansion whose `command_name`
# is the match key. The docs' matcher table says as much — `UserPromptExpansion` |
# command name | your skill or command names.

R3="$(make_repo e3)"
M3="$(marker_path "$R3" "$SID")"

for name in canonical-sdlc bionic:canonical-sdlc /canonical-sdlc /bionic:canonical-sdlc; do
  rm -f "$M3"
  fire "$SID" "$(expansion_payload "$SID" "$R3" "$name")"
  expect_eq "the expansion of [$name] exits 0" "0" "$HOOK_RC"
  expect_empty "…and prints nothing on stdout" "$HOOK_OUT"
  if [ -f "$M3" ]; then ok "…and engages the session"; else
    no "…and engages the session" "no file at $M3"
  fi
done

for name in loop bionic:help bionic:doctor clear canonical-sdlc-notes ""; do
  rm -f "$M3"
  fire "$SID" "$(expansion_payload "$SID" "$R3" "$name")"
  if [ -e "$M3" ]; then no "the expansion of [$name] writes NO marker" "marker appeared"; else
    ok "the expansion of [$name] writes NO marker"
  fi
  fire "$SID" "$(expansion_payload "$SID" "$R3" "bionic:canonical-sdlc")"
  if [ -f "$M3" ]; then ok "…paired: the real command on the same fixture DOES engage"; else
    no "…paired: the real command on the same fixture DOES engage" "the negative above was vacuous"
  fi
done

# ============================================================
section "E4 (AC-4) — engaged_session: the predicate every wall reads"
# ============================================================

R4="$(make_repo e4)"
M4="$(marker_path "$R4" "$SID")"

call_engaged "$R4" "$SID"
expect_eq "no marker on disk -> engaged_session is FALSE" "1" "$ES_ST"

fire "$SID" "$(skill_payload "$SID" "$R4" "bionic:canonical-sdlc")"
call_engaged "$R4" "$SID"
expect_eq "a regular file at the marker path -> TRUE" "0" "$ES_ST"

# A FOREIGN session's marker is not this session's engagement. The path is keyed by
# sid precisely so one session cannot arm another's walls.
call_engaged "$R4" "$OTHER_SID"
expect_eq "another session's sid -> FALSE even though a marker exists" "1" "$ES_ST"

# The `unknown` fallback farm-out-reminder and context-spend substitute for a missing
# sid must never name a readable marker: `.bionic/tmp/engaged-unknown.state` would
# otherwise engage every session that lost its id.
printf 'plan=none\nengaged_at=2026-09-03T00:00:00Z\n' > "$R4/.bionic/tmp/engaged-unknown.state"
call_engaged "$R4" "unknown"
expect_eq "the sid 'unknown' -> FALSE even with engaged-unknown.state planted" "1" "$ES_ST"

call_engaged "$R4" ""
expect_eq "an empty sid -> FALSE" "1" "$ES_ST"

# A sid carrying a path separator must never escape .bionic/tmp.
printf 'plan=none\n' > "$SANDBOX/escape.state"
call_engaged "$R4" "../../../escape"
expect_eq "a sid carrying '/' -> FALSE (no traversal)" "1" "$ES_ST"
call_engaged "$R4" "a b"
expect_eq "a sid carrying a space -> FALSE" "1" "$ES_ST"

# A SYMLINK at the marker path is refused before it is followed — the guard idiom
# patrol-revive.sh uses on its stamp. A hostile repo may CLOSE a wall and must never
# OPEN one, and this is the one artifact whose presence opens them.
rm -f "$M4"
printf 'plan=none\nengaged_at=2026-09-03T00:00:00Z\n' > "$SANDBOX/planted.state"
ln -s "$SANDBOX/planted.state" "$M4"
call_engaged "$R4" "$SID"
expect_eq "a symlink at the marker path -> FALSE (refused, not followed)" "1" "$ES_ST"

# …and the hook refuses to write through it, rather than clobbering the target.
fire "$SID" "$(skill_payload "$SID" "$R4" "bionic:canonical-sdlc")"
expect_eq "the hook exits 0 on a symlinked marker path" "0" "$HOOK_RC"
if [ -L "$M4" ]; then ok "…and leaves the symlink in place"; else no "…and leaves the symlink in place"; fi
expect_eq "…and does not write through it" \
  "plan=none" "$(head -1 "$SANDBOX/planted.state")"
rm -f "$M4"

# A DIRECTORY at the marker path is not a regular file either.
mkdir -p "$M4"
call_engaged "$R4" "$SID"
expect_eq "a directory at the marker path -> FALSE" "1" "$ES_ST"
rmdir "$M4"

# ============================================================
section "E5 (AC-17) — registration and the loader idiom"
# ============================================================

HJ_ROWS=$(jq -r '
  .hooks | to_entries[] | .key as $ev | .value[]
  | (.matcher // "") as $mt
  | .hooks[] | "\($ev)|\($mt)|\(.command)|\(.timeout // "")"
' "$HOOKS_JSON" 2>/dev/null)

expect_contains "hooks.json registers engage.sh on PreToolUse matcher Skill" \
  'PreToolUse|Skill|${CLAUDE_PLUGIN_ROOT}/hooks/engage.sh|10' "$HJ_ROWS"
expect_contains "hooks.json registers engage.sh on UserPromptExpansion" \
  'UserPromptExpansion||${CLAUDE_PLUGIN_ROOT}/hooks/engage.sh|10' "$HJ_ROWS"
expect_eq "engage.sh is registered exactly twice, and no more" "2" \
  "$(printf '%s\n' "$HJ_ROWS" | /usr/bin/grep -c 'engage\.sh')"

# The loader idiom, byte for byte against the pin — the same comparison
# cross-gate §N.1 and hook-adoption §1 make, restated here so this suite fails on
# its own subject rather than only in the roster suites.
N_BLOCK="$( . "$LOADER_LIB" && bionic_loader_pin )"
BLOCK_OF=$(awk '/^# --- bionic-loader\/v2 BEGIN$/{f=1} f{print} f&&/^# --- bionic-loader\/v2 END$/{exit}' "$HOOK")
expect_eq "engage.sh carries the canonical loader block, byte for byte" "$N_BLOCK" "$BLOCK_OF"

WANT_LINE=$(awk '/^# --- bionic-loader\/v2 BEGIN$/{print prev; exit} {prev=$0}' "$HOOK")
case "$WANT_LINE" in
  BIONIC_LIB_WANT=\"*\") ok "engage.sh declares BIONIC_LIB_WANT above the block" ;;
  *) no "engage.sh declares BIONIC_LIB_WANT above the block" "line above BEGIN was: [$WANT_LINE]" ;;
esac
WANTS=$(printf '%s' "$WANT_LINE" | sed -e 's/^BIONIC_LIB_WANT="//' -e 's/"$//')
SOURCED=$(/usr/bin/grep -oE '^\. "\$BIONIC_LIB/[a-z.-]+\.sh"' "$HOOK" \
  | sed -E 's|^\. "\$BIONIC_LIB/||; s|"$||' | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "engage.sh sources exactly the libraries it wants" \
  "$(printf '%s' "$WANTS" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" "$SOURCED"

# The trigger must never block an invocation: it fails OPEN on a missing library.
expect_eq "engage.sh fails OPEN on a missing library (and only that)" "0 1" \
  "$(/usr/bin/grep -c 'loader_fail_closed "' "$HOOK") $(/usr/bin/grep -c 'loader_fail_open "' "$HOOK")"

# It resolves its root and its session id through the library, like every other reader.
expect_eq "engage.sh resolves its root through the library" "yes" \
  "$(/usr/bin/grep -q 'project_root "' "$HOOK" && echo yes || echo no)"
expect_eq "engage.sh takes its session id from lib/session.sh" "yes" \
  "$(/usr/bin/grep -q 'session_id "' "$HOOK" && echo yes || echo no)"
expect_eq "engage.sh defines no private root resolver" "" \
  "$(/usr/bin/grep -l '^resolve_project_root()' "$HOOK" 2>/dev/null)"

# ============================================================
section "E6 (AC-18) — engagement precedes the plan, and precedes the tree"
# ============================================================

# (a) A run's Step 0 happens BEFORE its plan file exists. The marker is still written,
# with plan=none, and the walls bind once the plan lands — without re-invocation.
R6="$(make_repo_planless)"
M6="$(marker_path "$R6" "$SID")"
fire "$SID" "$(skill_payload "$SID" "$R6" "bionic:canonical-sdlc")"
expect_eq "with no plan on disk the hook still exits 0" "0" "$HOOK_RC"
if [ -f "$M6" ]; then ok "…and still writes the marker"; else no "…and still writes the marker" "no file at $M6"; fi
expect_eq "…whose plan field reads none" "plan=none" "$(head -1 "$M6" 2>/dev/null)"
call_engaged "$R6" "$SID"
expect_eq "…and engaged_session is TRUE with no run open" "0" "$ES_ST"

# (b) A FRESH project with no .bionic at all. Nothing else in the payload owns tree
# creation, so without this the first engagement of a new project runs unwalled.
R7="$(make_repo_fresh)"
M7="$(marker_path "$R7" "$SID")"
if [ -e "$R7/.bionic" ]; then no "the fresh fixture starts with no .bionic (non-vacuity)" "it has one"; else
  ok "the fresh fixture starts with no .bionic (non-vacuity)"
fi
fire "$SID" "$(skill_payload "$SID" "$R7" "bionic:canonical-sdlc")"
expect_eq "a fresh project exits 0" "0" "$HOOK_RC"
if [ -d "$R7/.bionic/tmp" ]; then ok "…and the .bionic/tmp tree is created"; else
  no "…and the .bionic/tmp tree is created" "no directory at $R7/.bionic/tmp"
fi
expect_eq "…and .bionic/.gitignore is exactly '*'" "*" "$(cat "$R7/.bionic/.gitignore" 2>/dev/null)"
if [ -f "$M7" ]; then ok "…and the marker lands in the new tree"; else
  no "…and the marker lands in the new tree" "no file at $M7"
fi

# The tree is created ONCE and an existing .gitignore is never rewritten.
printf 'kept-by-the-project\n' > "$R7/.bionic/.gitignore"
fire "$SID" "$(skill_payload "$SID" "$R7" "bionic:canonical-sdlc")"
expect_eq "a second engagement leaves an existing .bionic/.gitignore alone" \
  "kept-by-the-project" "$(cat "$R7/.bionic/.gitignore" 2>/dev/null)"

# (c) A .bionic that is a SYMLINK is refused outright: the hook neither follows it nor
# writes into whatever it points at.
R8="$(make_repo_fresh)"
mkdir -p "$SANDBOX/elsewhere/tmp"
ln -s "$SANDBOX/elsewhere" "$R8/.bionic"
fire "$SID" "$(skill_payload "$SID" "$R8" "bionic:canonical-sdlc")"
expect_eq "a symlinked .bionic exits 0" "0" "$HOOK_RC"
if [ -e "$SANDBOX/elsewhere/tmp/engaged-$SID.state" ]; then
  no "…and nothing is written through the symlink" "marker appeared in the link target"
else
  ok "…and nothing is written through the symlink"
fi

# (d) A .bionic/tmp that is a FILE, not a directory: report, never block.
R9="$(make_repo_fresh)"
mkdir -p "$R9/.bionic"
printf 'not a directory\n' > "$R9/.bionic/tmp"
fire "$SID" "$(skill_payload "$SID" "$R9" "bionic:canonical-sdlc")"
expect_eq "a non-directory .bionic/tmp exits 0 — reported, never blocking" "0" "$HOOK_RC"
expect_empty "…and prints nothing on stdout" "$HOOK_OUT"
expect_eq "…and leaves the file alone" "not a directory" "$(cat "$R9/.bionic/tmp" 2>/dev/null)"

# ============================================================
section "E7 — the sid must resolve, or nothing is written"
# ============================================================

RA="$(make_repo e7)"
# No sid anywhere: not in the env, not in the payload. `session_id` returns 1 and the
# hook has no file to name.
NOSID=$(jq -nc --arg c "$RA" \
  '{transcript_path:"/dev/null",cwd:$c,hook_event_name:"PreToolUse",
    tool_name:"Skill",tool_input:{skill:"bionic:canonical-sdlc"}}')
HOOK_OUT=$(env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SESSION_ID bash "$HOOK" <<< "$NOSID" 2>/dev/null)
HOOK_RC=$?
expect_eq "a payload with no session id anywhere exits 0" "0" "$HOOK_RC"
expect_eq "…and writes no marker at all" "0" \
  "$(find "$RA/.bionic/tmp" -maxdepth 1 -name 'engaged-*' 2>/dev/null | wc -l | tr -d ' ')"

# The env value is primary and the payload is a witness: a divergence keys the marker
# to the env id, never the payload's.
fire "$SID" "$(skill_payload "$OTHER_SID" "$RA" "bionic:canonical-sdlc")"
if [ -f "$(marker_path "$RA" "$SID")" ]; then ok "on divergence the marker is keyed to the ENV id"; else
  no "on divergence the marker is keyed to the ENV id" "no file at $(marker_path "$RA" "$SID")"
fi
if [ -e "$(marker_path "$RA" "$OTHER_SID")" ]; then
  no "…and not to the payload's witness id" "a marker appeared for the payload id"
else
  ok "…and not to the payload's witness id"
fi

# A malformed payload is not a crash.
HOOK_OUT=$(env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$SID" bash "$HOOK" <<< 'not json at all' 2>/dev/null)
HOOK_RC=$?
expect_eq "a non-JSON payload exits 0" "0" "$HOOK_RC"
expect_empty "…and prints nothing" "$HOOK_OUT"

# ============================================================
section "E8 (wave-session-bound-run, AC-7/AC-8/AC-9) — bind_plan, the single writer"
# ============================================================
#
# `payload/scripts/lib/binding.sh` is the ONE function allowed to write the marker.
# Three callers land here — this hook, poker's `bind` verb, the governing skill's
# bind-on-first-write — and the whole point of one writer is that the invariants are
# asserted ONCE, here: the two-line shape, mode 600, the symlink refusal, and
# membership in `open_runs` at the instant of the write.
#
# THE FAIL DIRECTION IS STILL INVERTED. A binding is what makes a session's walls
# read a PARTICULAR plan, so a wrong binding is worse than no binding: it points a
# gate at somebody else's run. Every refusal arm below therefore sits beside a
# positive on the SAME root, one argument apart.

R10="$(make_repo e8)"
P10A="$R10/.bionic/docs/plans/wave-01.plan.md"

# (a) THE SHAPE, byte for byte. Not "contains plan=" — the file is exactly two lines,
# in this order, newline-terminated, and nothing else.
M10="$(marker_path "$R10" "$SID")"
rm -f "$M10"
call_bind "$R10" "$SID" "$P10A"
expect_eq "bind_plan to the root's one open plan exits 0" "0" "$BIND_ST"
expect_empty "…and prints nothing on stdout" "$BIND_OUT"
expect_empty "…and nothing on stderr" "$BIND_ERR"
if [ -f "$M10" ]; then ok "…and the marker is a regular file"; else no "…and the marker is a regular file" "no file at $M10"; fi
ST10=$(engat_of "$M10")
printf 'plan=%s\nengaged_at=%s\n' "$P10A" "$ST10" > "$SANDBOX/expect10.state"
if cmp -s "$SANDBOX/expect10.state" "$M10"; then
  ok "…and the marker is byte-for-byte plan= + engaged_at=, newline-terminated"
else
  no "…and the marker is byte-for-byte plan= + engaged_at=, newline-terminated" \
     "got: $(od -An -c "$M10" 2>/dev/null | tr -s ' ')"
fi
if printf '%s' "$ST10" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  ok "…and engaged_at is an ISO-8601 UTC stamp"
else
  no "…and engaged_at is an ISO-8601 UTC stamp" "engaged_at was [$ST10]"
fi

# (b) MODE 600 OVER A PRE-EXISTING 0644 MARKER. `>` keeps the old mode, so the umask
# in the writer is not enough on its own — this is the arm that catches a writer that
# dropped the explicit chmod.
printf 'plan=none\nengaged_at=2020-01-01T00:00:00Z\n' > "$M10"
chmod 644 "$M10"
expect_eq "the pre-existing marker really is 0644 (non-vacuity)" "644" "$(mode_of "$M10")"
call_bind "$R10" "$SID" "$P10A"
expect_eq "…a rewrite over it exits 0" "0" "$BIND_ST"
expect_eq "…and the marker is mode 0600 afterwards" "600" "$(mode_of "$M10")"
expect_eq "…and the plan field was actually rewritten (non-vacuity)" "$P10A" "$(plan_of "$M10")"

# (c) ENGAGED_AT IS PRESERVED across a rewrite — a session engages once, and the
# stamp is the answer to "since when", not "most recently touched".
printf 'plan=none\nengaged_at=2019-03-04T05:06:07Z\n' > "$M10"
call_bind "$R10" "$SID" "$P10A"
expect_eq "a rewrite preserves the existing engaged_at" "2019-03-04T05:06:07Z" "$(engat_of "$M10")"
expect_eq "…while the plan field moves (the paired positive)" "$P10A" "$(plan_of "$M10")"
# …and a marker with NO engaged_at line gets a fresh one rather than an empty field.
printf 'plan=none\n' > "$M10"
call_bind "$R10" "$SID" "$P10A"
if printf '%s' "$(engat_of "$M10")" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  ok "a marker with no engaged_at line gets a fresh stamp"
else
  no "a marker with no engaged_at line gets a fresh stamp" "engaged_at was [$(engat_of "$M10")]"
fi

# (d) CRLF-TOLERANT READ of the old marker. A marker that went through a
# CRLF-normalising tool must not yield a preserved stamp with a trailing CR — every
# consumer compares that value as text, and the writer would bake the CR in forever.
printf 'plan=none\r\nengaged_at=2018-07-08T09:10:11Z\r\n' > "$M10"
expect_eq "the CRLF fixture really carries CRs (non-vacuity)" "2" \
  "$(tr -cd '\r' < "$M10" | wc -c | tr -d ' ')"
call_bind "$R10" "$SID" "$P10A"
expect_eq "a CRLF marker's engaged_at is preserved without its CR" "2018-07-08T09:10:11Z" "$(engat_of "$M10")"
expect_eq "…and the rewritten marker carries no CR at all" "0" \
  "$(tr -cd '\r' < "$M10" | wc -c | tr -d ' ')"
printf 'plan=%s\nengaged_at=2018-07-08T09:10:11Z\n' "$P10A" > "$SANDBOX/expect10c.state"
if cmp -s "$SANDBOX/expect10c.state" "$M10"; then ok "…and is byte-for-byte the two-line shape"; else
  no "…and is byte-for-byte the two-line shape" "got: $(od -An -c "$M10" 2>/dev/null | tr -s ' ')"
fi

# (e) `none` IS ALWAYS ACCEPTED. It is what engagement writes when the root holds zero
# or several open runs, so a writer that validated it as a path would make the
# commonest engagement impossible.
call_bind "$R10" "$SID" "none"
expect_eq "bind_plan … none exits 0" "0" "$BIND_ST"
expect_eq "…and writes plan=none" "none" "$(plan_of "$M10")"
expect_eq "…and still preserves engaged_at" "2018-07-08T09:10:11Z" "$(engat_of "$M10")"
expect_eq "…and is still mode 0600" "600" "$(mode_of "$M10")"

# (f) A PLAN THAT IS NOT AN OPEN RUN OF THIS ROOT IS REFUSED — four ways, each paired
# with the open plan of the same root on the same call shape.
R10B="$(make_repo e8b)"
P10B="$R10B/.bionic/docs/plans/wave-01.plan.md"
CLOSED10="$(mk_closed_plan "$R10" "wave-09-closed.plan.md")"
NOTPLAN10="$(mk_nonplan "$R10" "notes.md")"

for bad_pair in "outside-this-root|$P10B" "closed|$CLOSED10" "not-a-plan|$NOTPLAN10" \
                "missing|$R10/.bionic/docs/plans/no-such.plan.md" "relative|wave-01.plan.md"; do
  why="${bad_pair%%|*}"; badp="${bad_pair#*|}"
  printf 'plan=sentinel\nengaged_at=2017-01-01T00:00:00Z\n' > "$M10"
  call_bind "$R10" "$SID" "$badp"
  expect_eq "bind_plan refuses a $why plan (exit 1)" "1" "$BIND_ST"
  expect_eq "…and leaves the marker untouched" "sentinel" "$(plan_of "$M10")"
  expect_empty "…and prints nothing" "$BIND_OUT"
  # the pair: same root, same marker, one argument apart
  call_bind "$R10" "$SID" "$P10A"
  expect_eq "…paired: the root's open plan on the same fixture is ACCEPTED" "0" "$BIND_ST"
  expect_eq "…paired: and the marker now names it" "$P10A" "$(plan_of "$M10")"
done

# A closed plan re-opened in place is accepted — the refusal above was about STATE,
# not about the file, and this is what proves it.
mk_open_plan "$R10" "wave-09-closed.plan.md" >/dev/null
call_bind "$R10" "$SID" "$CLOSED10"
expect_eq "the same path re-opened in place is now ACCEPTED" "0" "$BIND_ST"
expect_eq "…and the marker names it" "$CLOSED10" "$(plan_of "$M10")"
mk_closed_plan "$R10" "wave-09-closed.plan.md" >/dev/null

# (g) A SYMLINK AT THE MARKER PATH IS REFUSED BEFORE IT IS FOLLOWED. The writer is the
# only thing in the fleet that opens this path for WRITING, so this guard is the one
# that decides whether a planted link lets a hostile repo clobber a file outside the
# tree at the instant the user invokes the skill.
rm -f "$M10"
printf 'plan=none\nengaged_at=2016-01-01T00:00:00Z\n' > "$SANDBOX/bindtarget.state"
ln -s "$SANDBOX/bindtarget.state" "$M10"
call_bind "$R10" "$SID" "$P10A"
expect_eq "bind_plan refuses a symlinked marker path (exit 1)" "1" "$BIND_ST"
if [ -L "$M10" ]; then ok "…and leaves the symlink in place"; else no "…and leaves the symlink in place"; fi
expect_eq "…and does not write through it" \
  "plan=none
engaged_at=2016-01-01T00:00:00Z" "$(cat "$SANDBOX/bindtarget.state")"
rm -f "$M10"
call_bind "$R10" "$SID" "$P10A"
expect_eq "…paired: with the link removed the same call WRITES (exit 0)" "0" "$BIND_ST"
expect_eq "…paired: and the marker is a real file naming the plan" "$P10A" "$(plan_of "$M10")"

# (g2) A SYMLINK ON THE MARKER'S *DIRECTORY* IS REFUSED TOO (S10a, review SEC F1). The leaf
# test in (g) answered "is the marker a link" and left "is the marker's directory a link"
# unasked, so a tree shipping `.bionic/tmp` — or `.bionic` — as a symlink had the writer
# create a file outside the root with every other guard satisfied. Two arms, one per
# ancestor, each paired with the same call after the link is undone. The assertion is not
# only the exit status: it is that NOTHING landed at the link's target, which is the actual
# harm.
for depth in tmp bionic; do
  R10G="$(make_repo "e8g2$depth")"
  P10G="$R10G/.bionic/docs/plans/wave-01.plan.md"
  case "$depth" in
    tmp)    LINKED="$R10G/.bionic/tmp"; ELSEWHERE="$SANDBOX/e8g2-outside-tmp";    LABEL=".bionic/tmp" ;;
    bionic) LINKED="$R10G/.bionic";     ELSEWHERE="$SANDBOX/e8g2-outside-bionic"; LABEL=".bionic" ;;
  esac
  mv "$LINKED" "$ELSEWHERE"
  ln -s "$ELSEWHERE" "$LINKED"
  expect_eq "the $depth fixture really is a symlink (non-vacuity)" "yes" \
    "$([ -L "$LINKED" ] && echo yes || echo no)"
  expect_eq "…and the plan is still reachable through it (non-vacuity)" "yes" \
    "$([ -f "$P10G" ] && echo yes || echo no)"
  call_bind "$R10G" "$SID" "$P10G"
  expect_eq "bind_plan refuses a symlinked $LABEL directory (exit 1)" "1" "$BIND_ST"
  expect_empty "…and prints nothing" "$BIND_OUT"
  expect_eq "…and NOTHING was written outside the root through the link" "0" \
    "$(find "$ELSEWHERE" -name 'engaged-*.state' 2>/dev/null | wc -l | tr -d ' ')"
  # the pair: undo the link, leave everything else identical, and the same call writes
  rm -f "$LINKED"
  mv "$ELSEWHERE" "$LINKED"
  call_bind "$R10G" "$SID" "$P10G"
  expect_eq "…paired: with the link undone the same call WRITES (exit 0)" "0" "$BIND_ST"
  expect_eq "…paired: and the marker names the plan" "$P10G" \
    "$(plan_of "$(marker_path "$R10G" "$SID")")"
done

# (j) THE MARKER HOLDS THE CANONICAL SPELLING, NOT THE ARGUMENT (S10a, review SEC's
# correctness note). `bind_plan` validated a resolved path and then wrote the raw one, so a
# caller spelling the plan with a `..` left a marker whose text does not share the docs-root
# prefix it was just checked against. The value written is `_bind_resolve`'s.
rm -f "$M10"
call_bind "$R10" "$SID" "$R10/.bionic/docs/plans/../plans/wave-01.plan.md"
expect_eq "a dot-dot spelling that lands back inside is still ACCEPTED (exit 0)" "0" "$BIND_ST"
expect_eq "…and the marker holds the CANONICAL path, not the argument" "$P10A" "$(plan_of "$M10")"
call_bind "$R10" "$SID" "none"
expect_eq "…and the literal none is still stored verbatim, never resolved" "none" "$(plan_of "$M10")"

# (h) THE SID SHAPE RULE IS `engaged_marker_path`'s, NOT RESTATED. A sid the reader
# refuses must be a sid the writer refuses, or the fleet grows a file nobody reads.
for bad_sid in "" "unknown" "../../../escape" "a b"; do
  call_bind "$R10" "$bad_sid" "$P10A"
  expect_eq "bind_plan refuses the sid [$bad_sid] (exit 1)" "1" "$BIND_ST"
  expect_empty "…and prints nothing for sid [$bad_sid]" "$BIND_OUT"
done
expect_eq "…and no stray marker was created by any of them" "1" \
  "$(find "$R10/.bionic/tmp" -maxdepth 1 -name 'engaged-*' 2>/dev/null | wc -l | tr -d ' ')"
call_bind "$R10" "$SID" "$P10A"
expect_eq "…paired: the well-formed sid on the same root still writes" "0" "$BIND_ST"

# (i) A WRITE THAT CANNOT LAND IS EXIT 2, not exit 1: a refusal and a broken tree are
# different answers, and only one of them is the caller's fault.
R10C="$(make_repo e8c)"
M10C="$(marker_path "$R10C" "$SID")"
P10C="$R10C/.bionic/docs/plans/wave-01.plan.md"
mkdir -p "$M10C"
call_bind "$R10C" "$SID" "$P10C"
expect_eq "a directory at the marker path is a WRITE FAILURE (exit 2)" "2" "$BIND_ST"
rmdir "$M10C"
call_bind "$R10C" "$SID" "$P10C"
expect_eq "…paired: with the directory gone the same call writes (exit 0)" "0" "$BIND_ST"

# ============================================================
section "E9 (AC-7) — engagement binds the SOLE open run, and a binding survives"
# ============================================================
#
# THE RULE THIS SUITE NOW OWNS (wave-session-bound-run, spec §Design "Session binding";
# amended at S10a, review C-1):
#
#   the marker already names a plan            -> LEAVE IT, open or closed
#   otherwise, exactly one open run in the root -> bind to it
#   otherwise (zero, or two and up)             -> bind to `none`
#
# The old hook bound `active_run` unconditionally, which is the NEWEST open plan. Both
# halves of the change are asserted below and neither passes under the old rule: a
# second, newer plan must NOT steal a live binding, and two open plans must produce no
# binding at all rather than a coin-flip on mtime.
#
# THE CLOSED CASE MOVED (S10a). Until S10a a `bound-closed` session fell through to the
# count rule, and (e) below pinned that as correct. It is not: when the root holds exactly
# one open run, that run belongs to ANOTHER SESSION, so a session whose own wave had just
# closed was silently re-pointed at the neighbour's plan by the act of re-invoking the
# skill. (e) now pins the preservation and pairs it with the count rule firing for a
# session that is genuinely unbound on the same root, one line apart.

# (a) Exactly one open run: the marker names it, exactly.
R11="$(make_repo e9a)"
M11="$(marker_path "$R11" "$SID")"
P11="$R11/.bionic/docs/plans/wave-01.plan.md"
call_open_runs "$R11"
expect_eq "the one-run fixture really holds exactly one open run (non-vacuity)" "1" \
  "$(printf '%s\n' "$OR_OUT" | grep -c . )"
fire "$SID" "$(skill_payload "$SID" "$R11" "bionic:canonical-sdlc")"
expect_eq "engaging a root with one open run exits 0" "0" "$HOOK_RC"
expect_eq "…and the marker's plan field is exactly that plan" "$P11" "$(plan_of "$M11")"
expect_eq "…and the marker is exactly two lines" "2" "$(wc -l < "$M11" | tr -d ' ')"

# (b) TWO open runs: no binding at all. Under the old rule this bound the newer one.
# Both stamps are RELATIVE to real "now" (S2: `live_runs` reads real mtime-vs-now here,
# no `BIONIC_NOW_EPOCH` pin), one hour apart, so each plan stays inside the default
# live-window while `-nt` ordering between them is unchanged.
P11B="$(mk_open_plan "$R11" "wave-02.plan.md" "$(rel_stamp 60)")"
touch -t "$(rel_stamp 3600)" "$P11"
call_open_runs "$R11"
expect_eq "the two-run fixture really holds two open runs (non-vacuity)" "2" \
  "$(printf '%s\n' "$OR_OUT" | grep -c . )"
expect_eq "…and the NEWER of the two is what active_run/open_runs would pick" "$P11B" \
  "$(printf '%s\n' "$OR_OUT" | head -1)"
rm -f "$M11"
fire "$SID" "$(skill_payload "$SID" "$R11" "bionic:canonical-sdlc")"
expect_eq "engaging a root with two open runs exits 0" "0" "$HOOK_RC"
expect_eq "…and binds NOTHING: plan=none" "none" "$(plan_of "$M11")"
case "$(cat "$M11" 2>/dev/null)" in
  *"$P11B"*) no "…and neither plan's path appears in the marker" "the newer plan's path is in the marker" ;;
  *"$P11"*)  no "…and neither plan's path appears in the marker" "the older plan's path is in the marker" ;;
  *) ok "…and neither plan's path appears in the marker" ;;
esac
# the pair: drop back to one open run on the SAME root and the binding returns
rm -f "$P11B"
fire "$SID" "$(skill_payload "$SID" "$R11" "bionic:canonical-sdlc")"
expect_eq "…paired: with one open run again the same root binds to it" "$P11" "$(plan_of "$M11")"

# (c) NO open run at all: plan=none, and the count rule is what says so.
R12="$(make_repo_planless)"
M12="$(marker_path "$R12" "$SID")"
call_open_runs "$R12"
expect_eq "the planless fixture really holds no open run (non-vacuity)" "1" "$OR_ST"
fire "$SID" "$(skill_payload "$SID" "$R12" "bionic:canonical-sdlc")"
expect_eq "engaging a planless root writes plan=none" "none" "$(plan_of "$M12")"

# (d) A LIVE BINDING SURVIVES RE-ENGAGEMENT even when a NEWER open plan has landed.
# This is the wave's own claim: the session's binding decides WHAT, and newest-plan is
# a fallback for the unbound, not a rule that outranks a commitment already made.
R13="$(make_repo e9d)"
M13="$(marker_path "$R13" "$SID")"
P13A="$R13/.bionic/docs/plans/wave-01.plan.md"
# RELATIVE to real "now" (S2: `live_runs` reads real mtime-vs-now here, no
# `BIONIC_NOW_EPOCH` pin), so the first engagement still finds it live.
touch -t "$(rel_stamp 7200)" "$P13A"
fire "$SID" "$(skill_payload "$SID" "$R13" "bionic:canonical-sdlc")"
expect_eq "the session binds to the only plan there is (non-vacuity)" "$P13A" "$(plan_of "$M13")"
AT13=$(engat_of "$M13")
P13B="$(mk_open_plan "$R13" "wave-02.plan.md" "$(rel_stamp 60)")"
call_open_runs "$R13"
expect_eq "a NEWER open plan is now the root's newest (non-vacuity)" "$P13B" \
  "$(printf '%s\n' "$OR_OUT" | head -1)"
fire "$SID" "$(skill_payload "$SID" "$R13" "bionic:canonical-sdlc")"
expect_eq "re-engagement exits 0" "0" "$HOOK_RC"
expect_eq "…and the ORIGINAL binding is preserved, not the newest plan" "$P13A" "$(plan_of "$M13")"
case "$(cat "$M13" 2>/dev/null)" in
  *"$P13B"*) no "…and the newer plan's path appears nowhere in the marker" "it does" ;;
  *) ok "…and the newer plan's path appears nowhere in the marker" ;;
esac
expect_eq "…and engaged_at is unchanged across re-engagement" "$AT13" "$(engat_of "$M13")"

# (e) A binding whose plan has CLOSED IS STILL PRESERVED (S10a, review C-1). This is the
# exact shape of the bug the wave was opened on, reached through the engagement door: the
# session's own wave is delivered, ONE other run is open in the root, and that run is
# somebody else's. Falling to the count rule here hands this session the neighbour's plan
# and its evidence gate then gates on it.
#
# THE PAIR IS ON THE SAME ROOT, one field apart: a session with NO binding at all engages
# against the identical tree and the count rule fires normally. Without it this row would
# pass on a hook that had stopped writing markers at all.
R14="$(make_repo e9e)"
M14="$(marker_path "$R14" "$SID")"
P14A="$R14/.bionic/docs/plans/wave-01.plan.md"
fire "$SID" "$(skill_payload "$SID" "$R14" "bionic:canonical-sdlc")"
expect_eq "the session binds to its plan while it is open (non-vacuity)" "$P14A" "$(plan_of "$M14")"
AT14=$(engat_of "$M14")
mk_closed_plan "$R14" "wave-01.plan.md" >/dev/null
P14B="$(mk_open_plan "$R14" "wave-02.plan.md")"
call_open_runs "$R14"
expect_eq "…and after delivery the root holds exactly one open run, the new one" "$P14B" "$OR_OUT"
fire "$SID" "$(skill_payload "$SID" "$R14" "bionic:canonical-sdlc")"
expect_eq "re-engaging a session bound to a DELIVERED plan exits 0" "0" "$HOOK_RC"
expect_eq "…and the dead binding is PRESERVED, not swapped for the root's sole open run" \
  "$P14A" "$(plan_of "$M14")"
case "$(cat "$M14" 2>/dev/null)" in
  *"$P14B"*) no "…and the neighbour's plan appears nowhere in the marker" "it does" ;;
  *) ok "…and the neighbour's plan appears nowhere in the marker" ;;
esac
expect_eq "…and engaged_at is untouched by the refused rewrite" "$AT14" "$(engat_of "$M14")"
# the pair: an UNBOUND session on the SAME tree still gets the count rule
M14B="$(marker_path "$R14" "$OTHER_SID")"
rm -f "$M14B"
fire "$OTHER_SID" "$(skill_payload "$OTHER_SID" "$R14" "bionic:canonical-sdlc")"
expect_eq "…paired: a session with no binding on the same root binds to the sole open run" \
  "$P14B" "$(plan_of "$M14B")"
expect_eq "…paired: and the first session's marker is still its own closed plan" \
  "$P14A" "$(plan_of "$M14")"

# (e2) A REFUSED BIND ON THE UNBOUND ARM STILL LEAVES A MARKER (S10a, review C-4). `PLAN` is
# chosen from a walk that has finished; `bind_plan` walks AGAIN for its own membership check,
# so a run closing inside that window made the one write refuse and the session engaged with
# no marker at all — unengaged, and therefore unwalled, which is the direction this hook's
# own fail-direction argument forbids.
#
# THE RACE IS FORCED, NOT WAITED FOR. A throwaway plugin tree (hooks/ beside scripts/lib/,
# the shape the loader's first candidate finds — the pattern
# tests/cross-gate-agreement.test.sh §A2 uses) carries a `bind_plan` doctored to refuse every
# argument but `none`, which is exactly what the losing side of the race sees. The shipped
# library is not touched. The seam is the writer, and the writer is not what is under test
# here: what is under test is whether the HOOK still leaves a marker when the writer says no.
E9F_TREE="$SANDBOX/e9f-tree"
mkdir -p "$E9F_TREE/hooks" "$E9F_TREE/scripts/lib"
cp "$REPO_ROOT"/payload/scripts/lib/*.sh "$E9F_TREE/scripts/lib/"
cp "$HOOK" "$E9F_TREE/hooks/engage.sh"
cat >> "$E9F_TREE/scripts/lib/binding.sh" <<'REFUSER'

# S10a test double: the losing side of the bind_plan TOCTOU. Everything but `none` refuses.
bind_plan() {
  [ "$3" = "none" ] || return 1
  local p; p=$(engaged_marker_path "$1" "$2") || return 1
  ( umask 077; printf 'plan=none\nengaged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$p" )
}
REFUSER
R15="$(make_repo e9f)"
M15="$(marker_path "$R15" "$SID")"
rm -f "$M15"
call_open_runs "$R15"
expect_eq "the e9f fixture holds exactly one open run, so the hook picks a PATH (non-vacuity)" "1" \
  "$(printf '%s\n' "$OR_OUT" | grep -c . )"
HOOK_OUT=$(env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$E9F_TREE/hooks/engage.sh" <<< "$(skill_payload "$SID" "$R15" "bionic:canonical-sdlc")" \
  2>"$SANDBOX/.err")
expect_eq "a bind refused mid-race still exits 0" "0" "$?"
if [ -f "$M15" ]; then ok "…and a marker EXISTS: the session is engaged, not silently unwalled"; else
  no "…and a marker EXISTS: the session is engaged, not silently unwalled" "no file at $M15"; fi
expect_eq "…and it says plan=none, the answer the count rule would have given" "none" "$(plan_of "$M15")"

# (f) The hook writes through the one writer, and nowhere else. A second `>` onto the
# marker path anywhere in the hook is the regression this pins.
expect_eq "engage.sh calls bind_plan" "yes" \
  "$(/usr/bin/grep -q 'bind_plan ' "$HOOK" && echo yes || echo no)"
expect_eq "engage.sh performs no marker write of its own" "0" \
  "$(/usr/bin/grep -c '> *"\$MARKER"' "$HOOK")"
expect_eq "engage.sh wants binding.sh from the loader" "1" \
  "$(/usr/bin/grep -c '^BIONIC_LIB_WANT=".*binding\.sh' "$HOOK")"

# ============================================================
section "E10 (AC-2, wave-roster-lifecycle S2) — the count rule counts LIVE runs, not merely open ones"
# ============================================================
#
# S2 (spec AC-2; design §2 "engage.sh"). `RUNS=$(open_runs "$REPO")` becomes
# `RUNS=$(live_runs "$REPO")`; the `= "1"` count rule and the single `bind_plan` call site
# are unchanged (that call site is load-bearing for cross-gate §B2 — S1's report, and the
# comment above it in engage.sh, both say so). LIVE ⊆ OPEN always, so every E9 case above is
# unaffected by fixtures where the sole/newest open plan is also fresh; this section adds the
# cases where open and live now disagree — a plan that is open but QUIET.
#
# THE CLOCK IS AN INPUT, same idiom as run-predicate.test.sh R10: `BIONIC_NOW_EPOCH` pins
# "now" for `live_runs`, and each plan's mtime is set with `touch -t` relative to it, so the
# rows measure the live-window rather than how long the suite took to reach them. The pin is
# exported around `fire` (not baked into it) because `fire`'s own `env -u … VAR=… bash …`
# invocation inherits the rest of the calling shell's exported environment.

E10_NOW=1789000000
e10_age() {  # <file> <seconds before E10_NOW>
  local at=$(( E10_NOW - $2 ))
  touch -t "$(date -r "$at" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$at" +%Y%m%d%H%M.%S)" "$1"
}
E10_DAY=86400

# (a) THREE open plans, exactly one fresh (within the default 7d window): the marker names
# the FRESH one. Under the old open-count rule this fixture bound nothing at all (three
# open runs); under the live rule it binds because exactly one is live.
R20="$(make_repo_planless)"
M20="$(marker_path "$R20" "$SID")"
P20FRESH="$(mk_open_plan "$R20" "fresh.plan.md")"
P20Q1="$(mk_open_plan "$R20" "quiet-1.plan.md")"
P20Q2="$(mk_open_plan "$R20" "quiet-2.plan.md")"
e10_age "$P20FRESH" 3600
e10_age "$P20Q1" $(( 8 * E10_DAY ))
e10_age "$P20Q2" $(( 20 * E10_DAY ))
call_open_runs "$R20"
expect_eq "the three-plan fixture really holds three OPEN runs (non-vacuity)" "3" \
  "$(printf '%s\n' "$OR_OUT" | grep -c .)"
export BIONIC_NOW_EPOCH="$E10_NOW"
fire "$SID" "$(skill_payload "$SID" "$R20" "bionic:canonical-sdlc")"
unset BIONIC_NOW_EPOCH
expect_eq "engaging three open plans, exactly one LIVE, exits 0" "0" "$HOOK_RC"
expect_eq "…and the marker names the LIVE plan, not merely a member of the open set" \
  "$P20FRESH" "$(plan_of "$M20")"

# (b) TWO fresh plans (both live): the live count is not one, so no binding at all — the
# same "several agree" refusal E9(b) pins for open, now pinned for live.
R21="$(make_repo_planless)"
M21="$(marker_path "$R21" "$SID")"
P21A="$(mk_open_plan "$R21" "fresh-a.plan.md")"
P21B="$(mk_open_plan "$R21" "fresh-b.plan.md")"
e10_age "$P21A" 3600
e10_age "$P21B" 7200
call_open_runs "$R21"
expect_eq "the two-fresh fixture holds two OPEN runs (non-vacuity)" "2" \
  "$(printf '%s\n' "$OR_OUT" | grep -c .)"
export BIONIC_NOW_EPOCH="$E10_NOW"
fire "$SID" "$(skill_payload "$SID" "$R21" "bionic:canonical-sdlc")"
unset BIONIC_NOW_EPOCH
expect_eq "engaging two LIVE open plans exits 0" "0" "$HOOK_RC"
expect_eq "…and binds NOTHING: plan=none" "none" "$(plan_of "$M21")"
case "$(cat "$M21" 2>/dev/null)" in
  *"$P21A"*|*"$P21B"*) no "…and neither plan's path appears in the marker" "one does" ;;
  *) ok "…and neither plan's path appears in the marker" ;;
esac

# (c) ONE open plan, but QUIET (backdated past the default 7d window): the OPEN count is
# one — the exact shape E9(a) binds under the old rule — but the LIVE count is zero, so
# plan=none. This is S2's headline case: an open-but-quiet solo run must NOT bind.
R22="$(make_repo_planless)"
M22="$(marker_path "$R22" "$SID")"
P22="$(mk_open_plan "$R22" "quiet-solo.plan.md")"
e10_age "$P22" $(( 8 * E10_DAY ))
call_open_runs "$R22"
expect_eq "the quiet-solo fixture still holds exactly one OPEN run (non-vacuity)" "1" \
  "$(printf '%s\n' "$OR_OUT" | grep -c .)"
export BIONIC_NOW_EPOCH="$E10_NOW"
fire "$SID" "$(skill_payload "$SID" "$R22" "bionic:canonical-sdlc")"
unset BIONIC_NOW_EPOCH
expect_eq "engaging a root whose sole open run is quiet exits 0" "0" "$HOOK_RC"
expect_eq "…and binds NOTHING: plan=none, though the OPEN count said one" "none" "$(plan_of "$M22")"
case "$(cat "$M22" 2>/dev/null)" in
  *"$P22"*) no "…and the quiet plan's path appears nowhere in the marker" "it does" ;;
  *) ok "…and the quiet plan's path appears nowhere in the marker" ;;
esac
# the pair: the SAME plan while still fresh binds normally, so the row above measured
# liveness and not some other property of this fixture.
R22B="$(make_repo_planless)"
M22B="$(marker_path "$R22B" "$SID")"
P22B="$(mk_open_plan "$R22B" "quiet-solo.plan.md")"
e10_age "$P22B" 3600
export BIONIC_NOW_EPOCH="$E10_NOW"
fire "$SID" "$(skill_payload "$SID" "$R22B" "bionic:canonical-sdlc")"
unset BIONIC_NOW_EPOCH
expect_eq "…paired: the identically-shaped plan while still FRESH binds" "$P22B" "$(plan_of "$M22B")"

# (d) AN EXISTING BOUND-OPEN BINDING SURVIVES RE-ENGAGEMENT, unaffected by the live/open
# swap. This is E9(d)/E9(e)'s own claim (S2's plan names it explicitly as a case that must
# stay green rather than a new assertion): a session's binding decides WHAT, and the live
# count — like the open count before it — is a rule for the UNBOUND only. No new fixture is
# built here; E9(d) and E9(e) above are the proof, re-affirmed for the record.

# ============================================================
finish
