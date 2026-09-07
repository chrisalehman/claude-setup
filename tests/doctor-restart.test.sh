#!/bin/bash
# tests/doctor-restart.test.sh — doctor.sh's "restart needed" row (bionic 1.4.0
# fold-in, spec AC-37, plan slice DOCTOR-RESTART; ratified 2026-09-03 "Add
# them. Folding them in is cheap and the case is good.", the dead-wall
# incident recorded in the plan's Assumptions as "SESSION b1a850c1 FINDING
# (2026-09-03T02:06Z)").
#
# THE CONTRACT UNDER TEST. The CLI snapshots hooks.json once, at process
# start; a hook file edited on disk afterward registers nothing in a process
# already running — every wall named in that snapshot stays inert until the
# process exits and a new one starts. Doctor's row: for each live CLI session
# (patrol_live_sessions — kill -0 proven) whose cwd is THIS project's root,
# compare its startedAt against the mtime of hooks.json in the plugin tree the
# CLI loads — the SAME tree the version row already resolves
# (DOCTOR_INSTALL_PATH, DOCTOR/5 in the plan's Assumptions), never re-derived.
# A session started before that file's last change is running a stale
# registration: one `✗ restart needed` row naming the pid and both times (UTC,
# short), plus a FIX line telling the operator to exit and restart. A session
# started after the file's last change, no session file for this cwd, or a
# session file naming a DIFFERENT cwd — all silent (format rule: a healthy
# state prints nothing new).
#
# HERMETIC, SAME POSTURE AS doctor-fleet.test.sh. Doctor runs with its cwd
# inside a fixture project holding its own .bionic/, so project_root answers
# the fixture and nothing reads this checkout's real state. The "live"
# session names this test's own pid ($$), alive by construction. The plugin
# tree is a SEPARATE fixture git repository named by a fixture
# plugins/installed_plugins.json registry entry — never this checkout's own
# hooks.json, whose real mtime this suite must not depend on or perturb.
#
# PHYSICAL PATHS. project_root canonicalises through `pwd -P` (lib/root.sh);
# on macOS /tmp is a symlink to /private/tmp, so a session's `cwd` field must
# be the CANONICAL path or the cwd-match this row performs never fires — the
# same rule lib/patrol.sh states for its own `_patrol_real`. PROJ_REAL below
# is the physical path; the raw mktemp path is never compared against.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below (tests/
# assert-helper-race.test.sh): containment is bash `[[ == * ]]` in-process.
#
# Usage: bash tests/doctor-restart.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
DOCTOR_SH="${PAYLOAD}/scripts/doctor.sh"

