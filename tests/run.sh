#!/usr/bin/env bash
#
# tests/run.sh — one-command test runner for bionic.
#
# No CI needed: just `bash tests/run.sh`. Every gating suite is hermetic — no
# network, no auth, no daemon — and every one of them runs on every invocation.
#
#   GATING suites (set the exit code — must be green):
#     every `tests/*.test.sh`, sorted, read at run time — LOCATION IS THE
#                                      DECLARATION (fixit 1.5.1, D-1). A file in
#                                      tests/ gates because it is there: a suite
#                                      dropped in today runs on the very next
#                                      invocation, with no edit anywhere. There
#                                      is no opt-out, no skip list and no second
#                                      roster; a protocol meant to be run by hand
#                                      lives in `.bionic/tests/`, not here. THE
#                                      ROSTER WALL below refuses a glob match
#                                      that is not a suite, and an empty tests/
#                                      is refused rather than reported green over
#                                      nothing. (This replaced fifty-five
#                                      hand-listed `run` lines, where a suite the
#                                      list forgot silently never ran at all.)
#
# There is no conditional suite and no skip category. The last one was
# tests/bootstrap-e2e-docker.sh, which ran the whole of claude-bootstrap.sh in a
# container; the installer was deleted in epic-17 W5 (4/6) and the suite went
# with it (W5 audit F-3) — it had been green only because the Docker daemon was
# down, and would have gone red the moment a contributor ran it daemon-up.
#
# ── TWO MODES, ONE ROSTER (epic-17 W7 S10, spec AC-16) ───────────────────────
#
#   bash tests/run.sh              width from the machine's own pressure rung
#   bash tests/run.sh --serial     one at a time, in roster order
#   bash tests/run.sh --dry-run    print the job width and exit, run nothing
#   BIONIC_TEST_JOBS_CEILING=8 bash tests/run.sh   the ceiling the rung reads against
#   BIONIC_TEST_TIMING=t.tsv bash tests/run.sh   also write <label>TAB<seconds>
#
# The derived roster below is the roster in BOTH modes — the directory is the
# only place a suite is named, and neither mode has a list of its own. In
# --serial each entry
# runs where it stands; by default each entry enqueues, the queue drains through
# xargs -P, and the results print afterwards in roster order. Same labels, same
# captured-output blocks, same `Gating:` line, same exit status: a mode is a
# scheduling choice and nothing else.
#
# THE WIDTH IS READ, NOT SET (wave-roster-lifecycle S9, spec AC-15, R4). A run
# samples the machine's pressure once and reads `pressure_level` (resources.sh)
# over the ring against a ceiling — `BIONIC_TEST_JOBS_CEILING`, falling back to
# the old default of 8 — so a run started while the machine is under strain gets
# a narrower width automatically instead of a human having to notice and set
# `BIONIC_TEST_JOBS` by hand. `BIONIC_TEST_JOBS` is retired as an input for
# exactly that reason: a literal a caller fixes cannot answer "how busy is the
# machine right now". A caller who still sets it is told once, on stderr, and
# ignored rather than silently overridden.
#
# WHY IT IS SAFE TO RUN THEM AT ONCE. Not by assumption — by audit. Epic-17 W7 S8
# read every suite in this roster for fixture root, every write outside it and every
# read of machine state another suite could mutate, and found no shared write, no
# shared lock, no fixed port and no fixed /tmp name: every suite that touches disk
# does so under its own `mktemp -d`, and the one place many of them read concurrently
# (this checkout, via tests/lib/resolve-roots.sh) has no writer in the roster at all.
# THE AUDIT IS TWO FILES, and a maintainer needs both: S8 read the 44 suites that
# existed when it ran (`.bionic/docs/record/epic-17-w7/s8-isolation-audit.md`), and
# S8b read the one the same wave added, env.test.sh, which appears nowhere in the
# first file (`.bionic/docs/record/epic-17-w7/s8b-isolation-delta.md`). Neither file
# covers the roster as it stands now: epic-18 wave-03 deleted nineteen of those
# suites on the reliability ruling (commit 8582861), one of the nineteen
# (fresh-home.test.sh) was later revived, rc-item.test.sh was added new, and
# epic-19 wave-01 added doctor-patrol.test.sh (F3) and command-relay.test.sh
# (F4), bionic 1.3.2 added git-argv, cmd-class and patrol-marker, and wave-01
# verification-cannot-lie added four more. A maintainer re-derives the roster
# rather than trusting a number in a comment — `ls tests/*.test.sh` IS the
# roster now, so the count is never anywhere else to go stale. Neither audit file
# re-covers what changed since
# it ran; a suite added or restored after S8b carries no isolation proof
# beyond its own file. A suite that writes outside its own mktemp root breaks this
# premise, and a derived roster picks that suite up the moment the file lands, so
# WRITING the suite is the moment to check its isolation — and to extend the
# audit, since neither existing file can cover a suite written after it.
#
# WHY EIGHT (FOUR AT MEASUREMENT TIME) AND NOT FORTY-FIVE. Measured, not guessed. When
# seven of these slices each ran a full suite concurrently on one machine, free memory
# fell to ~188 MB and the kernel SIGKILLed a suite mid-run (W7 assumption A4.2). Four was
# the width with headroom on that measurement; the default was raised to eight on
# 2026-08-22 (ef23f75, user's call) and `BIONIC_TEST_JOBS_CEILING` is there for a machine
# with less or more. NOT `BIONIC_TEST_JOBS`, which is retired as an input — line 51 above
# says so and line 249 prints it at runtime.
#
# EVERY SUITE IS A CLIENT OF ONE FRAMEWORK (wave-01 S10, spec AC-12). Before a
# roster line is launched its source is read, and a suite that defines a name
# tests/lib/assert.sh owns — or its own PASS/FAIL/TOTAL counters — at column 0 is
# REFUSED, named, and counted failed — and so is a suite that does not adopt the
# framework at all (one that sources it nowhere, or never calls `finish`). The
# rule, its two exemptions (an indented or subshell-scoped redefinition, and a
# definition inside a heredoc body) and the scanner all live in the framework;
# see `_tf_adoption_refusal` there and THE ADOPTION WALL below.
#
# WHY A SIGNAL DEATH IS NOT A FAILED ASSERTION. That same kill was reported as a
# plain ✗ FAIL, which reads as "this suite's assertions failed" and sends the
# reader hunting a defect that is not there. A suite that dies by signal now says
# so and names the signal. It still counts as failed and still fails the run —
# what changed is that the report is true.
#
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# ── one suite, in its own process ────────────────────────────────────────────
# `run.sh --one <label>` is not a mode anyone types: it is what xargs forks for
# each queued suite. It looks its command up in the queue by label, captures the
# suite's output to <label>.out and leaves the exit status in <label>.rc and the
# elapsed seconds in <label>.sec beside it.
#
# IT ALWAYS EXITS 0. A suite's verdict travels in its .rc file, never in this
# process's status — xargs abandons a queue when a child exits nonzero, so a
# worker that forwarded a red suite's status would stop the run at the first red
# suite and leave the rest unreported.
if [ "${1:-}" = "--one" ]; then
  _one_label="${2:?run.sh --one needs a suite label}"
  _one_queue="${BIONIC_TEST_QUEUE:?run.sh --one is an internal mode}"
  _one_work="${BIONIC_TEST_WORK:?run.sh --one is an internal mode}"
  _one_cmd="$(awk -F'\t' -v l="$_one_label" '$1 == l { print $2; exit }' "$_one_queue")"
  _one_start="$(date +%s)"
  # Deliberately unquoted. The queued string is a roster line's own words
  # (`bash tests/foo.test.sh`), written in this file — never outside input.
  # shellcheck disable=SC2086
  $_one_cmd >"$_one_work/${_one_label}.out" 2>&1
  _one_rc=$?
  printf '%s\n' "$_one_rc" >"$_one_work/${_one_label}.rc"
  printf '%s\n' "$(( $(date +%s) - _one_start ))" >"$_one_work/${_one_label}.sec"
  exit 0
