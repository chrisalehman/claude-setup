#!/bin/bash
# Tests for lib/platform.sh — platform detection library.
# Validates that all exported variables and functions are set correctly
# for the current OS. Does NOT test cross-platform (can't mock uname easily);
# instead validates invariants that hold on any supported platform.
#
# Usage: bash lib/platform.test.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

# ---------- helpers (same as tests/scripts.test.sh) ----------

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

# ---------- source the library ----------

source "${REPO}/lib/platform.sh"

# ============================================================
# SECTION 1: OS detection
# ============================================================

echo ""
echo "=== Section 1: OS detection ==="

ACTUAL_OS="$(uname)"

# 1a: OS variable is set and matches uname
expect_eq "OS matches uname output" "$ACTUAL_OS" "$OS"

# 1b: OS is one of the supported values
expect_true "OS is Darwin or Linux" test "$OS" = "Darwin" -o "$OS" = "Linux"

# ============================================================
# SECTION 2: Homebrew prefix
# ============================================================

echo ""
echo "=== Section 2: Homebrew prefix ==="

# 2a: BREW_PREFIX is set (non-empty on a machine with brew installed)
if command -v brew &>/dev/null; then
  expect_true "BREW_PREFIX is non-empty when brew is installed" [ -n "$BREW_PREFIX" ]
  # 2b: BREW_PREFIX directory exists
  expect_true "BREW_PREFIX directory exists" [ -d "$BREW_PREFIX" ]
  # 2c: brew binary exists at the expected path
  expect_true "brew binary exists at BREW_PREFIX/bin/brew" [ -x "${BREW_PREFIX}/bin/brew" ]
else
  echo "SKIP: brew not installed — BREW_PREFIX tests skipped"
fi

# 2d: On Darwin, BREW_PREFIX is one of the known macOS paths
if [ "$OS" = "Darwin" ] && [ -n "$BREW_PREFIX" ]; then
  expect_true "Darwin BREW_PREFIX is /opt/homebrew or /usr/local" \
    test "$BREW_PREFIX" = "/opt/homebrew" -o "$BREW_PREFIX" = "/usr/local"
fi

# 2e: On Linux, BREW_PREFIX is the Linuxbrew path (if set)
if [ "$OS" = "Linux" ] && [ -n "$BREW_PREFIX" ]; then
  expect_eq "Linux BREW_PREFIX is /home/linuxbrew/.linuxbrew" "/home/linuxbrew/.linuxbrew" "$BREW_PREFIX"
fi

# ============================================================
# SECTION 3: Shell rc file
# ============================================================

echo ""
echo "=== Section 3: Shell rc file ==="

# 3a: SHELL_RC is set and non-empty
expect_true "SHELL_RC is non-empty" [ -n "$SHELL_RC" ]

# 3b: SHELL_RC_NAME is set and non-empty
expect_true "SHELL_RC_NAME is non-empty" [ -n "$SHELL_RC_NAME" ]

# 3c: SHELL_RC_NAME is .bashrc or .zshrc
expect_true "SHELL_RC_NAME is .bashrc or .zshrc" \
  test "$SHELL_RC_NAME" = ".bashrc" -o "$SHELL_RC_NAME" = ".zshrc"

# 3d: SHELL_RC ends with SHELL_RC_NAME
_shell_rc_basename="$(basename "$SHELL_RC")"
expect_eq "SHELL_RC basename matches SHELL_RC_NAME" "$SHELL_RC_NAME" "$_shell_rc_basename"

# 3e: If current shell is zsh, SHELL_RC_NAME should be .zshrc
if [ "$(basename "${SHELL:-/bin/bash}")" = "zsh" ]; then
  expect_eq "zsh shell produces .zshrc" ".zshrc" "$SHELL_RC_NAME"
fi

# 3f: If current shell is bash, SHELL_RC_NAME should be .bashrc
if [ "$(basename "${SHELL:-/bin/bash}")" = "bash" ]; then
  expect_eq "bash shell produces .bashrc" ".bashrc" "$SHELL_RC_NAME"
fi

# ============================================================
# SECTION 4: Playwright cache
# ============================================================

echo ""
echo "=== Section 4: Playwright cache ==="

# 4a: PLAYWRIGHT_CACHE is set and non-empty
expect_true "PLAYWRIGHT_CACHE is non-empty" [ -n "$PLAYWRIGHT_CACHE" ]

# 4b: On Darwin, PLAYWRIGHT_CACHE uses ~/Library/Caches path
if [ "$OS" = "Darwin" ]; then
  expect_eq "Darwin PLAYWRIGHT_CACHE is ~/Library/Caches/ms-playwright" \
    "$HOME/Library/Caches/ms-playwright" "$PLAYWRIGHT_CACHE"
fi

# 4c: On Linux, PLAYWRIGHT_CACHE uses ~/.cache path
if [ "$OS" = "Linux" ]; then
  expect_eq "Linux PLAYWRIGHT_CACHE is ~/.cache/ms-playwright" \
    "$HOME/.cache/ms-playwright" "$PLAYWRIGHT_CACHE"
fi

# ============================================================
# SECTION 5: sed_inplace function
# ============================================================

echo ""
echo "=== Section 5: sed_inplace function ==="

# 5a: sed_inplace is defined as a function
_is_func() { declare -f sed_inplace >/dev/null 2>&1; }
expect_true "sed_inplace is a defined function" _is_func

# 5b: sed_inplace works on a temp file
_sed_tmp="$(mktemp)"
echo "hello world" > "$_sed_tmp"
sed_inplace 's/world/planet/' "$_sed_tmp"
_sed_result="$(cat "$_sed_tmp")"
rm -f "$_sed_tmp"
expect_eq "sed_inplace performs substitution correctly" "hello planet" "$_sed_result"

# ============================================================
# SECTION 6: Unsupported OS handling
# ============================================================

echo ""
echo "=== Section 6: Unsupported OS handling ==="

# 6a: Sourcing with a mocked unsupported uname should fail
# We can't easily mock uname, but we can verify the case statement
# covers exactly Darwin and Linux by checking the source
expect_true "platform.sh has unsupported OS exit" grep -q "Unsupported OS" "${REPO}/lib/platform.sh"

# ============================================================
# SECTION 7: Library is purely declarative
# ============================================================

echo ""
echo "=== Section 7: Library properties ==="

# 7a: platform.sh does not contain install/apt/brew-install commands
expect_false "platform.sh does not run apt install" grep -q "apt install\|apt-get install" "${REPO}/lib/platform.sh"
expect_false "platform.sh does not run brew install" grep -q "brew install" "${REPO}/lib/platform.sh"

# 7b: Both bootstrap and reset source the library
expect_true "bootstrap sources lib/platform.sh" grep -q 'source.*lib/platform\.sh' "${REPO}/claude-bootstrap.sh"
expect_true "reset sources lib/platform.sh" grep -q 'source.*lib/platform\.sh' "${REPO}/claude-reset.sh"

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
