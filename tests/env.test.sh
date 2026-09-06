#!/bin/bash
# ENVIRONMENT SETTINGS — epic-17 wave-07 slice S4 (spec R4 / AC-5, AC-6, AC-7).
#
# WHAT THIS SUITE OWNS. payload/scripts/lib/env.sh: the `env` object in the CLI's
# own settings.json — which names bionic puts there, the merge that adds one
# without touching the rest of the file, the delete that removes one and takes
# the object with it when it empties, and the difference between a value the
# FILE carries and a value THIS PROCESS has.
#
# WHAT IT DOES NOT OWN. How setup asks for the write, how remove asks for the
# delete or migrates the retired ~/.zshrc block, how doctor renders the pair,
# and the settings-writer shape env.sh delegates to. tests/setup.test.sh,
# tests/remove.test.sh, and tests/doctor.test.sh used to cover those in turn —
# all three were deleted at 8582861 (epic-18 wave-03) and nothing replaced
# them, so none of this is tested from outside this file today. This file's
# writes still route through env.sh's own writer rather than restating it,
# same as always.
#
# WHY "CONFIGURED" AND "LIVE" ARE TWO ARMS EVERYWHERE BELOW. On 2026-08-21 a
# session ran with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` written to disk and absent
# from the process — the host had launched its shell with rc files disabled — and
# nothing bionic printed could tell those two states apart. Every read arm here
# is therefore doubled: what the file says, and what the running process has,
# planted independently so an implementation that answered one from the other
# fails.
#
# HERMETIC. No network, no live ~/.claude: every arm builds its own settings
# file under $TMP and hands its path over through BIONIC_SETTINGS_FILE, the same
# override deps.sh reads in production. jq is the real jq — it is a hard
# dependency of the thing under test, not a seam.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below — the lesson
# tests/assert-helper-race.test.sh used to pin (deleted at 8582861, epic-18
# wave-03; nothing replaced the pin): containment is bash `[[ == * ]]`
# in-process, and grep runs against FILE arguments only.
#
# Usage: bash tests/env.test.sh
# Registered by name in tests/run.sh (tests/*.test.sh is NOT auto-globbed).

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
ENV_SH="${REPO}/payload/scripts/lib/env.sh"
SETUP_SH="${REPO}/payload/scripts/setup.sh"
REMOVE_SH="${REPO}/payload/scripts/remove.sh"
DOCTOR_SH="${REPO}/payload/scripts/doctor.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "env.test.sh: jq is required"; exit 1; }

# ---------------------------------------------------------------------------
# Fixtures
#
# FIXTURE FIDELITY (spec AC-5). The shape below is this machine's own
# settings.json as it stood on 2026-08-21 — an `env` object holding a name that
# is NOT bionic's beside a `permissions` object and other top-level keys. That
# combination is the whole risk surface: a write that assigned `.env` instead of
# merging into it would delete a user's tokens, and a write that rebuilt the
# document would drop `permissions`. The key names in the record are this
# machine's; the values are not, and are not needed to reproduce the shape.
# ---------------------------------------------------------------------------

