#!/usr/bin/env bash
#
# claude-bootstrap.sh
# Sets up Claude Code plugins, skills, and dependencies.
# Idempotent — safe to run multiple times; produces the same result.
# Requires: claude CLI + Homebrew (macOS or Linux/WSL)
#
set -euo pipefail

cleanup() { rm -f ~/.claude/settings.json.tmp ~/.claude/CLAUDE.md.tmp; }
trap cleanup EXIT

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

# ─── Platform Detection ─────────────────────────────────────────────────────

source "${SCRIPT_DIR}/lib/platform.sh"

# ─── Homebrew ────────────────────────────────────────────────────────────────

if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Re-source to pick up the newly installed brew
  source "${SCRIPT_DIR}/lib/platform.sh"
fi

# ─── Config reader ──────────────────────────────────────────────────────────

# Reads claude-config.txt and calls a callback for each entry of a given type.
# Usage: read_config <type> <callback>
#   callback receives: field1 field2 field3 (trimmed, pipe-delimited; f2 and f3 may be empty)
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

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  echo -n "  ${cmd}... "
  if command -v "$cmd" &>/dev/null; then
    echo "✓ (already installed)"
    return 0
  fi
  brew install "$pkg" --quiet &>/dev/null
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

do_install_uv_tool() {
  local pkg="$1" binary="${2:-$1}"
  echo -n "  ${pkg} (→ ${binary})... "
  if command -v "$binary" &>/dev/null; then
    echo "✓ (already installed)"
    return 0
  fi
  uv tool install "$pkg" --quiet 2>/dev/null
  echo "✓"
}

do_build_local_package() {
  local pkg="$1"
  local pkg_dir="${SCRIPT_DIR}/${pkg}"

  # Only build if the directory has a package.json (it's a local Node package)
  [ -f "${pkg_dir}/package.json" ] || return 0

  echo -n "  ${pkg} (npm install && build)... "
  (cd "$pkg_dir" && npm install --silent 2>/dev/null && npm run build --silent 2>/dev/null)
  echo "✓"
}

# Registers an MCP server via claude mcp add. If env_vars is provided (comma-separated
# list of env var names, e.g. "KEY1,KEY2"), reads their values from the current shell
# environment and passes them as -e flags. Skips with a warning if any are missing.
do_configure_mcp_server() {
  local name="$1" pkg="$2" env_vars="${3:-}"

  echo -n "  ${name} (${pkg})... "

  # Check if already configured via claude mcp
  if claude mcp get "$name" &>/dev/null; then
    echo "✓ (already configured)"
    return 0
  fi

  # Build env-var flags from comma-separated list (e.g. "TRELLO_API_KEY,TRELLO_TOKEN")
  local env_flags=()
  if [ -n "$env_vars" ]; then
    local missing=()
    IFS=',' read -ra vars <<< "$env_vars"
    for var in "${vars[@]}"; do
      var="$(echo "$var" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      local val="${!var:-}"
      if [ -z "$val" ]; then
        missing+=("$var")
      else
        env_flags+=("-e" "${var}=${val}")
      fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
      echo "⚠ skipped (set ${missing[*]} in your environment, then re-run)"
      return 0
    fi
  fi

  # Check if the package exists as a local subdirectory with a built server
  local local_server="${SCRIPT_DIR}/${pkg}/dist/server.js"

  if [ -f "$local_server" ]; then
    # Local package — resolve absolute path and register via claude mcp add
    local abs_path
    abs_path="$(cd "$(dirname "$local_server")" && pwd)/$(basename "$local_server")"

    claude mcp add "$name" -s user ${env_flags[@]+"${env_flags[@]}"} -- node "$abs_path" &>/dev/null
    echo "✓ (local)"
  else
    # Remote package — register via claude mcp add
    claude mcp add "$name" -s user ${env_flags[@]+"${env_flags[@]}"} -- npx -y "$pkg" &>/dev/null
    echo "✓"
  fi
}