fi

# ── argv ─────────────────────────────────────────────────────────────────────
# Refused, not ignored. Before this slice the runner read no argv at all, so
# `bash tests/run.sh --serial` ran the whole roster and looked like it had
# honoured a flag it had never heard of.
SERIAL=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "usage: bash tests/run.sh [--serial] [--dry-run]"
      echo "  --serial            one suite at a time, in roster order"
      echo "  --dry-run           print the job width and exit; run nothing"
      echo "  BIONIC_TEST_JOBS_CEILING  the ceiling the pressure rung reads against (default 8)"
      echo "  BIONIC_TEST_TIMING  a file to append <label>TAB<seconds> to"
      exit 0
      ;;
    *)
      echo "tests/run.sh: unknown option: $1" >&2
      echo "usage: bash tests/run.sh [--serial] [--dry-run]" >&2
      exit 2
      ;;
  esac
  shift
done

# ── THE ROSTER IS THE DIRECTORY (fixit 1.5.1; design D-1, AC-3/AC-4/AC-5) ────
#
# ONE PRODUCER OF "GATING". The glob is expanded HERE and nowhere else in this
# file: the positional parameters below are the roster, and every reader — the
# wall, the count, both schedulers, --dry-run — reads them. Two producers is how
# a census disagrees with itself, which is the whole reason the hand list went.
#
# LOCATION IS THE DECLARATION. There is no opt-out list, no skip variable and no
# retraction input, and adding one would put the census back on two inputs
# (tests/lib/impact.sh globs the same directory and would have to learn the list
# too). Something meant to be run by hand belongs in `.bionic/tests/`.
#
# WHY THE GLOB CANNOT BE TRUSTED BLIND — THE ROSTER WALL. `tests/*.test.sh` is a
# filename pattern, not a promise: a helper, a scratch copy or a half-written
# file dropped in tests/ would be launched as a suite and reported as a failure
# that is really a misplaced file. So every match is read for the shape all the
# suites share (measured 2026-09-06, 55/55 on both halves):
#
#   - its first line is `#!/bin/bash` — the interpreter ADR-001 pins;
#   - it sources the framework at tests/lib/assert.sh.
#
# A match that fails either is REFUSED: the run stops here, non-zero, naming the
# file, before any suite is launched. That is deliberately unlike the per-suite
# adoption wall further down, which fails one suite and lets the rest report:
# this one says the roster itself cannot be trusted, and there is no verdict to
# give until it is.
#
# NO FRAMEWORK, NO FRAMEWORK HALF — SAID OUT LOUD. The second half asks whether a
# file adopts the framework THIS TREE owns, so a tree with no framework can ask
# nothing and the half goes inert, announced on stderr. It is the same honest
# reading the per-suite wall below already ships, and it is the state the
# runner-mechanics suites drive their scratch trees in (interpreter-pin plants
# raw interpreter probes; runner-width and cross-gate §RG copy this file into a
# tree with no framework at all). The shebang half still binds there.
#
# AN EMPTY tests/ IS REFUSED, not run. A run over no suites would print
# `Gating: 0 passed, 0 failed` and exit 0 — a green verdict over nothing, which
# is the exact lie this runner's walls exist to make impossible.
set -- "$REPO"/tests/*.test.sh
if [ "$#" -eq 1 ] && [ ! -e "$1" ]; then set --; fi
if [ "$#" -eq 0 ]; then
  echo "tests/run.sh: no suites under tests/ — the roster is that directory, and nothing in it matches tests/*.test.sh" >&2
  exit 2
fi

ROSTER_FRAMEWORK=yes
if [ ! -r "$REPO/tests/lib/assert.sh" ]; then
  ROSTER_FRAMEWORK=no
  echo "tests/run.sh: no framework at tests/lib/assert.sh — the roster wall's framework half is inert for this run" >&2
fi

_roster_refusals=""
for _roster_file in "$@"; do
  _roster_first=""
  IFS= read -r _roster_first <"$_roster_file" || :
  if [ "$_roster_first" != '#!/bin/bash' ]; then
    _roster_refusals="${_roster_refusals}  tests/${_roster_file##*/}: first line is not #!/bin/bash"$'\n'
    continue
  fi
  [ "$ROSTER_FRAMEWORK" = yes ] || continue
  if ! grep -qE '^[[:space:]]*(\.|source)[[:space:]].*assert\.sh' "$_roster_file"; then
    _roster_refusals="${_roster_refusals}  tests/${_roster_file##*/} does not source the framework at tests/lib/assert.sh"$'\n'
  fi
