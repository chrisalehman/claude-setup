#!/bin/bash
# tests/command-relay.test.sh — the command-relay contract (F4, epic-19 wave-01,
# spec AC-F4; grounding record/epic-19/step1-fixes-grounding.md §4).
#
# WHAT THIS SUITE OWNS. Two malformation sources named at grounding §4, both
# under the AC-F4 umbrella of "/bionic:setup and /bionic:doctor render faithfully
# in the command relay":
#
#   (b) THE CONTRACT TEXT. `agents-src/blocks/voice-contract.md` used to say
#       "in one block" — a phrase a relaying agent can satisfy with plain
#       markdown prose, which collapses the scripts' leading whitespace and
#       destroys the column alignment `item()`/`_doctor_cell` exist to produce.
#       Group A pins the demand for a FENCED code block in the shared block and
#       in every rendered command file it reaches, plus the render/manifest
#       agreement (a stale rendering would be a second, silent way this
#       contract could drift from what ships).
#
#   (a) NO WIDTH TRUNCATION. setup.sh's `item()` third field and the `--all`
#       plan's verb lines interpolate absolute paths (settings.json, a shell
#       rc, the legacy skill directory) with no bound. Group B drives the real
#       script — EXECUTED, NOT SOURCED, the same convention
#       tests/doctor-patrol.test.sh states, because setup.sh carries no
#       sourcing guard and runs its whole nine-step pass the moment it is
#       loaded — against fixtures built with `BIONIC_SETTINGS_FILE` /
#       `BIONIC_SHELL_RC` pointing at deliberately long paths, and asserts no
#       printed line exceeds the same 100-column budget doctor.sh already
#       holds itself to (spec AC-15, doctor.sh:179).
#
# EVERY NEGATIVE IS BESIDE A POSITIVE ON THE SAME EXTRACTOR (no-vacuous-tests
# rule): each long-path arm has a short-path twin proving the helper leaves an
# ordinary path untouched, so a truncator that fired unconditionally — or one
# that fired never — would both be caught.
#
# HERMETIC. PATH excludes every directory this machine's real `claude`/`brew`/
# `npm`/`uv`/`pnpm`/`gh`/`node` binaries live in (`/usr/bin:/bin` only, which
# still carries `jq` and `git` on macOS) — `bionic_cli_plugin_state` and `check_dep`
# both degrade to `unknown`/`no` without a network call or a hang when their
# mechanism's binary is absent (verified at lib/checks.sh's own `bionic_cli_plugin_state`,
# which was setup.sh's `_setup_cli_plugin` until 1.5.1 moved it beside the rows
# that read it:
# `command -v claude >/dev/null 2>&1 || { echo "unknown|"; return 0; }`). HOME
# is a fresh mktemp tree; nothing here reads or writes the real machine.
#
# Usage: bash tests/command-relay.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
SETUP_SH="${PAYLOAD}/scripts/setup.sh"
VOICE_BLOCK="${REPO}/agents-src/blocks/voice-contract.md"
SETUP_MD="${PAYLOAD}/commands/setup.md"
DOCTOR_MD="${PAYLOAD}/commands/doctor.md"
RENDER_SH="${REPO}/agents-src/render.sh"
WIDTH_SH="${PAYLOAD}/scripts/lib/width.sh"

# The column budget and its ruler, sourced from the product rather than
# restated: this suite asserts against `BIONIC_LINE_WIDTH`, so a change to the
# budget moves the assertion with it and can never leave the two disagreeing.
# shellcheck source=/dev/null
. "$WIDTH_SH"

command -v jq >/dev/null 2>&1 || { echo "command-relay.test.sh: jq is required"; exit 1; }

# All-lines-fit is the AC-15 assertion, restated for setup.sh's own output: no
# line printed may exceed the column budget.
#
# MEASURED IN COLUMNS, THROUGH THE PRODUCT'S OWN COUNTER. The budget is a column
# count — a terminal lays out columns — and the glyphs this report prints are
# three bytes each for one column, so a byte ruler condemns a line that fits and
# was what this helper used before S9. `bionic_cols` (lib/width.sh) is the one
# owner of that measurement, and a test measuring one way while the script
# truncates another is a wall with a gap in it. Using the implementation's own
# ruler cannot catch a bug IN the ruler, so the ruler is pinned directly below.
expect_all_lines_fit() {  # <label> <max-width> <text>
  local label="$1" max="$2" text="$3" longest=0 n
  while IFS= read -r line || [ -n "$line" ]; do
    n="$(bionic_cols "$line")"
    [ "$n" -gt "$longest" ] && longest="$n"
  done <<< "$text"
  if [ "$longest" -le "$max" ]; then ok "$label"; else no "$label" "longest line is ${longest} columns (budget ${max})"; fi
}

