#!/usr/bin/env bash
#
# claude-bootstrap.sh
# Sets up Claude Code plugins, skills, and dependencies.
# Idempotent — safe to run multiple times; produces the same result.
# Requires: claude CLI (macOS + Homebrew)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/claude-config.txt"

# ─── Prerequisite checks ────────────────────────────────────────────────────

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found. $2" >&2
    exit 1
  fi
}

check_cmd claude  "Install with: brew install claude-code"

# ─── Homebrew ────────────────────────────────────────────────────────────────

if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ─── Config reader ──────────────────────────────────────────────────────────

# Reads claude-config.txt and calls a callback for each entry of a given type.
# Usage: read_config <type> <callback>
#   callback receives: field1 field2 (trimmed, pipe-delimited)
read_config() {
  local type="$1" callback="$2"
  while IFS='|' read -r entry_type f1 f2; do
    entry_type="$(echo "$entry_type" | xargs)"
    [ "$entry_type" = "$type" ] || continue
    f1="$(echo "$f1" | xargs)"
    f2="$(echo "${f2:-}" | xargs)"
    "$callback" "$f1" "$f2"
  done < <(grep -v '^\s*#' "$CONFIG" | grep -v '^\s*$')
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  echo -n "  ${cmd}... "
  if command -v "$cmd" &>/dev/null; then
    echo "✓ (already installed)"
    return 0
  fi
  brew install "$pkg" --quiet 2>/dev/null
  echo "✓"
}

do_install_brew_dep() {
  local binary="$1" pkg="${2:-$1}"
  ensure_cmd "$binary" "$pkg"
}

do_install_npm_global() {
  local pkg="$1"
  echo -n "  ${pkg}... "
  if npm list -g --depth=0 "$pkg" &>/dev/null; then
    echo "✓ (already installed)"
  else
    npm install -g "$pkg" --silent 2>/dev/null
    echo "✓"
  fi
}

do_configure_mcp_server() {
  local name="$1" pkg="$2"
  local settings=~/.claude/settings.json

  echo -n "  ${name} (${pkg})... "

  # Create settings file if it doesn't exist
  if [ ! -f "$settings" ]; then
    echo '{}' > "$settings"
  fi

  # Check if MCP server already configured
  if jq -e ".mcpServers.\"${name}\"" "$settings" &>/dev/null; then
    echo "✓ (already configured)"
    return 0
  fi

  # Merge new MCP server entry
  local tmp="${settings}.tmp"
  jq --arg name "$name" --arg pkg "$pkg" '
    .mcpServers //= {} |
    .mcpServers[$name] = { "command": "npx", "args": [$pkg] }
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"

  echo "✓"
}

do_install_marketplace() {
  local name="$1"
  echo -n "  ${name}... "
  claude plugin marketplace add "$name" 2>&1 | tail -1
}

do_install_plugin() {
  local plugin="$1" source="$2"
  echo -n "  ${plugin} (${source})... "
  if claude plugin install "${plugin}@${source}" 2>&1 | grep -q "already"; then
    echo "✓ (already installed)"
  else
    echo "✓"
  fi
}

do_install_github_skill() {
  local name="$1" repo="$2"
  echo -n "  ${name} (${repo})... "
  local tmp="/tmp/claude-skill-${name}"
  rm -rf "$tmp"
  git clone --depth 1 --quiet "https://github.com/${repo}.git" "$tmp"
  mkdir -p ~/.claude/skills
  rm -rf ~/.claude/skills/"${name}"
  cp -r "$tmp" ~/.claude/skills/"${name}"
  rm -rf "$tmp"
  echo "✓"
}