do_install_marketplace() {
  local name="$1"
  echo -n "  ${name}... "
  local output
  if output=$(claude plugin marketplace add "$name" 2>&1); then
    echo "✓"
  elif echo "$output" | grep -qi "already"; then
    echo "✓ (already added)"
  else
    echo "FAILED: $output" >&2
    exit 1
  fi
}

do_install_plugin() {
  local plugin="$1" source="$2"
  echo -n "  ${plugin} (${source})... "
  if claude plugin list 2>&1 | grep -q "${plugin}@${source}"; then
    echo "✓ (already installed)"
    return 0
  fi
  if claude plugin install "${plugin}@${source}" &>/dev/null; then
    echo "✓"
  else
    echo "FAILED" >&2
    exit 1
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
  cp -r "$tmp" ~/.claude/skills/"${name}" && rm -rf ~/.claude/skills/"${name}"/.git
  rm -rf "$tmp"
  echo "✓"
}

do_install_github_skill_pack() {
  local name="$1" repo="$2"
  echo -n "  ${name} (${repo})... "
  local tmp="/tmp/claude-skill-pack-${name}"
  rm -rf "$tmp"
  git clone --depth 1 --quiet "https://github.com/${repo}.git" "$tmp"
  mkdir -p ~/.claude/skills
  local count=0
  for skill_dir in "$tmp"/.claude/skills/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name="$(basename "$skill_dir")"
    rm -rf ~/.claude/skills/"${skill_name}"
    cp -r "$skill_dir" ~/.claude/skills/"${skill_name}" && rm -rf ~/.claude/skills/"${skill_name}"/.git
    count=$((count + 1))
  done
  rm -rf "$tmp"
  echo "✓ (${count} skills)"
}

do_install_local_skill() {
  local name="$1"
  local source="${SCRIPT_DIR}/skills/${name}"
  echo -n "  ${name} (local)... "
  if [ ! -d "$source" ] || [ ! -f "${source}/SKILL.md" ]; then
    echo "ERROR: skills/${name}/SKILL.md not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi
  mkdir -p ~/.claude/skills
  rm -rf ~/.claude/skills/"${name}"
  cp -r "$source" ~/.claude/skills/"${name}"
  echo "✓"
}

do_install_local_command() {
  local name="$1"
  local source="${SCRIPT_DIR}/commands/${name}.md"
  echo -n "  /${name} (local)... "
  if [ ! -f "$source" ]; then
    echo "ERROR: commands/${name}.md not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi
  mkdir -p ~/.claude/commands
  cp "$source" ~/.claude/commands/"${name}.md"
  echo "✓"
}

