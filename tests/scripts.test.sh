#!/bin/bash
# Tests for claude-bootstrap.sh and claude-reset.sh shared logic.
# Covers config parsing, config file well-formedness, script symmetry,
# hook consistency, and shell alias marker consistency.
# Does NOT run bootstrap or reset — no side effects.
#
# Usage: bash tests/scripts.test.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${REPO}/claude-config.txt"
BOOTSTRAP="${REPO}/claude-bootstrap.sh"
RESET="${REPO}/claude-reset.sh"

PASS=0
FAIL=0
TOTAL=0

# ---------- helpers ----------

expect_true() {
  local label="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

expect_false() {
  local label="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "FAIL (expected false): $label"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"
    PASS=$((PASS + 1))
  fi
}

expect_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

expect_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

# ---------- setup: define read_config pointing at $_temp_config ----------
#
# Identical to the function in both scripts. We keep it here so tests can
# run it against a temp file without sourcing the full scripts (side effects).

# _cfg_file: path to the config file that read_config operates against.
# Set to a tmpfile for Section 1 parsing tests; set to $CONFIG for real-config tests.
# The EXIT trap only cleans up $S1_TMPFILE (created here for Section 1).
_cfg_file=""
S1_TMPFILE="$(mktemp)"

read_config() {
  local type="$1" callback="$2"
  while IFS='|' read -r entry_type f1 f2 f3; do
    entry_type="$(echo "$entry_type" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$entry_type" = "$type" ] || continue
    f1="$(echo "$f1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    f2="$(echo "${f2:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    f3="$(echo "${f3:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    "$callback" "$f1" "$f2" "$f3"
  done < <(grep -v '^\s*#' "$_cfg_file" | grep -v '^\s*$')
}

cleanup() {
  rm -f "$S1_TMPFILE"
}
trap cleanup EXIT

# ============================================================
# SECTION 1: Config file parsing (read_config)
# ============================================================

echo ""
echo "=== Section 1: Config file parsing (read_config) ==="

_cfg_file="$S1_TMPFILE"
cat > "$_cfg_file" << 'EOF'
# This is a comment — must be skipped
brew-dep     | git
brew-dep     | rg            | ripgrep
npm-global   | @playwright/cli
npm-global   | @sentry/cli
mcp-server   | context7      | @upstash/context7-mcp@latest
mcp-server   | trello        | @delorenj/mcp-server-trello | TRELLO_API_KEY,TRELLO_TOKEN
mcp-server   | sentry        | @sentry/mcp-server@latest   | SENTRY_ACCESS_TOKEN

   # Indented comment — must be skipped

local-skill  | rigorous-refactor
env-var      | CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS | 1
statusline   | npx ccstatusline@latest
plugin       | superpowers         | claude-plugins-official
global-memory | claude-global.md
uv-tool      | notebooklm-py       | notebooklm
EOF

# 1a: Basic two-field entry (git) parses correctly
_found_git=0
_found_git_f2="nonempty"
_check_git() {
  if [ "$1" = "git" ]; then
    _found_git=1
    _found_git_f2="$2"
  fi
}
read_config "brew-dep" _check_git
expect_eq "brew-dep two-field: git entry found" "1" "$_found_git"
expect_eq "brew-dep two-field: git f2 is empty" "" "$_found_git_f2"

# 1b: Three-field brew-dep entry (binary != package)
_found_rg_pkg=""
_check_rg() {
  if [ "$1" = "rg" ]; then
    _found_rg_pkg="$2"
  fi
}
read_config "brew-dep" _check_rg
expect_eq "brew-dep three-field: rg maps to ripgrep" "ripgrep" "$_found_rg_pkg"

# 1c: npm-global entry parses correctly (@playwright/cli)
_found_playwright=0
_check_playwright() {
  if [ "$1" = "@playwright/cli" ]; then
    _found_playwright=1
  fi
}
read_config "npm-global" _check_playwright
expect_eq "npm-global: @playwright/cli entry found" "1" "$_found_playwright"

# 1d: mcp-server two-field entry (name + package, no env vars)
_ctx7_pkg=""
_check_ctx7() {
  if [ "$1" = "context7" ]; then
    _ctx7_pkg="$2"
  fi
}
read_config "mcp-server" _check_ctx7
expect_eq "mcp-server two-field: context7 pkg correct" "@upstash/context7-mcp@latest" "$_ctx7_pkg"

# 1e: mcp-server three-field entry (name + package + env vars)
_trello_env=""
_check_trello() {
  if [ "$1" = "trello" ]; then
    _trello_env="$3"
  fi
}
read_config "mcp-server" _check_trello
expect_eq "mcp-server three-field: trello env vars parsed" "TRELLO_API_KEY,TRELLO_TOKEN" "$_trello_env"

# 1f: Commented lines are skipped — type '#' should produce zero callbacks
_comment_count=0
_count_entries() { _comment_count=$((_comment_count + 1)); }
read_config "#" _count_entries
expect_eq "commented lines produce no callbacks" "0" "$_comment_count"

# 1g: Blank lines are skipped — exactly 2 brew-dep entries in test config
_brew_count=0
_count_brew() { _brew_count=$((_brew_count + 1)); }
read_config "brew-dep" _count_brew
expect_eq "blank lines skipped: exactly 2 brew-dep entries" "2" "$_brew_count"

# 1h: Fields are trimmed of leading/trailing whitespace
_local_skill_name=""
_check_local_skill() { _local_skill_name="$1"; }
read_config "local-skill" _check_local_skill
expect_eq "local-skill: name whitespace-trimmed" "rigorous-refactor" "$_local_skill_name"

# 1i: env-var two-field entry (key and value both trimmed)
_env_key="" _env_val=""
_check_env() { _env_key="$1"; _env_val="$2"; }
read_config "env-var" _check_env
expect_eq "env-var: key trimmed correctly" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "$_env_key"
expect_eq "env-var: value trimmed correctly" "1" "$_env_val"

# 1j: statusline single-field entry
_statusline_cmd=""
_check_statusline() { _statusline_cmd="$1"; }
read_config "statusline" _check_statusline
expect_eq "statusline: command parsed" "npx ccstatusline@latest" "$_statusline_cmd"

# 1k: plugin two-field entry
_plugin_name="" _plugin_src=""
_check_plugin() { _plugin_name="$1"; _plugin_src="$2"; }
read_config "plugin" _check_plugin
expect_eq "plugin: name trimmed" "superpowers" "$_plugin_name"
expect_eq "plugin: source trimmed" "claude-plugins-official" "$_plugin_src"

# 1l: global-memory single-field entry
_gm_file=""
_check_gm() { _gm_file="$1"; }
read_config "global-memory" _check_gm
expect_eq "global-memory: filename parsed" "claude-global.md" "$_gm_file"

# 1m: uv-tool two-field entry (package + binary)
_uv_pkg="" _uv_bin=""
_check_uv() { _uv_pkg="$1"; _uv_bin="$2"; }
read_config "uv-tool" _check_uv
expect_eq "uv-tool: package parsed" "notebooklm-py" "$_uv_pkg"
expect_eq "uv-tool: binary parsed" "notebooklm" "$_uv_bin"

# 1n: Optional f3 field is empty string when not present (not unbound variable)
_ctx7_f3="__unset__"
_check_ctx7_f3() {
  if [ "$1" = "context7" ]; then
    _ctx7_f3="$3"
  fi
}
read_config "mcp-server" _check_ctx7_f3
expect_eq "mcp-server two-field: f3 is empty string (not unset)" "" "$_ctx7_f3"

# 1n: sentry entry has correct env var in f3
_sentry_env=""
_check_sentry() {
  if [ "$1" = "sentry" ]; then
    _sentry_env="$3"
  fi
}
read_config "mcp-server" _check_sentry
expect_eq "mcp-server: sentry f3 has SENTRY_ACCESS_TOKEN" "SENTRY_ACCESS_TOKEN" "$_sentry_env"

# 1o: npm-global sentry-cli entry parses correctly
_found_sentry_cli=0
_check_sentry_cli() {
  if [ "$1" = "@sentry/cli" ]; then
    _found_sentry_cli=1
  fi
}
read_config "npm-global" _check_sentry_cli
expect_eq "npm-global: @sentry/cli entry found" "1" "$_found_sentry_cli"

# 1p: Unknown type yields zero callbacks
_unknown_count=0
_count_unknown() { _unknown_count=$((_unknown_count + 1)); }
read_config "no-such-type" _count_unknown
expect_eq "unknown type yields zero callbacks" "0" "$_unknown_count"

# 1q: mcp-server callback receives all three fields (f1, f2, f3) for three-field entry
_trello_f1="" _trello_f2="" _trello_f3=""
_check_trello_all() {
  if [ "$1" = "trello" ]; then
    _trello_f1="$1"; _trello_f2="$2"; _trello_f3="$3"
  fi
}
read_config "mcp-server" _check_trello_all
expect_eq "mcp-server: trello f1=name" "trello" "$_trello_f1"
expect_eq "mcp-server: trello f2=pkg" "@delorenj/mcp-server-trello" "$_trello_f2"
expect_eq "mcp-server: trello f3=env_vars" "TRELLO_API_KEY,TRELLO_TOKEN" "$_trello_f3"

# ============================================================
# SECTION 2: Config file consistency (claude-config.txt)
# ============================================================

echo ""
echo "=== Section 2: Config file consistency (claude-config.txt) ==="

_cfg_file="$CONFIG"

KNOWN_TYPES="brew-dep npm-global uv-tool mcp-server plugin marketplace github-skill github-skill-pack local-skill local-command global-memory env-var statusline"

# 2a: Every uncommented, non-blank line has at least one pipe delimiter
_bad_lines=""
while IFS= read -r line; do
  stripped="$(echo "$line" | sed 's/^[[:space:]]*//')"
  [ -z "$stripped" ] && continue
  if echo "$stripped" | grep -q '^#'; then
    continue
  fi
  if ! echo "$line" | grep -q '|'; then
    _bad_lines="${_bad_lines}${line}\n"
  fi
done < "$CONFIG"
expect_eq "all uncommented non-blank lines have a pipe delimiter" "" "$_bad_lines"

# 2b: Every type field on uncommented lines is a known type
_unknown_types=""
while IFS='|' read -r entry_type _rest; do
  entry_type="$(echo "$entry_type" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  found=0
  for known in $KNOWN_TYPES; do
    if [ "$entry_type" = "$known" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    _unknown_types="${_unknown_types}${entry_type} "
  fi
done < <(grep -v '^\s*#' "$CONFIG" | grep -v '^\s*$')
expect_eq "all type fields are known types" "" "$_unknown_types"

# 2c: Every local-skill entry has a skills/<name>/SKILL.md file
_missing_skills=""
_check_local_skill_exists() {
  local name="$1"
  if [ ! -f "${REPO}/skills/${name}/SKILL.md" ]; then
    _missing_skills="${_missing_skills}${name} "
  fi
}
read_config "local-skill" _check_local_skill_exists
expect_eq "all local-skill entries have SKILL.md" "" "$_missing_skills"

# 2c-bis: Every local-command entry has a commands/<name>.md file
_missing_commands=""
_check_local_command_exists() {
  local name="$1"
  if [ ! -f "${REPO}/commands/${name}.md" ]; then
    _missing_commands="${_missing_commands}${name} "
  fi
}
read_config "local-command" _check_local_command_exists
expect_eq "all local-command entries have commands/<name>.md" "" "$_missing_commands"

# 2d: Every global-memory file exists in the repo root
_missing_gm=""
_check_gm_exists() {
  local file="$1"
  if [ ! -f "${REPO}/${file}" ]; then
    _missing_gm="${_missing_gm}${file} "
  fi
}
read_config "global-memory" _check_gm_exists
expect_eq "all global-memory files exist in repo" "" "$_missing_gm"

# 2e: MCP server env var lists use valid identifier syntax (UPPER_SNAKE_CASE, comma-separated)
_bad_env_vars=""
_check_mcp_env_format() {
  local name="$1" env_vars="$3"
  [ -z "$env_vars" ] && return 0
  local old_ifs="$IFS"
  IFS=',' read -ra vars <<< "$env_vars"
  IFS="$old_ifs"
  for var in "${vars[@]}"; do
    var="$(echo "$var" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "$var" ] || ! echo "$var" | grep -qE '^[A-Z_][A-Z0-9_]*$'; then
      _bad_env_vars="${_bad_env_vars}${name}:${var} "
    fi
  done
}
read_config "mcp-server" _check_mcp_env_format
expect_eq "MCP env var names are valid UPPER_SNAKE_CASE identifiers" "" "$_bad_env_vars"

# 2f: Config file has at least one brew-dep entry
_brew_total=0
_count_brew_real() { _brew_total=$((_brew_total + 1)); }
read_config "brew-dep" _count_brew_real
expect_true "config has at least one brew-dep entry" [ "$_brew_total" -gt 0 ]

# 2g: Config file has at least one mcp-server entry
_mcp_total=0
_count_mcp_real() { _mcp_total=$((_mcp_total + 1)); }
read_config "mcp-server" _count_mcp_real
expect_true "config has at least one mcp-server entry" [ "$_mcp_total" -gt 0 ]

# 2h: Config file has exactly one statusline entry
_statusline_total=0
_count_statusline() { _statusline_total=$((_statusline_total + 1)); }
read_config "statusline" _count_statusline
expect_eq "config has exactly one statusline entry" "1" "$_statusline_total"

# 2i: Config file has exactly one global-memory entry
_gm_total=0
_count_gm() { _gm_total=$((_gm_total + 1)); }
read_config "global-memory" _count_gm
expect_eq "config has exactly one global-memory entry" "1" "$_gm_total"

# ============================================================
# SECTION 3: Bootstrap/reset script symmetry
# ============================================================

echo ""
echo "=== Section 3: Bootstrap/reset script symmetry ==="

# 3a: Both scripts define read_config
expect_true "bootstrap defines read_config function" grep -q "^read_config()" "$BOOTSTRAP"
expect_true "reset defines read_config function" grep -q "^read_config()" "$RESET"

# 3b: Both scripts derive config path from SCRIPT_DIR
expect_true "bootstrap uses CONFIG variable from SCRIPT_DIR" grep -q 'CONFIG=.*claude-config' "$BOOTSTRAP"
expect_true "reset uses CONFIG variable from SCRIPT_DIR" grep -q 'CONFIG=.*claude-config' "$RESET"

# 3c-3k: Every config type read in bootstrap is also read in reset
for config_type in mcp-server env-var statusline plugin global-memory github-skill local-skill local-command npm-global uv-tool marketplace; do
  expect_true "bootstrap reads type: ${config_type}" grep -q "\"${config_type}\"" "$BOOTSTRAP"
  expect_true "reset reads type: ${config_type}" grep -q "\"${config_type}\"" "$RESET"
done

# 3l: context7 MCP server entry is active (not commented out) in config
_ctx7_found=0
_check_ctx7_config() {
  if [ "$1" = "context7" ]; then
    _ctx7_found=1
  fi
}
read_config "mcp-server" _check_ctx7_config
expect_eq "context7 MCP server entry is active in config" "1" "$_ctx7_found"

# 3m: Any active mcp-server entries with env vars list at least one var
_mcp_with_empty_env=""
_check_mcp_has_env() {
  local name="$1" env_vars="$3"
  # If f3 is non-empty but all whitespace, that's a malformed entry
  if [ -n "$env_vars" ]; then
    local trimmed
    trimmed="$(echo "$env_vars" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "$trimmed" ]; then
      _mcp_with_empty_env="${_mcp_with_empty_env}${name} "
    fi
  fi
}
read_config "mcp-server" _check_mcp_has_env
expect_eq "no mcp-server entries have whitespace-only env var list" "" "$_mcp_with_empty_env"

# 3n: read_config function body is identical in bootstrap and reset
_bootstrap_fn="$(awk '/^read_config\(\)/{found=1} found{print} found && /^\}$/{exit}' "$BOOTSTRAP")"
_reset_fn="$(awk '/^read_config\(\)/{found=1} found{print} found && /^\}$/{exit}' "$RESET")"
expect_eq "read_config function body identical in bootstrap and reset" "$_bootstrap_fn" "$_reset_fn"

# 3o: Both scripts source lib/platform.sh
expect_true "bootstrap sources lib/platform.sh" grep -q 'source.*lib/platform\.sh' "$BOOTSTRAP"
expect_true "reset sources lib/platform.sh" grep -q 'source.*lib/platform\.sh' "$RESET"

# 3p: agent-skills plugin entry is active (not commented out) in config
_agent_skills_found=0
_agent_skills_source=""
_check_agent_skills() {
  if [ "$1" = "agent-skills" ]; then
    _agent_skills_found=1
    _agent_skills_source="$2"
  fi
}
read_config "plugin" _check_agent_skills
expect_eq "agent-skills plugin entry is active in config" "1" "$_agent_skills_found"
expect_eq "agent-skills plugin sourced from addy-agent-skills" "addy-agent-skills" "$_agent_skills_source"

# 3q: addyosmani/agent-skills marketplace entry is active in config
_addy_marketplace_found=0
_check_addy_marketplace() {
  if [ "$1" = "addyosmani/agent-skills" ]; then
    _addy_marketplace_found=1
  fi
}
read_config "marketplace" _check_addy_marketplace
expect_eq "addyosmani/agent-skills marketplace entry is active in config" "1" "$_addy_marketplace_found"

# ============================================================
# SECTION 4: Hook file consistency
# ============================================================

echo ""
echo "=== Section 4: Hook file consistency ==="

# 4a: Every non-test .sh in hooks/ has a matching .test.sh
_hooks_missing_tests=""
for hook in "${REPO}/hooks/"*.sh; do
  [ -f "$hook" ] || continue
  name="$(basename "$hook")"
  if echo "$name" | grep -q '\.test\.sh$'; then
    continue
  fi
  testfile="${REPO}/hooks/${name%.sh}.test.sh"
  if [ ! -f "$testfile" ]; then
    _hooks_missing_tests="${_hooks_missing_tests}${name} "
  fi
done
expect_eq "every hook .sh has a matching .test.sh" "" "$_hooks_missing_tests"

# 4b: Every .test.sh in hooks/ has a corresponding non-test hook
_tests_missing_hooks=""
for test in "${REPO}/hooks/"*.test.sh; do
  [ -f "$test" ] || continue
  name="$(basename "$test")"
  hookname="${name%.test.sh}.sh"
  if [ ! -f "${REPO}/hooks/${hookname}" ]; then
    _tests_missing_hooks="${_tests_missing_hooks}${name} "
  fi
done
expect_eq "every .test.sh has a corresponding hook .sh" "" "$_tests_missing_hooks"

# 4c: Every hook file referenced inside MANAGED_HOOKS in bootstrap exists in hooks/
_missing_managed_hooks=""
while IFS= read -r line; do
  # Lines look like: "PreToolUse|Bash|~/.claude/hooks/foo.sh"
  if echo "$line" | grep -qE '"[^"]+\|[^|]*\|[^"]+\.sh"'; then
    hookfile="$(echo "$line" | grep -oE 'hooks/[^"]+\.sh' | head -1)"
    if [ -n "$hookfile" ]; then
      basename_hook="$(basename "$hookfile")"
      if [ ! -f "${REPO}/hooks/${basename_hook}" ]; then
        _missing_managed_hooks="${_missing_managed_hooks}${basename_hook} "
      fi
    fi
  fi
done < <(grep -A 20 'MANAGED_HOOKS=(' "$BOOTSTRAP" | grep -v 'MANAGED_HOOKS=(')
expect_eq "all MANAGED_HOOKS entries exist in hooks/ dir" "" "$_missing_managed_hooks"

# 4d: MANAGED_HOOKS includes protect-main.sh
expect_true "MANAGED_HOOKS includes protect-main.sh" grep -q 'protect-main\.sh' "$BOOTSTRAP"

# 4e: MANAGED_HOOKS includes protect-database.sh
expect_true "MANAGED_HOOKS includes protect-database.sh" grep -q 'protect-database\.sh' "$BOOTSTRAP"

# 4f: MANAGED_HOOKS includes memory-update.sh as a Stop hook
expect_true "MANAGED_HOOKS includes memory-update.sh as Stop hook" \
  grep -qE '^\s*"Stop\|\|.*memory-update\.sh"' "$BOOTSTRAP"

# 4g: MANAGED_HOOKS includes memory-cleanup.sh as a SessionStart hook with startup matcher
expect_true "MANAGED_HOOKS includes memory-cleanup.sh as SessionStart|startup" \
  grep -qE '^\s*"SessionStart\|startup\|.*memory-cleanup\.sh"' "$BOOTSTRAP"

# 4h: MANAGED_HOOKS includes canonical-sdlc-evidence-gate.sh as a PreToolUse|Bash hook
expect_true "MANAGED_HOOKS includes canonical-sdlc-evidence-gate.sh as PreToolUse|Bash" \
  grep -qE '^\s*"PreToolUse\|Bash\|.*canonical-sdlc-evidence-gate\.sh"' "$BOOTSTRAP"

# 4i: hooks/ dir contains at least one non-test hook
_hook_count=0
for hook in "${REPO}/hooks/"*.sh; do
  [ -f "$hook" ] || continue
  if ! echo "$(basename "$hook")" | grep -q '\.test\.sh$'; then
    _hook_count=$((_hook_count + 1))
  fi
done
expect_true "hooks/ contains at least one non-test hook" [ "$_hook_count" -gt 0 ]

# ============================================================
# SECTION 5: Shell alias marker consistency
# ============================================================

echo ""
echo "=== Section 5: Shell alias marker consistency ==="

# 5a: Bootstrap defines ALIAS_START containing 'bionic:start'
_bootstrap_start="$(grep 'ALIAS_START=' "$BOOTSTRAP" | head -1)"
expect_contains "bootstrap ALIAS_START contains bionic:start" "bionic:start" "$_bootstrap_start"

# 5b: Bootstrap defines ALIAS_END containing 'bionic:end'
_bootstrap_end="$(grep 'ALIAS_END=' "$BOOTSTRAP" | head -1)"
expect_contains "bootstrap ALIAS_END contains bionic:end" "bionic:end" "$_bootstrap_end"

# 5c: Reset defines ALIAS_START with the same value as bootstrap
_reset_start="$(grep 'ALIAS_START=' "$RESET" | head -1)"
expect_eq "reset ALIAS_START matches bootstrap ALIAS_START" "$_bootstrap_start" "$_reset_start"

# 5d: Reset defines ALIAS_END with the same value as bootstrap
_reset_end="$(grep 'ALIAS_END=' "$RESET" | head -1)"
expect_eq "reset ALIAS_END matches bootstrap ALIAS_END" "$_bootstrap_end" "$_reset_end"

# 5e: Bootstrap uses bionic:start marker (may also reference old claude-setup:start for migration)
expect_true "bootstrap references bionic:start" grep -q 'bionic:start' "$BOOTSTRAP"
# The active start_marker variable must be bionic:start (not the legacy value)
_bs_active_marker="$(grep 'start_marker=' "$BOOTSTRAP" | grep -v 'old_start' | grep -v '#' | head -1)"
expect_contains "bootstrap active start_marker uses bionic:start" "bionic:start" "$_bs_active_marker"

# 5f: Reset uses bionic:start marker (no migration code — must not reference old claude-setup:start at all)
expect_true "reset references bionic:start" grep -q 'bionic:start' "$RESET"
expect_false "reset does not reference claude-setup:start" grep -q 'claude-setup:start' "$RESET"

# 5g: Bootstrap global-memory section uses bionic:start and bionic:end markers
expect_true "bootstrap global-memory start_marker is bionic:start" \
  grep -q 'bionic:start' "$BOOTSTRAP"
expect_true "bootstrap global-memory end_marker is bionic:end" \
  grep -q 'bionic:end' "$BOOTSTRAP"

# 5h: Reset global-memory section uses bionic:start and bionic:end markers
expect_true "reset global-memory start_marker is bionic:start" \
  grep -q 'bionic:start' "$RESET"
expect_true "reset global-memory end_marker is bionic:end" \
  grep -q 'bionic:end' "$RESET"

# 5i: Bootstrap verification section checks for bionic:start in shell rc
_bootstrap_verify_shell="$(grep -A 3 '"  Shell alias:"' "$BOOTSTRAP" 2>/dev/null || grep -A 3 'Shell alias:' "$BOOTSTRAP" | head -6)"
expect_contains "bootstrap verification checks bionic:start in shell rc" "bionic:start" "$_bootstrap_verify_shell"

# 5j: Reset verification section checks for bionic:start in shell rc
_reset_verify_shell="$(grep -A 3 'Shell alias:' "$RESET" | head -8)"
expect_contains "reset verification checks bionic:start in shell rc" "bionic:start" "$_reset_verify_shell"

# ============================================================
# Results
# ============================================================

echo ""
echo "========================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
