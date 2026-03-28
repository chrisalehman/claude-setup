#!/usr/bin/env bash
#
# claude-reset.sh
# Removes Claude Code plugins and skills installed by claude-bootstrap.sh.
# Idempotent — safe to run multiple times; produces the same result.
# Requires: claude CLI (brew install claude-code)
#
# Usage:
#   bash claude-reset.sh          # prompt before removal
#   bash claude-reset.sh --all    # remove everything without prompting
#
set -euo pipefail

cleanup() { rm -f ~/.claude/settings.json.tmp ~/.claude/CLAUDE.md.tmp ~/.zshrc.tmp; }
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/claude-config.txt"

# ─── Options ─────────────────────────────────────────────────────────────────

REMOVE_ALL=false
if [[ "${1:-}" == "--all" ]]; then
  REMOVE_ALL=true
fi

if ! $REMOVE_ALL; then
  read -rp "Remove all installed plugins and skills? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    REMOVE_ALL=true
  fi
fi

# ─── Prerequisite checks ────────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo "ERROR: 'claude' not found. Install with: brew install claude-code" >&2
  exit 1
fi

# ─── Config reader ──────────────────────────────────────────────────────────
# callback receives: field1 field2 field3 (trimmed, pipe-delimited; f2 and f3 may be empty)