command -v jq >/dev/null 2>&1 || { echo "doctor-restart.test.sh: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "doctor-restart.test.sh: git is required"; exit 1; }

TMP="$(mktemp -d /tmp/bionic-doctor-restart.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CHOME="${TMP}/claude-home"
mkdir -p "${CHOME}/plugins" "${CHOME}/sessions"
PROJ="${TMP}/proj"
mkdir -p "${PROJ}/.bionic/tmp"
PROJ_REAL="$(cd "$PROJ" && pwd -P)"
FIXTURE_RC="${TMP}/dot.zshrc"
: > "$FIXTURE_RC"

LIVE_PID=$$

# ---------- fixture builders ----------

# A minimal git repository standing in for "the plugin tree the CLI loads" —
# never this checkout's own hooks.json. doctor.sh's DOCTOR_INSTALL_PATH
# resolution (`_doctor_is_repo`) requires a real repository; `git init` with
# no commit already satisfies `git rev-parse --git-dir`.
make_plugin_tree() {  # -> dir on stdout
  local dir
  dir="$(mktemp -d -p "$TMP")"
  git init -q "$dir" >/dev/null 2>&1
  mkdir -p "$dir/hooks"
  printf '{}' > "$dir/hooks/hooks.json"
  printf '%s' "$dir"
}

# Backdate hooks.json to an exact epoch second. `touch -t` reads its spec in
# LOCAL time, so the spec is generated with `date -r` (also local) rather than
# `date -u -r` — the two cancel regardless of the machine's timezone.
set_hooks_mtime() {  # <plugin-tree> <epoch-seconds>
  touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1/hooks/hooks.json"
}

write_installed_plugins() {  # <claude-home> <installPath>
  jq -nc --arg path "$2" '{plugins:{"bionic@bionic":[{installPath:$path}]}}' \
    > "$1/plugins/installed_plugins.json"
}

# The real CLI's own session shape, named by pid — doctor.sh reads
# `<claude-home>/sessions/<pid>.json` directly for `startedAt`, the one field
# patrol_live_sessions' own formatted line does not carry.
write_session() {  # <pid> <cwd> <startedAt-ms>
  jq -nc --arg cwd "$2" --argjson pid "$1" --argjson started "$3" \
    '{pid:$pid, sessionId:("fixture-" + ($pid|tostring)), cwd:$cwd, startedAt:$started, status:"busy"}' \
    > "${CHOME}/sessions/$1.json"
}

run_doctor() {
  ( cd "$PROJ" && HOME="$TMP" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
      BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

# Two fixed epochs an hour apart, so "older"/"newer" is unambiguous and the
# suite's own clock never enters the comparison.
HOOKS_MTIME=1788003600     # 2026-08-27T15:00:00 local
BEFORE_MS=1788000000000    # an hour earlier
AFTER_MS=1788007200000     # an hour later

section "Section 1: session older than hooks.json — restart needed"

TREE1="$(make_plugin_tree)"
set_hooks_mtime "$TREE1" "$HOOKS_MTIME"
write_installed_plugins "$CHOME" "$TREE1"
write_session "$LIVE_PID" "$PROJ_REAL" "$BEFORE_MS"

OUT1="$(run_doctor)"

expect_match "1: the row fires" "*✗ restart needed*" "$OUT1"
expect_match "2: it names the pid" "*restart needed*${LIVE_PID}*" "$OUT1"
expect_match "3: a fix line tells the operator to exit and restart" \
  "*exit claude and start it again*" "$OUT1"
expect_match "4: the fix line cites what the process registered" \
  "*registered hooks.json as it was at*" "$OUT1"

section "Section 2: session newer than hooks.json — silent"

rm -f "${CHOME}/sessions/${LIVE_PID}.json"
TREE2="$(make_plugin_tree)"
set_hooks_mtime "$TREE2" "$HOOKS_MTIME"
write_installed_plugins "$CHOME" "$TREE2"
write_session "$LIVE_PID" "$PROJ_REAL" "$AFTER_MS"

OUT2="$(run_doctor)"

expect_no_match "5: no restart-needed row" "*restart needed*" "$OUT2"
expect_no_match "6: no matching fix line" "*exit claude and start it again*" "$OUT2"

section "Section 3: no session file for this cwd — silent"

rm -f "${CHOME}/sessions/${LIVE_PID}.json"
TREE3="$(make_plugin_tree)"
set_hooks_mtime "$TREE3" "$HOOKS_MTIME"
write_installed_plugins "$CHOME" "$TREE3"
# No sessions/*.json at all.

OUT3="$(run_doctor)"

expect_no_match "7: no restart-needed row with no session file" "*restart needed*" "$OUT3"

section "Section 4: a session file for ANOTHER cwd is ignored"

TREE4="$(make_plugin_tree)"
set_hooks_mtime "$TREE4" "$HOOKS_MTIME"
write_installed_plugins "$CHOME" "$TREE4"
ELSEWHERE="${TMP}/elsewhere"
mkdir -p "$ELSEWHERE"
ELSEWHERE_REAL="$(cd "$ELSEWHERE" && pwd -P)"
# Times that WOULD fire the row if the cwd filter did not apply first.
write_session "$LIVE_PID" "$ELSEWHERE_REAL" "$BEFORE_MS"

OUT4="$(run_doctor)"

expect_no_match "8: a session naming a different cwd is not this project's row" \
  "*restart needed*" "$OUT4"

finish