done
if [ -n "$_roster_refusals" ]; then
  echo "tests/run.sh: the roster wall refuses — tests/*.test.sh matched a file that is not a suite:" >&2
  printf '%s' "$_roster_refusals" >&2
  echo "tests/run.sh: nothing was run. Every gating suite starts with #!/bin/bash and sources tests/lib/assert.sh; a protocol meant to be run by hand belongs in .bionic/tests/." >&2
  exit 2
fi

# ── job width from the machine's own pressure rung (S9, spec AC-15, R4) ──────
# Sample now, then read the median-smoothed rung over the ceiling Step 0 derived
# (BIONIC_TEST_JOBS_CEILING; the old literal default of 8 is the fallback for a
# caller that never named one). BIONIC_TEST_JOBS is retired as an input — see the
# header note above — so a caller who still sets it is told once, on stderr,
# and the value is ignored rather than silently honoured or silently dropped.
#
# A DRY RUN SAMPLES NOTHING (S25, critic K-4 option 2: `--dry-run` is ratified
# user-facing surface, and the obligation that rides with that is that a dry run
# writes nothing). Before this fix the sample below ran unconditionally, so
# `--dry-run` — documented above and at `-h` as "print the job width and exit;
# run nothing" — quietly appended one line to the machine's pressure ring on
# every invocation. The real (non-dry) path below still samples first, exactly
# as AC-15 requires of every consumer; only the dry-run path is exempted, and it
# reads the rung the ring already carries instead.
if [ -n "${BIONIC_TEST_JOBS:-}" ]; then
  echo "tests/run.sh: BIONIC_TEST_JOBS is retired — width now comes from the machine's pressure rung; set BIONIC_TEST_JOBS_CEILING to change the ceiling it reads against. The value you set (${BIONIC_TEST_JOBS}) is ignored." >&2
fi
# shellcheck source=/dev/null
. "$REPO/payload/scripts/lib/resources.sh"
if [ "$DRY_RUN" -eq 0 ]; then
  pressure_sample >/dev/null 2>&1 || :
fi
JOBS="$(pressure_level "${BIONIC_TEST_JOBS_CEILING:-8}")"
# A GARBAGE CEILING FALLS BACK, IT DOES NOT KILL THE RUN (Step-6 review C-6). The `:-8`
# above covers an UNSET variable and nothing else: `pressure_level` refuses a ceiling that
# is not a positive integer with exit 2 and prints nothing on stdout, so `JOBS` came out
# empty and `xargs -P ""` aborted the whole run. This file runs under `set -uo pipefail`
# with no `-e`, so the refusal was silent apart from `pressure_level`'s own stderr line —
# which is still printed, and is the explanation for this fallback.
case "$JOBS" in ''|*[!0-9]*) JOBS=8 ;; esac

if [ "$DRY_RUN" -eq 1 ]; then
  echo "JOBS=$JOBS"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── THE INTERPRETER PIN (wave-01 verification-cannot-lie S2, spec AC-1; ADR-001) ──
#
# WHAT IT FIXES. Every payload script and hook pins `#!/bin/bash` — bash 3.2 on a Mac — and
# the CLI runs a hook BY PATH, so the shebang is what chooses the interpreter in production.
# The roster below, though, TYPES the interpreter: `bash tests/x.test.sh` takes whatever
# `bash` is first on PATH, which on a machine with Homebrew bash is 5.3. A green run the
# default way therefore proved the payload under an interpreter it is never executed with,
# and 3.2-only failures — a bare `"${arr[@]}"` under `set -u`, the here-string divergence
# tests/interpreter-pin.test.sh plants — could not be seen from here at all. ADR-001 settled
# it: one interpreter, the one the shebang names, so each host tests its own production
# interpreter by construction.
#
# HOW. One directory, with one entry in it, first on PATH for the run. `bash` resolves to
# `/bin/bash` for every child of this process — the workers `xargs` forks, the suites they
# run, and anything those suites start — and the REST of PATH is the caller's own, so `jq`,
# `git` and `claude` resolve exactly where they did. It is called THE INTERPRETER PIN and
# never "the PATH shim": v1 wave 0 deletes an unrelated piece by that name, and two
# mechanisms sharing one name is how a reader ends up in the wrong file.
#
# THE MARKER travels with it. tests/lib/resolve-roots.sh — the seam every suite sources —
# re-executes a HAND-run suite under `/bin/bash` so a suite typed at a prompt lands on the
# same interpreter this pin would have given it; the marker tells it that a suite launched
# from here is already pinned and must not re-exec.
if [ ! -x /bin/bash ]; then
  echo "tests/run.sh: /bin/bash is not executable — the interpreter every payload script's shebang names is unrunnable on this host" >&2
  exit 2
fi
PIN="$TMP/pin"
mkdir -p "$PIN"
ln -sf /bin/bash "$PIN/bash"
PATH="$PIN:$PATH"
export PATH
export BIONIC_TEST_INTERPRETER_PINNED=1

# ── THE ENVIRONMENT STAMP (S2, spec AC-3) ────────────────────────────────────
# A run's verdict is a claim about an environment, so the run says which one: the OS, the
# interpreter the suites actually got (asked of the pinned binary, not of this process), the
# locale that decides how every width and sort behaves, and the launch directory the pin was
# built in. Printed twice — in the header, where a reader meets the run, and beside
# `Gating:`, where they read its verdict — because a captured log is usually read from one
# end or the other.
ENV_STAMP="$(printf 'env: os=%s bash=%s locale=%s path=%s' \
  "$(uname -s | tr '[:upper:]' '[:lower:]')" \
  "$("$PIN/bash" -c 'echo "$BASH_VERSION"' 2>/dev/null)" \
  "${LC_ALL:-${LANG:-unset}}" \
  "$PIN")"
