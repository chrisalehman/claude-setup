#!/bin/bash
# tests/interpreter-pin.test.sh — the interpreter pin, the environment stamp, and the
# runner's stderr-strict arm (wave-01 verification-cannot-lie, slice S2; spec AC-1, AC-2,
# AC-3, AC-10, and the runner half of AC-14).
#
# WHAT THE PIN IS. Every payload script and hook pins `#!/bin/bash` — bash 3.2 on a Mac —
# and the CLI runs a hook by path, so the shebang chooses the interpreter. The suites,
# though, type `bash "$HOOK"`, which picks up whatever `bash` is first on PATH: Homebrew
# 5.3 on this machine. A green run the default way therefore proved the payload under an
# interpreter it is never executed with (ADR-001, "one interpreter: the shebang is the
# contract"). `tests/run.sh` now launches every child with a one-entry LAUNCH DIRECTORY
# first on PATH whose only entry is `bash -> /bin/bash`; the rest of PATH is the caller's
# own, so `jq`, `git` and `claude` still resolve exactly where they did.
#
# ITS NAME IS "THE INTERPRETER PIN", never "the PATH shim" (design ledger now-4: v1 wave 0
# deletes an unrelated omnigent piece by that name, and two mechanisms sharing one name is
# how a reader ends up reading the wrong file).
#
# WHY A SUITE OF ITS OWN. A verification instrument must be proven to CATCH what it exists
# to catch. §3 plants two constructs that are MEASURED divergences between 3.2 and 5.x —
# not guesses:
#
#   (a) the quoted-`$( )`-inside-`case` leak: 3.2's parser ends the command substitution at
#       the first `)` of a `case` pattern and leaks the remainder as literal text, so the
#       function returns garbage and exits 0 — a green for the wrong reason;
#   (b) the here-string temporary-assignment divergence (research-code-map §4.e, measured
#       there for the first time): in `VAR=x cmd <<< "$(f)"` the temporary assignment IS in
#       effect while the here-string's command substitution expands under 3.2 and is NOT
#       under 5.3, so `f` runs under the stripped PATH and the here-string arrives empty.
#       This is the live defect behind `jq: command not found` in the recorded 3.2 baseline
#       and behind tests/patrol-revive.test.sh:264.
#
# Each planted suite asserts the 5.x answer. Driven through the pinned runner both go RED;
# run directly under the machine's other interpreter both go GREEN. A pin that stopped
# pinning would show up here as two suites that quietly started passing.
#
# THE SECOND INTERPRETER IS DISCOVERED, NOT ASSUMED. Rows that need a bash whose version
# differs from /bin/bash's are SKIPPED, loudly and by name, on a host that has only one —
# a Linux box where /bin/bash is 5.x has nothing to compare against, and a row that cannot
# be driven must say so rather than pass.
#
# HERMETIC. Every runner drive below is against a SCRATCH TREE (the shipped tests/run.sh,
# byte for byte, over a tests/ directory holding only this suite's own probe files — the
# roster is derived from the directory, so nothing needs rewriting) under this suite's own
# mktemp root, with the pressure ring and clock pinned. Nothing here runs the real roster —
# that would recurse into this very file.
#
# Usage: bash tests/interpreter-pin.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
REPO="$BIONIC_SCRIPTS_DIR"

