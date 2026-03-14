#!/usr/bin/env bash
#
# claude-bootstrap.sh
# Sets up Claude Code plugins, skills, and dependencies.
# Idempotent — safe to run multiple times; produces the same result.
# Requires: claude CLI, git (macOS + Homebrew)
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
check_cmd git     "Install with: xcode-select --install"

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
  if command -v "$cmd" &>/dev/null; then return 0; fi
  echo -n "  Installing ${pkg}... "
  brew install "$pkg" --quiet 2>/dev/null
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

# ─── Dependencies ───────────────────────────────────────────────────────────

echo "Dependencies:"
ensure_cmd uv
echo ""

# ─── Marketplaces ────────────────────────────────────────────────────────────

echo "Marketplaces:"
read_config "marketplace" do_install_marketplace
echo ""

# ─── Plugins ─────────────────────────────────────────────────────────────────

echo "Plugins:"
read_config "plugin" do_install_plugin
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
echo "Done"