echo "$ENV_STAMP"

( . tests/lib/resolve-roots.sh
  printf 'Roots: hooks=%s skills=%s scripts=%s\n\n' \
    "$BIONIC_HOOKS_DIR" "$BIONIC_SKILLS_DIR" "$BIONIC_SCRIPTS_DIR" )

QUEUE="$TMP/queue"; : >"$QUEUE"
export BIONIC_TEST_QUEUE="$QUEUE" BIONIC_TEST_WORK="$TMP"

# ── THE ADOPTION WALL (wave-01 verification-cannot-lie S10, spec AC-12) ──────
#
# WHAT IT REFUSES. Two things, and the second was added in Step 6 (critic K-7).
#
#   SHADOWING. A suite that defines, at COLUMN 0 and outside any heredoc body, a
#   name tests/lib/assert.sh owns — `ok`, `no`, any `expect_*` the framework
#   defines, `section`, `setup_section`, `finish`, `anchor` — or a counter reset
#   (`PASS=0`, `FAIL=0`, `TOTAL=0`).
#
#   NOT ADOPTING AT ALL. A suite that sources the framework nowhere, or never
#   calls `finish`. Refusing a shadow is only half of "one framework, adopted by
#   every suite": a suite spelling its helpers `t_ok`/`t_no` and its counters
#   `P`/`F`, printing its own tally and exiting 0, shadows nothing and used to
#   pass untouched. That all 55 suites adopt was a MEASUREMENT taken by the
#   migration slices, not a mechanism, and `0 refused` read as proof of a wall
#   that was not there.
#
# A refusal is a FAILED suite: it is named in the tally, it is named under
# `Failed:`, and the run exits 1.
#
# WHY IT IS A WALL AND NOT ADVICE. A private `ok()` replaces the framework's for
# the whole suite, and with it goes everything the framework was adopted for —
# the section floor (AC-13), the derivation that catches a vanished helper
# (AC-14), and one true tally. A suite in that state reports its own verdict on
# its own terms, which is the lie this wave exists to close.
#
# THE RULE AND ITS TWO EXEMPTIONS LIVE IN THE FRAMEWORK, beside the names they
# protect and the scanner that reads them (`_tf_adoption_refusal`, which reuses
# `_tf_scan` — the runner does not carry a second scanner that would skip
# heredocs differently). This file's part is to ask, once per roster line,
# before the suite is launched.
#
# NO FRAMEWORK, NO WALL — SAID OUT LOUD. The rule is "a name the framework in
# THIS tree owns", so a tree with no framework owns no names and can refuse
# nothing. That is the honest reading and it is what the scratch trees other
# suites build (they copy this runner, not the framework) get; it is announced
# on stderr rather than left silent, because a wall that is off and quiet is
# indistinguishable from a wall that is passing everything.
TF_LIB="$REPO/tests/lib/assert.sh"
if [ -r "$TF_LIB" ]; then
  # shellcheck source=/dev/null
  . "$TF_LIB"
else
  echo "tests/run.sh: no framework at tests/lib/assert.sh — the adoption wall is inert for this run" >&2
  _tf_adoption_refusal() { :; }
fi

# _wall_suite <cmd...> -> the file a roster line runs, or nothing. The last
# argument that names a readable file: roster lines are `bash tests/x.test.sh`,
# and a line whose file is missing is left to fail on its own terms.
_wall_suite() {
  local a suite=""
  for a in "$@"; do [ -f "$a" ] && suite="$a"; done
  printf '%s' "$suite"
}

pass=0; fail=0; failed=""

# Opt-in, and opt-in on purpose: no per-suite timing has ever existed (W7 S8
# finding (c) had to answer "which suite is the long pole" with a line-count
# proxy), and a gating run's output must not change just because someone wanted
# the numbers.
_timing() {  # _timing <label> <seconds>
  [ -n "${BIONIC_TEST_TIMING:-}" ] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"$BIONIC_TEST_TIMING"
}

_label() { printf '  %-36s ' "$1"; }

# _lost_command <captured-output-file> -> the interpreter's own "command not found"
# diagnostic, if the suite's output carries one.
#
# THE SHAPE, NOT THE WORDS (spec AC-14, runner half). A suite here runs under `set -uo
# pipefail` with no `-e`, so a call to a helper that was deleted or renamed is one line on
# stderr and nothing else: the suite runs on, its own pass/total never notices, and this
# runner prints ✓ PASS. That is a green with a hole in it, and it has happened — the
# `expect_eq` call that asserted nothing in cross-gate-agreement, found by research, not by
# a run. So a suite that exited 0 is now read as well as counted.
#
# Matched on the DIAGNOSTIC's structure — `<script>: line <n>: <cmd>: command not found`, or
# `<shell>: <cmd>: command not found` for a `bash -c` — never on the bare phrase, because
# suites legitimately PRINT the phrase in an assertion label
# (tests/dispatch-preflight.test.sh asserts a fix command produces no 'command not found',
# and prints that label when it passes). awk rather than `grep | head`, so a long capture
# cannot turn this into the SIGPIPE-under-pipefail flake the assert-helper race taught.
_lost_command() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk '/[^ \t]+: (line [0-9]+: )?[^ \t]+: command not found/ { print; exit }' "$1" 2>/dev/null
}