SKIPPED=0
skip() { SKIPPED=$((SKIPPED + 1)); echo "SKIP: $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/interpreter-pin-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

SYS_BASH="/bin/bash"
SYS_VER="$("$SYS_BASH" -c 'echo "$BASH_VERSION"' 2>/dev/null)"

# The other interpreter, if this host has one: any bash whose $BASH_VERSION differs from
# /bin/bash's. Homebrew's is looked at first because that is what this machine has; the
# rest of the search is whatever `type -ap` can see.
find_alt_bash() {
  local c v
  for c in /opt/homebrew/bin/bash /usr/local/bin/bash $(type -ap bash 2>/dev/null); do
    [ -x "$c" ] || continue
    v="$("$c" -c 'echo "$BASH_VERSION"' 2>/dev/null)"
    [ -n "$v" ] || continue
    if [ "$v" != "$SYS_VER" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}
ALT_BASH="$(find_alt_bash)" || ALT_BASH=""
ALT_VER=""
ALT_DIR="$TMPROOT/alt-bin"
mkdir -p "$ALT_DIR"
if [ -n "$ALT_BASH" ]; then
  ALT_VER="$("$ALT_BASH" -c 'echo "$BASH_VERSION"')"
  ln -sf "$ALT_BASH" "$ALT_DIR/bash"
fi

echo "=== interpreter-pin: /bin/bash is ${SYS_VER:-unknown}; other interpreter: ${ALT_BASH:-none} ${ALT_VER}"
echo ""

# ── the scratch tree ─────────────────────────────────────────────────────────
# The shipped runner, byte for byte. Same layout the runner resolves against: it derives
# $REPO from its own path and sources $REPO/payload/scripts/lib/resources.sh, and
# tests/lib/resolve-roots.sh sits beside it.
#
# THE ROSTER IS THE TREE (fixit 1.5.1). The runner derives its roster from the tests/
# directory it is run in, so a drive's roster is exactly the probe files planted below
# and no rewrite is needed — the copy is the shipped file, unedited. These trees carry
# no tests/lib/assert.sh, so the roster wall's framework half is inert here and the
# probes are raw interpreter probes rather than framework clients, which is what they
# have to be: §3 runs two of them directly under a second interpreter.
mk_tree() {  # mk_tree <dir>
  local dir="$1"
  mkdir -p "$dir/tests/lib" "$dir/payload/scripts/lib"
  cp "$REPO/tests/run.sh" "$dir/tests/run.sh"
  cp "$REPO/tests/lib/resolve-roots.sh" "$dir/tests/lib/resolve-roots.sh"
  cp "$REPO"/payload/scripts/lib/*.sh "$dir/payload/scripts/lib/" 2>/dev/null
}

# drive <tree> <mode|""> — run the scratch runner with the ALTERNATE interpreter first on
# PATH (the hostile case: a foreign `bash` is what `bash tests/…` would otherwise pick),
# leaving DRV_OUT and DRV_RC behind. The pin marker is unset first: this very suite may be
# running under the real runner, which exports it, and an inherited marker would make the
# hand-run rows below vacuous.
DRV_OUT=""; DRV_RC=0
drive() {
  local tree="$1" mode="${2:-}"
  DRV_OUT="$( cd "$tree" && \
    unset BIONIC_TEST_INTERPRETER_PINNED && \
    PATH="$ALT_DIR:$PATH" \
    BIONIC_PRESSURE_RING="$TMPROOT/ring" \
    BIONIC_NOW_EPOCH="1700000000" \
    BIONIC_TEST_JOBS_CEILING="2" \
    BIONIC_PROBE_OUT="$TMPROOT/probe.out" \
    bash tests/run.sh ${mode:+"$mode"} 2>&1 )"
  DRV_RC=$?
}

section "§1 the pin: every child of the runner is /bin/bash, and the rest of PATH is intact (AC-1)"
#
# The probe is a real suite in the roster. It cannot report through stdout — the runner
# prints a passing suite's captured output nowhere — so it writes the facts it reads to
# $BIONIC_PROBE_OUT, which the runner passes through by inheriting this suite's environment.

PROBE_TREE="$TMPROOT/probe-tree"
mk_tree "$PROBE_TREE"
cat > "$PROBE_TREE/tests/probe.test.sh" <<'PROBE_EOF'
#!/bin/bash
{ echo "BASH_VERSION=$BASH_VERSION"
  echo "bash=$(command -v bash 2>/dev/null || echo MISSING)"
  echo "git=$(command -v git 2>/dev/null || echo MISSING)"
  echo "first_path_entry=${PATH%%:*}"
  echo "bash_target=$(readlink "$(command -v bash 2>/dev/null)" 2>/dev/null || echo NONE)"
} > "$BIONIC_PROBE_OUT"
exit 0
PROBE_EOF

HOST_GIT="$(command -v git 2>/dev/null || echo MISSING)"

for MODE in "--serial" ""; do
  MODE_NAME="parallel"; [ -n "$MODE" ] && MODE_NAME="serial"
  : > "$TMPROOT/probe.out"
  drive "$PROBE_TREE" "$MODE"
  P_OUT="$(cat "$TMPROOT/probe.out" 2>/dev/null)"
  P_VER="$(printf '%s\n' "$P_OUT" | sed -n 's/^BASH_VERSION=//p')"
  P_BASH="$(printf '%s\n' "$P_OUT" | sed -n 's/^bash=//p')"
  P_GIT="$(printf '%s\n' "$P_OUT" | sed -n 's/^git=//p')"
  P_FIRST="$(printf '%s\n' "$P_OUT" | sed -n 's/^first_path_entry=//p')"

  expect_eq "1.1 ($MODE_NAME) the probe suite ran at all (not vacuous)" "0" "$DRV_RC"
  expect_eq "1.2 ($MODE_NAME) the suite's interpreter is the system one" "$SYS_VER" "$P_VER"
  expect_eq "1.3 ($MODE_NAME) \`bash\` inside a suite resolves through the launch directory" \
    "$P_FIRST/bash" "$P_BASH"
  if [ -n "$ALT_BASH" ]; then
    expect_ne "1.3b ($MODE_NAME) …a directory the RUNNER put ahead of the caller's own PATH" \
      "$ALT_DIR" "$P_FIRST"
  else
    skip "1.3b ($MODE_NAME) the launch directory is the runner's, not the caller's" "this host has only one bash"
  fi
  expect_eq "1.4 ($MODE_NAME) …and that entry is /bin/bash" "$SYS_BASH" \
    "$(printf '%s\n' "$P_OUT" | sed -n 's/^bash_target=//p')"
  expect_eq "1.5 ($MODE_NAME) the rest of PATH is the caller's own: git resolves where it did" \
    "$HOST_GIT" "$P_GIT"
  # NON-VACUITY: the drive really did put a foreign interpreter first, so 1.2 is the pin
  # answering and not "there is only one bash on this machine".
  if [ -n "$ALT_BASH" ]; then
    expect_ne "1.6 ($MODE_NAME) …and the interpreter the drive offered was NOT the system one" \
      "$SYS_VER" "$ALT_VER"
  else
    skip "1.6 ($MODE_NAME) the drive offered a foreign interpreter" "this host has only one bash"
  fi
done
echo ""

section "§2 hand-run parity: a suite invoked by hand re-execs once under /bin/bash (AC-2)"
#
# The seam every suite already sources does the work, so a suite typed at a prompt under
# another interpreter lands on the same one the runner would have given it. The guard is the
# RUNNING INTERPRETER, not a marker: after `exec /bin/bash "$0"`, `$BASH` is `/bin/bash`, so
# the re-exec happens exactly once and can never loop (critic K-4, Step 6).

HAND="$TMPROOT/hand.test.sh"
{ printf '#!/bin/bash\n'
  printf 'echo start >> "$HAND_COUNT"\n'
  printf '. "%s/tests/lib/resolve-roots.sh"\n' "$REPO"
  printf 'echo "BASH_VERSION=$BASH_VERSION" > "$HAND_OUT"\n'
  printf 'echo "argv=$*" >> "$HAND_OUT"\n'
  printf 'echo "roots=$BIONIC_HOOKS_DIR" >> "$HAND_OUT"\n'
} > "$HAND"
chmod +x "$HAND"

hand_run() {  # hand_run <interpreter> [marker] — leaves HAND_VER / HAND_STARTS / HAND_ARGV
  : > "$TMPROOT/hand.count"; : > "$TMPROOT/hand.out"
  ( if [ -n "${2:-}" ]; then
      BIONIC_TEST_INTERPRETER_PINNED="$2"; export BIONIC_TEST_INTERPRETER_PINNED
    else
      unset BIONIC_TEST_INTERPRETER_PINNED
    fi
    PATH="$ALT_DIR:$PATH" \
    HAND_COUNT="$TMPROOT/hand.count" HAND_OUT="$TMPROOT/hand.out" \
    "$1" "$HAND" one two ) >/dev/null 2>&1
  HAND_VER="$(sed -n 's/^BASH_VERSION=//p' "$TMPROOT/hand.out")"
  HAND_ARGV="$(sed -n 's/^argv=//p' "$TMPROOT/hand.out")"
  HAND_ROOTS="$(sed -n 's/^roots=//p' "$TMPROOT/hand.out")"
  HAND_STARTS="$(wc -l < "$TMPROOT/hand.count" | tr -d ' ')"
}

if [ -n "$ALT_BASH" ]; then
  hand_run "$ALT_BASH"
  expect_eq "2.1 a hand-run suite under the other interpreter reports the system version" \
    "$SYS_VER" "$HAND_VER"
  expect_eq "2.2 …by re-executing exactly once (the marker cannot loop)" "2" "$HAND_STARTS"
  expect_eq "2.3 …with its arguments intact across the re-exec" "one two" "$HAND_ARGV"
  expect_eq "2.4 …and the seam still answers the question it exists for" \
    "$REPO/hooks" "$HAND_ROOTS"

  # --- THE MARKER IS NOT THE TEST (critic K-4) ------------------------------
  # `tests/run.sh` exports BIONIC_TEST_INTERPRETER_PINNED to every descendant of
  # a run, so a hand-run started from inside a suite, a debugger, or a shell that
  # had once run the runner INHERITS it. While the guard trusted that marker the
  # pin was skipped and nothing said so: the suite reported bash 5.3 and there is
  # no stamp on the hand-run path to record which interpreter made the log.
  hand_run "$ALT_BASH" "1"
  expect_eq "2.4a an inherited pin marker does not defeat the pin" "$SYS_VER" "$HAND_VER"
  expect_eq "2.4b …and the re-exec still happens exactly once" "2" "$HAND_STARTS"
  expect_eq "2.4c …with its arguments still intact" "one two" "$HAND_ARGV"
  # PAIRED, so 2.4a is not a row that would pass under any interpreter: the same
  # marker with the SYSTEM bash must not provoke a second start.
  hand_run "$SYS_BASH" "1"
  expect_eq "2.4d …and a suite already under /bin/bash still does not re-exec" "1" "$HAND_STARTS"
else
  skip "2.1–2.4d hand-run parity under a foreign interpreter" "this host has only one bash"
fi

hand_run "$SYS_BASH"
expect_eq "2.5 a hand-run suite ALREADY under /bin/bash does not re-exec" "1" "$HAND_STARTS"
expect_eq "2.6 …and reports the system version" "$SYS_VER" "$HAND_VER"
echo ""

section "§3 the planted 3.2 incompatibilities: the pin catches what it exists to catch (AC-10)"

PLANT_TREE="$TMPROOT/plant-tree"
mk_tree "$PLANT_TREE"

# (a) 3.2 ends the command substitution at the first `)` of the case pattern and leaks the
#     rest as text. Measured: 3.2.57 prints a parse error and garbage, exit 0; 5.3.15 prints A.
#
#     THE CONSTRUCT IS ASSEMBLED, NOT TYPED. tests/cross-gate-agreement.test.sh §BP forbids
#     the one-line `case` inside a command substitution anywhere under tests/ — the idiom is
#     banned in this tree precisely because `bash -n` cannot see it — and that lint reads
#     source text, so a planted copy typed literally here would trip the rule it is meant to
#     demonstrate. The same file's own mutation arm builds its copy through printf for the
#     same reason; this follows it.
PLANT_DOLLAR='$'
{ printf '#!/bin/bash\n'
  printf 'f() { echo "%s(case "%s1" in a) echo A;; *) echo other;; esac)"; }\n' \
    "$PLANT_DOLLAR" "$PLANT_DOLLAR"
  cat <<'PLANT_A_EOF'
got="$(f a 2>/dev/null)"
if [ "$got" = "A" ]; then echo "planted-case-leak: OK"; exit 0; fi
echo "planted-case-leak: expected [A], got [$got]"
exit 1
PLANT_A_EOF
} > "$PLANT_TREE/tests/planted-case-leak.test.sh"

# (b) the here-string temporary-assignment divergence (research-code-map §4.e). Hermetic:
#     the command the here-string's substitution needs is this file's own marker script, so
#     the row does not depend on jq being installed.
cat > "$PLANT_TREE/tests/planted-herestring.test.sh" <<'PLANT_B_EOF'
#!/bin/bash
BIN="$(mktemp -d)"; STRIP="$(mktemp -d)"
trap 'rm -rf "$BIN" "$STRIP"' EXIT
printf '#!/bin/bash\necho MARKER-OK\n' > "$BIN/probe_marker"; chmod +x "$BIN/probe_marker"
PATH="$BIN:$PATH"; export PATH
f() { probe_marker; }
for b in bash cat; do ln -sf "$(command -v "$b")" "$STRIP/$b"; done
got="$(PATH="$STRIP" cat <<< "$(f)" 2>/dev/null)"
if [ "$got" = "MARKER-OK" ]; then echo "planted-herestring: OK"; exit 0; fi
echo "planted-herestring: expected [MARKER-OK], got [$got]"
exit 1
PLANT_B_EOF

drive "$PLANT_TREE" "--serial"
expect_eq "3.1 the runner fails the run when a planted incompatibility is present" "1" "$DRV_RC"
expect_contains "3.2 …and reports both planted suites red" "Gating: 0 passed, 2 failed" "$DRV_OUT"
expect_contains "3.3 the quoted-\$( ) case leak is named" "- planted-case-leak.test.sh" "$DRV_OUT"
expect_contains "3.4 the here-string divergence is named" "- planted-herestring.test.sh" "$DRV_OUT"

# …and the same two files, unchanged, under the other interpreter: green. The planted
# constructs are 3.2/5.x DIVERGENCES, not broken scripts — which is the whole claim.
if [ -n "$ALT_BASH" ]; then
  ALT_A_OUT="$("$ALT_BASH" "$PLANT_TREE/tests/planted-case-leak.test.sh" 2>&1)"; ALT_A_RC=$?
  ALT_B_OUT="$("$ALT_BASH" "$PLANT_TREE/tests/planted-herestring.test.sh" 2>&1)"; ALT_B_RC=$?
  expect_eq "3.5 the case-leak file is GREEN under the other interpreter" "0" "$ALT_A_RC"
  expect_contains "3.6 …reporting the 5.x answer" "planted-case-leak: OK" "$ALT_A_OUT"
  expect_eq "3.7 the here-string file is GREEN under the other interpreter" "0" "$ALT_B_RC"
  expect_contains "3.8 …reporting the 5.x answer" "planted-herestring: OK" "$ALT_B_OUT"
else
  skip "3.5–3.8 the planted files are green under the other interpreter" "this host has only one bash"
fi
echo ""

section "§4 the environment stamp: the run says which environment it ran in (AC-3)"
#
# One line, twice: in the header, where a reader meets the run, and beside `Gating:`, where
# they read its verdict — a tail -5 of a captured log carries the environment with it.

drive "$PROBE_TREE" "--serial"
STAMPS="$(printf '%s\n' "$DRV_OUT" | grep -c '^env: ')"
expect_eq "4.1 the stamp is printed exactly twice" "2" "$STAMPS"
expect_regex "4.2 …with all four fields, in order" \
  '^env: os=[a-z]+ bash=[^ ]+ locale=[^ ]+ path=/' "$DRV_OUT"
STAMP_LINE="$(printf '%s\n' "$DRV_OUT" | grep '^env: ' | head -1)"
STAMP_TAIL="$(printf '%s\n' "$DRV_OUT" | grep '^env: ' | tail -1)"
expect_eq "4.3 the header stamp and the Gating stamp are the same line" "yes" \
  "$( [ -n "$STAMP_LINE" ] && [ "$STAMP_LINE" = "$STAMP_TAIL" ] && echo yes || echo no )"
expect_contains "4.4 the version it names is the interpreter the suites actually got" \
  "bash=$SYS_VER" "$STAMP_LINE"
expect_eq "4.5 the os field is this machine's" \
  "$(uname -s | tr '[:upper:]' '[:lower:]')" \
  "$(printf '%s\n' "$STAMP_LINE" | sed -n 's/^env: os=\([^ ]*\).*/\1/p')"
expect_eq "4.6 the locale field is the one the run inherited" \
  "${LC_ALL:-${LANG:-unset}}" \
  "$(printf '%s\n' "$STAMP_LINE" | sed -n 's/.* locale=\([^ ]*\).*/\1/p')"
# The path field names the launch directory the pin was built in — the same directory the
# probe suite saw first on its own PATH, so the stamp is reporting the mechanism and not a
# label somebody typed.
STAMP_PATH="$(printf '%s\n' "$STAMP_LINE" | sed -n 's/.* path=\(.*\)$/\1/p')"
expect_eq "4.7 the path field is the launch directory the suites were given" \
  "$(sed -n 's/^first_path_entry=//p' "$TMPROOT/probe.out")" "$STAMP_PATH"
# The Gating line still says what it always said, in the shape every reader and every
# close-out log greps for.
expect_contains "4.8 the Gating line is unchanged in shape" "Gating: 1 passed, 0 failed" "$DRV_OUT"
echo ""

section "§5 stderr-strict: a green suite that lost a command is red (the runner half of AC-14)"
#
# `set -uo pipefail` with no `-e` is this repo's suite convention, so a call to a helper
# that vanished is a `command not found` on stderr and nothing else — the suite finishes,
# its own tally never notices, and the runner prints ✓ PASS. The runner now reads the
# captured output of a suite that exited 0 and refuses it if the interpreter told it a
# command was missing.
#
# THE FALSE-POSITIVE GUARD is the second suite: several suites in the real roster PRINT the
# phrase in an assertion label (tests/dispatch-preflight.test.sh:771 asserts a fix command
# produces no 'command not found'). The arm matches the interpreter's own diagnostic shape,
# not the words, so a suite that merely quotes them stays green.

STRICT_TREE="$TMPROOT/strict-tree"
mk_tree "$STRICT_TREE"
cat > "$STRICT_TREE/tests/noisy.test.sh" <<'NOISY_EOF'
#!/bin/bash
set -uo pipefail
echo "PASS: 1: a helper that still exists"
bionic_helper_that_vanished "argument"
echo "PASS: 2: and the suite finished, none the wiser"
exit 0
NOISY_EOF
cat > "$STRICT_TREE/tests/quoting.test.sh" <<'QUOTING_EOF'
#!/bin/bash
set -uo pipefail
echo "PASS: fix-command run produces no 'command not found'"
echo "PASS: and no 'command not found' anywhere else either"
exit 0
QUOTING_EOF

drive "$STRICT_TREE" "--serial"
expect_eq "5.1 the run fails when a green suite lost a command" "1" "$DRV_RC"
expect_contains "5.2 …and the tally counts it failed" "Gating: 1 passed, 1 failed" "$DRV_OUT"
expect_contains "5.3 …naming the suite and why" "- noisy.test.sh" "$DRV_OUT"
expect_contains "5.4 …in words that send the reader to the missing command" "command not found" "$DRV_OUT"
expect_regex "5.5 a suite that only QUOTES the phrase stays green" \
  '^  quoting\.test\.sh +✓ PASS' "$DRV_OUT"
echo ""

echo "interpreter-pin: ${SKIPPED} skipped (see SKIP: rows above)"
finish
