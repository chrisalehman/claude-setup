#!/bin/bash
# tests/session.test.sh — payload/scripts/lib/session.sh (bionic 1.4.0 wave,
# spec AC-2, plan slice L-SESSION).
#
# WHAT THIS SUITE OWNS. The one library function `session_id`: the
# environment value (`$CLAUDE_CODE_SESSION_ID`) is primary, a payload sid
# passed as `$1` is a witness only. Agreement between the two is silent;
# divergence prints exactly one stderr line naming both values and still
# returns the env value; an unset env falls back to the payload with its own
# one-line notice; both absent is a hard failure (exit 1, one stderr line).
#
# Usage: bash tests/session.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

SESSION_SH="${BIONIC_SCRIPTS_DIR}/payload/scripts/lib/session.sh"

# Call session_id in a scrubbed environment.
#   session_call <env-sid|__UNSET__> <payload-sid>
# Sets SC_STDOUT, SC_STDERR, SC_STATUS.
session_call() {
  local envsid="$1" paysid="$2"
  local out_f err_f
  out_f="$(mktemp)"; err_f="$(mktemp)"
  if [ "$envsid" = "__UNSET__" ]; then
    env -i bash -c '. "$1"; session_id "$2"' _ "$SESSION_SH" "$paysid" >"$out_f" 2>"$err_f"
  else
    env -i CLAUDE_CODE_SESSION_ID="$envsid" bash -c '. "$1"; session_id "$2"' _ "$SESSION_SH" "$paysid" >"$out_f" 2>"$err_f"
  fi
  SC_STATUS=$?
  SC_STDOUT="$(cat "$out_f")"
  SC_STDERR="$(cat "$err_f")"
  rm -f "$out_f" "$err_f"
}

section "Group 0: sourcing the library is silent and has no side effects"

SOURCE_OUT="$(env -i bash -c '. "$1"' _ "$SESSION_SH" 2>&1)"
expect_eq "sourcing session.sh prints nothing" "" "$SOURCE_OUT"

section "Group 1: env and payload agree — silent, prints env"

session_call "sess-aaa" "sess-aaa"
expect_eq "agreement: stdout is the (shared) env value" "sess-aaa" "$SC_STDOUT"
expect_eq "agreement: no stderr" "" "$SC_STDERR"
expect_eq "agreement: exit 0" "0" "$SC_STATUS"

section "Group 2: env and payload diverge — one stderr line, prints env"

session_call "sess-env" "sess-pay"
expect_eq "divergence: stdout is the env value" "sess-env" "$SC_STDOUT"
expect_eq "divergence: exactly one stderr line naming both, env wins" \
  "session-id: payload sess-pay ≠ env sess-env — using env" "$SC_STDERR"
expect_eq "divergence: exit 0" "0" "$SC_STATUS"

section "Group 3: env unset, payload present — prints payload, one stderr line"

session_call "__UNSET__" "sess-pay"
expect_eq "env-unset: stdout is the payload value" "sess-pay" "$SC_STDOUT"
expect_eq "env-unset: one stderr line" \
  "session-id: env unset — using payload" "$SC_STDERR"
expect_eq "env-unset: exit 0" "0" "$SC_STATUS"

section "Group 4: both absent — exit 1, one stderr line, no stdout"

session_call "__UNSET__" ""
expect_eq "both-absent: no stdout" "" "$SC_STDOUT"
expect_eq "both-absent: one stderr line" \
  "session-id: no session id in env or payload" "$SC_STDERR"
expect_eq "both-absent: exit 1" "1" "$SC_STATUS"

finish