# _verdict <label> <exit-status-or-empty> <captured-output-file>
# The one place a result is judged and printed, so the two modes cannot drift.
_verdict() {
  local label="$1" rc="$2" out="$3" sig="" lost=""
  # The adoption wall refused this suite before it ran (S10). It never had an
  # exit status, so it is judged from the refusal the wall left behind.
  if [ -f "$TMP/${label}.refused" ]; then
    echo "✗ REFUSED (the adoption wall)"
    fail=$((fail+1))
    failed="${failed}\n    - ${label} (refused by the adoption wall, never run)"
    echo "───── ${label}: the adoption wall ─────"
    cat "$TMP/${label}.refused"
    echo "───── end ${label} ─────"
    return
  fi
  lost="$(_lost_command "$out")"
  if [ "$rc" = "0" ] && [ -z "$lost" ]; then
    echo "✓ PASS"; pass=$((pass+1)); return
  fi
  fail=$((fail+1))
  if [ "$rc" = "0" ]; then
    # Exited 0, but the interpreter said a command it called does not exist.
    echo "✗ FAIL (exited 0; a command it called was not found)"
    failed="${failed}\n    - ${label} (exited 0, but: ${lost})"
  elif [ -z "$rc" ]; then
    # No .rc file: the worker itself did not survive to write one.
    echo "✗ KILLED (no exit status recorded)"
    failed="${failed}\n    - ${label} (killed, no exit status)"
  elif [ "$rc" -gt 128 ] 2>/dev/null && sig="$(kill -l $((rc - 128)) 2>/dev/null)" && [ -n "$sig" ]; then
    echo "✗ KILLED (SIG${sig})"
    failed="${failed}\n    - ${label} (killed by SIG${sig})"
  else
    echo "✗ FAIL"
    failed="${failed}\n    - ${label}"
  fi
  echo "───── ${label}: captured output ─────"
  [ -f "$out" ] && cat "$out"
  echo "───── end ${label} ─────"
}

run() {  # run <label> <cmd...>   — gating
  local label="$1"; shift
  # THE WALL, ASKED BEFORE THE SUITE IS LAUNCHED (S10). A refused suite is not
  # run at all: the refusal is written down here, and _verdict reads it where
  # every other verdict is read — so a refusal prints in roster order in both
  # modes and lands in the same tally.
  local _suite _refusal
  _suite="$(_wall_suite "$@")"
  if [ -n "$_suite" ]; then
    _refusal="$(_tf_adoption_refusal "$_suite")"
    if [ -n "$_refusal" ]; then
      printf 'adoption wall: %s\n' "$_refusal" >"$TMP/${label}.refused"
      if [ "$SERIAL" -eq 1 ]; then
        _label "$label"
        _verdict "$label" "" "$TMP/${label}.out"
      else
        printf '%s\t%s\n' "$label" "$*" >>"$QUEUE"
      fi
      return
    fi
  fi
  if [ "$SERIAL" -eq 1 ]; then
    local start rc
    _label "$label"
    start="$(date +%s)"
    "$@" >"$TMP/${label}.out" 2>&1
    rc=$?
    _timing "$label" "$(( $(date +%s) - start ))"
    _verdict "$label" "$rc" "$TMP/${label}.out"
  else
    printf '%s\t%s\n' "$label" "$*" >>"$QUEUE"
  fi
}
echo "Gating suites:"
# THE ROSTER, WALKED. `"$@"` still holds the glob derived and vetted at the top
# of this file — nothing between here and there touches the positional
# parameters (tests/lib/assert.sh sets none; the seam's re-exec exempts this file
# by name) — so this loop reads the ONE derivation rather than expanding the glob
# a second time. The label is the basename, which is what every roster line said
# twice before.
for _suite_file in "$@"; do
  _suite="${_suite_file##*/}"
  run "$_suite" bash "tests/$_suite"
