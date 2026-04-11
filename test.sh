#!/usr/bin/env bash
#
# test.sh
# Runs all test suites. Exit code is non-zero if any suite fails.
#
# Usage: ./test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

run_suite() {
  local file="$1"
  echo ""
  echo "── $(basename "$file") ──"
  if bash "$file"; then
    :
  else
    FAILED=$((FAILED + 1))
  fi
}

run_suite "${SCRIPT_DIR}/hooks/protect-main.test.sh"
run_suite "${SCRIPT_DIR}/hooks/protect-database.test.sh"
run_suite "${SCRIPT_DIR}/hooks/memory-update.test.sh"
run_suite "${SCRIPT_DIR}/hooks/memory-cleanup.test.sh"
run_suite "${SCRIPT_DIR}/tests/scripts.test.sh"
run_suite "${SCRIPT_DIR}/lib/platform.test.sh"

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: ${FAILED} suite(s) had failures"
  exit 1
else
  echo "All suites passed ✓"
fi