do_install_global_memory() {
  local file="$1"
  local source="${SCRIPT_DIR}/${file}"
  local target=~/.claude/CLAUDE.md
  local start_marker="<!-- claude-setup:start -->"
  local end_marker="<!-- claude-setup:end -->"

  echo -n "  ${file} → ~/.claude/CLAUDE.md... "

  if [ ! -f "$source" ]; then
    echo "ERROR: '${file}' not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi

  mkdir -p ~/.claude

  local content
  content="$(cat "$source")"
  local section="${start_marker}
${content}
${end_marker}"

  if [ ! -f "$target" ]; then
    # No existing file — create with managed section
    echo "$section" > "$target"
  elif grep -q "$start_marker" "$target"; then
    # Markers exist — replace managed section
    local tmp="${target}.tmp"
    {
      awk -v start="$start_marker" '
        $0 == start { exit }
        { print }
      ' "$target"
      echo "$section"
      awk -v end="$end_marker" '
        found { print }
        $0 == end { found=1 }
      ' "$target"
    } > "$tmp" && mv "$tmp" "$target"
  else
    # File exists, no markers — append with blank line separator
    printf "\n%s\n" "$section" >> "$target"
  fi

  echo "✓"
}

# ─── Brew Dependencies ──────────────────────────────────────────────────────

echo "Brew dependencies:"
read_config "brew-dep" do_install_brew_dep
echo ""

# ─── npm Globals ─────────────────────────────────────────────────────────────

echo "npm globals:"
if ! command -v npm &>/dev/null; then
  echo "  ERROR: npm not found — install node first" >&2
  exit 1
fi
read_config "npm-global" do_install_npm_global
echo ""

# ─── Playwright Browsers ────────────────────────────────────────────────────

echo -n "Playwright browsers (chromium)... "
npx playwright install chromium --quiet 2>/dev/null || npx playwright install chromium 2>/dev/null
echo "✓"
echo ""

# ─── Marketplaces ────────────────────────────────────────────────────────────

echo "Marketplaces:"
read_config "marketplace" do_install_marketplace
echo ""

# ─── Plugins ─────────────────────────────────────────────────────────────────

echo "Plugins:"
read_config "plugin" do_install_plugin
echo ""

# ─── Global Memory ─────────────────────────────────────────────────────────

echo "Global memory:"
read_config "global-memory" do_install_global_memory
echo ""

# ─── Shell Alias ─────────────────────────────────────────────────────────────

echo "Shell alias:"
echo -n "  claude → claude --dangerously-skip-permissions... "
CLAUDE_BIN="$(command -v claude)"
ALIAS_LINE="alias claude='${CLAUDE_BIN} --dangerously-skip-permissions'"
ZSHRC=~/.zshrc
if grep -qxF "$ALIAS_LINE" "$ZSHRC" 2>/dev/null; then
  echo "✓ (already installed)"
else
  printf '\n%s\n' "$ALIAS_LINE" >> "$ZSHRC"
  echo "✓"
fi
echo ""

# ─── Custom Skills ───────────────────────────────────────────────────────────

echo "Custom skills:"
read_config "github-skill" do_install_github_skill
echo ""

# ─── Skill Setup ────────────────────────────────────────────────────────────

echo "Skill setup:"
echo -n "  excalidraw-diagram renderer... "
(cd ~/.claude/skills/excalidraw-diagram/references && uv sync --quiet 2>&1 && uv run playwright install chromium 2>&1) | tail -1
echo "  ✓"
echo ""

# ─── MCP Servers ─────────────────────────────────────────────────────────────

echo "MCP servers:"
read_config "mcp-server" do_configure_mcp_server
echo ""

# ─── Verification ───────────────────────────────────────────────────────────

echo "Verification:"

echo ""
echo "  Plugins (official skills):"
claude plugin list 2>&1 | while IFS= read -r line; do echo "    $line"; done

echo ""
echo "  Custom skills:"
for skill_dir in ~/.claude/skills/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "$skill_dir")"
  if [ -f "${skill_dir}SKILL.md" ]; then
    echo "    ${name} ✓"
  else
    echo "    ${name} ⚠ (missing SKILL.md)"
  fi
done

echo ""
echo "  Global memory:"
if [ -f ~/.claude/CLAUDE.md ] && grep -q "<!-- claude-setup:start -->" ~/.claude/CLAUDE.md; then
  echo "    ~/.claude/CLAUDE.md ✓"
else
  echo "    ~/.claude/CLAUDE.md — not installed"
fi

echo ""
echo "  Shell alias:"
if [ -f ~/.zshrc ] && grep -qF "dangerously-skip-permissions" ~/.zshrc; then
  echo "    ~/.zshrc ✓"
else
  echo "    ~/.zshrc — not installed"
fi

echo ""
echo "Done"