# AN EXPLICIT /tmp TEMPLATE, short side only. macOS's `mktemp -d` ignores
# TMPDIR and always roots under /var/folders/.../T — itself 50-60 columns
# before a single fixture byte is added — which would make the SHORT arms
# below false positives for "this path never needed eliding": they would need
# eliding for reasons that have nothing to do with this suite. An explicit
# template forces the short base; it is still a fresh, unique directory per
# run, so isolation is unaffected.
TMP="$(mktemp -d "/tmp/cr.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Group A — the relay contract demands a fenced code block
# ═══════════════════════════════════════════════════════════════════════════

VOICE_TEXT="$(cat "$VOICE_BLOCK")"
expect_contains  "A1: voice-contract.md demands a fenced code block"       "fenced code block" "$VOICE_TEXT"
expect_absent "A2: voice-contract.md no longer says the bare 'in one block'" ", in one block," "$VOICE_TEXT"

SETUP_MD_TEXT="$(cat "$SETUP_MD")"
DOCTOR_MD_TEXT="$(cat "$DOCTOR_MD")"
expect_contains "A3: rendered setup.md carries the fenced-block demand"  "fenced code block" "$SETUP_MD_TEXT"
expect_contains "A4: rendered doctor.md carries the fenced-block demand" "fenced code block" "$DOCTOR_MD_TEXT"

expect_true "A5: render.sh --check finds no drift (templates, finals and manifest agree)" \
  bash "$RENDER_SH" --check

# ═══════════════════════════════════════════════════════════════════════════
# Group B0 — the ruler and the truncator themselves (lib/width.sh)
# ═══════════════════════════════════════════════════════════════════════════
#
# EVERY ASSERTION IN GROUP B IS MEASURED WITH `bionic_cols`, so a ruler that
# always answered 0 would pass every all-lines-fit arm below with nothing under
# it. These four pin the ruler and its truncator directly, each negative beside
# the positive it means nothing without.

ASCII_S='abcdefghij'                       # 10 bytes, 10 columns
GLYPH_S='✓ ✗ – — ≥ … ·'                    # 7 glyphs (six 3-byte, · is 2) + 6 spaces
expect_eq "B0a: bionic_cols counts a plain ASCII string as its length" \
  "10" "$(bionic_cols "$ASCII_S")"
expect_eq "B0b: bionic_cols counts each 3-byte glyph as one column" \
  "13" "$(bionic_cols "$GLYPH_S")"
# `wc -c`, not `${#GLYPH_S}`: bash's length is CHARACTERS under a UTF-8 locale
# and bytes under C, and this arm is only worth anything if it is bytes. The
# 26-vs-13 gap is the whole reason a byte ruler cannot wall this report.
expect_eq "B0c: and that is fewer columns than the string has bytes" \
  "26" "$(printf '%s' "$GLYPH_S" | wc -c | tr -d ' ')"

expect_eq "B0d: bionic_trunc leaves a string inside the budget untouched" \
  "$ASCII_S" "$(bionic_trunc "$ASCII_S" 20)"
expect_eq "B0e: bionic_trunc elides a string past the budget, to the budget" \
  "abcd…" "$(bionic_trunc "$ASCII_S" 5)"
expect_eq "B0f: an elided string measures exactly its budget in columns" \
  "5" "$(bionic_cols "$(bionic_trunc "$ASCII_S" 5)")"

expect_eq "B0g: the budget setup and doctor share is 100 columns" \
  "100" "$BIONIC_LINE_WIDTH"

# ═══════════════════════════════════════════════════════════════════════════
# Group B — width truncation on setup's free-form fields
# ═══════════════════════════════════════════════════════════════════════════

# A curated PATH: real jq/git/bash/coreutils, no claude/brew/npm/uv/pnpm/gh/node
# (all of which live under /opt/homebrew/bin on the authoring machine) — see
# the file header for why this keeps bionic_cli_plugin_state/check_dep fast and
# network-free rather than needing a shim binary for each.
BIN_PATH="/usr/bin:/bin"

# One very long absolute path (>150 columns on its own) — long enough that any
# item() line or plan verb line carrying it whole would blow well past 100
# columns, however the fixed prefix around it is padded.
LONGSEG="$(printf 'segment-%.0s' $(seq 1 20))"