read_config() {
  local type="$1" callback="$2"
  while IFS='|' read -r entry_type f1 f2 f3; do
    entry_type="$(echo "$entry_type" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$entry_type" = "$type" ] || continue
    f1="$(echo "$f1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    f2="$(echo "${f2:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    f3="$(echo "${f3:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    "$callback" "$f1" "$f2" "$f3"
  done < <(grep -v '^\s*#' "$CONFIG" | grep -v '^\s*$')
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

confirm() {
  if $REMOVE_ALL; then return 0; fi
  read -rp "  Remove $1? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

do_remove_skill() {
  local name="$1"
  if ! confirm "${name}"; then
    echo "  ${name} — skipped"
    return 0
  fi
  echo -n "  ${name}... "
  if [ -d ~/.claude/skills/"${name}" ]; then
    rm -rf ~/.claude/skills/"${name}"
    echo "✓"
  else
    echo "✓ (already removed)"
  fi
}

do_remove_github_skill_pack() {
  local name="$1" repo="$2"
  if ! confirm "${name} (all skills from ${repo})"; then
    echo "  ${name} — skipped"
    return 0
  fi
  echo -n "  ${name} (${repo})... "
  local tmp="/tmp/claude-skill-pack-${name}"
  rm -rf "$tmp"
  if git clone --depth 1 --quiet "https://github.com/${repo}.git" "$tmp" 2>/dev/null; then
    local count=0
    for skill_dir in "$tmp"/.claude/skills/*/; do
      [ -d "$skill_dir" ] || continue
      local skill_name
      skill_name="$(basename "$skill_dir")"
      rm -rf ~/.claude/skills/"${skill_name}"
      count=$((count + 1))
    done
    rm -rf "$tmp"
    echo "✓ (${count} skills removed)"
  else
    echo "⚠ (cannot fetch skill list — remove ~/.claude/skills/ entries manually)"
  fi
  # Clean up old project-local artifacts from npx-skill era
  rm -rf "${SCRIPT_DIR}/.agents" "${SCRIPT_DIR}/.kiro" "${SCRIPT_DIR}/skills-lock.json" "${SCRIPT_DIR}/.claude/skills"
}

do_remove_plugin() {
  local plugin="$1" source="$2"
  if ! confirm "${plugin} (${source})"; then
    echo "  ${plugin} — skipped"
    return 0
  fi
  echo -n "  ${plugin} (${source})... "
  claude plugin uninstall "${plugin}@${source}" &>/dev/null && echo "✓" || echo "✓ (already removed)"
}

do_remove_marketplace() {
  local name="$1"
  if ! confirm "${name}"; then
    echo "  ${name} — skipped"
    return 0
  fi
  echo -n "  ${name}... "
  claude plugin marketplace remove "$name" &>/dev/null && echo "✓" || echo "✓ (already removed)"
}

do_remove_global_memory() {
  local file="$1"
  local target=~/.claude/CLAUDE.md
  local start_marker="<!-- claude-setup:start -->"
  local end_marker="<!-- claude-setup:end -->"

  if ! confirm "global memory (${file})"; then
    echo "  global memory — skipped"
    return 0
  fi

  echo -n "  ~/.claude/CLAUDE.md... "

  if [ ! -f "$target" ]; then
    echo "✓ (already removed)"
    return 0
  fi

  if ! grep -q "$start_marker" "$target"; then
    echo "✓ (no managed section)"
    return 0
  fi

  # Remove managed section using awk
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"

  # Delete file if only whitespace remains
  if [ ! -s "$target" ] || ! grep -q '[^[:space:]]' "$target"; then
    rm -f "$target"
  fi

  echo "✓"
}

do_clean_local_package() {
  local pkg="$1"
  local pkg_dir="${SCRIPT_DIR}/${pkg}"

  # Only clean if the directory has a package.json (it's a local Node package)
  [ -f "${pkg_dir}/package.json" ] || return 0

  if ! confirm "local package build artifacts: ${pkg}"; then
    echo "  ${pkg} — skipped"
    return 0
  fi

  echo -n "  ${pkg} (node_modules/ and dist/)... "
  local removed=0
  if [ -d "${pkg_dir}/node_modules" ]; then
    rm -rf "${pkg_dir}/node_modules"
    removed=$((removed + 1))
  fi
  if [ -d "${pkg_dir}/dist" ]; then
    rm -rf "${pkg_dir}/dist"
    removed=$((removed + 1))
  fi
  if [ "$removed" -gt 0 ]; then
    echo "✓"
  else
    echo "✓ (already removed)"
  fi
}

do_remove_mcp_server() {
  local name="$1" pkg="$2" env_vars="${3:-}"

  if ! confirm "MCP server: ${name}"; then
    echo "  ${name} — skipped"
    return 0
  fi

  echo -n "  ${name}... "

  if ! claude mcp get "$name" &>/dev/null; then
    echo "✓ (already removed)"
    return 0
  fi

  claude mcp remove "$name" -s user &>/dev/null && echo "✓" || echo "✓ (already removed)"
}

do_remove_npm_global() {
  local pkg="$1"
  if ! confirm "CLI tool: ${pkg}"; then
    echo "  ${pkg} — skipped"
    return 0
  fi
  echo -n "  ${pkg}... "
  if npm list -g --depth=0 "$pkg" &>/dev/null; then
    npm uninstall -g "$pkg" --silent 2>/dev/null
    echo "✓"
  else
    echo "✓ (already removed)"
  fi
}

verify_npm_global_removed() {
  local pkg="$1"
  if npm list -g --depth=0 "$pkg" &>/dev/null; then
    npm_global_found=true
    echo "    ${pkg} — still installed"
  fi
}

verify_mcp_removed() {
  local name="$1"
  if claude mcp get "$name" &>/dev/null; then
    mcp_found=true
    echo "    ${name} — still configured"
  fi
}

verify_local_package_clean() {
  local pkg="$1"
  local pkg_dir="${SCRIPT_DIR}/${pkg}"
  [ -f "${pkg_dir}/package.json" ] || return 0
  if [ -d "${pkg_dir}/node_modules" ] || [ -d "${pkg_dir}/dist" ]; then
    local_pkg_found=true
    echo "    ${pkg} — build artifacts still present"
  fi
}

# ─── Global Hooks ──────────────────────────────────────────────────────────

echo "Global hooks:"
if ! confirm "global hooks (~/.claude/hooks/)"; then
  echo "  hooks — skipped"
else
  settings=~/.claude/settings.json
  hooks_removed=0
  # Remove only hooks that exist in this repo's hooks/ directory
  for hook in "${SCRIPT_DIR}"/hooks/*.sh; do
    [ -f "$hook" ] || continue
    [[ "$(basename "$hook")" == *.test.sh ]] && continue
    name="$(basename "$hook")"
    echo -n "  ${name}... "
    if [ -f ~/.claude/hooks/"${name}" ]; then
      rm -f ~/.claude/hooks/"${name}"
      echo "✓"
    else
      echo "✓ (already removed)"
    fi
    hooks_removed=$((hooks_removed + 1))
    # Remove matching entries from settings.json
    if [ -f "$settings" ] && jq -e '.hooks.PreToolUse' "$settings" &>/dev/null; then
      # Note: uses literal ~ to match what bootstrap stored in settings.json
      cmd="~/.claude/hooks/${name}"
      tmp="${settings}.tmp"
      jq --arg c "$cmd" '
        .hooks.PreToolUse |= map(select(.hooks | all(.command != $c)))
      ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    fi
  done
  # Clean up empty PreToolUse array, then clean up empty hooks object if nothing else remains
  if [ -f "$settings" ]; then
    tmp="${settings}.tmp"
    jq 'if .hooks.PreToolUse == [] then del(.hooks.PreToolUse) else . end' "$settings" > "$tmp" && mv "$tmp" "$settings"
    # Clean up empty hooks object
    jq 'if .hooks == {} then del(.hooks) else . end' "$settings" > "$tmp" && mv "$tmp" "$settings"
  fi
  if [ "$hooks_removed" -eq 0 ]; then
    echo "  (no hooks to remove)"
  fi
fi
echo ""

# ─── Env Vars ─────────────────────────────────────────────────────────────

do_remove_env_var() {
  local key="$1" _val="$2"  # _val unused; config format requires two fields
  if ! confirm "env var: ${key}"; then
    echo "  ${key} — skipped"
    return 0
  fi
  local settings=~/.claude/settings.json
  echo -n "  ${key}... "
  if [ ! -f "$settings" ] || ! jq -e --arg k "$key" '.env[$k]' "$settings" &>/dev/null; then
    echo "✓ (already removed)"
    return 0
  fi
  local tmp="${settings}.tmp"
  jq --arg k "$key" 'del(.env[$k]) | if .env == {} then del(.env) else . end' "$settings" > "$tmp" && mv "$tmp" "$settings"
  echo "✓"
}

echo "Env vars:"
read_config "env-var" do_remove_env_var
echo ""

# ─── Status Line ──────────────────────────────────────────────────────────────

do_remove_statusline() {
  local _cmd="$1"
  if ! confirm "status line"; then
    echo "  status line — skipped"
    return 0
  fi
  local settings=~/.claude/settings.json
  echo -n "  status line... "
  if [ ! -f "$settings" ] || ! jq -e '.statusLine' "$settings" &>/dev/null; then
    echo "✓ (already removed)"
    return 0
  fi
  local tmp="${settings}.tmp"
  jq 'del(.statusLine)' "$settings" > "$tmp" && mv "$tmp" "$settings"
  echo "✓"
}

echo "Status line:"
read_config "statusline" do_remove_statusline

echo -n "  ccstatusline config... "
if ! confirm "ccstatusline config (~/.config/ccstatusline/)"; then
  echo "skipped"
else
  if [ -d ~/.config/ccstatusline ]; then
    rm -rf ~/.config/ccstatusline
    echo "✓"
  else
    echo "✓ (already removed)"
  fi
fi
echo ""

# ─── Local Package Builds ────────────────────────────────────────────────────

echo "Local packages:"
read_config "mcp-server" do_clean_local_package
echo ""

# ─── MCP Servers ───────────────────────────────────────────────────────────

echo "MCP servers:"
read_config "mcp-server" do_remove_mcp_server
echo ""

# ─── Playwright Browsers ────────────────────────────────────────────────────

echo "Playwright browsers:"
if ! confirm "Playwright browsers (chromium)"; then
  echo "  browsers — skipped"
else
  echo -n "  chromium... "
  if npx playwright uninstall --all 2>/dev/null; then
    echo "✓"
  elif [ -d ~/Library/Caches/ms-playwright ]; then
    rm -rf ~/Library/Caches/ms-playwright
    echo "✓ (cache removed directly)"
  else
    echo "✓ (already removed)"
  fi
fi
echo ""

# ─── CLI Tools (npm) ───────────────────────────────────────────────────────

echo "CLI tools (npm):"
read_config "npm-global" do_remove_npm_global
echo ""

# ─── CLI Tools (brew) ─────────────────────────────────────────────────────

echo "CLI tools (brew):"
echo "  (not removed — system-level tools may be used by other software)"
echo ""

# ─── Custom Skills ──────────────────────────────────────────────────────────

echo "Custom skills:"
read_config "github-skill" do_remove_skill
read_config "github-skill-pack" do_remove_github_skill_pack
read_config "local-skill" do_remove_skill
echo ""

# ─── Skill Setup ────────────────────────────────────────────────────────────

echo "Skill setup:"
echo "  excalidraw-diagram renderer — not removed separately (.venv removed with skill dir; Playwright cache removed above)"
echo ""

# ─── Global Memory ──────────────────────────────────────────────────────────

echo "Global memory:"
read_config "global-memory" do_remove_global_memory
echo ""

# ─── Shell Alias ─────────────────────────────────────────────────────────────

echo "Shell alias:"
ZSHRC=~/.zshrc
if ! confirm "shell alias (dangerously-skip-permissions)"; then
  echo "  shell alias — skipped"
else
  echo -n "  ~/.zshrc alias... "
  if [ -f "$ZSHRC" ] && grep -q "alias claude=.*dangerously-skip-permissions" "$ZSHRC"; then
    grep -v "alias claude=.*dangerously-skip-permissions" "$ZSHRC" > "${ZSHRC}.tmp" && mv "${ZSHRC}.tmp" "$ZSHRC"
    # Delete file if only whitespace remains
    if [ ! -s "$ZSHRC" ] || ! grep -q '[^[:space:]]' "$ZSHRC"; then
      rm -f "$ZSHRC"
    fi
    echo "✓"
  else
    echo "✓ (already removed)"
  fi
fi
echo ""

# ─── Plugins ────────────────────────────────────────────────────────────────

echo "Plugins:"
read_config "plugin" do_remove_plugin
echo ""

# ─── Marketplaces ───────────────────────────────────────────────────────────

echo "Marketplaces:"
read_config "marketplace" do_remove_marketplace
echo ""

# ─── Verification ───────────────────────────────────────────────────────────

echo "Verification:"

echo ""
echo "  Plugins (official skills):"
plugin_output="$(claude plugin list 2>&1)"
if echo "$plugin_output" | grep -q "No plugins"; then
  echo "    (none installed) ✓"
else
  echo "$plugin_output" | while IFS= read -r line; do echo "    $line"; done
fi

echo ""
echo "  Custom skills:"
if [ -d ~/.claude/skills ] && [ "$(ls -A ~/.claude/skills 2>/dev/null)" ]; then
  for skill_dir in ~/.claude/skills/*/; do
    [ -d "$skill_dir" ] || continue
    echo "    $(basename "$skill_dir") — still present"
  done
else
  echo "    (none installed) ✓"
fi

echo ""
echo "  Global memory:"
if [ -f ~/.claude/CLAUDE.md ] && grep -q "<!-- claude-setup:start -->" ~/.claude/CLAUDE.md; then
  echo "    ~/.claude/CLAUDE.md — managed section still present"
else
  echo "    ~/.claude/CLAUDE.md ✓ (clean)"
fi

echo ""
echo "  Shell alias:"
if [ -f ~/.zshrc ] && grep -qF "dangerously-skip-permissions" ~/.zshrc; then
  echo "    ~/.zshrc — alias still present"
else
  echo "    ~/.zshrc ✓ (clean)"
fi

echo ""
echo "  Global hooks:"
if [ -d ~/.claude/hooks ] && [ "$(ls -A ~/.claude/hooks 2>/dev/null)" ]; then
  for hook in ~/.claude/hooks/*; do
    echo "    $(basename "$hook") — still present"
  done
else
  echo "    (none installed) ✓"
fi

echo ""
echo "  CLI tools (npm):"
npm_global_found=false
read_config "npm-global" verify_npm_global_removed
if ! $npm_global_found; then
  echo "    (none installed) ✓"
fi

echo ""
echo "  MCP servers:"
mcp_found=false
read_config "mcp-server" verify_mcp_removed
if ! $mcp_found; then
  echo "    (all removed) ✓"
fi

echo ""
echo "  Local package builds:"
local_pkg_found=false
read_config "mcp-server" verify_local_package_clean
if ! $local_pkg_found; then
  echo "    (all clean) ✓"
fi

echo ""
echo "  Playwright browsers:"
if [ -d ~/Library/Caches/ms-playwright ] && [ "$(ls -A ~/Library/Caches/ms-playwright 2>/dev/null)" ]; then
  echo "    ~/Library/Caches/ms-playwright — still present"
else
  echo "    ~/Library/Caches/ms-playwright ✓ (clean)"
fi

echo ""
echo "  Skill setup:"
if [ -d ~/.claude/skills/excalidraw-diagram/references/.venv ]; then
  echo "    excalidraw-diagram .venv — still present (skill dir not removed?)"
else
  echo "    excalidraw-diagram .venv ✓ (clean)"
fi

echo "" ; echo "Done"