# <path> — a settings file with a foreign env name and a permissions block.
plant_settings_populated() {
  cat > "$1" <<'JSON'
{
  "env": {
    "OTHER": "x"
  },
  "permissions": {
    "defaultMode": "auto",
    "allow": [
      "Bash(git status:*)"
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "ccstatusline"
  }
}
JSON
}

# <path> — a settings file with no env object at all: the ordinary shape of a
# machine that never ran setup.
plant_settings_no_env() {
  cat > "$1" <<'JSON'
{
  "permissions": {
    "allow": []
  }
}
JSON
}

# Run one env.sh call against a fixture settings file, in a fresh bash with a
# controlled environment. Everything before `--` is an env assignment; the rest
# is the function and its arguments.
env_run() {  # <settings-file> [env assignments...] -- <function> [args...]
  local settings="$1"; shift
  local a seen=0
  local -a envs=() args=()
  for a in "$@"; do
    if [ "$seen" = "0" ] && [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = "1" ]; then args+=("$a"); else envs+=("$a"); fi
  done
  env -i \
    HOME="$TMP/home" \
    PATH="$PATH" \
    BIONIC_SETTINGS_FILE="$settings" \
    ${envs[@]+"${envs[@]}"} \
    bash -c '. "$1"; shift; "$@"' _ "$ENV_SH" ${args[@]+"${args[@]}"} 2>&1
}

# The same, but reporting the call's exit status instead of its output.
env_status() {  # <settings-file> [env assignments...] -- <function> [args...]
  env_run "$@" >/dev/null 2>&1
}

mkdir -p "$TMP/home"

section "Group 1: the roster and the defaults"

# ONE LIST, THREE READERS. setup writes it, remove deletes it, doctor reports
# it, and all three walk this string. A name that lives in one of them and not
# here is a name the other two cannot see.
expect_eq "ENV_KEYS is exactly the three names bionic owns" \
  "CLAUDE_CODE_ENABLE_TODO_TOOLS BASH_MAX_TIMEOUT_MS CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" \
  "$(env_run "$TMP/nonexistent.json" -- eval 'echo "$ENV_KEYS"')"

expect_eq "the task-list name defaults to 1" "1" \
  "$(env_run "$TMP/nonexistent.json" -- env_default CLAUDE_CODE_ENABLE_TODO_TOOLS)"
# The third name, carried forward from the retired installer's roster at epic-18
# T4 (AC-8). It was an `env-var | CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS | 1` line
# in claude-config.txt that the port dropped silently, which is the whole class
# this task exists to close.
expect_eq "the agent-teams name defaults to 1" "1" \
  "$(env_run "$TMP/nonexistent.json" -- env_default CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)"
expect_eq "the long-command ceiling defaults to thirty minutes, in milliseconds" "1800000" \
  "$(env_run "$TMP/nonexistent.json" -- env_default BASH_MAX_TIMEOUT_MS)"
expect_false "a name that is not bionic's has no default" \
  env_status "$TMP/nonexistent.json" -- env_default SOMETHING_ELSE

# The ceiling is larger than the longest command bionic runs (the serial suite,
# about fifteen minutes). Stated as an inequality rather than a second copy of
# the number, so raising the ceiling does not need this line edited.
CEILING="$(env_run "$TMP/nonexistent.json" -- env_default BASH_MAX_TIMEOUT_MS)"
expect_true "…and that ceiling clears the serial suite's own wall-clock" \
  test "$CEILING" -gt 900000

section "Group 2: env_set merges into a populated file"

S="$TMP/populated.json"
plant_settings_populated "$S"
expect_true "env_set reports success" \
  env_status "$S" -- env_set BASH_MAX_TIMEOUT_MS 1800000
expect_eq "…the new name is in .env" "1800000" \
  "$(jq -r '.env.BASH_MAX_TIMEOUT_MS' "$S")"
expect_eq "…the foreign env name is untouched" "x" "$(jq -r '.env.OTHER' "$S")"
expect_eq "…and permissions came through whole" "auto" \
  "$(jq -r '.permissions.defaultMode' "$S")"
expect_eq "…including the accreted allow list" "Bash(git status:*)" \
  "$(jq -r '.permissions.allow[0]' "$S")"
expect_eq "…and an unrelated top-level key survives too" "command" \
  "$(jq -r '.statusLine.type' "$S")"

# Both names, written one after the other: the second write must not evict the
# first, which is what an `.env = {…}` assignment would do.
expect_true "the second name writes beside the first" \
  env_status "$S" -- env_set CLAUDE_CODE_ENABLE_TODO_TOOLS 1
expect_eq "…and both are there" "1 1800000" \
  "$(jq -r '[.env.CLAUDE_CODE_ENABLE_TODO_TOOLS, .env.BASH_MAX_TIMEOUT_MS] | join(" ")' "$S")"
expect_eq "…with the foreign name still beside them" "x" "$(jq -r '.env.OTHER' "$S")"

# IDEMPOTENT. The same write twice leaves the same bytes — this is what lets
# setup's item say "nothing to do" honestly rather than rewriting on every run.
BYTES_BEFORE="$(shasum -a 256 "$S" | awk '{print $1}')"
env_status "$S" -- env_set CLAUDE_CODE_ENABLE_TODO_TOOLS 1
expect_eq "writing the same value twice changes no bytes" \
  "$BYTES_BEFORE" "$(shasum -a 256 "$S" | awk '{print $1}')"

section "Group 3: env_set creates the env object when there is none"

S2="$TMP/no-env.json"
plant_settings_no_env "$S2"
expect_true "env_set on a file with no env object succeeds" \
  env_status "$S2" -- env_set CLAUDE_CODE_ENABLE_TODO_TOOLS 1
expect_eq "…the object was created with the name in it" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_TODO_TOOLS' "$S2")"
expect_eq "…and the rest of the document is unchanged" "0" \
  "$(jq -r '.permissions.allow | length' "$S2")"

# A machine with no settings.json at all — a fresh box — gets one rather than an
# error, the same way deps.sh's statusline write does.
S3="$TMP/absent.json"
expect_true "env_set on a machine with no settings file creates it" \
  env_status "$S3" -- env_set BASH_MAX_TIMEOUT_MS 1800000
expect_eq "…carrying the name" "1800000" "$(jq -r '.env.BASH_MAX_TIMEOUT_MS' "$S3")"

section "Group 4: env_get reads the file, and only the file"

S4="$TMP/get.json"
plant_settings_populated "$S4"
env_status "$S4" -- env_set BASH_MAX_TIMEOUT_MS 1800000
expect_eq "env_get prints the configured value" "1800000" \
  "$(env_run "$S4" -- env_get BASH_MAX_TIMEOUT_MS)"
expect_false "env_get exits non-zero for a name the file does not carry" \
  env_status "$S4" -- env_get CLAUDE_CODE_ENABLE_TODO_TOOLS
expect_eq "…and prints nothing" "" \
  "$(env_run "$S4" -- env_get CLAUDE_CODE_ENABLE_TODO_TOOLS)"

# THE 2026-08-21 DEFECT, STATED AS AN ARM. A value live in the process must not
# make env_get answer yes: that is exactly the confusion — a name exported into
# the session but absent from the file reads as configured, and the next session
# does not have it.
expect_false "a name live in the process is still absent from the file" \
  env_status "$S4" CLAUDE_CODE_ENABLE_TODO_TOOLS=1 -- env_get CLAUDE_CODE_ENABLE_TODO_TOOLS

expect_false "env_get on a machine with no settings file exits non-zero" \
  env_status "$TMP/never-existed.json" -- env_get BASH_MAX_TIMEOUT_MS

section "Group 5: env_unset deletes exactly one name"

S5="$TMP/unset.json"
plant_settings_populated "$S5"
env_status "$S5" -- env_set BASH_MAX_TIMEOUT_MS 1800000
env_status "$S5" -- env_set CLAUDE_CODE_ENABLE_TODO_TOOLS 1

expect_true "env_unset succeeds" env_status "$S5" -- env_unset BASH_MAX_TIMEOUT_MS
expect_eq "…the name is gone" "" "$(jq -r '.env.BASH_MAX_TIMEOUT_MS // ""' "$S5")"
expect_eq "…the other bionic name is still there" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_TODO_TOOLS' "$S5")"
expect_eq "…and the foreign name is untouched" "x" "$(jq -r '.env.OTHER' "$S5")"

expect_true "the second delete succeeds too" \
  env_status "$S5" -- env_unset CLAUDE_CODE_ENABLE_TODO_TOOLS
expect_eq "…leaving the env object holding exactly the foreign name" '{"OTHER":"x"}' \
  "$(jq -c '.env' "$S5")"
expect_eq "…and permissions still whole" "auto" "$(jq -r '.permissions.defaultMode' "$S5")"

# THE OBJECT GOES WHEN IT EMPTIES. An `"env": {}` left behind is bionic
# footprint that reads like a bionic setting whose value nobody can find.
S6="$TMP/unset-empty.json"
plant_settings_no_env "$S6"
env_status "$S6" -- env_set CLAUDE_CODE_ENABLE_TODO_TOOLS 1
env_status "$S6" -- env_set BASH_MAX_TIMEOUT_MS 1800000
env_status "$S6" -- env_unset CLAUDE_CODE_ENABLE_TODO_TOOLS
env_status "$S6" -- env_unset BASH_MAX_TIMEOUT_MS
expect_eq "the env object is deleted once bionic's last name leaves it" "false" \
  "$(jq -r 'has("env")' "$S6")"
expect_eq "…and the document that carried it is otherwise unchanged" "0" \
  "$(jq -r '.permissions.allow | length' "$S6")"

# Absent is success: a second teardown reports nothing wrong, because nothing is.
expect_true "env_unset of a name that is not there succeeds" \
  env_status "$S6" -- env_unset BASH_MAX_TIMEOUT_MS
expect_true "env_unset on a machine with no settings file succeeds" \
  env_status "$TMP/never-existed-2.json" -- env_unset BASH_MAX_TIMEOUT_MS
expect_false "…and does not create one" test -f "$TMP/never-existed-2.json"

section "Group 6: env_live reads the process, and only the process"

S7="$TMP/live.json"
plant_settings_populated "$S7"
env_status "$S7" -- env_set BASH_MAX_TIMEOUT_MS 1800000

expect_eq "env_live prints the value the process actually carries" "1800000" \
  "$(env_run "$S7" BASH_MAX_TIMEOUT_MS=1800000 -- env_live BASH_MAX_TIMEOUT_MS)"
expect_false "env_live exits non-zero when the process does not carry it" \
  env_status "$S7" -- env_live BASH_MAX_TIMEOUT_MS
expect_eq "…and prints nothing" "" "$(env_run "$S7" -- env_live BASH_MAX_TIMEOUT_MS)"

# THE PAIR THAT NAMES THE DEFECT. Configured and not live is the state a
# restart fixes; live and not configured is the state that dies with the
# session. Both are reachable, and neither answers the other.
expect_true "configured and not live: the file says yes" \
  env_status "$S7" -- env_get BASH_MAX_TIMEOUT_MS
expect_false "…and the process says no" \
  env_status "$S7" -- env_live BASH_MAX_TIMEOUT_MS
expect_true "live and not configured: the process says yes" \
  env_status "$S7" CLAUDE_CODE_ENABLE_TODO_TOOLS=1 -- env_live CLAUDE_CODE_ENABLE_TODO_TOOLS
expect_false "…and the file says no" \
  env_status "$S7" CLAUDE_CODE_ENABLE_TODO_TOOLS=1 -- env_get CLAUDE_CODE_ENABLE_TODO_TOOLS

# A name exported EMPTY is set. Reporting it absent would send a user to repair
# something they deliberately cleared.
expect_true "a name exported empty is live" \
  env_status "$S7" BASH_MAX_TIMEOUT_MS= -- env_live BASH_MAX_TIMEOUT_MS

section "Group 7: the file's mode survives a write"

# The `env` block is where tokens live on a lot of machines, so a settings.json
# a user deliberately kept at 0600 must not come back at 0644 because bionic
# wrote two of its own names into it. env.sh adds no writer of its own — it
# calls deps.sh's. tests/remove.test.sh used to pin that writer's shape from
# the other side; it was deleted at 8582861, so this arm is now the only test
# exercising the mode-survival behaviour at all.
S8="$TMP/mode.json"
plant_settings_populated "$S8"
chmod 600 "$S8"
env_status "$S8" -- env_set BASH_MAX_TIMEOUT_MS 1800000
expect_eq "a 0600 settings file is still 0600 after env_set" "600" \
  "$(stat -f '%Lp' "$S8" 2>/dev/null || stat -c '%a' "$S8" 2>/dev/null)"
env_status "$S8" -- env_unset BASH_MAX_TIMEOUT_MS
expect_eq "…and after env_unset" "600" \
  "$(stat -f '%Lp' "$S8" 2>/dev/null || stat -c '%a' "$S8" 2>/dev/null)"

# THE SETTINGS FILE THAT IS A SYMLINK (S14, the S13 class). `stat -f '%Lp'` on a
# symlink reports the LINK's own mode, never the file it points at — a
# `~/.claude/settings.json` symlinked into a dotfiles repo would hand `chmod`
# the link's mode (755) and publish the rewrite, tokens included, as
# `rwxr-xr-x`. `stat -L` is what makes this pass; tests/remove.test.sh used to
# carry the same arm for the writer's other two siblings, but that suite was
# deleted at 8582861 and nothing replaced it — this arm is now the only one
# testing the symlink case.
#
# AND THE LINK SURVIVES (critic delta 2 N1, A6.S15.1): "wrote through the link"
# was false of this run until S15 — the rename detached the link and left the
# dotfiles copy holding the old content. `_dep_settings_write_jq` now resolves to
# the final target, and the three arms below assert it.
S8_DIR="$TMP/symlink-mode"; mkdir -p "$S8_DIR/dotfiles" "$S8_DIR/home"
plant_settings_populated "$S8_DIR/dotfiles/settings.json"
chmod 600 "$S8_DIR/dotfiles/settings.json"
ln -s "$S8_DIR/dotfiles/settings.json" "$S8_DIR/home/settings.json"
S8_LINK="$S8_DIR/home/settings.json"
# (fixture sanity check removed epic-18 W3 4/6: no production subject -- see ledger-env.md)
env_status "$S8_LINK" -- env_set BASH_MAX_TIMEOUT_MS 1800000
expect_true "symlink arm: env_set really wrote through the link (not vacuous)" \
  bash -c 'jq -e ".env.BASH_MAX_TIMEOUT_MS == \"1800000\"" "$1" >/dev/null' _ "$S8_LINK"
expect_eq "a symlinked settings.json is published at its TARGET's 0600, never the link's 755" \
  "600" "$(stat -L -f '%Lp' "$S8_LINK" 2>/dev/null || stat -L -c '%a' "$S8_LINK" 2>/dev/null)"
expect_true "symlink arm: settings.json is STILL a symlink after env_set" test -L "$S8_LINK"
expect_eq "…and still points where it did" \
  "$S8_DIR/dotfiles/settings.json" "$(readlink "$S8_LINK")"
expect_true "…and it is the dotfiles TARGET that carries the new key, not a detached copy" \
  bash -c 'jq -e ".env.BASH_MAX_TIMEOUT_MS == \"1800000\"" "$1" >/dev/null' _ "$S8_DIR/dotfiles/settings.json"

# The wall, from this side: env.sh renames no tmp over a settings file of its
# own. tests/remove.test.sh used to count the payload's settings writers and
# pin the list, so a private writer here would have been a fifth; that suite
# was deleted at 8582861 and nothing replaced the count, so this local check is
# now the only wall against env.sh growing one.
expect_eq "env.sh contains no settings writer of its own" "0" \
  "$(/usr/bin/grep -c 'mv "\$tmp" "\$settings"' "$ENV_SH" | tr -d ' ')"
expect_true "…it calls the pinned one by name" \
  /usr/bin/grep -q '_dep_settings_write_jq' "$ENV_SH"

section "Group 8: the three callers reach this file and not around it"

# ONE HOME MEANS ONE READER AND ONE WRITER. A caller that reached into `.env`
# with its own jq would be a second opinion about what bionic's environment is,
# which is the defect this file exists to end.
# remove.sh is the DOCUMENTED EXEMPTION and not an oversight: its standalone
# door runs on a machine where scripts/lib/ no longer exists, so it cannot
# source this file and carries a copy of the delete program instead. That copy
# used to be pinned to the original by tests/remove.test.sh, the same way six
# other literals in that script were; the suite was deleted at 8582861 and
# nothing replaced any of those pins. setup and doctor have no such door and
# have no excuse.
for caller in "$SETUP_SH" "$DOCTOR_SH"; do
  expect_eq "$(basename "$caller") reaches .env through no jq of its own" "" \
    "$(/usr/bin/grep -n '\.env\[\|\.env\.\|\.env //' "$caller" || true)"
done
# And remove.sh's copy is the ONE copy: the delete program is spelled once there,
# as a named constant, so the pin has something to hold.
expect_eq "remove.sh spells the env delete program exactly once, as a constant" "1" \
  "$(/usr/bin/grep -c "^RM_ENV_UNSET_JQ=" "$REMOVE_SH" | tr -d ' ')"
expect_true "remove.sh calls env_unset when the library is beside it" \
  /usr/bin/grep -q 'env_unset' "$REMOVE_SH"
expect_true "setup.sh sources env.sh" /usr/bin/grep -q 'env\.sh' "$SETUP_SH"
expect_true "doctor.sh sources env.sh" /usr/bin/grep -q 'env\.sh' "$DOCTOR_SH"

# setup writes bionic's names through env_set and nothing else writes them.
expect_true "setup.sh writes through env_set" /usr/bin/grep -q 'env_set' "$SETUP_SH"
expect_true "doctor.sh reads through env_get and env_live" \
  bash -c 'grep -q "env_get" "$1" && grep -q "env_live" "$1"' _ "$DOCTOR_SH"

# setup no longer writes to a shell rc for the environment. The export it used
# to append is the thing that did not reach the session it was written for.
expect_eq "setup.sh appends no CLAUDE_CODE_ENABLE_TODO_TOOLS export to a shell rc" "" \
  "$(/usr/bin/grep -n 'export CLAUDE_CODE_ENABLE_TODO_TOOLS' "$SETUP_SH" || true)"

finish