do_install_global_memory() {
  local file="$1"
  local source="${SCRIPT_DIR}/${file}"
  local target=~/.claude/CLAUDE.md
  local start_marker="<!-- bionic:start -->"
  local end_marker="<!-- bionic:end -->"
  local old_start="<!-- claude-setup:start -->"

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

  # Migrate old claude-setup markers to bionic
  if [ -f "$target" ] && grep -q "$old_start" "$target"; then
    sed_inplace "s|<!-- claude-setup:start -->|${start_marker}|;s|<!-- claude-setup:end -->|${end_marker}|" "$target"
  fi

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

verify_brew_dep() {
  local binary="$1"
  if command -v "$binary" &>/dev/null; then
    echo "    ${binary} ✓"
  else
    echo "    ${binary} — not found"
    verify_errors+=("${binary} CLI tool — not found")
  fi
}

verify_npm_global() {
  local pkg="$1"
  if npm list -g --depth=0 "$pkg" &>/dev/null; then
    echo "    ${pkg} ✓"
  else
    echo "    ${pkg} — not found"
    verify_errors+=("${pkg} npm package — not found")
  fi
}

verify_uv_tool() {
  local pkg="$1" binary="${2:-$1}"
  if command -v "$binary" &>/dev/null; then
    echo "    ${binary} ✓"
  else
    echo "    ${binary} — not found"
    verify_errors+=("${binary} uv tool (${pkg}) — not found")
  fi
}

verify_mcp_server() {
  local name="$1" pkg="${2:-}" env_vars="${3:-}"
  if claude mcp get "$name" &>/dev/null; then
    echo "    ${name} ✓"
    return 0
  fi
  # If the server requires env vars that aren't set, it was intentionally skipped
  if [ -n "$env_vars" ]; then
    local missing=()
    IFS=',' read -ra vars <<< "$env_vars"
    for var in "${vars[@]}"; do
      var="$(echo "$var" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [ -z "${!var:-}" ]; then
        missing+=("$var")
      fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
      echo "    ${name} — skipped (${missing[*]} not set)"
      verify_warnings+=("${name} MCP server — skipped (set ${missing[*]} in your environment)")
      return 0
    fi
  fi
  echo "    ${name} — not configured"
  verify_errors+=("${name} MCP server — not configured")
}

verify_local_package_built() {
  local pkg="$1"
  local pkg_dir="${SCRIPT_DIR}/${pkg}"
  [ -f "${pkg_dir}/package.json" ] || return 0
  if [ -d "${pkg_dir}/node_modules" ] && [ -d "${pkg_dir}/dist" ]; then
    echo "    ${pkg} ✓"
  else
    echo "    ${pkg} — node_modules/ or dist/ missing"
    verify_errors+=("${pkg} local package — node_modules/ or dist/ missing")
  fi
}

# ─── CLI Tools (brew) ───────────────────────────────────────────────────────

echo "CLI tools (brew):"
read_config "brew-dep" do_install_brew_dep
echo ""

# ─── CLI Tools (npm) ─────────────────────────────────────────────────────────

echo "CLI tools (npm):"
if ! command -v npm &>/dev/null; then
  echo "  ERROR: npm not found — install node first" >&2
  exit 1
fi
read_config "npm-global" do_install_npm_global
echo ""

# ─── CLI Tools (uv) ─────────────────────────────────────────────────────────

echo "CLI tools (uv):"
if ! command -v uv &>/dev/null; then
  echo "  ERROR: uv not found — install with: brew install uv" >&2
  exit 1
fi
# Ensure uv tool bin directory is on PATH (uv installs binaries to ~/.local/bin/)
uv_bin_dir="$(uv tool dir --bin 2>/dev/null)"
if [ -n "$uv_bin_dir" ] && [[ ":$PATH:" != *":${uv_bin_dir}:"* ]]; then
  export PATH="${uv_bin_dir}:${PATH}"
fi
read_config "uv-tool" do_install_uv_tool
echo ""

# ─── Playwright Browsers ────────────────────────────────────────────────────

echo -n "Playwright browsers (chromium)... "
npx playwright install chromium 2>/dev/null
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
ALIAS_RC="$SHELL_RC"
ALIAS_START="# ─── bionic:start ───"
ALIAS_END="# ─── bionic:end ───"
ALIAS_CONTENT="alias claude='claude --dangerously-skip-permissions'"
ALIAS_SECTION="${ALIAS_START}
${ALIAS_CONTENT}
${ALIAS_END}"

# Migrate old unmarked alias to marker-based section
if [ -f "$ALIAS_RC" ] && grep -q "alias claude=.*dangerously-skip-permissions" "$ALIAS_RC" && ! grep -qF "$ALIAS_START" "$ALIAS_RC"; then
  grep -v "alias claude=.*dangerously-skip-permissions" "$ALIAS_RC" > "${ALIAS_RC}.tmp" && mv "${ALIAS_RC}.tmp" "$ALIAS_RC"
  printf '\n%s\n' "$ALIAS_SECTION" >> "$ALIAS_RC"
  echo "✓ (migrated to markers)"
elif grep -qF "$ALIAS_START" "$ALIAS_RC" 2>/dev/null; then
  # Markers exist — replace managed section
  {
    awk -v start="$ALIAS_START" '
      $0 == start { exit }
      { print }
    ' "$ALIAS_RC"
    echo "$ALIAS_SECTION"
    awk -v end="$ALIAS_END" '
      found { print }
      $0 == end { found=1 }
    ' "$ALIAS_RC"
  } > "${ALIAS_RC}.tmp" && mv "${ALIAS_RC}.tmp" "$ALIAS_RC"
  echo "✓ (already installed)"
else
  # No markers, no alias — append
  printf '\n%s\n' "$ALIAS_SECTION" >> "$ALIAS_RC"
  echo "✓"
fi
echo ""

# ─── Custom Skills ───────────────────────────────────────────────────────────

echo "Custom skills:"
read_config "github-skill" do_install_github_skill
read_config "github-skill-pack" do_install_github_skill_pack
read_config "local-skill" do_install_local_skill
echo ""

# ─── Custom Commands ────────────────────────────────────────────────────────

echo "Custom commands:"
read_config "local-command" do_install_local_command
echo ""

# ─── Skill Setup ────────────────────────────────────────────────────────────

echo "Skill setup:"
if [ -d ~/.claude/skills/excalidraw-diagram/references ]; then
  echo -n "  excalidraw-diagram renderer... "
  (cd ~/.claude/skills/excalidraw-diagram/references && uv sync --quiet 2>&1 && uv run playwright install chromium 2>&1) | tail -1
  echo "  ✓"
else
  echo "  excalidraw-diagram — skipped (not installed)"
fi
if command -v notebooklm &>/dev/null; then
  echo -n "  notebooklm skill install... "
  notebooklm skill install &>/dev/null && echo "✓" || echo "✓ (skill already installed)"
else
  echo "  notebooklm — skipped (CLI not installed)"
fi
echo ""

# ─── Global Hooks ────────────────────────────────────────────────────────────

echo "Global hooks:"
mkdir -p ~/.claude/hooks
for hook in "${SCRIPT_DIR}"/hooks/*.sh; do
  [ -f "$hook" ] || continue
  [[ "$(basename "$hook")" == *.test.sh ]] && continue
  name="$(basename "$hook")"
  echo -n "  ${name}... "
  cp "$hook" ~/.claude/hooks/"$name"
  chmod +x ~/.claude/hooks/"$name"
  echo "✓"
done

# Merge hook config into global settings
echo -n "  settings.json hook config... "
settings=~/.claude/settings.json
if [ ! -f "$settings" ]; then
  echo '{}' > "$settings"
fi

# Define all managed hooks (event|matcher_or_empty|command pairs)
# PreToolUse and PostToolUse use a Bash matcher; SessionStart uses a
# source matcher (startup — don't fire on compact/clear/resume since
# cleanup was already done for this notebook); Stop and UserPromptSubmit
# take no matcher (Stop fires on every turn end and is debounced inside
# the hook script; UserPromptSubmit fires on every user prompt).
MANAGED_HOOKS=(
  "PreToolUse|Bash|~/.claude/hooks/protect-main.sh"
  "PreToolUse|Bash|~/.claude/hooks/protect-database.sh"
  "PreToolUse|Bash|~/.claude/hooks/canonical-sdlc-evidence-gate.sh"
  "PreToolUse|Write|~/.claude/hooks/canonical-sdlc-governing-skill.sh"
  "PreToolUse|Edit|~/.claude/hooks/canonical-sdlc-governing-skill.sh"
  "PostToolUse|Bash|~/.claude/hooks/memory-commit-save.sh"
  "Stop||~/.claude/hooks/memory-update.sh"
  "SessionStart|startup|~/.claude/hooks/memory-cleanup.sh"
  "UserPromptSubmit||~/.claude/hooks/terseness-reminder.sh"
)

hooks_added=0
for entry in "${MANAGED_HOOKS[@]}"; do
  IFS='|' read -r event matcher cmd <<< "$entry"

  # Ensure the event array exists
  if ! jq -e --arg ev "$event" '.hooks[$ev]' "$settings" &>/dev/null; then
    tmp="${settings}.tmp"
    jq --arg ev "$event" '.hooks[$ev] = []' "$settings" > "$tmp" && mv "$tmp" "$settings"
  fi

  # Skip if this exact command already exists in the event array
  if jq -e --arg ev "$event" --arg c "$cmd" \
    '.hooks[$ev][] | select(.hooks[] | .command == $c)' \
    "$settings" &>/dev/null; then
    continue
  fi

  # Build the hook entry — with or without matcher
  tmp="${settings}.tmp"
  if [ -n "$matcher" ]; then
    jq --arg ev "$event" --arg m "$matcher" --arg c "$cmd" '
      .hooks[$ev] += [{
        "matcher": $m,
        "hooks": [{"type": "command", "command": $c, "timeout": 10}]
      }]
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
  else
    jq --arg ev "$event" --arg c "$cmd" '
      .hooks[$ev] += [{
        "hooks": [{"type": "command", "command": $c}]
      }]
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
  fi
  hooks_added=$((hooks_added + 1))
done

if [ "$hooks_added" -gt 0 ]; then
  echo "✓ (added ${hooks_added} hook entries)"
else
  echo "✓ (already configured)"
fi
echo ""

# ─── Env Vars ───────────────────────────────────────────────────────────────

echo "Env vars:"

env_added=0
do_set_env_var() {
  local key="$1" val="$2"
  echo -n "  ${key}=${val}... "
  if jq -e --arg k "$key" --arg v "$val" '.env[$k] == $v' "$settings" &>/dev/null; then
    echo "✓ (already set)"
    return
  fi
  tmp="${settings}.tmp"
  jq --arg k "$key" --arg v "$val" '.env[$k] = $v' "$settings" > "$tmp" && mv "$tmp" "$settings"
  env_added=$((env_added + 1))
  echo "✓"
}
read_config "env-var" do_set_env_var
echo ""

# ─── Status Line ──────────────────────────────────────────────────────────────

echo "Status line:"

do_set_statusline() {
  local cmd="$1"
  echo -n "  ${cmd}... "
  if jq -e --arg c "$cmd" '.statusLine.command == $c' "$settings" &>/dev/null; then
    echo "✓ (already set)"
    return
  fi
  tmp="${settings}.tmp"
  jq --arg c "$cmd" '.statusLine = {"type": "command", "command": $c}' "$settings" > "$tmp" && mv "$tmp" "$settings"
  echo "✓"
}
read_config "statusline" do_set_statusline
echo ""

# ─── ccstatusline Config ──────────────────────────────────────────────────────

echo "ccstatusline config:"
echo -n "  settings.json → ~/.config/ccstatusline/settings.json... "
mkdir -p ~/.config/ccstatusline
if diff -q "${SCRIPT_DIR}/ccstatusline/settings.json" ~/.config/ccstatusline/settings.json &>/dev/null; then
  echo "✓ (already up to date)"
else
  cp "${SCRIPT_DIR}/ccstatusline/settings.json" ~/.config/ccstatusline/settings.json
  echo "✓"
fi
echo ""

# ─── Local Package Builds ────────────────────────────────────────────────────

echo "Local packages:"
read_config "mcp-server" do_build_local_package
echo ""

# ─── MCP Servers ─────────────────────────────────────────────────────────────

echo "MCP servers:"
read_config "mcp-server" do_configure_mcp_server
echo ""

# ─── Verification ───────────────────────────────────────────────────────────

verify_errors=()
verify_warnings=()
echo "Verification:"

echo ""
echo "  CLI tools (brew):"
read_config "brew-dep" verify_brew_dep

echo ""
echo "  CLI tools (npm):"
read_config "npm-global" verify_npm_global

echo ""
echo "  CLI tools (uv):"
read_config "uv-tool" verify_uv_tool

echo ""
echo "  Playwright browsers:"
if ls "${PLAYWRIGHT_CACHE}"/chromium-* &>/dev/null; then
  echo "    chromium ✓"
else
  echo "    chromium — not found"
  verify_errors+=("chromium browser — not found")
fi

echo ""
echo "  Skill setup:"
if [ -d ~/.claude/skills/excalidraw-diagram/references/.venv ]; then
  echo "    excalidraw-diagram renderer ✓"
else
  echo "    excalidraw-diagram renderer — .venv not found (skill not installed or uv sync failed)"
fi
if [ -f ~/.claude/skills/notebooklm/SKILL.md ]; then
  echo "    notebooklm skill ✓"
elif command -v notebooklm &>/dev/null; then
  echo "    notebooklm skill — SKILL.md not found (run: notebooklm skill install)"
fi

echo ""
echo "  Local package builds:"
read_config "mcp-server" verify_local_package_built

echo ""
echo "  MCP servers:"
read_config "mcp-server" verify_mcp_server

echo ""
echo "  Global hooks:"
for hook in ~/.claude/hooks/*.sh; do
  [ -f "$hook" ] || continue
  echo "    $(basename "$hook") ✓"
done

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
echo "  Custom commands:"
if [ -d ~/.claude/commands ] && [ -n "$(ls -A ~/.claude/commands 2>/dev/null)" ]; then
  for cmd_file in ~/.claude/commands/*.md; do
    [ -f "$cmd_file" ] || continue
    echo "    /$(basename "$cmd_file" .md) ✓"
  done
else
  echo "    (none installed)"
fi


echo ""
echo "  Status line:"
if jq -e '.statusLine.command' "$settings" &>/dev/null; then
  echo "    $(jq -r '.statusLine.command' "$settings") ✓"
else
  echo "    (not configured)"
fi

echo ""
echo "  ccstatusline config:"
if diff -q "${SCRIPT_DIR}/ccstatusline/settings.json" ~/.config/ccstatusline/settings.json &>/dev/null; then
  echo "    settings.json ✓"
else
  echo "    settings.json — out of sync"
  verify_errors+=("ccstatusline settings.json — out of sync")
fi

echo ""
echo "  Global memory:"
if [ -f ~/.claude/CLAUDE.md ] && grep -q "<!-- bionic:start -->" ~/.claude/CLAUDE.md; then
  echo "    ~/.claude/CLAUDE.md ✓"
else
  echo "    ~/.claude/CLAUDE.md — not installed"
fi

echo ""
echo "  Shell alias:"
if [ -f "$SHELL_RC" ] && grep -qF "# ─── bionic:start ───" "$SHELL_RC"; then
  echo "    ~/${SHELL_RC_NAME} ✓"
else
  echo "    ~/${SHELL_RC_NAME} — not installed"
fi

# ─── Summary Report ─────────────────────────────────────────────────────────

echo ""
error_count=${#verify_errors[@]}
warning_count=${#verify_warnings[@]}

if [ "$error_count" -eq 0 ] && [ "$warning_count" -eq 0 ]; then
  echo "Done ✓"
else
  if [ "$error_count" -gt 0 ]; then
    echo "Done (${error_count} error(s), ${warning_count} warning(s))"
  else
    echo "Done ✓ (${warning_count} warning(s))"
  fi
  echo ""
  if [ "$error_count" -gt 0 ]; then
    echo "  Errors:"
    for msg in "${verify_errors[@]}"; do
      echo "    ✗ ${msg}"
    done
  fi
  if [ "$warning_count" -gt 0 ]; then
    if [ "$error_count" -gt 0 ]; then echo ""; fi
    echo "  Warnings:"
    for msg in "${verify_warnings[@]}"; do
      echo "    ⚠ ${msg}"
    done
  fi
fi

if [ "$error_count" -gt 0 ]; then
  exit 1
fi