done
# Moved from hooks/*.test.sh (epic-17 W4 S9, spec AC-9 / D3 "move the tests"): one
# hook behavior suite per hook script, hand-listed like every suite below —
# hooks/ retains only the *.sh scripts themselves, so there is no longer a
# directory whose contents are safely globbable as "the hook tests".
# agent-render.test.sh (the agent-file render pipeline, epic-17 W4 S2) and its terminal-
# disposition cross-file pin (epic-17 W4 S7) were deleted at 8582861 (epic-18 wave-03);
# nothing replaced either.
# Cross-COMPONENT proofs (epic-15 W1R slice 4/6). They belong to no single hook,
# so they live here rather than under hooks/ — which also means they are invisible
# to the glob above and must stay hand-listed.
# plugin-manifest.test.sh (epic-17 wave-01 S1), assert-helper-race.test.sh (epic-17 W1,
# the SIGPIPE-race lesson every suite above still cites), plugin-paths.test.sh (epic-17
# W1 S3, the plugin-layout path rewrite) and plugin-payload.test.sh (epic-17 W1 S6, the
# payload-boundary pin) were all deleted at 8582861 (epic-18 wave-03); nothing replaced
# any of them.
# Harness-on-harness (epic-17 W2 S1). Catch-proof for tests/lib/resolve-roots.sh, the
# path-resolution seam every suite sources: plants a doctored tree and proves the
# override binds in BOTH directions. Belongs to no single hook, so hand-listed.
# version-ssot.test.sh (epic-17 W2 S4, the plugin.json version-owner pin) and
# plugin-lib.test.sh ("Payload libraries", epic-17 W3 S1 — the deps.sh SSoT table and
# detect.sh's machine-fact functions, driven against fixture roots and a fixture PATH)
# were both deleted at 8582861 (epic-18 wave-03); nothing replaced either.
# The read-only probes added at epic-17 W6 S2 (spec R5/AC-8, AC-9; R8/AC-13):
# detect_plugin_load_state and detect_plugin_duplicates, driven against the
# `claude plugin list` transcripts captured during W5's F12 measurement and a
# planted plugin registry. Its own suite rather than a group in plugin-lib.test.sh
# (deleted at 8582861, epic-18 wave-03) — different fixture regime (a captured CLI
# transcript, not a fixture tree) — and so, like every suite outside hooks/,
# hand-listed here or it never runs.
# The worktree contract (epic-17 W3 S2, spec AC-10 / D4): payload/scripts/spawn-worktree.sh
# driven against scratch git repositories, with its attestation line pinned byte-exactly
# because dispatchers quote that line into their ledger rows. Its own suite rather than a
# section of plugin-lib.test.sh (deleted at 8582861, epic-18 wave-03) — different subject,
# different fixture regime — and so, like every suite outside hooks/, hand-listed here or
# it never runs.
# The worktree LEASE (bionic 1.4.0 wave, spec AC-11/AC-28, plan slice WORKTREE):
# payload/scripts/lib/worktree.sh — the land verb (merge --no-ff, remove,
# prune, and the four refusals around it), the legacy `.bionic` links C2
# retired, and the lease overruns the Patrol tick reports. Its own suite rather
# than a group in spawn-worktree.test.sh: that one drives an EXECUTED script
# against a scratch repo, this one sources a library and calls functions, and
# the fixture regimes differ (a fixture claude-home for the D1 predicate).
# Hand-listed like every suite outside hooks/.
# The JIT / degradation contract (epic-17 W3 S10, spec AC-5): payload/scripts/lib/jit.sh's
# jit_check + jit_offer, driven against a fixture PATH, proving jit_offer calls install_dep
# BY NAME (the ownership-table agreement) and mutates nothing on decline. Hand-listed like
# every suite outside hooks/.
# The environment settings (epic-17 W7 S4, spec R4 / AC-5..AC-7):
# payload/scripts/lib/env.sh — the `env` object in settings.json, the merge that adds one
# name without touching the rest of the file, and the difference between a value the FILE
# carries and a value THIS PROCESS has. Hand-listed like every suite outside hooks/.
# The session-id function (bionic 1.4.0 wave, spec AC-2, plan slice L-SESSION):
# payload/scripts/lib/session.sh's session_id — env is primary, a payload sid
# is a witness only; divergence prints once and env still wins. Hand-listed
# like every suite outside hooks/.
# The rc item (epic-18 wave-03 slice 4/7, spec R6 / AC-5, AC-6): the `claude()`
# shell function as a setup-managed item — env.sh's roster and rc write/read/delete,
# the consented step in setup.sh, doctor's row, and remove.sh's strip through both
# of its doors, driven against sandbox HOMEs with a planted .zshrc and read back
# through a real `zsh -ic 'type claude'`. Hand-listed like every suite outside hooks/.
# The pristine-install suite (epic-18 T6, spec AC-10/AC-7; revived and raised at
# wave-03 on Chris's D2): an empty $HOME through `setup --all` all-yes, `doctor`,
# and `remove --all`, asserted against a MANIFEST of bytes rather than against a
# report's own summary line. It is the only suite that starts from nothing and
# the only one that reads all three scripts in one machine's lifetime, which is
# also why it now carries the rc item — setup's newest write target, and the one
# that lands in a file the user already owned. Hand-listed like every suite here.
# The PATROL section (F3, epic-19 wave-01, spec AC-F3): payload/scripts/doctor.sh's
# running-Patrols-or-nothing render, driven against a fixture claude-home (a real
# spawned process + a planted transcript) and a fixture repo's roster file — no
# doctor.test.sh existed before this suite (the broad one, epic-17 W3 S7, was
# deleted at 8582861 for fingerprinting the whole machine). Hand-listed like every
# suite outside hooks/.
# The command-relay contract (F4, epic-19 wave-01, spec AC-F4): the shared
# voice-contract block (and every rendered command file it reaches) demands a
# fenced code block rather than the collapsible "one block", proven alongside
# `render.sh --check` so a template edit without a re-render goes red here too;
# and setup.sh's item()/plan-verb free-form fields — which routinely carry
# absolute paths with no bound — stay inside the same 100-column budget
# doctor.sh already holds itself to (AC-15). Hand-listed like every suite
# outside hooks/.
# The installed-vs-latest version row (F5, epic-19 wave-01, spec AC-F5):
# doctor.sh's BIONIC NATIVE table gains a per-feed-kind `version` row — a git
# feed compares against the marketplace's cached clone and names the exact
# repair command on lag, a directory feed consumes the existing registry-sha
# lag/reconverge machinery instead of a meaningless self-compare, and an
# undeterminable feed kind degrades to an honest `unknown` line. Hand-listed
# like every suite outside hooks/.
# bionic 1.3.2 (wave-01-dogfood-fixes, 2026-08-30) — three suites for the three shared-truth
# additions of that wave, each hand-listed like every suite outside hooks/:
#   - git-argv.test.sh: scripts/lib/git-argv.sh (the git-argv reading protect-main and the
#     evidence gate source), the fail-closed sourcing proof, and the in-tree `source` pin
#   - cmd-class.test.sh: scripts/lib/cmd-class.sh (the argv-positional suite-class reading
#     farm-out-reminder and background-suite-guard source), same fail-closed proof
#   - patrol-marker.test.sh: the `session-poker.sh tick` marker pinned across its three
#     spellings (lib/patrol.sh SSoT, patrol-duties-gate.sh, SKILL.md)
# wave-01 verification-cannot-lie (S13, spec AC-21): the BUDGET arm of
# hooks/background-suite-guard.sh — a dispatched agent may run only the suites its roster
# row allows, and never the full tree unless the row names it. The hook's older
# backgrounded-suite arm stays where it has always been proved (cmd-class.test.sh §C4,
# which drives the pair as hooks.json registers it); this suite owns the budget half.
# bionic 1.4.0 (wave-bionic-1.4.0-update, L-RUN slice, spec AC-8): the one library function
# `active_run` — docs_root, active_plan, active_run — that every always-on hook gates its
# own work behind. Hand-listed like every suite outside hooks/.
# wave-roster-lifecycle (S4, spec AC-6): payload/scripts/lib/agents.sh — the one reader of
# the harness's newest recorded ListAgents answer, which the dispatch budget, both stop
# gates, standdown and the Patrol tick all resolve liveness through. Hand-listed like every
# suite outside hooks/.
# task-engaged-session (T1, matrix AC-1..4, AC-17, AC-18): hooks/engage.sh, the ENGAGEMENT
# trigger — the one act that puts a session inside bionic. Both invocation paths (a Skill
# tool call and a typed slash command's UserPromptExpansion), the marker it writes, and
# lib/run.sh's `engaged_session` predicate every wall reads before it reads anything else.
# Hand-listed like every suite outside hooks/.
# bionic 1.4.0 (wave-bionic-1.4.0-update, slice L-LOADER, spec AC-16) — the one loader
# idiom. payload/scripts/lib/loader.sh carries the canonical text between
# `# --- bionic-loader/v2 BEGIN` / `# --- bionic-loader/v2 END`; this suite pastes that
# text into throwaway hooks under its own mktemp root and drives the three candidate
# classes, the two fail policies and the four-command repair allowlist. Hermetic: HOME
# and BIONIC_PLUGINS_DIR are overridden per run, so the real ~/.claude is never read.
# ── bionic 1.4.0, the library spine (wave-bionic-1.4.0-update) ────────────────
#   - root.test.sh: scripts/lib/root.sh — `project_root` / `project_root_candidates`,
#     seven real on-disk topologies (nested repo under a .bionic workspace, linked
#     worktree, phantom nested .bionic, symlinked .bionic, .bionic inside $HOME,
#     unrelated repo, no-git/no-.bionic) each paired with a differential control
# bionic 1.4.0 (L-DETECT/4.4, spec AC-21): scripts/lib/shell.sh's shell_rc_file, the one
# rc-file resolver detect.sh's and remove.sh's shell-rc functions now both delegate to,
# pinned structurally (thin caller, no hand-rolled case split) and by cross-file agreement
# across zsh/bash/fish/unrecognized $SHELL.
# bionic 1.4.0 (L-DETECT/4.2, spec AC-19): scripts/lib/detect.sh's version_compare, a
# semver-shaped three-int ordering primitive replacing the string-inequality compare in
# detect_plugin_latest, which gains a real `ahead` state for an installed build newer
# than the marketplace's cached clone.
# bionic 1.4.0 (L-DETECT/4.5, spec AC-22): scripts/lib/patrol.sh's PATROL_STALE_MULTIPLIER,
# one exported staleness constant replacing the inline "twice the poker interval" literal in
# patrol_stamp_state's own reader (session-poker.sh and dispatch-preflight.sh switch to it in
# later slices).
# bionic 1.4.0 (slice ADOPT, spec AC-7/AC-8/AC-9/AC-12/AC-16): the CONVENTION every hook
# now carries — one loader block byte for byte under its own BIONIC_LIB_WANT line, the
# root/session/run facts asked of the library rather than restated, and the run predicate
# DRIVEN over real fixtures (no .bionic, a closed run, an open run) so a hook that calls
# `active_run` and ignores the answer cannot pass. Both missing-library fail classes drive
# too: the repair allowlist that ends the lockout, and the one-line step-aside.
# bionic 1.4.0 (wave-bionic-1.4.0-update, 2026-09-02) — the library spine's unit suites, one
# per fact, hand-listed like every suite outside hooks/:
#   - resources.test.sh: scripts/lib/resources.sh (probe / budget / pressure — the parallel
#     budget as a function of the machine instead of a number a human guessed) and the
#     version-2 preflight attestation that records it. The kill datum this suite's memory
#     term is built on is the one written at :63-68 of this file.
# wave-roster-lifecycle S9 (spec AC-15): this file's own job width — pressure_sample then
# pressure_level over BIONIC_TEST_JOBS_CEILING, and --dry-run, the flag that makes the width
# observable without running the whole roster. S25 (K-4 option 2) made --dry-run the
# EXCEPTION to AC-15's sample-before-you-read obligation: it reads the ring as it stands
# and samples nothing, so it can observe the width without also mutating machine state.
# Hand-listed like every suite outside hooks/.
# wave-01 verification-cannot-lie S2 (spec AC-1, AC-2, AC-3, AC-10 and the runner half of
# AC-14): this file's OWN interpreter pin — the launch directory that makes `bash` mean
# /bin/bash for every child, the environment stamp beside the header and the tally, the
# hand-run re-exec in tests/lib/resolve-roots.sh, and the two MEASURED 3.2/5.x divergences
# planted to prove the pin catches what it exists to catch. Every drive is against a scratch
# copy of this runner with its own roster, so nothing there re-enters the real one.
# Hand-listed like every suite outside hooks/.
#   - docs-pins.test.sh: doc-text agreement pins with no other home. §1 (RELEASE, spec
#     AC-36) is the help version pair — replaces the coverage version-ssot.test.sh had
#     before it was deleted below; WALLS and SCHED append their own numbered sections
#     to this same file in later slices of this wave rather than each owning a suite.
# bionic 1.4.0 (wave-bionic-1.4.0-update, slice DOCTOR handoff 3.1, spec AC-15): doctor's
# `walls` row. The four hooks the loader idiom replaced are asked, through the idiom itself
# (`bionic_loader_pin` driven with $0 set to each hook's own path), whether the library they
# source still resolves; a copied payload tree with one library deleted is the fixture.
# Hermetic: HOME and BIONIC_PLUGINS_DIR are overridden per run, so the healing candidates
# cannot reach this machine's real registry and quietly repair the damage.
# bionic 1.4.0 (wave-bionic-1.4.0-update, slice DOCTOR handoff 4.6, spec AC-23):
# scripts/lib/width.sh's closed glyph set, measured under `LC_ALL=C` — the locale the
# substitution exists for, and the only one where the assertion is not vacuous. Section 2
# is differential: it sweeps the glyphs doctor.sh and setup.sh actually put into a bounded
# row and requires each to measure one column, so the next glyph someone reaches for is
# caught here rather than by a crooked table on somebody's terminal.
# bionic 1.4.0 (wave-bionic-1.4.0-update, slice DOCTOR handoff 4.6, spec AC-23): the facts
# doctor gathered on every invocation and printed for nobody — the installed agent copies
# and their drift, the legacy hook FILES on disk, the duplicate-registry scan, the legacy
# skill copy's path — plus the pnpm-store diagnosis, which used to answer three different
# unreadable-store situations with one sentence about a cache having no surface. §7 is
# structural: a top-level assignment in doctor.sh that nothing else in the file reads is a
# probe that ran for nobody, and the allow-list there names what this slice deliberately
# left alone.
# bionic 1.4.0 (wave-bionic-1.4.0-update, slice DOCTOR-RESTART, fold-in spec AC-37):
# doctor's "restart needed" row — the CLI snapshots hooks.json once at process start, so
# a live session whose startedAt precedes that file's mtime in the plugin tree the CLI
# loads (DOCTOR_INSTALL_PATH, reused from the version row) is running a stale hook
# registration. Alphabetical among the doctor-*.test.sh suites.
# bionic 1.4.0 (wave-bionic-1.4.0-update, slice DOCTOR handoff 5.3 and 1.4; spec AC-27,
# AC-4's doctor line, AC-8, AC-11): doctor's RESOURCES section — the live probe, and per
# live session the budget its preflight attestation recorded (version 1 → "no budget
# recorded", the honest reading of a fail-open resources load) — plus the three run-scoped
# rows: the active run as `active_run` sees it, the predecessor rosters a /clear left with
# open dispatches, and the legacy `.bionic` symlinks under .worktrees/. Hermetic: doctor is
# run with its cwd inside a fixture project holding its own .bionic/, and the "live"
# sessions name the suite's own pid.
# wave-01 verification-cannot-lie (slice S1; spec AC-13/AC-14/AC-15): the test
# framework's own suite. tests/lib/assert.sh is the one thing in this tree that decides
# whether a result EXISTS — sections, the counters, the assertion helpers, and the
# load-time derivation that turns a called-but-undefined helper from a discarded stderr
# line into a refusal — so it is the one thing that cannot be certified by the mechanism
# it certifies. Every row plants a scratch suite and reads the verdict the framework gave.
# wave-01-verification-cannot-lie S12 (spec AC-18, AC-19): the impacted-suite
# derivation. Its §F planted-edit proof runs real suites against a mutated
# scratch tree — minutes, not seconds — so it is behind BIONIC_IMPACT_PLANTED=1
# and is NOT what this line runs; the committed record of that proof is at
# .bionic/docs/record/wave-verification-cannot-lie/s12-planted-edits.log.
# The following suites were deleted at 8582861 (epic-18 wave-03, the MEDIUM/LOW-reliability
# ruling) and nothing replaced their coverage:
#   - command-format.test.sh (epic-17 W3 S9) — payload/commands/*.md conventions
#   - command-permissions.test.sh (epic-17 W6 S9b) — allowed-tools <-> fenced-command agreement
#   - diagrams.test.sh (epic-17 W4 S8) — the two composed-SVG diagram pins
#   - setup.test.sh (epic-17 W3 S6) — payload/scripts/setup.sh driven end to end
#   - doctor.test.sh (epic-17 W3 S7) — the read-only diagnosis, no-mutation wall
#   - remove.test.sh (epic-17 W3 S8) — footprint removal, the never-list wall, the
#     standalone door (this is the suite the epic-18 wave-03 citesweep started from)
#   - close-out.test.sh, agent-roles.test.sh — no live description survived in this file
# voice-contract.test.sh (epic-17 W6 S1, the presentation contract) and
# script-vocabulary.test.sh (epic-17 W6 S4, the same banned-vocabulary lint applied to
# setup.sh/doctor.sh/remove.sh's own print output) were deleted earlier still, in an
# unrelated purge, commit b959b5e.
# See `git show --stat 8582861 -- tests/` for the full list of nineteen deleted files.
# lib/platform.test.sh RETIRED at epic-17 W5 (Step-6 review). The library it
# covered exported OS, BREW_PREFIX, SHELL_RC, PLAYWRIGHT_CACHE and sed_inplace
# for exactly two consumers — claude-bootstrap.sh and claude-reset.sh — and 4/6
# deleted both. Nothing in the payload ever sourced it, so from that commit its
# own suite was its only consumer and the pair was a closed loop testing itself.
# Where the facts went, so this is a move and not a loss: the shell rc lives in
# detect.sh (_detect_shell_rc) and remove.sh (_rm_shell_rc), the Playwright cache
# in the dep table's BIONIC_PLAYWRIGHT_CACHE probe, and the payload does its own
# rewriting in bash rather than sed, so sed_inplace has no successor because it
# has no question left to answer.


