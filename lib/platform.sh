#!/usr/bin/env bash
#
# lib/platform.sh
# Platform detection library sourced by claude-bootstrap.sh and claude-reset.sh.
# Exports OS-specific variables. Does not install anything.
#
# Exports:
#   OS              — "Darwin" or "Linux"
#   BREW_PREFIX     — Homebrew prefix path
#   SHELL_RC        — Full path to shell rc file (~/.bashrc or ~/.zshrc)
#   SHELL_RC_NAME   — Basename of shell rc file (.bashrc or .zshrc)
#   PLAYWRIGHT_CACHE — OS-specific Playwright browser cache directory
#   sed_inplace()   — Portable sed -i wrapper (BSD vs GNU)

OS="$(uname)"

# ─── Homebrew prefix ───────────────────────────────────────────────────────

case "$OS" in
  Darwin)
    if [ -x /opt/homebrew/bin/brew ]; then
      BREW_PREFIX="/opt/homebrew"
    elif [ -x /usr/local/bin/brew ]; then
      BREW_PREFIX="/usr/local"
    else
      BREW_PREFIX=""
    fi
    ;;
  Linux)
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
      BREW_PREFIX="/home/linuxbrew/.linuxbrew"
    else
      BREW_PREFIX=""
    fi
    ;;
  *)
    echo "ERROR: Unsupported OS '${OS}'. Bionic supports macOS and Linux (WSL2)." >&2
    exit 1
    ;;
esac

# Put brew on PATH if installed
if [ -n "$BREW_PREFIX" ] && [ -x "${BREW_PREFIX}/bin/brew" ]; then
  eval "$("${BREW_PREFIX}/bin/brew" shellenv)"
fi

# ─── Shell rc file ─────────────────────────────────────────────────────────
# shellcheck disable=SC2034  # SHELL_RC and SHELL_RC_NAME are consumed by sourcing scripts (bootstrap/reset)

case "$(basename "${SHELL:-/bin/bash}")" in
  zsh)
    SHELL_RC=~/.zshrc
    SHELL_RC_NAME=".zshrc"
    ;;
  *)
    SHELL_RC=~/.bashrc
    SHELL_RC_NAME=".bashrc"
    ;;
esac

# ─── Playwright cache ─────────────────────────────────────────────────────
# shellcheck disable=SC2034  # PLAYWRIGHT_CACHE is consumed by sourcing scripts (bootstrap/reset)

case "$OS" in
  Darwin) PLAYWRIGHT_CACHE=~/Library/Caches/ms-playwright ;;
  Linux)  PLAYWRIGHT_CACHE=~/.cache/ms-playwright ;;
esac

# ─── Portable sed -i ──────────────────────────────────────────────────────

sed_inplace() {
  if [ "$OS" = "Darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}