# <extra-env-assignment>... -- <setup.sh args...> — the `--` is this function's
# own sentinel (handled below, in-process) and is never seen by `env` itself,
# which cannot tell an assignment from an argument once both are in one list.
run_setup() {
  local envs=() args=() past_dash=0 a
  for a in "$@"; do
    if [ "$past_dash" = "0" ] && [ "$a" = "--" ]; then past_dash=1; continue; fi
    if [ "$past_dash" = "0" ]; then envs+=("$a"); else args+=("$a"); fi
  done
  env -i PATH="$BIN_PATH" HOME="$TMP/home" \
    BIONIC_PLUGIN_ROOT="$PAYLOAD" CLAUDE_PLUGIN_ROOT="$PAYLOAD" \
    "${envs[@]}" bash "$SETUP_SH" "${args[@]}" < /dev/null 2>&1
}

mkdir -p "$TMP/home"

# ── B1/B2: item()'s third field — the "environment" idempotence guard ───────
# Fixture content matches env.sh's ENV_KEYS exactly, so the guard at
# setup.sh's `[ -n "$missing" ] ||` fires with no consent needed.
write_env_fixture() {  # <settings-file>
  mkdir -p "$(dirname "$1")"
  jq -n '{env: {CLAUDE_CODE_ENABLE_TODO_TOOLS: "1", BASH_MAX_TIMEOUT_MS: "1800000", CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"}}' \
    > "$1"
}

SHORT_SETTINGS="$TMP/s.json"
write_env_fixture "$SHORT_SETTINGS"
SHORT_OUT="$(run_setup BIONIC_SETTINGS_FILE="$SHORT_SETTINGS" -- --only environment)"
expect_all_lines_fit "B1: --only environment, short path — every line fits 100 columns" "$BIONIC_LINE_WIDTH" "$SHORT_OUT"
expect_contains      "B2: --only environment, short path — full path shown, untouched" "$SHORT_SETTINGS" "$SHORT_OUT"
expect_absent  "B3: --only environment, short path — nothing needed eliding" "…" "$SHORT_OUT"

LONG_SETTINGS="$TMP/${LONGSEG}/${LONGSEG}/${LONGSEG}/settings.json"
write_env_fixture "$LONG_SETTINGS"
LONG_OUT="$(run_setup BIONIC_SETTINGS_FILE="$LONG_SETTINGS" -- --only environment)"
expect_all_lines_fit "B4: --only environment, long path — every line still fits 100 columns" "$BIONIC_LINE_WIDTH" "$LONG_OUT"
expect_contains      "B5: --only environment, long path — the field was elided" "…" "$LONG_OUT"
expect_absent  "B6: --only environment, long path — the untruncated path is gone" "$LONG_SETTINGS" "$LONG_OUT"

# ── B7/B8: item()'s third field — the "claude-proxy" idempotence guard ──────
write_rc_fixture() {  # <rc-file>
  mkdir -p "$(dirname "$1")"
  {
    echo '# ─── bionic:rc:start ───'
    echo 'claude() { command claude --allow-dangerously-skip-permissions "$@"; }'
    echo '# ─── bionic:rc:end ───'
  } > "$1"
}

SHORT_RC="$TMP/r.zshrc"
write_rc_fixture "$SHORT_RC"
SHORT_RC_OUT="$(run_setup BIONIC_SHELL_RC="$SHORT_RC" -- --only claude-proxy)"
expect_all_lines_fit "B7: --only claude-proxy, short rc path — every line fits 100 columns" "$BIONIC_LINE_WIDTH" "$SHORT_RC_OUT"
expect_contains      "B8: --only claude-proxy, short rc path — full path shown, untouched" "$SHORT_RC" "$SHORT_RC_OUT"

LONG_RC="$TMP/${LONGSEG}/${LONGSEG}/${LONGSEG}/dot.zshrc"
write_rc_fixture "$LONG_RC"
LONG_RC_OUT="$(run_setup BIONIC_SHELL_RC="$LONG_RC" -- --only claude-proxy)"
expect_all_lines_fit "B9: --only claude-proxy, long rc path — every line still fits 100 columns" "$BIONIC_LINE_WIDTH" "$LONG_RC_OUT"
expect_contains      "B10: --only claude-proxy, long rc path — the field was elided" "…" "$LONG_RC_OUT"
expect_absent  "B11: --only claude-proxy, long rc path — the untruncated path is gone" "$LONG_RC" "$LONG_RC_OUT"

# ── B12: the --all plan's verb lines carry the same bound ───────────────────
# Neither settings.json nor the rc exist yet, so both items are genuinely
# pending and _setup_item_verb's path-carrying lines land on the printed plan
# (stdin closed → the trailing consent answers "not asked" and exits 0 with
# the plan already on screen — no mutation happens).
ALL_OUT="$(run_setup BIONIC_SETTINGS_FILE="$TMP/${LONGSEG}/${LONGSEG}/settings.json" \
                     BIONIC_SHELL_RC="$TMP/${LONGSEG}/${LONGSEG}/dot.zshrc" \
                     -- --all)"
