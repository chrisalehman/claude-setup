#!/bin/bash
# tests/commands.test.sh — /bionic:version, driven through its own rendered command body
# (epic-22 wave-01 slice 14, spec AC-E2.1).
#
# WHAT THIS SUITE OWNS. `payload/commands/version.md` is a GENERATED file (agents-src/
# render.sh) whose body is one line of markdown naming a script: `bash ${CLAUDE_PLUGIN_ROOT}/
# scripts/version.sh`. This suite extracts that command literally out of the rendered file's
# first ```bash fence — never a hand-retyped invocation that could drift from what the file
# actually says — and runs it with CLAUDE_PLUGIN_ROOT pointed at a payload directory, so a
# future edit to the command body is exercised as written rather than as remembered.
#
# HERMETIC. HOME/BIONIC_CLAUDE_HOME are fresh mktemp trees carrying only the two registry
# files detect.sh's marketplace facts read (`known_marketplaces.json`, `installed_plugins.
# json`); CLAUDE_PLUGIN_ROOT points at this repo's own payload/. Nothing on the real machine
# is read.
#
# Usage: bash tests/commands.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
VERSION_MD="${PAYLOAD}/commands/version.md"
VERSION_TMPL="${REPO}/agents-src/templates/commands/version.md.tmpl"
VOICE_BLOCK="${REPO}/agents-src/blocks/voice-contract.md"

command -v jq >/dev/null 2>&1 || { echo "commands.test.sh: jq is required"; exit 1; }

expect_true "0: payload/commands/version.md exists (rendered)" test -f "$VERSION_MD"
expect_true "0b: agents-src/templates/commands/version.md.tmpl exists (its source)" \
  test -f "$VERSION_TMPL"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── The command literal, extracted from the rendered file itself ────────────
#
# The FIRST ```bash fence, never the second (untagged) fence a few lines further down that
# only illustrates the printed line's shape — language-tagging is what tells them apart.
extract_bash_fence() {  # <file> -> the body of its first ```bash ... ``` block
  awk '
    /^```bash$/ { inb = 1; next }
    inb && /^```$/ { exit }
    inb { print }
  ' "$1"
}

VERSION_CMD="$(extract_bash_fence "$VERSION_MD")"
expect_contains "1: the extracted command invokes version.sh rooted at CLAUDE_PLUGIN_ROOT" \
  '${CLAUDE_PLUGIN_ROOT}/scripts/version.sh' "$VERSION_CMD"

# The extraction has to run something — a fence-matching bug that found nothing would leave
# every arm below executing an empty string and passing for the wrong reason.
expect_nonempty "2: the extracted command is non-empty" "$VERSION_CMD"

# ── Fixture builders (same shape as tests/doctor-version.test.sh) ───────────

make_registry_home() {  # -> claude-home dir on stdout
  local dir
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/plugins"
  printf '%s' "$dir"
}

write_known_marketplaces_dir() {  # <claude-home> <source-path>
  jq -nc --arg path "$2" \
    '{bionic:{source:{source:"directory", path:$path}, installLocation:"/nonexistent-cache", lastUpdated:"2026-08-27T00:00:00Z"}}' \
    > "$1/plugins/known_marketplaces.json"
}

write_empty_known_marketplaces() {  # <claude-home> — no bionic entry at all
  printf '{}' > "$1/plugins/known_marketplaces.json"
}

write_installed_plugins() {  # <claude-home> <installPath>
  jq -nc --arg path "$2" \
    '{plugins:{"bionic@bionic":[{installPath:$path}]}}' \
    > "$1/plugins/installed_plugins.json"
}

# run_version_cmd <claude-home> -> stdout+stderr of the EXTRACTED command, run exactly as
# the rendered file spells it (CLAUDE_PLUGIN_ROOT substituted the same way the CLI
# substitutes it for a real slash command).
run_version_cmd() {
  ( cd "$REPO" && HOME="$TMP" BIONIC_CLAUDE_HOME="$1" CLAUDE_PLUGIN_ROOT="$PAYLOAD" \
      bash -c "$VERSION_CMD" < /dev/null 2>&1 )
}

FORMAT_RE='^bionic [0-9][0-9.]* \(installed\) · .+ · .+ · (this checkout|OTHER checkout|unregistered)$'

# One-line-and-nothing-else, measured the same way every arm below measures it: the output
# has exactly one line, and that line matches FORMAT_RE end to end.
assert_one_line_matching() {  # <label> <output>
  local label="$1" out="$2" n
  n="$(printf '%s\n' "$out" | grep -c .)"
  if [ "$n" != "1" ]; then
    no "$label" "expected exactly one line, got ${n}: ${out}"
    return
  fi
  if [[ "$out" =~ $FORMAT_RE ]]; then
    ok "$label"
  else
    no "$label" "line does not match the format: ${out}"
  fi
}

section "Section 1: this checkout — a directory-feed registry naming THIS tree"

HOME_THIS="$(make_registry_home)"
write_known_marketplaces_dir "$HOME_THIS" "$REPO"
write_installed_plugins "$HOME_THIS" "$PAYLOAD"
OUT_THIS="$(run_version_cmd "$HOME_THIS")"

assert_one_line_matching "3: prints exactly one line matching the format" "$OUT_THIS"
expect_match "4: says 'this checkout' when the registry names the tree under test" \
  "*this checkout" "$OUT_THIS"

section "Section 2: OTHER checkout — a directory-feed registry naming a different tree"

OTHER_TREE="$(mktemp -d -p "$TMP")"
HOME_OTHER="$(make_registry_home)"
write_known_marketplaces_dir "$HOME_OTHER" "$OTHER_TREE"
write_installed_plugins "$HOME_OTHER" "$PAYLOAD"
OUT_OTHER="$(run_version_cmd "$HOME_OTHER")"

assert_one_line_matching "5: prints exactly one line matching the format" "$OUT_OTHER"
expect_match "6: says 'OTHER checkout' when the registry names a different tree" \
  "*OTHER checkout" "$OUT_OTHER"

section "Section 3: unregistered — no marketplace entry names a source at all"

HOME_UNREG="$(make_registry_home)"
write_empty_known_marketplaces "$HOME_UNREG"
OUT_UNREG="$(run_version_cmd "$HOME_UNREG")"

assert_one_line_matching "7: prints exactly one line matching the format" "$OUT_UNREG"
expect_match "8: says 'unregistered' when no registration names a source" \
  "*unregistered" "$OUT_UNREG"

section "Section 4: the voice contract — same presentation demand as the other commands"

VOICE_TEXT="$(cat "$VOICE_BLOCK")"
VERSION_MD_TEXT="$(cat "$VERSION_MD")"
expect_contains "9: rendered version.md carries the fenced-block demand" \
  "fenced code block" "$VERSION_MD_TEXT"
expect_contains "10: …and the shared voice-contract block really is the source of it" \
  "fenced code block" "$VOICE_TEXT"

section "Section 5: render.sh --check agrees this file is not stale"

expect_true "11: agents-src/render.sh --check reports every rendered final clean" \
  bash "${REPO}/agents-src/render.sh" --check

finish
