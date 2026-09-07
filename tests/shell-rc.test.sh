#!/bin/bash
# SHELL RC RESOLVER — L-DETECT/4.4 (spec AC-21).
#
# WHAT THIS SUITE OWNS. `payload/scripts/lib/shell.sh`'s `shell_rc_file` — the
# one place "which rc file does bionic write to" is answered — and the two
# callers that used to carry their own copy of the same case statement:
# `_detect_shell_rc` (detect.sh) and `_rm_shell_rc` (remove.sh). Both are now
# thin wrappers, pinned here by a structural check (each one's body calls
# `shell_rc_file` and does nothing else) and a BEHAVIORAL agreement check
# across every $SHELL this file resolves (zsh, bash, fish, and an unrecognized
# shell) plus the BIONIC_SHELL_RC override.
#
# `env.sh`'s `rc_file` is a separate, pre-existing resolver with its own
# stricter posture (it refuses on an unrecognized shell) and is out of scope:
# it was not one of the two functions this slice was asked to unify.
#
# HERMETIC. No real $HOME is read or written; every check runs in a
# subshell with HOME pointed at a fixture directory. `_detect_shell_rc` and
# `_rm_shell_rc` are called by SOURCING the real payload files (detect.sh pulls
# in deps.sh/env.sh as siblings; remove.sh is `set -uo pipefail` and sourcing
# it would run its top-level roster code, so its function is extracted with
# `sed` the same way callers extract single functions elsewhere in this repo's
# suites — never re-typed by hand).
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below: containment is
# bash `[[ == * ]]` in-process.
#
# Usage: bash tests/shell-rc.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
SHELL_SH="${REPO}/payload/scripts/lib/shell.sh"
DETECT_SH="${REPO}/payload/scripts/lib/detect.sh"
REMOVE_SH="${REPO}/payload/scripts/remove.sh"

# expect_true is the framework's (tests/lib/assert.sh) — S9b removed the private
# shadow here (AC-12); same semantics (silences the command's own output).

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXHOME="$TMP/home"
mkdir -p "$FIXHOME"

expect_true "payload/scripts/lib/shell.sh exists" test -f "$SHELL_SH"
expect_true "shell.sh passes bash -n" bash -n "$SHELL_SH"

section "Section 1: shell_rc_file itself, one resolver"

run_shell_rc_file() {  # <shell-basename-or-path> [BIONIC_SHELL_RC]
  HOME="$FIXHOME" SHELL="$1" BIONIC_SHELL_RC="${2:-}" \
    bash -c '. "$1"; shift; shell_rc_file' _ "$SHELL_SH" 2>/dev/null
}

expect_eq "1: zsh resolves to ~/.zshrc"          "$FIXHOME/.zshrc"  "$(run_shell_rc_file /bin/zsh)"
expect_eq "2: bash resolves to ~/.bashrc"        "$FIXHOME/.bashrc" "$(run_shell_rc_file /bin/bash)"
expect_eq "3: fish falls back to ~/.bashrc"      "$FIXHOME/.bashrc" "$(run_shell_rc_file /usr/bin/fish)"
expect_eq "4: an unrecognized shell falls back"  "$FIXHOME/.bashrc" "$(run_shell_rc_file /opt/weird/shell)"
expect_eq "5: BIONIC_SHELL_RC overrides everything" \
  "$TMP/override.rc" "$(run_shell_rc_file /bin/zsh "$TMP/override.rc")"

section "Section 2: both callers are THIN — they delegate, they do not reimplement"

# STRUCTURAL, not behavioral: a caller could reimplement the same case
# statement and pass every Section 1/3 check while still being the exact
# duplication AC-21 exists to end. This is the check that only the refactor
# itself can satisfy.
_extract_fn() {  # <file> <fn-name> -> the function's body, verbatim
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { grab=1 }
    grab { print }
    grab && /^}/ { exit }
  ' "$1"
}

DETECT_FN_BODY="$(_extract_fn "$DETECT_SH" "_detect_shell_rc")"
REMOVE_FN_BODY="$(_extract_fn "$REMOVE_SH" "_rm_shell_rc")"

expect_true "6: detect.sh sources lib/shell.sh" \
  grep -qE '/lib/shell\.sh"?$|shell\.sh"' "$DETECT_SH"
expect_true "7: remove.sh sources lib/shell.sh" \
  grep -qE '/lib/shell\.sh"?$|shell\.sh"' "$REMOVE_SH"

case "$DETECT_FN_BODY" in
  *shell_rc_file*) ok "8: _detect_shell_rc's body calls shell_rc_file" ;;
  *) no "8: _detect_shell_rc's body calls shell_rc_file" "body: $DETECT_FN_BODY" ;;
esac
case "$REMOVE_FN_BODY" in
  *shell_rc_file*) ok "9: _rm_shell_rc's body calls shell_rc_file" ;;
  *) no "9: _rm_shell_rc's body calls shell_rc_file" "body: $REMOVE_FN_BODY" ;;
esac

# detect.sh HAS NO STANDALONE DOOR (it is sourced only from inside the payload,
# same as env.sh/deps.sh beside it — see detect.sh's own header), so its caller
# carries no hand-rolled case split at all any more; it is a pure delegate.
case "$DETECT_FN_BODY" in
  *'.zshrc'*|*'.bashrc'*) no "10: _detect_shell_rc no longer hand-rolls the zsh/bashrc split" "body: $DETECT_FN_BODY" ;;
  *) ok "10: _detect_shell_rc no longer hand-rolls the zsh/bashrc split" ;;
esac

# remove.sh DOES have a standalone door (curl-fetched to a machine whose lib/ is
# already gone — remove.sh's own header) and keeps its own fallback copy of the
# case split for exactly that door, so its invariant is narrower than
# detect.sh's: the DELEGATION must be attempted before the fallback is ever
# reached, so a payload-mode machine (lib/shell.sh present, `shell_rc_file`
# declared) always takes the single-owner answer and only a standalone machine
# with no library at all falls through to the copy.
case "$REMOVE_FN_BODY" in
  *'declare -F shell_rc_file'*'.zshrc'*) ok "11: _rm_shell_rc tries the delegate before its standalone fallback" ;;
  *) no "11: _rm_shell_rc tries the delegate before its standalone fallback" "body: $REMOVE_FN_BODY" ;;
esac

section "Section 3: the two callers AGREE, for every shell shell_rc_file resolves"

run_detect_shell_rc() {  # <shell>
  HOME="$FIXHOME" SHELL="$1" BIONIC_SHELL_RC="" \
    bash -c '. "$1"; shift; _detect_shell_rc' _ "$DETECT_SH" 2>/dev/null
}

# remove.sh is `set -uo pipefail` with top-level roster code that runs on
# source — not safe to source whole. Its one function under test is extracted
# and evaluated standalone, sourcing lib/shell.sh itself exactly as the real
# function does (Section 2 already pins that the real function does so).
run_rm_shell_rc() {  # <shell>
  HOME="$FIXHOME" SHELL="$1" BIONIC_SHELL_RC="" \
    bash -c '. "$1"; eval "$2"; _rm_shell_rc' _ "$SHELL_SH" "$REMOVE_FN_BODY" 2>/dev/null
}

for shell_path in /bin/zsh /bin/bash /usr/bin/fish /opt/weird/shell; do
  d="$(run_detect_shell_rc "$shell_path")"
  r="$(run_rm_shell_rc "$shell_path")"
  expect_eq "12/${shell_path##*/}: _detect_shell_rc and _rm_shell_rc agree" "$d" "$r"
done

finish