expect_contains      "B13: --all plan reaches the environment/claude-proxy verb lines" "bionic would:" "$ALL_OUT"
expect_all_lines_fit "B14: --all plan, long paths pending — every line fits 100 columns" "$BIONIC_LINE_WIDTH" "$ALL_OUT"

# ═══════════════════════════════════════════════════════════════════════════
# Group C — the cut is a CHARACTER cut, under the locale the product runs in
# ═══════════════════════════════════════════════════════════════════════════
#
# WHAT THIS GROUP EXISTS TO CATCH, and why nothing above it could. Group B runs
# setup under `env -i` with no LANG — the C locale, where bash's `${#s}` counts
# BYTES. The predecessor truncator tested length one way and cut the other
# (`${#s}` characters, `printf '%.*s'` bytes); under C those two units are the
# same and the bug is invisible, while under the UTF-8 locale a real user's
# shell exports it slices a multi-byte glyph in half and emits invalid UTF-8.
# Same code, same input, two locales, two answers: the hermetic fixture was
# exercising a different code path than the one that ships (Step-6 critic C-1,
# reproduced on 3 of 5 cut offsets).
#
# SO THIS GROUP SETS THE LOCALE and walks the cut across successive offsets.
# One offset could pass by luck — a cut landing on a character boundary is
# valid whatever the unit — so the loop moves the boundary one column at a time
# through a run of accented characters, which is what makes a byte cut fail on
# two of every three.
#
# `iconv -f UTF-8 -t UTF-8` IS THE ORACLE: it succeeds only if its input is
# well-formed UTF-8. Nothing bash can measure about a string tells you whether
# it ends mid-sequence.

# Bash `case` over the locale list, not `grep`: the assertion-helper race rule
# forbids `producer | grep -q` here, and the shell grep on this machine is ugrep,
# which answers differently enough to have cost a false negative already.
have_utf8_locale() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in en_US.UTF-8|en_US.utf8) return 0 ;; esac
  done <<< "$(locale -a 2>/dev/null)"
  return 1
}

if ! command -v iconv >/dev/null 2>&1; then
  no "C: iconv is required to validate encoding and is not on PATH"
elif ! have_utf8_locale; then
  no "C: an en_US.UTF-8 locale is required and this machine has none"
else
  # A run of 3-byte characters long enough to be crossed by the cut, behind a
  # pad whose length moves the cut through it one column per iteration.
  UTF8_ACC="$(printf 'é%.0s' $(seq 1 40))"
  UTF8_BAD=0; UTF8_ELIDED=0; UTF8_N=0
  for _pad_n in 0 1 2 3 4 5; do
    UTF8_PAD="$(printf 'x%.0s' $(seq 1 $((20 + _pad_n))))"
    UTF8_DIR="${TMP}/u${_pad_n}/${UTF8_PAD}${UTF8_ACC}"
    mkdir -p "$UTF8_DIR"
    UTF8_SETTINGS="${UTF8_DIR}/s.json"
    write_env_fixture "$UTF8_SETTINGS"
    UTF8_OUT="$(run_setup LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
                          BIONIC_SETTINGS_FILE="$UTF8_SETTINGS" -- --only environment)"
    UTF8_N=$((UTF8_N + 1))
    printf '%s' "$UTF8_OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || UTF8_BAD=$((UTF8_BAD + 1))
    case "$UTF8_OUT" in *…*) UTF8_ELIDED=$((UTF8_ELIDED + 1)) ;; esac
  done

  # THE POSITIVE THE ENCODING ARM MEANS NOTHING WITHOUT: every one of these
  # runs actually reached the truncator. A fixture short enough to print whole
  # would pass the iconv check without the cut ever happening.
  expect_eq "C1: every UTF-8 offset drove a line that needed eliding" \
    "$UTF8_N" "$UTF8_ELIDED"
  expect_eq "C2: and every one of them is well-formed UTF-8" "0" "$UTF8_BAD"

  # The cut is a cut, not a pass-through: the untruncated path is gone and the
  # budget still holds under a locale where a glyph is one column, not three.
  expect_absent "C3: the untruncated accented path is gone" "$UTF8_DIR" "$UTF8_OUT"
  expect_all_lines_fit "C4: and every line still fits the budget under UTF-8" \
    "$BIONIC_LINE_WIDTH" "$UTF8_OUT"
fi

finish