# ── drain the queue, then report in roster order ─────────────────────────────
# Nothing above printed a result in the default mode; every `run` line enqueued.
# The suites run now, $JOBS at a time (eight by default), each in its own process
# writing its own files; then the queue is walked again IN ORDER so the report reads the same as
# a serial one — a reader comparing two runs is comparing rosters, not schedules.
if [ "$SERIAL" -eq 0 ]; then
  # A suite the adoption wall refused stays in the queue — the report below walks
  # it, and roster order is what makes two runs comparable — but it is not
  # launched: its verdict is already on disk.
  LAUNCH="$TMP/launch"; : >"$LAUNCH"
  while IFS="$(printf '\t')" read -r label _queued_cmd; do
    [ -n "$label" ] || continue
    [ -f "$TMP/${label}.refused" ] && continue
    printf '%s\n' "$label" >>"$LAUNCH"
  done <"$QUEUE"
  [ -s "$LAUNCH" ] && xargs -P "$JOBS" -n1 bash "$SELF" --one <"$LAUNCH"
  while IFS="$(printf '\t')" read -r label _queued_cmd; do
    [ -n "$label" ] || continue
    _label "$label"
    rc=""
    [ -f "$TMP/${label}.rc" ] && rc="$(cat "$TMP/${label}.rc")"
    [ -f "$TMP/${label}.sec" ] && _timing "$label" "$(cat "$TMP/${label}.sec")"
    _verdict "$label" "$rc" "$TMP/${label}.out"
  done <"$QUEUE"
fi

echo "──────────────────────────────────────────────"
echo "Gating: ${pass} passed, ${fail} failed"
echo "$ENV_STAMP"
if [ "$fail" -ne 0 ]; then
  echo -e "Failed:${failed}"
  exit 1
fi
echo "All gating suites green ✓"
