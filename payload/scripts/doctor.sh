#!/bin/bash
# doctor.sh — the read-only diagnosis (epic-17 wave-03 slice S7, spec AC-3).
#
# WHAT THIS FILE OWNS. Nothing factual. Doctor is a RENDERING SURFACE: every
# number, verdict and state below is computed by detect.sh, deps.sh or env.sh
# and printed here in a shape a person can act on. The design's
# ownership table says so in one word — doctor "diagnoses, never treats" — and
# that word is the whole contract: no mutations, one pass, exit 0.
#
# ONE QUESTION, ASKED LAST (wave-06, ratified D-D). The instant report —
# everything this machine can be asked about without leaving it — prints in full
# first. Then doctor asks whether to check for tool updates, because that is the
# one fact that costs a network round trip to two package managers and a user
# waiting on a diagnosis should not pay for it unasked. The rejected shapes are
# what this one has to keep out: always-on is a forced wait, an argument alone is
# forgettable, and a cache would make the read-only report write a file.
# Answering yes appends UPDATES and nothing else changes: doctor prints the
# upgrade command, and never runs it.
#
# THE QUESTION IS ALWAYS PRINTED; ONLY THE WAITING IS CONDITIONAL. Where stdin
# can carry an answer — a terminal, a pipe, a file — doctor asks and waits. Where
# it cannot (a closed stream, or the socket a tool harness hands a script) the
# same line is printed and the run ends: no wait, and no narration of why. That
# is setup.sh's rule applied here — it prints every consented question as it
# declines it, so whoever is relaying the script's output can put the question to
# the person who can answer it. A question the reader never sees is a feature
# nobody can use.
#
# `--updates` IS THAT ANSWER COMING BACK. The relay runs doctor again with the
# flag, which skips the question and appends UPDATES. It is NOT an assume-yes
# knob: the rule setup states in its own header — that an env var switching
# consent off would be the hole in "consent per event" — guards MUTATIONS, and
# this flag guards a read. Two package managers are asked what is outdated; the
# upgrade command is printed and never run. By the time the flag is passed the
# user has already said yes.
#
# EVERY SHELL-OUT IS BOUNDED. Three of the facts below leave this process: the
# CLI's own plugin listing, `brew outdated`, `npm outdated -g`. Each runs under a
# time limit (15 seconds; `BIONIC_DOCTOR_PROBE_SECONDS` accelerates it for the
# suite), because the machine where a diagnosis matters most is exactly the one
# where a CLI or a package manager hangs, and a doctor that hung with it would be
# useless at the only moment it was needed. A probe that runs out of time is
# `unknown` with a cause, never a confident answer.
#
# EXIT 0, ALWAYS — FOR A DIAGNOSIS. A diagnosis is not a failure. A machine with
# eleven absent dependencies and a broken hook channel has been diagnosed
# *successfully*; reporting that as a non-zero exit would make every caller treat
# a working doctor as a broken one. The report's content is the signal, never the
# status. TWO THINGS ARE NOT DIAGNOSES and both exit 2 before any fact is
# gathered: an option this script does not know, because answering a misspelled
# flag with a clean report and status 0 would tell a caller that asked for
# something, and did not get it, that all was well; and a payload missing a
# library this script sources, because there is no report to print and the
# alternative is the interpreter's own error trace. Neither has diagnosed
# anything, and 2 is this file's word for that.
#
# WHY READ-ONLY IS STRUCTURAL AND NOT MERELY INTENDED. Doctor calls only the
# read-only half of each library — detect.sh's fact functions, env.sh's
# `env_get` / `env_live`, deps.sh's table accessors. It never
# calls `install_dep`, `remove_dep` or `bionic_strip_permission_block`, and it
# never shells out to brew/npm/uv/claude for anything but a version probe the
# libraries already own. tests/doctor.test.sh used to fingerprint a whole
# fixture machine — every file's sha256 AND every path — before and after a
# full run; it was deleted at 8582861 (epic-18 wave-03) and nothing replaced
# the fingerprint wall.
#
# THE THREE-VALUED WORLD. `present`, `absent` and `unknown` are three answers,
# not two-plus-an-error. A dependency whose mechanism has no presence surface
# (the pnpm store is a cache), a count that cannot be taken because `jq` — one of
# the table's own rows — is missing: those are `unknown`, and coercing them to
# `absent`/`0` would report a machine that could not be read as one that read
# clean. Every `unknown` printed below carries a NAMED CAUSE, because "unknown"
# on its own is a shrug rather than a diagnosis.
#
# EVERY BROKEN FACT CARRIES ITS FIX. The degradation map names an action per
# absent or violating dependency; the summary block is action lines and nothing
# else. A report that tells a user what is wrong and not what to do about it has
# done half the job.
#
# ROOTS ARE OVERRIDABLE — the same env knobs the libraries read
# (BIONIC_PLUGIN_ROOT, BIONIC_CLAUDE_HOME, BIONIC_SETTINGS_FILE,
# BIONIC_INSTALLED_PLUGINS_FILE, BIONIC_SHELL_RC,
# BIONIC_PLAYWRIGHT_CACHE). Doctor adds none of its own: a knob only doctor
# honoured would be a second definition of where this machine keeps its state.
#
# Executed, never sourced:  bash ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh

set -uo pipefail

# ─── Options ─────────────────────────────────────────────────────────────────
#
# Parsed FIRST, before a single fact is gathered: a caller who misspelled the one
# flag should be told so immediately, not after a full report they will not read.
DOCTOR_WANT_UPDATES=no
# THE REPORT IS AN INVENTORY, NOT A DOSSIER (certified 2026-08-22; verbose arm
# removed same day by owner order — the explainer prose is deleted, not parked).
# Three tables answer the three questions a user has — what ships in the plugin,
# what setup installed and at which version, what this machine's environment
# carries.
while [ $# -gt 0 ]; do
  case "$1" in
    --updates)          DOCTOR_WANT_UPDATES=yes ;;
    *)
      echo "doctor.sh: unknown option '$1' — the only option is --updates" >&2
      exit 2 ;;
  esac
  shift
done

# No `dirname` here for the same reason the libraries give: a diagnosis that
# needs coreutils to locate itself dies on the broken machine it exists for.
_doctor_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}
DOCTOR_LIB="$(cd "$(_doctor_self_dir)" && pwd -P)/lib"

# THIS CHECKOUT'S OWN ROOT (W4 4/4), three levels up from DOCTOR_LIB the same way
# `plugin_root`'s fallback (lib/roots.sh) climbs from lib to the payload directory
# (lib -> scripts -> payload), one level further still: a marketplace registration's
# `source.path` names a REPO root — it holds `.claude-plugin/marketplace.json`
# beside `payload/`, not the payload directory by itself. Resolved from doctor's
# own location, never from BIONIC_PLUGIN_ROOT: the "which tree" question this line
# answers is about where THIS SCRIPT physically lives, and an env override that
# redirected it would make the comparison answer a question nobody asked.
DOCTOR_REPO_ROOT="$(cd "${DOCTOR_LIB}/../../.." && pwd -P)"

# THE PAYLOAD-INTEGRITY GUARD, WHICH SETUP HAS CARRIED SINCE 1.5.1 AND THIS FILE
# DID NOT (Step-5 walk, Walk-D3). A payload copy missing lib/checks.sh answered
# `doctor` with three raw bash diagnostics — `No such file or directory`,
# `bionic_check_route: command not found`, `BIONIC_WALL_HOOKS: unbound variable`
# — no report at all, and status 1 under a header stating that a diagnosis always
# exits 0. Every one of those lines is the SHELL talking about doctor, in a file
# whose whole job is to talk about the machine; the reader is left holding an
# interpreter trace instead of the one sentence that would fix it. Setup was
# already answering the identical damage with a named file and a reinstall
# route, so the two surfaces disagreed about what a broken payload looks like.
#
# THE LIST IS WHAT THIS SCRIPT NEEDS, NOT WHAT SETUP NEEDS, which is why it is
# spelled here rather than shared. The two scripts source different libraries —
# setup wants deps/hooks/jit, doctor wants loader/root/run/resources — so there
# is no one list to own; and a shared CHECKER would have to live in a library
# that must itself exist before it can be sourced, which is the bootstrap this
# guard exists to survive. What is shared is the sentence and the route, and
# those are two echo lines.
#
# THE LAST TWO ARE ONE LEVEL DOWN, the way patrol.sh is on setup's list.
# detect.sh soft-sources deps.sh and shell.sh from its own directory, so a
# payload without them fails inside a library rather than at a line here — the
# same trace, one frame deeper — and they are part of what a complete payload
# means for this script too.
for _doctor_lib in detect.sh env.sh patrol.sh width.sh loader.sh root.sh run.sh \
                   resources.sh checks.sh deps.sh shell.sh; do
  if [ ! -f "${DOCTOR_LIB}/${_doctor_lib}" ]; then
    echo "doctor.sh: cannot find ${DOCTOR_LIB}/${_doctor_lib} — the payload looks incomplete." >&2
    echo "           reinstall with: claude plugin install bionic@bionic" >&2
    exit 2
  fi
done

# shellcheck source=/dev/null
. "${DOCTOR_LIB}/detect.sh"
# env.sh, for its READ half only — `env_get` (what settings.json says) and
# `env_live` (what THIS process has). Those are two different facts and the gap
# between them is a restart, not a repair; a report that collapsed them is the
# 2026-08-21 defect this section exists to end. env.sh's write half is never
# called from here, the same way this file never calls install_dep.
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/env.sh"
# patrol.sh, which owns the ONE fact on this page that has no file behind it. The
# CLI keeps its cron table in memory and writes none of it down, so "is the
# Patrol armed, once, and firing" is reconstructed from a session file and a
# transcript. Sourced after detect.sh because it borrows that library's bound
# for the one shell-out it makes.
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/patrol.sh"
# width.sh, which owns the 100-column rule this file's format rules state and
# every row builder below now enforces. It was prose here and a constant in
# setup.sh until S9 — the same number in two files with nothing binding them,
# and the copy nothing walled (this one) was the one that broke.
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/width.sh"
# loader.sh, which is a CARRIER and not a loader: sourcing it defines
# `bionic_loader_pin` and nothing else. Doctor wants it for one job — the
# `walls` row below drives the canonical idiom text against each wall hook's own
# path instead of re-implementing the candidate list a third time. A row that
# re-derived "where would this hook look" could disagree with where the hook
# actually looks, which is the whole failure the row exists to catch.
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/loader.sh"
# root.sh, run.sh and resources.sh — the library spine this page reports on
# (bionic 1.4.0). `project_root` is the SSoT for which project this cwd is in, so
# the run-scoped rows below read the same address space every hook does;
# `active_run` is the predicate those hooks gate their own work behind, printed
# here rather than re-derived; `resources_probe` is the machine the fleet is
# about to run on. All three are pure functions of disk and none of them writes.
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/root.sh"
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/run.sh"
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/resources.sh"
# checks.sh, THE TABLE OF CHECKS — one row per fact bionic needs true on a
# machine, and for each row the label this page prints, the party that repairs it
# and the hint that names that party. setup.sh renders its roster from the same
# rows. This page keeps its own presentation entirely — the columns, the widths,
# the collapsed verdict — and gets its FACTS from there, which is what stops a
# row here from promising a repair setup has no item for (the field defect of
# 2026-09-05: `16 legacy hook files … → /bionic:setup` over a run that then said
# "nothing left to do"). checks.sh's detectors are read-only, every one of them,
# so sourcing it changes nothing about this page's central promise.
# shellcheck source=/dev/null
. "${DOCTOR_LIB}/checks.sh"

# The standalone removal door (design D5a: the remover must not depend on the
# thing it removes). Printed as TEXT for the user to run — doctor never fetches
# it. scripts/remove.sh is the same file this URL serves; slice S8 owns that
# script, and this constant is the one place doctor names its public location.
BIONIC_REMOVE_RAW_URL="https://raw.githubusercontent.com/chrisalehman/bionic/main/payload/scripts/remove.sh"

# The id the CLI knows this plugin by — `<name>@<catalog>`, which is the key the
# listing prints and the argument an install command takes. Named once here
# because it appears in a fact lookup and in two fix lines.
#
# DERIVED, NOT SPELLED, AND DERIVED IN ONE PLACE (bionic 1.4.4 fixit, A-5; one
# owner at phase 4, review-b B-7). This used to be the literal `bionic@bionic`
# while setup.sh composed the same id from the catalog and deps.sh composed it a
# third time — three copies of one expansion, none of them pinned, because no
# suite re-pointed the catalog. `dep_plugin_id` is the owner now. deps.sh is in
# this process by the time this line runs: detect.sh is sourced above and soft-
# sources deps.sh when `check_dep` is undefined (lib/detect.sh:77-80), which is
# always true here — this file sources no library before detect.sh. The default
# on a machine that sets no environment is unchanged.
BIONIC_PLUGIN_ID="$(dep_plugin_id)"

# ─── Bounded probes ──────────────────────────────────────────────────────────
#
# THE THREE THINGS DOCTOR RUNS THAT IT DOES NOT CONTROL — the CLI's plugin
# listing, `brew outdated`, `npm outdated` — go through `detect_bounded`, which
# lives in detect.sh beside the probe it was written for. It moved there at S11
# (critic F-3): setup runs the same listing through the same function, and a
# bound only one of two callers has is a bound the product does not have. The
# mechanism, and why it is one mechanism rather than two, is documented at the
# function.

# ─── Small renderers ─────────────────────────────────────────────────────────
#
# THE FOUR FORMAT RULES (spec AC-15, approved 2026-08-22). This report used to
# spend two lines on every fact — a value, then a sentence explaining the value —
# and open each section with a paragraph about how the section works. Read down a
# terminal that is eighty columns wide, a long line then wrapped into a second
# one, and a twenty-row machine printed as a hundred and twelve lines nobody
# could scan. The rules, in the shape they are implemented here:
#
#   1. ONE LINE PER ITEM, with a status symbol in column one. `_doctor_item` is
#      the only way a fact reaches the page, so a row added by any future arm
#      inherits the format without knowing it exists.
#   2. NO PROSE ON A HEALTHY ITEM. A value that is fine is the value and nothing
#      else; the sentence that used to follow it explained a state the symbol now
#      carries. Section explainers are gone from the default output entirely —
#      what the DEPENDENCIES class column means, how a roster line is counted.
#      That reasoning lives in
#      the comments of this file, where the person it is addressed to is reading.
#   3. THE VERDICT FIRST. SUMMARY is the first section and FIX is the second, so
#      the two questions a reader actually has — is anything wrong, and what do I
#      type — are answered before the detail they can skip.
#   4. FILLER COLLAPSES TO A COUNT. Fourteen dependencies contributing zero
#      roster lines, six legacy checks all clean: those are one line each about
#      nothing. They are counted and summarised, and only the rows carrying a
#      real value are printed.
#
# AND EVERY LINE FITS. Nothing printed below may exceed `BIONIC_LINE_WIDTH`
# columns (lib/width.sh, 100) — because a wrapped line is rule 1 broken by the
# terminal rather than by this file. This used to be a sentence and nothing
# else: tests/doctor.test.sh walled it for both fixture machines until that
# suite was deleted at 8582861 (epic-18 wave-03), and the next row added to this
# file — F5's version row, slice 4/4 of this very wave — came out at 104 columns
# on the wave's own T3 capture and past 130 in its worst case. The rule is now
# enforced where rows are BUILT (the three builders below, plus the verdict
# line), so a row added by a future arm inherits the bound the same way it
# inherits the format, and walled from outside by an all-lines-fit assertion on
# real output in tests/doctor-version.test.sh and tests/command-relay.test.sh.

# The three symbols, and the invariant that gives them meaning: ✗ is printed if
# and only if the same run puts a matching line in FIX. Anything true but not
# actionable — an install behind the tip, a locally edited role file, a
# when-needed tool nobody has needed yet — is `–`, never ✗. A report that marked
# every unusual fact as broken would be nagging a machine that is working, which
# is the defect the degradation map already had to have designed out of it.
DOCTOR_OK='✓'
DOCTOR_BAD='✗'
DOCTOR_NIL='–'

# A padded column with nothing after it is trailing whitespace, which every diff
# and every `git show` renders as an error. Rows are built and then trimmed.
_doctor_rtrim() {  # <line>
  local s="${1}"
  printf '%s' "${s%"${s##*[! ]}"}"
}

# All three are three bytes, so `%s` in the symbol position pads the same width
# for each and the label column below it stays straight. Padding the symbol
# itself with `%-Ns` would NOT be safe: printf pads to a byte count, and a
# multi-byte glyph in a padded field steps the whole column two places left.
# 30, because the longest label this report prints is an environment name —
# CLAUDE_CODE_ENABLE_TODO_TOOLS, 29 characters — and a label that overruns its
# column pushes one row's value out of line with every other row's.
_doctor_item() {  # <symbol> <label> <value>
  local prefix
  printf -v prefix '  %s %-30s ' "$1" "$2"
  printf '%s\n' "$(_doctor_rtrim "$(bionic_line "$prefix" "${3:-}")")"
}

# The FIX section, accumulated as the run discovers problems and printed near the
# top — which is why it is collected rather than echoed where it is found. One
# line per problem, and the line ENDS with what to type: a problem stated without
# its command is the half of the job this report used to leave undone.
#
# THERE USED TO BE A THIRD ACCUMULATOR HERE, `FIX_LINES`, holding every line with
# its ✗ glyph on the front. Nothing printed it: the verdict renders from the two
# below, and the count that read it is now summed by `fix` itself. It is gone
# rather than kept, because a string built on every run and read by nobody is the
# shape tests/doctor-reads.test.sh §7 exists to refuse.
# THE VERDICT LINE NAMES THE PROBLEMS, so the problems have to be nameable. Each
# fix sentence is `<what is wrong> → <what to type>`, and the half before the
# arrow is already the name — accumulated here rather than re-derived later,
# because a second parse of this report's own prose is exactly the kind of
# reading that drifts. Problems /bionic:setup can repair are kept apart from the
# ones it cannot: one command covers the first group and is said once, and the
# rest each need their own line or they reach the user as a count with no cure.
FIX_NAMES_SETUP=""
FIX_LINES_OTHER=""
# THE SUFFIX THIS SORTS ON IS THE TABLE'S, NOT A LITERAL (1.5.1). Which lines fold
# into the one collapsed sentence at the bottom of the page is decided by whether
# they end in setup's own route, and that string is spelled once — in
# lib/checks.sh, where every row that carries it reads it from. Read into a
# constant because the sort runs once per fix line.
DOCTOR_SETUP_ROUTE="$(bionic_check_route setup)"
# HOW MANY ✗ ROWS THIS LINE STANDS FOR, SAID WHERE THE LINE IS WRITTEN (1.5.1,
# Walk-D1). The headline is a count of the machine's problems and the tables
# below render one ✗ row per problem, so the two numbers are the same number and
# a reader who counts the rows must land on the headline. Most fix lines are
# worth exactly one row, which is the default. A COLLAPSED line — eleven absences
# under one `/bionic:setup`, three unwritten environment names under one, four
# dead sessions under one verb — is worth the rows it collapsed, and only the
# call site knows how many that is.
#
# WHICH IS WHY IT IS DECLARED AND NOT RECONSTRUCTED. This was arithmetic at the
# bottom of the file until now: count the ✗ lines, then subtract each collapsed
# line and add the ✗ rows of the table it collapsed. That shape has to be
# extended by hand for every new collapse and every new line, and it was wrong
# twice at once by the time the Step-5 walk measured it. The dependency line was
# swapped for EVERY ✗ dependency row, including the rows of `presence is unknown`
# and `violates constraint` lines that were already counted as themselves, so
# each of those was worth two problems; and the environment line was swapped for
# nothing at all, so three unwritten names were worth one. On the walk's fixture
# the first error was +2 and the second -2 and the page's total came out right
# over two broken halves. A number declared beside the sentence it belongs to
# cannot drift from it that way.
N_FIX=0
fix() {  # <problem> → <command> [<✗ rows this line stands for; default 1>]
  local line="${1}" name="${1%% → *}"
  N_FIX=$(( N_FIX + ${2:-1} ))
  case "$line" in
    *"$DOCTOR_SETUP_ROUTE") FIX_NAMES_SETUP="${FIX_NAMES_SETUP}${FIX_NAMES_SETUP:+; }${name}" ;;
    *)                FIX_LINES_OTHER="${FIX_LINES_OTHER}${line}"$'\n' ;;
  esac
}

# yes/no/unknown as the words a person reads in a report.
_doctor_word() {  # <yes|no|stale|unknown>
  case "${1:-}" in
    yes)     echo "present" ;;
    no)      echo "absent" ;;
    # THE FOURTH ANSWER (AC-17). A venv built against a different `uv.lock` than
    # the one now shipped is neither present-and-correct nor absent, and calling
    # it either would send a reader to the wrong repair.
    stale)   echo "stale" ;;
    unknown) echo "unknown" ;;
    *)       echo "${1:-unknown}" ;;
  esac
}

# One field of a `|`-delimited machine line, BY KEY. The Patrol records are the
# only input this report parses that it did not also print, and every other
# reader of a line in this shape — five hooks — reads it the same way, by key
# and never by position.
_doctor_pfield() {  # <line> <key>
  local f
  while IFS= read -r f; do
    case "$f" in "${2}="*) printf '%s' "${f#"${2}="}"; return 0 ;; esac
  done <<EOF
$(printf '%s' "${1:-}" | tr '|' '\n')
EOF
  printf ''
}

# A PATH AS A PERSON WOULD TYPE IT. Home-relative, because that is both shorter
# and the spelling a reader would put into a shell — and because the rows that
# name a path under the claude-home have about forty columns to say it in, which
# an absolute `/Users/<name>/…` spends a quarter of before it starts.
_doctor_tilde() {  # <path>
  local p="${1:-}"
  case "$p" in
    "${HOME:-/nonexistent}"/*) printf '~%s' "${p#"${HOME}"}" ;;
    *)                         printf '%s' "$p" ;;
  esac
}

# HOW LONG AGO, IN ONE TOKEN. The mtime read is lib/patrol.sh's (`_patrol_mtime`
# — BSD `stat -f` then GNU `stat -c`, whichever answers), so there is no second
# spelling of a portability workaround on this page. A file whose age cannot be
# taken says so rather than reporting zero, which would read as "touched just
# now" — the confident wrong answer this report is not allowed to give.
_doctor_file_age() {  # <file> -> "12m old" | "3h old" | "2d old" | "age unknown"
  local mt now delta
  mt="$(_patrol_mtime "${1:-}")" || mt=""
  case "$mt" in ''|*[!0-9]*) echo "age unknown"; return 0 ;; esac
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) echo "age unknown"; return 0 ;; esac
  delta=$(( now - mt ))
  [ "$delta" -ge 0 ] || delta=0
  if   [ "$delta" -lt 3600 ];  then echo "$(( delta / 60 ))m old"
  elif [ "$delta" -lt 86400 ]; then echo "$(( delta / 3600 ))h old"
  else                              echo "$(( delta / 86400 ))d old"
  fi
}

_doctor_plural() {  # <count> <singular> <plural>
  if [ "${1:-0}" = "1" ]; then echo "$2"; else echo "$3"; fi
}

# Why a value came back `unknown`. The mechanism decides: a cache has no
# presence surface at all, and everything else is a missing tool the report can
# name. Rendering-layer explanation only — the VALUE is always the library's.
#
# SHORT ENOUGH TO RIDE ON THE ROW (AC-15). These used to be sentences, printed on
# a line of their own under the row they explained; they are now the row's last
# column, so each has to leave the line inside 100 columns. Nothing was dropped
# that a reader could act on: "the pnpm content-addressable store is a cache, not
# an install surface" and "a cache, no presence surface" answer the same question,
# and only one of them fits beside the fact it is about.
# THE STORE HAS A SURFACE, SO THE CAUSE NAMES THE FILE (AC-23). "a cache, no
# presence surface" stopped being true at the commit that taught the probe to
# read pnpm's `index.db` — the store names every cached `<name>@<version>` — and
# a reader told a cache cannot be read has nothing to check, while a reader told
# which file could not be read does. `_dep_check_pnpm_store` answers `unknown` in
# exactly three situations and this names all three, in the order that function
# tests them.
#
# ASKED AT MOST ONCE. The dep sweep calls the cause up to three times per row
# (the dependency row, the third-party row, the roster row), and `pnpm store
# path` is a shell-out — so it is memoised, and it goes through the same bound
# every other shell-out on this page does.
_DOCTOR_PNPM_CAUSE=""
_doctor_pnpm_cause() {
  [ -z "$_DOCTOR_PNPM_CAUSE" ] || { printf '%s' "$_DOCTOR_PNPM_CAUSE"; return 0; }
  local store idx
  if ! command -v pnpm >/dev/null 2>&1; then
    _DOCTOR_PNPM_CAUSE="pnpm is not on PATH"
  else
    store="${BIONIC_PNPM_STORE:-}"
    [ -n "$store" ] || store="$(detect_bounded "$(detect_probe_seconds)" pnpm store path 2>/dev/null)"
    store="${store%/}"
    idx="${store}/index.db"
    if [ -z "$store" ]; then
      _DOCTOR_PNPM_CAUSE="pnpm store path did not answer"
    elif [ ! -f "$idx" ]; then
      _DOCTOR_PNPM_CAUSE="no store index at ${idx}"
    elif [ ! -r "$idx" ]; then
      _DOCTOR_PNPM_CAUSE="the store index at ${idx} is unreadable"
    else
      # Unreachable through the probe — a readable index answers yes or no, never
      # unknown — and here so this function has no silent arm.
      _DOCTOR_PNPM_CAUSE="the store index could not be searched"
    fi
  fi
  printf '%s' "$_DOCTOR_PNPM_CAUSE"
}

_doctor_unknown_cause() {  # <kind> — the install mechanism the table names
  case "${1:-}" in
    pnpm-store) _doctor_pnpm_cause; echo ;;
    native)
      if command -v jq >/dev/null 2>&1; then echo "the plugin registry could not be parsed"
      else echo "jq is not on PATH"; fi ;;
    npm-global) echo "npm is not on PATH" ;;
    mcp-server) echo "the claude CLI is not on PATH" ;;
    statusline)
      if command -v jq >/dev/null 2>&1; then echo "settings.json could not be parsed"
      else echo "jq is not on PATH"; fi ;;
    *)          echo "no presence surface" ;;
  esac
}

# ─── The three certified tables ──────────────────────────────────────────────
#
# ONE ROW BUILDER PER TABLE, and the widths live here rather than at each
# callsite, because a column is only a column while every row agrees about it.
# Each builder trims its own tail, so a row whose last cell is empty — the
# healthy case, since rule 2 gives a working item no prose — leaves no trailing
# whitespace behind.
#
# PRINTF PADS BYTES; A TERMINAL LAYS OUT COLUMNS, and every glyph this report
# reaches for outside ASCII — ✓ ✗ – — ≥ … — is three bytes wide and one column
# wide. A `%-11s` field holding one of them therefore comes out two columns
# short, and the whole table steps left from that row down. It is not
# hypothetical: `—` is the version cell of every row whose mechanism keeps no
# version, which on an ordinary machine is a third of the table.
#
# SO CELLS ARE PADDED BY COLUMN COUNT, and the counter is `bionic_cols`
# (lib/width.sh) — the same one the budget below is measured with, because a
# report that padded in one unit and truncated in another is a table that can
# still come out crooked. This file used to carry its own copy (`_doctor_cols`);
# it was deleted at S9 with the shared owner it duplicated.

# One cell, padded to a column width. A cell already at or over its width is
# printed whole and pushes its neighbours right — truncating a name to keep a
# column straight would be choosing the table's looks over its content.
_doctor_cell() {  # <string> <width>
  local s="${1:-}" w="${2:-0}" n
  n=$(( w - $(bionic_cols "$s") ))
  if [ "$n" -gt 0 ]; then printf '%s%*s' "$s" "$n" ""; else printf '%s' "$s"; fi
}

# `component  count  detail` — four rows on a healthy machine, so the count
# column is narrow and the detail column gets the room.
_doctor_native_row() {  # <symbol> <component> <count> <detail>
  local prefix
  prefix="  $1 $(_doctor_cell "$2" 10) $(_doctor_cell "$3" 8) "
  printf '%s\n' "$(_doctor_rtrim "$(bionic_line "$prefix" "${4:-}" "${5:-}")")"
}

# `name  version  source  state`. The source column is what makes this table
# worth reading twice: two rows can both say `present 1.2.3` and be installed by
# entirely different machinery, and which machinery it was decides what a user
# types to repair or remove it.
# THE SIXTH ARGUMENT IS THE INSTRUCTION THAT MAY NOT BE EATEN, the same contract
# `_doctor_env_row` below already has and for the same reason (lib/width.sh's
# worked example). Four fixed cells leave this row exactly 44 columns for its
# state, and `absent → claude plugin install bionic@bionic` — the core-dependency
# route — is all 44 of them. Passed as the tail it would come back as
# `…install bion…`: a row that states a problem and truncates its cure, which is
# the one failure this table cannot afford. Every other row passes nothing here
# and is rendered exactly as before.
_doctor_third_row() {  # <symbol> <name> <version> <source> <state> [<instruction>]
  local prefix
  prefix="  $1 $(_doctor_cell "$2" 21) $(_doctor_cell "$3" 11) $(_doctor_cell "$4" 17) "
  printf '%s\n' "$(_doctor_rtrim "$(bionic_line "$prefix" "${5:-}" "${6:-}")")"
}

# `KEY=value  state`. The left cell is one token on purpose — an environment
# name and its value are a single fact, and splitting them into two columns made
# a reader join them back up by eye on every row.
# The fourth argument is the instruction the cut may not eat — the same contract
# `_doctor_env3` already has, and needed here from the moment these rows started
# naming PATHS: a directory of unbounded length in the state cell would otherwise
# push the `→ /bionic:setup` off the end and leave a row that states a problem and
# withholds its cure (lib/width.sh's own worked example).
_doctor_env_row() {  # <symbol> <key=value or label> <state> [<instruction>]
  local prefix
  prefix="  $1 $(_doctor_cell "$2" 42) "
  printf '%s\n' "$(_doctor_rtrim "$(bionic_line "$prefix" "${3:-}" "${4:-}")")"
}

# WHICH MACHINERY PUT IT THERE, in the words a user would use for it. Keyed on
# the table's `kind`, which IS the install mechanism, with one deliberate
# exception: a `native` row's mechanism field holds the upstream git URL, but the
# CLI installs it through a marketplace and records it in installed_plugins.json,
# so `marketplace` is the honest answer for where that version came from. The
# github fallback is not speculative — it reads the mechanism field a row
# actually carries, so a source-of-truth that is a repository names the
# repository rather than a scheme nobody would recognise.
_doctor_source_of() {  # <name> -> one of the source words
  local name="${1:-}" kind mech owner_repo
  kind="$(dep_field "$name" kind)"
  mech="$(dep_field "$name" source_url)"
  case "$kind" in
    native)             echo "marketplace" ;;
    brew-dep|brew-cask) echo "brew" ;;
    npm-global)         echo "npm -g" ;;
    uv-tool)            echo "uv tool" ;;
    mcp-server)         echo "MCP" ;;
    statusline)         echo "npm -g" ;;
    playwright-browser) echo "playwright cache" ;;
    pnpm-store)         echo "pnpm" ;;
    *)
      case "$mech" in
        https://github.com/*|http://github.com/*)
          owner_repo="${mech#*github.com/}"; owner_repo="${owner_repo%.git}"
          echo "github ${owner_repo}" ;;
        *:*) echo "${mech%%:*}" ;;
        *)   echo "${mech:-unknown}" ;;
      esac ;;
  esac
}

# WHY A ROW HAS NO VERSION, said in the version column's own terms. `—` is the
# cell, and the state cell has to earn it: a reader who sees a dash where every
# neighbouring row carries a number is owed the reason, and "unknown" alone is
# the shrug this report is not allowed to make. Keyed on the mechanism, because
# the mechanism is what does or does not keep a version.
_doctor_no_version_reason() {  # <kind>
  case "${1:-}" in
    mcp-server) echo "an MCP registration records no version" ;;
    statusline) echo "npm has no global record of it" ;;
    pnpm-store) echo "a content-addressable cache, no version surface" ;;
    *)          echo "this mechanism records no version" ;;
  esac
}

# ─── Facts, gathered once ────────────────────────────────────────────────────
#
# Every function called here is one of detect.sh's, deps.sh's or env.sh's. Nothing
# below re-derives a fact from the filesystem that a library already owns.

PLUGIN_FACT="$(detect_plugin_integrity)"
PLUGIN_VERSION="${PLUGIN_FACT#plugin: version=}"; PLUGIN_VERSION="${PLUGIN_VERSION%% *}"
PLUGIN_HOOKS="${PLUGIN_FACT##*hooks=}"

AGENT_FACT="$(detect_agent_integrity)"
AGENT_STATE="${AGENT_FACT#*state=}";       AGENT_STATE="${AGENT_STATE%% *}"
AGENT_TOTAL="${AGENT_FACT#*total=}";       AGENT_TOTAL="${AGENT_TOTAL%% *}"
AGENT_MODIFIED="${AGENT_FACT#*modified=}"; AGENT_MODIFIED="${AGENT_MODIFIED%% *}"
AGENT_NAMES="${AGENT_FACT#*names=}";       AGENT_NAMES="${AGENT_NAMES%% *}"
AGENT_CAUSE="${AGENT_FACT##*cause=}"

TODO_FACT="$(detect_env_todo_tools)";        TODO_STATE="${TODO_FACT##*present=}"
RC_PROXY_FACT="$(detect_rc_claude_proxy)";   RC_PROXY_STATE="${RC_PROXY_FACT##*present=}"
LEGACY_HOOK_FACT="$(detect_legacy_channel_hooks)"; LEGACY_HOOK_COUNT="${LEGACY_HOOK_FACT##*count=}"
SKILL_COPY_FACT="$(detect_legacy_skill_copy)"
SKILL_COPY_PATH="${SKILL_COPY_FACT##*path=}"
HOOK_FILES_FACT="$(detect_legacy_hook_files)"
HOOK_FILES_COUNT="${HOOK_FILES_FACT#*count=}"; HOOK_FILES_COUNT="${HOOK_FILES_COUNT%% *}"
HOOK_FILES_PATH="${HOOK_FILES_FACT#*path=}";   HOOK_FILES_PATH="${HOOK_FILES_PATH%% *}"
HOOK_FILES_CAUSE="${HOOK_FILES_FACT##*cause=}"
# `cause=` is present only on the unknown line, so on the ordinary line the
# strip-longest above returns the whole record. Cleared here rather than parsed
# twice, so the render below can test it for emptiness.
case "$HOOK_FILES_FACT" in *" cause="*) ;; *) HOOK_FILES_CAUSE="" ;; esac
STATUSLINE_NPX_FACT="$(detect_statusline_npx_command)"
STATUSLINE_NPX_STATE="${STATUSLINE_NPX_FACT##*present=}"
# THE TREE THE REGISTRY NAMES, NOT THE ONE THE USER IS STANDING IN (AC-20,
# handoff 4.3). `detect_registry_sha_lag` defaults its repo directory to `$PWD`,
# and doctor used to call it bare — so the commit in the header above and the
# whole directory-feed version row below were facts about the caller's cwd
# rather than about the plugin the CLI is running. Run from an unrelated
# repository, doctor compared the registry's recorded sha against THAT
# repository's HEAD and reported `not-in-repo` about a build nobody had asked
# it about. `installPath` is the CLI's own record of where the install landed,
# which is the only directory the comparison means anything against.
#
# THE FALLBACK IS THE SAME ANSWER BY THE OTHER ROUTE, never the cwd:
# `plugin_root` (lib/roots.sh) honours BIONIC_PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT and
# otherwise resolves from the library's own location. A registry that names no
# installPath at all is a registry `detect_registry_sha_lag` will answer
# `unknown` about anyway, so nothing is lost and nothing is guessed.
# AND THE CANDIDATE THAT IS A REPOSITORY WINS, measured rather than assumed.
# On a GIT feed the registry's installPath is the cache the CLI loads, and the
# comparison is meaningful there. On a DIRECTORY feed — every dogfood install —
# the registry records the cache too, but the CLI reads the SOURCE TREE and never
# opens that cache: comparing a recorded sha against a directory with no history
# would answer `unknown` forever and take the header's commit down with it, on
# exactly the machines this row is most useful. So the registry's answer is tried
# first and the plugin root second, and the first one that is a git repository is
# the one asked. Both are registry-derived; NEITHER is the cwd, which is the
# whole point.
DOCTOR_INSTALL_PATH="$(detect_plugin_install_path bionic 2>/dev/null)" || DOCTOR_INSTALL_PATH=""
_doctor_is_repo() { ( cd "${1:-/nonexistent}" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); }
if [ -z "$DOCTOR_INSTALL_PATH" ] || ! _doctor_is_repo "$DOCTOR_INSTALL_PATH"; then
  _doctor_root_alt="$(plugin_root)"
  if _doctor_is_repo "$_doctor_root_alt"; then DOCTOR_INSTALL_PATH="$_doctor_root_alt"; fi
  [ -n "$DOCTOR_INSTALL_PATH" ] || DOCTOR_INSTALL_PATH="$_doctor_root_alt"
fi
REG_SHA_FACT="$(detect_registry_sha_lag "$DOCTOR_INSTALL_PATH")"
REG_SHA_STATE="${REG_SHA_FACT#*state=}"; REG_SHA_STATE="${REG_SHA_STATE%% *}"
REG_SHA_REG="${REG_SHA_FACT#*registry=}"; REG_SHA_REG="${REG_SHA_REG%% *}"
REG_SHA_REPO="${REG_SHA_FACT#*repo=}";    REG_SHA_REPO="${REG_SHA_REPO%% *}"
REG_SHA_CAUSE="${REG_SHA_FACT##*cause=}"

# WHICH FEED THIS MACHINE CAME FROM, read once and reused everywhere below that
# branches on it (the header's sha choice, and F5's version row) — the same
# "gather once" discipline as every other fact on this page.
FEED_KIND="$(detect_marketplace_feed_kind)"

# WHICH TREE THE CLI LOADS THE PLUGIN FROM (W4 4/4). Read once here, printed once
# near the header below — the same "gather once" discipline as FEED_KIND above.
MP_SOURCE_PATH="$(detect_marketplace_source_path)"; MP_SOURCE_STATE=$?

# THE COMMIT THE HEADER NAMES IS THE ONE THE CLI IS RUNNING, which is not always
# the one the registry recorded. On a directory-source feed the CLI reads the
# TREE — the registry copy is a lagging snapshot nothing executes (W7 A5.1) — so
# on that feed, and only on that feed, a lag resolves to the tree's own HEAD.
# Printing the registry's sha there would put a commit in the header that no
# behaviour on this machine comes from, which is the one thing a provenance line
# must never do.
_doctor_sha8() { printf '%.8s' "${1:-}"; }
case "$REG_SHA_STATE" in
  match)       PAYLOAD_SHA="$(_doctor_sha8 "$REG_SHA_REG")" ;;
  lag)
    if [ "$FEED_KIND" = "directory" ]; then
      PAYLOAD_SHA="$(_doctor_sha8 "$REG_SHA_REPO")"
    else
      PAYLOAD_SHA="$(_doctor_sha8 "$REG_SHA_REG")"
    fi ;;
  not-in-repo) PAYLOAD_SHA="$(_doctor_sha8 "$REG_SHA_REG")" ;;
  *)           PAYLOAD_SHA="unknown" ;;
esac
[ -n "$PAYLOAD_SHA" ] || PAYLOAD_SHA="unknown"

# INSTALLED-VS-LATEST, PER FEED KIND (F5, epic-19 wave-01, spec AC-F5). Only
# the git feed needs the marketplace-clone compare — a directory feed's
# version row is built straight from REG_SHA_STATE + detect_reconverge_hint
# above, so nothing new is gathered for it here.
if [ "$FEED_KIND" = "git" ]; then
  LATEST_FACT="$(detect_plugin_latest)"
  LATEST_STATE="${LATEST_FACT#*state=}";         LATEST_STATE="${LATEST_STATE%% *}"
  LATEST_INSTALLED="${LATEST_FACT#*installed=}"; LATEST_INSTALLED="${LATEST_INSTALLED%% *}"
  LATEST_LATEST="${LATEST_FACT#*latest=}";       LATEST_LATEST="${LATEST_LATEST%% *}"
  LATEST_CAUSE="${LATEST_FACT##*cause=}"
fi

HOOK_WIRING_FACT="$(detect_hook_wiring)"
HOOK_TOTAL="${HOOK_WIRING_FACT#*total=}";     HOOK_TOTAL="${HOOK_TOTAL%% *}"
HOOK_RESOLVING="${HOOK_WIRING_FACT##*resolving=}"

# ─── What the payload itself carries ─────────────────────────────────────────
#
# THE PLUGIN'S OWN INVENTORY, counted from the tree the CLI resolved. Skills and
# commands have no checksum manifest the way the role files do — nothing declares
# how many there ought to be — so the denominator is what the payload directory
# holds and the numerator is how much of it is actually usable: a skill directory
# without its SKILL.md, a command file that is empty. On a whole payload those
# are equal, which is the point of printing them as `n/n` rather than as `n`: the
# reader sees at a glance both that the count is right and what it is counted
# against.
#
# COUNTED HERE, not in a library, and that is the same judgement `_doctor_roster_counts`
# already makes two hundred lines down for every OTHER plugin's install path.
# This is a directory listing, not a schema parse — there is no second reading of
# a format that could drift away from a first one, which is what the RV-7 rule
# against re-deriving facts in this file is protecting against.
_doctor_payload_root="$(plugin_root)"
SKILLS_TOTAL=0; SKILLS_OK=0; SKILL_NAMES=""
for _sk in "$_doctor_payload_root"/skills/*/; do
  [ -d "$_sk" ] || continue
  SKILLS_TOTAL=$((SKILLS_TOTAL + 1))
  _sk_name="${_sk%/}"; _sk_name="${_sk_name##*/}"
  SKILL_NAMES="${SKILL_NAMES}${SKILL_NAMES:+, }${_sk_name}"
  [ -s "${_sk}SKILL.md" ] && SKILLS_OK=$((SKILLS_OK + 1))
done
COMMANDS_TOTAL=0; COMMANDS_OK=0; COMMAND_NAMES=""
for _cm in "$_doctor_payload_root"/commands/*.md; do
  [ -f "$_cm" ] || continue
  COMMANDS_TOTAL=$((COMMANDS_TOTAL + 1))
  _cm_name="${_cm##*/}"; _cm_name="${_cm_name%.md}"
  COMMAND_NAMES="${COMMAND_NAMES}${COMMAND_NAMES:+, }${_cm_name}"
  [ -s "$_cm" ] && COMMANDS_OK=$((COMMANDS_OK + 1))
done

# ─── The walls, and whether they can still read a command ────────────────────
#
# THE ONE FACT THIS REPORT GATHERS BY RUNNING SOMEBODY ELSE'S CODE (AC-15,
# handoff 3.1). Four hooks stand over actions that cannot be taken back or
# cannot be re-classified — protect-main and the evidence gate refuse a command
# they cannot read, farm-out-reminder and background-suite-guard classify one —
# and each of them finds its library through the loader idiom
# (payload/scripts/lib/loader.sh, spec AC-16). A wall whose library has gone
# missing is the lockout this whole wave is named for: the wall fires, cannot
# read, and refuses everything including the command that would repair it.
#
# ASKED THROUGH THE IDIOM ITSELF, never through a copy of it. `bionic_loader_pin`
# prints the canonical block; it runs here in a child shell whose `$0` is the
# HOOK'S OWN PATH, which is the single input the block's candidate list is a
# function of. So this row cannot drift from what the hook will do when it
# fires — a re-implementation of "beside the hook, then the marketplace source,
# then the newest cache version" would be a fourth copy of the thing the pin
# exists to keep at one.
#
# READ-ONLY, LIKE EVERYTHING ELSE HERE. The block sets three variables and
# defines two functions; it executes neither `loader_fail_open` nor
# `loader_fail_closed`, so nothing refuses and nothing exits on doctor's behalf.
#
# THE WANTED BASENAMES COME FROM THE HOOK, not from a list kept here. A hook
# that adopts the idiom declares them on a `BIONIC_LIB_WANT=` line above the
# block; one that has not yet adopted it names its library in the `lib/<name>.sh`
# path it sources. Either way the answer is the hook's own, so this row keeps
# telling the truth across the slice that rewrites the hooks.
# THE ROSTER AND THE PROBE ARE lib/checks.sh's (1.5.1). A wall missing from the
# payload is a row of the check table like any other — a fact bionic needs true,
# with a party that repairs it — so the list of walls, "which libraries does this
# hook want" and "can it get them" live beside the rest of the table, and this
# page renders them. The detectors there are the same two questions this loop
# asks, which is what lets the table say who repairs a broken wall without a
# second copy of how to find one.

WALLS_TOTAL=0; WALLS_OK=0; WALL_ROWS=""
for _wall in $BIONIC_WALL_HOOKS; do
  WALLS_TOTAL=$((WALLS_TOTAL + 1))
  # ONE VERDICT, ASKED OF THE TABLE (Step-6 review B-2). This loop used to
  # re-implement `is the file readable` and `does the loader answer` beside the
  # detectors in lib/checks.sh that ask the same two questions — and those
  # detectors were never invoked, so the copy doctor ran and the copy the rows
  # named could drift apart with nothing going red. `bionic_check_wall_state` is
  # the one implementation; this page renders its answer.
  # Asked ONCE per wall: the state carries a loader probe, and asking twice would
  # be a second `bash -c` per row for an answer already in hand.
  _wall_state="$(bionic_check_wall_state "$_wall")"
  case "$_wall_state" in
    (ok)
      WALLS_OK=$((WALLS_OK + 1))
      ;;
    (missing)
      WALL_ROWS="${WALL_ROWS}$(_doctor_native_row "$DOCTOR_BAD" "wall" "—" \
        "${_wall} is not in this payload — reinstall the plugin")"$'\n'
      fix "the ${_wall} wall is missing from the payload → $(bionic_check_hint wall-payload)"
      ;;
    (unloadable=*)
      _wall_missing="${_wall_state#unloadable=}"
      WALL_ROWS="${WALL_ROWS}$(_doctor_native_row "$DOCTOR_BAD" "wall" "—" \
        "${_wall} cannot load ${_wall_missing}")"$'\n'
      fix "the ${_wall} wall cannot load ${_wall_missing} → $(bionic_check_hint wall-library)"
      ;;
  esac
done

INST_AGENT_FACT="$(detect_installed_agent_copies)"
INST_AGENT_STATE="${INST_AGENT_FACT#*state=}"; INST_AGENT_STATE="${INST_AGENT_STATE%% *}"
INST_AGENT_TOTAL="${INST_AGENT_FACT#*total=}"; INST_AGENT_TOTAL="${INST_AGENT_TOTAL%% *}"
INST_AGENT_DRIFT="${INST_AGENT_FACT#*drift=}"; INST_AGENT_DRIFT="${INST_AGENT_DRIFT%% *}"
INST_AGENT_NAMES="${INST_AGENT_FACT#*names=}"; INST_AGENT_NAMES="${INST_AGENT_NAMES%% *}"
INST_AGENT_CAUSE="${INST_AGENT_FACT##*cause=}"
HALF_FACT="$(detect_half_uninstalled)";      HALF_STATE="${HALF_FACT##*half-uninstalled=}"

HAVE_JQ=yes; command -v jq >/dev/null 2>&1 || HAVE_JQ=no

# ─── The two facts that come from outside this machine's files ───────────────
#
# LOAD STATE is the CLI's own conclusion and is not written anywhere readable, so
# the probe runs the listing — bounded, because a wedged CLI must not wedge the
# diagnosis of the machine it is wedging.
#
# THE FIELD SPLIT. `load-state=<s> error=<e>` in the three determinate states;
# `unknown` adds ` cause=<text>` (A-4.S2.4). `error` can hold spaces and the CLI's
# own punctuation, so it is taken to the end of the line and then trimmed of the
# cause suffix when there is one — the reverse order would truncate an error at
# the first space.
LOAD_FACT="$(detect_bounded "$(detect_probe_seconds)" detect_plugin_load_state "$BIONIC_PLUGIN_ID")"
LOAD_RC=$?
if [ "$LOAD_RC" = "124" ] || [ -z "$LOAD_FACT" ]; then
  LOAD_STATE="unknown"
  LOAD_ERROR="-"
  LOAD_CAUSE="the plugin listing did not answer within $(detect_probe_seconds) seconds"
else
  LOAD_STATE="${LOAD_FACT#load-state=}"; LOAD_STATE="${LOAD_STATE%% *}"
  LOAD_ERROR="${LOAD_FACT#*error=}"
  case "$LOAD_FACT" in
    *" cause="*) LOAD_CAUSE="${LOAD_FACT##* cause=}"; LOAD_ERROR="${LOAD_ERROR%% cause=*}" ;;
    *)           LOAD_CAUSE="" ;;
  esac
fi

# DUPLICATES: zero or more lines, each already carrying its own consolidation
# command. Silence means none — except that the probe never stays silent when it
# could not look (A-4.S2.8), which is why an unreadable registry arrives here as
# a `dup=unknown` line rather than as nothing. The bound is the probe's own now
# (W6 S15): the registry read runs `jq` over a path that can stall, so it goes
# through the same `detect_bounded` the listing does, and a stalled read arrives
# here as one more `dup=unknown` line with the seconds in its cause.
DUP_LINES="$(bionic_check_duplicate_lines)"

# ONE PLUGIN, REGISTERED TWICE — READ HERE, PRINTED IN TABLE 1 (AC-23). The scan
# ran on every invocation and reached no reader at all. Two registrations of one
# bare name means two payloads answering to the same id, and which of them a
# session loads is the CLI's business rather than anything a user chose — so each
# row names the ids and raises the exact consolidation command
# `_detect_duplicate_fix` already computed. Silence is the healthy case; the probe
# deliberately never stays silent when it could not LOOK, which arrives as a
# `dup=unknown` line and prints as an honest `–` with its cause.
#
# THE ROWS ARE BUILT HERE AND PRINTED LATER, because `fix` is collected before
# anything is printed — FIX is the second section on the page, and a fix raised
# from inside a render is a fix the verdict has already gone past.
DUP_ROWS=""
while IFS= read -r _dup_line; do
  [ -n "$_dup_line" ] || continue
  _dup_bare="${_dup_line#dup=}";  _dup_bare="${_dup_bare%% *}"
  if [ "$_dup_bare" = "unknown" ]; then
    _dup_cause="${_dup_line##*cause=}"
    DUP_ROWS="${DUP_ROWS}$(_doctor_native_row "$DOCTOR_NIL" "duplicates" "?" \
      "unknown — ${_dup_cause}")"$'\n'
  else
    _dup_ids="${_dup_line#*ids=}";  _dup_ids="${_dup_ids%% *}"
    _dup_fix="${_dup_line#*fix=}"
    DUP_ROWS="${DUP_ROWS}$(_doctor_native_row "$DOCTOR_BAD" "duplicates" "$_dup_bare" \
      "registered twice: ${_dup_ids//,/, }")"$'\n'
    fix "${_dup_bare} is registered twice → ${_dup_fix}"
  fi
done <<EOF
$DUP_LINES
EOF

# ─── The dependency sweep ────────────────────────────────────────────────────
#
# One pass over the table produces three renderings at once — the dependency
# rows, the roster-footprint rows, and the degradation map — because they are
# three views of the same facts and a second pass would be a second chance to
# disagree with the first.

# The installed tree of a plugin-shaped dependency, as the CLI recorded it, comes from
# detect.sh's `detect_plugin_install_path` — the same parse `detect_plugin_root` resolves
# bionic through. `installPath` is the registry's own answer to "where did this land", which
# is what makes the roster count a measurement rather than a guess about layout.
#
# THIS USED TO BE A SECOND PARSE (Step-6 review, RV-7). A local `_doctor_install_path` read
# the same CLI-internal schema with its own jq program, which is a duplication that cannot
# be noticed from either side: the CLI renames a field, the pinned copy in detect.sh gets
# fixed, and this one keeps answering in the old shape just as confidently. It also left
# detect_plugin_root with zero production callsites (RV-4) — the parse under test was the
# parse nobody ran. Deleting the local copy discharges both: one reading, and it is the
# reading the suite drives.
#
# TWO THINGS IMPROVED IN THE MOVE, both in the direction of answering rather than shrugging.
# The local copy gave up outright without `jq`; the shared parse has an awk lane, so a
# jq-less box now gets real roster counts instead of `unknown` wherever presence itself was
# knowable. And the shared parse checks that the recorded directory EXISTS, so a stale
# registry entry reports as unreadable here rather than as a confident count of zero.

# ROSTER FOOTPRINT, the counting method (design-ledger D6). Skill and agent
# METADATA — name plus description — is what loads into every session; the
# bodies are just-in-time. So a dependency's session cost is the number of skill
# and agent entries it contributes, and the layout the CLI installs says exactly
# where those live: one `skills/<slug>/SKILL.md` per skill, one `agents/<name>.md`
# per agent, under the registry's `installPath`. Counting the files IS counting
# the roster lines. A dependency that is not plugin-shaped — a binary, an npm
# package, an MCP registration — carries no skill or agent metadata, so it costs
# nothing at all.
#
# THE BRANCH IS ON SHAPE, NOT ON CLASS, and that distinction is a corrected bug
# (S3's hand-on). It used to key on the old dependency-lane code, which meant
# "installed by the harness" — and impeccable installs through the CLI exactly
# like the two core plugins while belonging to a different class. Keyed the old
# way, an INSTALLED plugin contributing a skill to every session was reported as
# contributing zero.
_doctor_roster_counts() {  # <install-path> -> "<skills> <agents>"
  local root="${1:-}" p skills=0 agents=0
  for p in "$root"/skills/*/SKILL.md; do [ -f "$p" ] && skills=$((skills + 1)); done
  for p in "$root"/agents/*.md;       do [ -f "$p" ] && agents=$((agents + 1)); done
  echo "${skills} ${agents}"
}

DEP_ROWS=""
THIRD_ROWS=""
ROSTER_ROWS=""
DEP_VERSIONS=""
N_PRESENT=0; N_ABSENT=0; N_UNKNOWN=0; N_VIOLATION=0
N_ABSENT_ACTIONABLE=0; N_ABSENT_WHEN_NEEDED=0; N_ABSENT_CORE=0
ROSTER_TOTAL=0; ROSTER_TOTAL_KNOWN=yes
ROSTER_ZERO=0
ABSENT_NAMES=""
ABSENT_CORE_NAMES=""

while IFS= read -r dep_name; do
  [ -n "$dep_name" ] || continue
  fact="$(detect_dep "$dep_name")" || continue

  present="${fact#*present=}";     present="${present%% *}"
  dep_version="${fact#*version=}"; dep_version="${dep_version%% *}"
  constraint="${fact#*constraint=}"; constraint="${constraint%% *}"
  verdict="${fact##*verdict=}"
  # WHEN bionic installs it, and HOW. `class` is what the table now declares and
  # what this report prints; `kind` names the install mechanism and decides the
  # two branches below that are about shape rather than policy.
  dep_class="$(dep_field "$dep_name" class)"
  kind="$(dep_field "$dep_name" kind)"

  DEP_VERSIONS="${DEP_VERSIONS}${dep_name}	${dep_version}"$'\n'

  # THE SYMBOL IS THE VERDICT COLUMN (AC-15 rule 1). The table used to carry the
  # word `ok`/`violation` in a sixth column; ✓/✗/– says the same thing in column
  # one, where a reader scanning twenty rows for the one that is wrong is already
  # looking. `violation` survives as the row's tail because it names WHICH kind of
  # wrong, which a symbol cannot, and the unknown rows carry their cause there for
  # the same reason.
  case "$present" in
    yes) if [ "$verdict" = "violation" ]; then dep_sym="$DOCTOR_BAD"; dep_tail="violation"
         else dep_sym="$DOCTOR_OK"; dep_tail=""; fi ;;
    no)  dep_tail=""
         if [ "$dep_class" = "when-needed" ]; then dep_sym="$DOCTOR_NIL"; dep_tail="installs on first use"
         else dep_sym="$DOCTOR_BAD"; fi ;;
    # STALE IS A REPAIR, NOT AN ABSENCE (AC-17). It reached this file folded into
    # the catch-all below, so a venv one lockfile behind rendered as `unknown`
    # beside a cause about a mechanism with no presence surface — and setup, on
    # the same reading, would have offered to install a renderer plainly sitting
    # on the machine. The ✗ is matched by the FIX line raised in the tallies.
    stale) dep_sym="$DOCTOR_BAD"; dep_tail="stale against the shipped uv.lock" ;;
    *)   dep_tail="$(_doctor_unknown_cause "$kind")"
         # A cache with no presence surface is never a ✗: nothing can make it
         # readable, so marking it broken would keep doctor from ever saying
         # "nothing to do" (Chris 2026-08-22).
         case "${dep_class}/${kind}" in
           when-needed/*|*/pnpm-store) dep_sym="$DOCTOR_NIL" ;;
           *)                          dep_sym="$DOCTOR_BAD" ;;
         esac ;;
  esac
  [ "$present" = "no" ] && dep_version="-"
  DEP_ROWS="${DEP_ROWS}$(_doctor_rtrim "$(printf '  %s %-12s %-20s %-8s %-9s %-11s %s' \
    "$dep_sym" "$dep_class" "$dep_name" "$(_doctor_word "$present")" \
    "$dep_version" "$constraint" "$dep_tail")")"$'\n'

  # ── the certified THIRD PARTY row ──
  #
  # A LITERAL VERSION WHEREVER ONE EXISTS. That is the whole point of the table:
  # `present` is a yes/no a user already assumed, and the version is the fact
  # that settles whether the thing on this machine is the thing the constraint
  # was written about. So a row reaches for a number twice — once through the
  # library's own probe, and once more through the npx cache for the one
  # mechanism whose probe cannot pin a version by construction — and only prints
  # `—` when there is genuinely nothing on disk to read.
  #
  # AND THE DASH IS NEVER BARE. Where a version could not be had, the state cell
  # says which mechanism could not keep one. A dash on its own reads as a bug in
  # this report rather than as a property of the thing being reported.
  third_version="$dep_version"
  third_state=""
  third_keep=""
  # THE ROUTE IS THE ROW'S, NOT THIS FILE'S (1.5.1). Which party repairs this
  # dependency is a fact about the dependency, and lib/checks.sh holds it: a
  # `basic` or `extra` row is setup's, a `core` row is the CLI's (deps.sh D1
  # forbids setup a second installer), and a `when-needed` row has no repair at
  # all because it is absent by design until a route asks for it. Reading the
  # hint here instead of spelling it means the four state arms below cannot
  # disagree with each other about who to send the reader to — which they did:
  # the violation arm and the unknown arm both said `/bionic:setup` for a core
  # row that the absent arm correctly sent to the CLI.
  _doctor_dep_hint="$(bionic_check_dep_hint "$dep_name" 2>/dev/null)" || _doctor_dep_hint=""
  # MULTI-PART ROWS SAY WHAT IS PRESENT (Chris 2026-08-22: "Why is ccstatusline
  # 'ok' for version, with no status?"). The two-half probes return a status word
  # in the version slot — it is not a version and never prints as one. The
  # version comes from wherever the mechanism actually keeps one (the npx cache,
  # the clone's HEAD), and the state cell names the halves that are in place.
  if [ "$present" = "yes" ]; then
    case "$kind" in
      statusline)
        # A REAL GLOBAL INSTALL NOW (epic-21 AC-3): ccstatusline installs
        # through `npm install -g`, not `npx`, so its version is read the
        # same way every other npm-global row's is — `npm list -g` — rather
        # than a cache that nothing writes into any more.
        third_version="$(_dep_check_npm_global "$dep_name")"; third_version="${third_version##*|}"
        third_state="command set, layout file in place" ;;
      mcp-server)
        [ "$third_version" = "unknown" ] && \
          third_version="$(dep_npx_version "$(_dep_locator_target "$(dep_field "$dep_name" source_url)")")" ;;
      github-skill)
        third_version="$(git -C "$(_dep_skills_dir)/${dep_name}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
        ;;
      uv-tool)
        [ "$dep_name" = "notebooklm" ] && third_state="tool and Claude skill both installed" ;;
    esac
  fi
  case "$present" in
    yes)
      if [ "$verdict" = "violation" ]; then
        third_state="violates ${constraint}${_doctor_dep_hint:+ → ${_doctor_dep_hint}}"
      elif [ "$third_version" = "unknown" ] && [ -z "$third_state" ]; then
        third_state="$(_doctor_no_version_reason "$kind")"
      fi ;;
    no)
      # THREE CLASSES, THREE OWNERS (bionic 1.4.4 fixit, AC-1). A `when-needed`
      # tool is absent by design until a route asks for it. A `basic` or `extra`
      # row is setup's — deps.sh's install arms do install it — and keeps the
      # hint it always had. A `core` row is neither: the CLI installed it
      # alongside bionic and setup has no item that can put it back, so the hint
      # it used to carry named a command that plans nothing for this row. The
      # route comes from deps.sh, which owns it for all four renderers — this
      # row, the headline core-absence line below, setup's absent arm and
      # setup's load-failure arm — and rides in the instruction slot so a cut
      # can never reach it.
      if   [ "$dep_class" = "when-needed" ]; then third_state="installs on demand"
      elif [ "$dep_class" = "core" ]; then third_state="absent"; third_keep="${_doctor_dep_hint:+ → ${_doctor_dep_hint}}"
      else third_state="not installed${_doctor_dep_hint:+ → ${_doctor_dep_hint}}"; fi ;;
    stale)
      third_state="stale against uv.lock${_doctor_dep_hint:+ — re-sync with ${_doctor_dep_hint}}" ;;
    *)
      third_state="$(_doctor_unknown_cause "$kind")"
      case "${dep_class}/${kind}" in
        when-needed/*) ;;
        */pnpm-store)  third_state="${third_state} — setup pre-warms it" ;;
        *)             third_state="${third_state}${_doctor_dep_hint:+ → ${_doctor_dep_hint}}" ;;
      esac ;;
  esac
  case "$third_version" in unknown|-|"") third_version="—" ;; esac
  THIRD_ROWS="${THIRD_ROWS}$(_doctor_third_row "$dep_sym" "$dep_name" "$third_version" \
    "$(_doctor_source_of "$dep_name")" "$third_state" "$third_keep")"$'\n'

  # ── roster footprint ──
  #
  # ZERO IS FILLER (AC-15 rule 4). A dependency that is not plugin-shaped
  # contributes nothing to the session roster, and so does one that is not
  # installed — fourteen such rows on this machine, each a line saying nothing.
  # They are counted here and printed as a single line below. An `unknown` is NOT
  # filler and keeps its own row: it is a number this report could not take, and
  # collapsing it into a count of zeroes would report an unreadable machine as a
  # cheap one.
  if [ "$kind" != "native" ] || [ "$present" = "no" ]; then
    ROSTER_ZERO=$((ROSTER_ZERO + 1))
  elif [ "$present" = "unknown" ]; then
    ROSTER_ROWS="${ROSTER_ROWS}$(_doctor_rtrim "$(printf '  %s %-21s %-9s %s' \
      "$DOCTOR_NIL" "$dep_name" "unknown" "$(_doctor_unknown_cause "$kind")")")"$'\n'
    ROSTER_TOTAL_KNOWN=no
  else
    install_path="$(detect_plugin_install_path "$dep_name")" || install_path=""
    if [ -z "$install_path" ] || [ ! -d "$install_path" ]; then
      ROSTER_ROWS="${ROSTER_ROWS}$(_doctor_rtrim "$(printf '  %s %-21s %-9s %s' \
        "$DOCTOR_NIL" "$dep_name" "unknown" "no readable installPath in the registry")")"$'\n'
      ROSTER_TOTAL_KNOWN=no
    else
      counts="$(_doctor_roster_counts "$install_path")"
      n_skills="${counts%% *}"; n_agents="${counts##* }"
      roster_lines=$((n_skills + n_agents))
      if [ "$roster_lines" = "0" ]; then
        ROSTER_ZERO=$((ROSTER_ZERO + 1))
      else
        ROSTER_ROWS="${ROSTER_ROWS}$(_doctor_rtrim "$(printf '  %s %-21s %-9s %s' \
          "$DOCTOR_OK" "$dep_name" "$roster_lines" \
          "${n_skills} $(_doctor_plural "$n_skills" skill skills) + ${n_agents} $(_doctor_plural "$n_agents" agent agents)")")"$'\n'
      fi
      ROSTER_TOTAL=$((ROSTER_TOTAL + roster_lines))
    fi
  fi

  # ── tallies and the degradation map ──
  #
  # AN ABSENT WHEN-NEEDED TOOL IS NOT A DEGRADATION (D-B, ratified 2026-08-20).
  # Absence is its NORMAL state: these install at the moment a route first needs
  # them, so a machine that has never run that route is correct to be without
  # them. Doctor used to call every absence a degradation and raise a matching
  # action, which told users to repair a machine that was working — and told them
  # to run the one command that would not have installed it anyway, since setup
  # deliberately never asks about these rows.
  #
  # AND A NO-ACTION LINE IS NOT A FIX (AC-15 rule 2). The degradation map used to
  # carry a line for every unusual row, including the when-needed ones whose line
  # ended "no action needed" — a problem list with entries that are not problems,
  # which is how a reader learns to skip the list. Those rows say what they are in
  # the DEPENDENCIES table (`– … installs on first use`) and reach FIX never.
  case "$present" in
    yes)
      N_PRESENT=$((N_PRESENT + 1))
      if [ "$verdict" = "violation" ]; then
        N_VIOLATION=$((N_VIOLATION + 1))
        case "$dep_class" in
          when-needed)
            fix "${dep_name} ${dep_version} violates constraint ${constraint} → the next route that needs it reinstalls it" ;;
          *)
            fix "${dep_name} ${dep_version} violates constraint ${constraint}${_doctor_dep_hint:+ → run ${_doctor_dep_hint}}" ;;
        esac
      fi
      ;;
    stale)
      # Counted with the violations rather than the absences: the thing is there
      # and it is wrong, which is what a violation is. The fix names a re-sync so
      # the reader is not told to install what they already have.
      N_VIOLATION=$((N_VIOLATION + 1))
      fix "${dep_name} is stale against the shipped uv.lock${_doctor_dep_hint:+ → run ${_doctor_dep_hint}}" ;;
    no)
      N_ABSENT=$((N_ABSENT + 1))
      case "$dep_class" in
        when-needed)
          N_ABSENT_WHEN_NEEDED=$((N_ABSENT_WHEN_NEEDED + 1)) ;;
        # COUNTED APART, BECAUSE THE COMMAND IS NOT THE SAME ONE (bionic 1.4.4
        # fixit, AC-2). The line below collapses absences into a single
        # `→ run /bionic:setup`, which is only honest while every name on it is
        # a name that command installs. A core dependency is not, so folding one
        # in put a name setup cannot act on into the one line a reader acts on
        # first. It gets its own line, with its own route, further down.
        core)
          N_ABSENT_CORE=$((N_ABSENT_CORE + 1))
          ABSENT_CORE_NAMES="${ABSENT_CORE_NAMES}${ABSENT_CORE_NAMES:+, }${dep_name}" ;;
        *)
          N_ABSENT_ACTIONABLE=$((N_ABSENT_ACTIONABLE + 1))
          # NAMED HERE, PRINTED AS ONE LINE BELOW. Eleven absences on a cold
          # machine are eleven problems with one identical command, and eleven
          # copies of `run /bionic:setup` is the filler rule 4 exists to stop.
          # The names are what the reader needs; the command is said once.
          ABSENT_NAMES="${ABSENT_NAMES}${ABSENT_NAMES:+, }${dep_name}" ;;
      esac
      ;;
    *)
      N_UNKNOWN=$((N_UNKNOWN + 1))
      # KEYED ON THE CLASS, WHICH IS WHAT THE SENTENCE IS ABOUT (six-axis review
      # C-2). This branch used to key on the mechanism — `pnpm-store` rows were
      # told "/bionic:setup re-warms the store either way" — and that was true
      # only while setup walked every non-native row. Setup now asks about
      # `core|basic|extra` and AC-11 makes a when-needed tool nobody's to install
      # until a route needs it, so the old clause named a command that would not
      # touch the row. A when-needed unknown has the same non-action as a
      # when-needed absence, and for the same reason — so it earns no FIX line.
      #
      # AMENDED 2026-08-22: TWO FACTS DECIDE THIS SENTENCE, and they are
      # orthogonal. The CLASS says whose job the row is. The MECHANISM says
      # whether the unknown can ever be RESOLVED — the pnpm store is a cache with
      # no installed-state to read, so "resolve the cause, then re-run doctor"
      # names a repair that does not exist. Class alone was enough while the only
      # such row was `when-needed`; the ruling that made `motion` an `extra` sent
      # it straight to the sentence about a repair nobody can perform.
      case "${dep_class}/${kind}" in
        when-needed/*) ;;
        */pnpm-store)  ;;
        *) fix "${dep_name} presence is unknown → resolve $(_doctor_unknown_cause "$kind"), then re-run /bionic:doctor" ;;
      esac
      ;;
  esac
done < <(dep_names)

# ─── The one address this page is about ──────────────────────────────────────
#
# THE ONE ADDRESS EVERY READER MUST AGREE ON. `project_root` (lib/root.sh) is the
# SSoT: the nearest ancestor holding a REAL `.bionic/` directory, after a linked
# worktree has been mapped onto its main repository. Every project-scoped row on
# this page reads the same address space the hooks do, which is the whole point
# of there being one function — a doctor answering about a different root than
# the wall it is diagnosing would be worse than a doctor that stayed quiet.
#
# RESOLVED HERE, BEFORE THE PATROL SECTION, and not where the run rows begin
# (FIX-DOCTOR/1). It used to be computed a hundred lines further down, which is
# how the Patrol section came to have no project filter at all: the address it
# would have had to filter on did not exist yet at the point it renders.
DOCTOR_ROOT="$(project_root "$PWD" 2>/dev/null)"
[ -n "$DOCTOR_ROOT" ] || DOCTOR_ROOT="$PWD"

# DOES THIS SESSION BELONG TO THE PROJECT BEING DIAGNOSED (T3 finding 1,
# 2026-09-03). Driven cold from a probe project, doctor printed a PATROL section
# naming two sessions from two OTHER projects while the `active run` row three
# lines below resolved the probe project's own plan — one page, two answers about
# which machine it was describing. Every live-session reader on this page now
# passes through here.
#
# THROUGH THE LIBRARY, NEVER A STRING COMPARE. A session records the cwd the CLI
# was started in, which is routinely a SUBDIRECTORY of its project, and on macOS
# routinely the /tmp spelling of a /private/tmp path. `project_root` resolves
# both — it canonicalises with `pwd -P` and walks for the `.bionic` — so the
# comparison is between two answers from the same function rather than between
# two spellings of a path. The `restart needed` row below did compare literally
# (`_rs_cwd = DOCTOR_ROOT`) and silently missed every session standing one
# directory in; it reads this instead.
#
# THE ANSWER IS MEMOISED because `project_root` shells out to git twice per call
# and this page asks about the same handful of cwds from three separate loops.
_DOCTOR_HERE_MEMO=""
_doctor_session_here() {  # <session cwd> -> 0 when it resolves onto DOCTOR_ROOT
  local cwd="${1:-}" line root
  [ -n "$cwd" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "${cwd}"$'\t'*) [ "${line#*$'\t'}" = "$DOCTOR_ROOT" ] && return 0; return 1 ;;
    esac
  done <<EOF
$_DOCTOR_HERE_MEMO
EOF
  root="$(project_root "$cwd" 2>/dev/null)" || root=""
  _DOCTOR_HERE_MEMO="${_DOCTOR_HERE_MEMO}${cwd}"$'\t'"${root}"$'\n'
  [ -n "$root" ] && [ "$root" = "$DOCTOR_ROOT" ]
}

# ─── The Patrol, gathered and rendered before the fix accounting ─────────────
#
# RUNNING PATROLS OR NOTHING (F3, epic-19 wave-01 — design ledger ratification
# round 2, 2026-08-27). Chris's own invariant is the whole rationale: an
# active run has exactly one Patrol armed, and F6 makes a dead one self-healing
# — the dispatch wall re-arms it the moment a dispatch needs it — so a reader
# of this page has nothing to act on beyond "is one running, and how much is
# it carrying". Everything this section used to reconstruct beyond that — the
# session's cwd, cron ids and prompt heads, the stamp's age and interval
# provenance, the dispatch-wall tally — answered a question this page no longer
# asks; that machinery still lives in lib/patrol.sh, doctor just stops rendering
# it. Two exceptions, both ratified:
#
#   - TWO Patrols armed on one session is always wrong regardless of how minimal
#     this page gets, so its fix line stays — and it costs nothing in the
#     healthy, single-Patrol case.
#   - THE STAMP'S STATE IS READ AGAIN, and rendered nowhere. Minimising this
#     section deleted the parse arm along with the row, and with it the only
#     fact that could tell an armed Patrol from a dead one — see the gate on
#     `_patrol_flush` below, which is where the whole argument lives. "Running
#     Patrols or nothing" needs a way to know which; this is the only one.
PATROL_ROWS=""
_patrol_add() { PATROL_ROWS="${PATROL_ROWS}$1"$'\n'; }
PATROL_LIVE=0

PATROL_LINES="$(patrol_report 2>/dev/null)"

_p_sid=""; _p_jobs=""; _p_n_patrol=0; _p_open=0; _p_present=""; _p_stamp=""; _p_blind=""
_p_here=""

# WHY THE JOB COUNT ALONE CANNOT ANSWER "IS IT RUNNING" (Step-6 correctness C1,
# a FAIL against AC-F3). The jobs on this page are RECONSTRUCTED FROM THE
# TRANSCRIPT — `CronCreate` tool_uses minus the ids a `CronDelete` names
# (lib/patrol.sh) — and the four events that actually kill a Patrol delete the
# job from the CLI's in-memory cron table with no tool call behind them: a
# `claude plugin update`, a `/reload-plugins`, a session continue, a `/clear`
# and resume. The transcript cannot observe any of them. So after any one, the
# count is still positive and this section printed `✓ session … · N open
# dispatches` for a Patrol that no longer exists — the very failure F6 shipped a
# whole hook to detect, with doctor contradicting that hook on the same machine.
#
# THE STAMP IS THE ONLY FACT ON THIS PAGE THAT KNOWS. hooks/session-poker.sh
# touches it on every tick, so its age answers "did this thing fire recently"
# where the transcript answers only "was it ever asked for". Slice 4/2 removed
# this parse arm while minimising the section; lib/patrol.sh never stopped
# emitting it. Restored here with a smaller job than it had — it renders
# nothing, it GATES.
#
#   firing      — the row prints, exactly as before.
#   not-firing  — a stamp that has gone stale: armed, and no longer ticking.
#                 No row (F3's ratified rule is running-or-nothing, and a dead
#                 Patrol is nothing), and one FIX line, because this is the one
#                 state of the three that a person can and should act on.
#   anything else — never armed, or deliberately ended: the disarm verb REMOVES
#                 the stamp (S10), so an absent stamp is a decision, not a
#                 fault. No row and no fix line, which is what the section
#                 already does for a machine with no Patrol at all.
_patrol_flush() {
  [ -n "$_p_sid" ] || return 0
  # THIS PROJECT'S SESSIONS ONLY (T3 finding 1). lib/patrol.sh walks every live
  # CLI process on the machine — that is its job, and hooks/session-poker.sh
  # wants the whole fleet — so the narrowing belongs to the renderer. Set from
  # the session's own recorded cwd, resolved through `project_root`; a session
  # belonging to another project is dropped whole, its rows and its fix lines
  # together, because a repair addressed to a project the reader is not standing
  # in is not a repair they can make.
  [ "$_p_here" = "yes" ] || return 0
  [ "$_p_n_patrol" -gt 0 ] || return 0
  local short="${_p_sid%%-*}" j id extras="" n open=0 blind="${_p_blind}"
  case "$blind" in ''|*[!0-9]*) blind=0 ;; esac
  case "$_p_stamp" in
    firing)
      PATROL_LIVE=$((PATROL_LIVE + 1))
      # ENGAGED / NOT ENGAGED — report only (T4/AC-16). `engaged_session` is
      # the same single switch every run-scoped hook reads first (lib/run.sh);
      # doctor changes nothing on disk, it only says which side of it this
      # session's marker is on. Computed once, read by both rows below, so a
      # bystander session (no marker) reads the same whether or not its
      # roster is present.
      local _p_engaged="not engaged"
      engaged_session "$DOCTOR_ROOT" "$_p_sid" && _p_engaged="engaged"
      # AN ABSENT ROSTER IS NOT A ZERO, and printing it as one is the defect
      # this arm exists to end (Chris 2026-08-29, on 1.3.0: `✓ session 61be8dc9 ·
      # 0 open dispatches` on a machine running two agents). The launch-time
      # hook does not survive a continue, a /clear+resume or a /reload-plugins,
      # so a long session can lose the wall and never write a roster file at
      # all — and `0 open dispatches` is then a number nobody dispatched,
      # printed beside a Patrol whose every tick was emitting `NOTIFY
      # wall-blind`. lib/patrol.sh has always said which of the two it is
      # (`present=yes|no`); this is the first renderer to read it.
      #
      # THE ROW KEEPS ITS ✓ BECAUSE THE PATROL IS RUNNING. Running-or-nothing
      # (F3) is about the Patrol, and the stamp above has already answered that
      # question; the roster is a different object, and its absence is what the
      # text says rather than what the symbol implies.
      #
      # AN ABSENT FILE IS NOT YET A DEFECT — `blind` IS (Step-6 correctness
      # FLAG, t1-six-axis-review §1). The roster file is created by the FIRST
      # dispatch: hooks/dispatch-preflight.sh:1337-1344 appends its header and
      # its first row together, and no hook pre-creates it at session start. So
      # `present=no` describes two different machines — a session whose wall was
      # lost and is launching agents nobody recorded, and a perfectly healthy
      # session that has simply not dispatched anything yet. Only the first has
      # something unrecorded, and `blind` (launches the roster never saw, from
      # the same `patrol-wall/v1` record the fix line below reads) is the field
      # that tells them apart. Gating on the file alone would print `roster
      # absent — launches unrecorded` over a session with no launches — the same
      # class of untrue claim this arm exists to end, pointed the other way — so
      # a zero `blind` falls through to the ordinary count row, where `0 open
      # dispatches` is what 1.3.0 printed and was TRUE.
      if [ "$_p_present" = "yes" ] || [ "$blind" -eq 0 ]; then
        open="$_p_open"
        _patrol_add "  ${DOCTOR_OK} session ${short} · ${open} open $(_doctor_plural "$open" dispatch dispatches) · ${_p_engaged}"
      else
        _patrol_add "  ${DOCTOR_OK} session ${short} · roster absent — launches unrecorded · ${_p_engaged}"
      fi
      # THE COUNT IS THE ACTIONABLE HALF. Doctor is now the ONE surface for this
      # fact — the tick's `NOTIFY wall-blind` diagnosis was deleted in 1.4.0
      # (slice ADOPT; it had no "no active run" branch and false-fired pre-plan),
      # so there is no second speller to agree with; tests/doctor-patrol.test.sh
      # §9 pins the `patrol-wall/v1` record this reads and the library that
      # defines it. It is printed for a present-but-incomplete roster too: the
      # row's open count stays true, and this line says what it does not cover.
      #
      # THE LINE ENDS IN THE COMMAND and carries no cause clause, which is
      # doctor's first format rule meeting lib/width.sh's 100 columns — the
      # spelled-out cause ran the line to 116. The row above already names the
      # absence, and the cure names the repair.
      if [ "$blind" -gt 0 ]; then
        fix "session ${short}: ${blind} $(_doctor_plural "$blind" launch launches) unrostered → re-invoke /bionic:canonical-sdlc"
      fi ;;
    not-firing)
      fix "session ${short}: the Patrol is armed but not firing → ask Claude to re-arm the Patrol" ;;
  esac

  # THE DUPLICATE VERDICT KEEPS THE NEWEST and names every older one. Creation
  # order is what the transcript gives, and the newest job is the one whose
  # prompt reflects the run as it now stands — an older duplicate is a leftover
  # from an arming that was repeated, which is exactly how the second one gets
  # there.
  if [ "$_p_n_patrol" -gt 1 ]; then
    n=0
    while IFS= read -r j; do
      [ -n "$j" ] || continue
      n=$((n + 1))
      [ "$n" -lt "$_p_n_patrol" ] || continue
      id="$j"
      [ "$id" = "?" ] && continue
      extras="${extras}${extras:+ }${id}"
    done <<EOF
$_p_jobs
EOF
    [ -n "$extras" ] && \
      fix "session ${short} has ${_p_n_patrol} Patrol jobs armed → CronDelete ${extras}"
  fi
}

while IFS= read -r _p_line; do
  [ -n "$_p_line" ] || continue
  case "$_p_line" in
    "patrol-session/v1|"*)
      _patrol_flush
      _p_sid="$(_doctor_pfield "$_p_line" session)"
      _p_jobs=""; _p_n_patrol=0; _p_open=0; _p_present=""; _p_stamp=""; _p_blind=""
      _p_here=no
      if _doctor_session_here "$(_doctor_pfield "$_p_line" cwd)"; then _p_here=yes; fi ;;
    "patrol-job/v1|"*)
      if [ "$(_doctor_pfield "$_p_line" kind)" = "patrol" ]; then
        _p_n_patrol=$((_p_n_patrol + 1))
        _p_jobs="${_p_jobs}$(_doctor_pfield "$_p_line" id)"$'\n'
      fi ;;
    "patrol-stamp/v1|"*)
      # Read for the gate above and rendered nowhere — the stamp's age,
      # interval and provenance stay deleted (spec AC-F3).
      _p_stamp="$(_doctor_pfield "$_p_line" state)" ;;
    "patrol-roster/v1|"*)
      _p_open="$(_doctor_pfield "$_p_line" open)"
      _p_present="$(_doctor_pfield "$_p_line" present)" ;;
    "patrol-wall/v1|"*)
      # LAUNCHES THE ROSTER NEVER SAW, already computed and already net of
      # refusals (lib/patrol.sh: agents - rostered - refused, floored at 0). The
      # field is EMPTY when the transcript could not be read at all — no jq on
      # the box, no file under projects/ — and an empty count is not a count, so
      # `_patrol_flush` treats it as zero rather than as an alarm. A machine
      # without jq gets a quieter page, never a false one.
      _p_blind="$(_doctor_pfield "$_p_line" blind)" ;;
  esac
done <<EOF
$PATROL_LINES
EOF
_patrol_flush

# ─── This project: the run, its predecessors, and the machine ────────────────
#
# `DOCTOR_ROOT` and `_doctor_session_here` are resolved ABOVE the Patrol section
# now — that section is the page's first project-scoped reader, and it cannot
# scope itself to an address that has not been computed yet (FIX-DOCTOR/1).

RUN_ROWS=""
_run_add() { RUN_ROWS="${RUN_ROWS}$1"$'\n'; }

# THE ACTIVE RUN, AS THE WALLS SEE IT (AC-8). `active_run` is the predicate every
# always-on hook gates its own work behind; printed here rather than re-derived,
# so a person can tell a machine whose walls are armed from one whose walls are
# inert. The path is home-relative for the same reason every other path on this
# page is — it is what fits, and it is what a person would type.
#
# THE AGE IS THE PLAN'S OWN mtime, which is what "is anyone still working on
# this" actually turns on. A `current:` alone says a run was opened; a `current:`
# next to a fortnight of silence says something else.
_doctor_run_plan="$(active_run "$DOCTOR_ROOT" 2>/dev/null)" || _doctor_run_plan=""
if [ -n "$_doctor_run_plan" ]; then
  _doctor_run_step="$(grep -m1 '^current:' "$_doctor_run_plan" 2>/dev/null \
                      | sed -e 's/^current:[[:space:]]*//' -e 's/[[:space:]]*$//')"
  _doctor_run_age="$(_doctor_file_age "$_doctor_run_plan")"
  # PROJECT-RELATIVE, not home-relative: every plan path starts
  # `<root>/.bionic/docs/plans/`, and the segment that identifies WHICH run is at
  # the far end — exactly where a truncation bites. Dropping the root is what
  # buys that end enough room to survive.
  _doctor_run_rel="${_doctor_run_plan#"${DOCTOR_ROOT}/"}"
  # AND THE STEP AND THE AGE ARE WHAT MUST SURVIVE THE CUT. They are the two
  # facts a reader acts on — armed or not, and still moving or not — so they go
  # in as the protected tail and the path absorbs the whole shortfall.
  _run_add "$(_doctor_rtrim "$(bionic_line \
    "$(printf '  %s %-30s ' "$DOCTOR_OK" "active run")" \
    "$_doctor_run_rel" " · current: ${_doctor_run_step:-?} · ${_doctor_run_age}")")"
else
  _run_add "$(_doctor_item "$DOCTOR_NIL" "active run" "none — no open plan under this root")"
fi

# PREDECESSOR ROSTERS (AC-4's doctor line). A `/clear` re-keys the session — the
# env and the hook payload both (probe A-probe-1/2) — and leaves the previous
# session's roster on disk with rows nobody will ever close. Those rows are the
# agents that outlived the conversation that launched them.
#
# COUNTED HERE, THROUGH THE LIBRARY, AND NEVER THROUGH THE TICK'S ADOPT VERB.
# `patrol_roster_state` is lib/patrol.sh's own reader — the same subtraction the
# Patrol section above already trusts — and doctor stays a rendering surface that
# runs nothing which could write. A roster whose session is LIVE is the Patrol
# section's subject, not this one's; only the ones whose owner is gone are listed.
# ONE LINE PER DEAD SESSION, AND IT COUNTS FILES (1.5.1 T5, defect
# fixit-1.5.2-dead-session-sweep.md). Two things changed here. The set is now
# every session with ANY session-keyed state whose owner is gone, taken from
# `patrol_dead_sessions` — the same walk `session-poker.sh sweep` deletes with,
# so the row and the cure it names cannot disagree. And the row fires on FILES,
# not on open rows: the session this defect was filed on had every row landed
# and six files on disk, so an open-row test rendered nothing while the
# directory kept growing. The open count still rides on the line when there is
# one, because a row nobody will close is worth more to a reader than a count of
# files.
#
# THE RESOURCES SECTION READS `_doctor_dead_sids` BELOW and drops the same
# sessions' attestations, so a dead session costs this page ONE line rather than
# one per section — the standing owner note (2026-08-23) that the per-session
# dump is noise, answered by collapsing rather than by hiding.
_doctor_dead_sids=""
_doctor_dead_n=0
while IFS= read -r _dead_sid; do
  [ -n "$_dead_sid" ] || continue
  _doctor_dead_sids="${_doctor_dead_sids} ${_dead_sid} "
  _doctor_dead_n=$((_doctor_dead_n + 1))
  _dead_files=0
  while IFS= read -r _dead_f; do
    [ -n "$_dead_f" ] && _dead_files=$((_dead_files + 1))
  done <<EOF2
$(patrol_session_state_files "$DOCTOR_ROOT" "$_dead_sid")
EOF2
  _dead_state="$(patrol_roster_state "$DOCTOR_ROOT" "$_dead_sid" 2>/dev/null)"
  _dead_open="$(_doctor_pfield "$_dead_state" open)"
  case "$_dead_open" in ''|*[!0-9]*) _dead_open=0 ;; esac
  # $DOCTOR_NIL, NOT $DOCTOR_BAD (R2, ticket-30; doctor-reads.test.sh 12f18's
  # own rule: "every ✗ row is a problem", count >= rows on the whole page).
  # Before R2 this line WAS the problem — the only cure was the raw script
  # named below, and every dead session that had one raised N_FIX by one via
  # the (now-removed) unconditional fix() call, keeping count == rows. Now
  # hooks/session-start.sh sweeps this routinely (REQ-R2) and the fix() call
  # below fires only when THAT auto-sweep itself failed — so a predecessor line
  # with no failure marker is informational history, not a problem nobody can
  # act on, and marking it ✗ while N_FIX stops counting it would be exactly
  # the count-less-than-rows defect 12f18 exists to catch. `active run: none`
  # a few lines above this loop uses the same glyph for the same reason: a
  # true fact about this project's state that names no action.
  if [ "$_dead_open" -gt 0 ]; then
    _run_add "$(_doctor_item "$DOCTOR_NIL" "predecessor ${_dead_sid%%-*}" \
      "${_dead_files} leftover $(_doctor_plural "$_dead_files" file files) · ${_dead_open} open $(_doctor_plural "$_dead_open" row rows) — a /clear left them unclosed")"
  else
    _run_add "$(_doctor_item "$DOCTOR_NIL" "predecessor ${_dead_sid%%-*}" \
      "${_dead_files} leftover $(_doctor_plural "$_dead_files" file files) — nothing open; the session is gone")"
  fi
done <<EOF
$(patrol_dead_sessions "$DOCTOR_ROOT" "${CLAUDE_CODE_SESSION_ID:-}")
EOF

# THE LINE THAT NAMES THE CURE, from the row rather than from a literal here —
# the same shape the legacy-symlink row below uses.
#
# R2 NARROWED WHAT RAISES THIS LINE (ticket-30). Before R2 this fired whenever
# `_doctor_dead_n > 0` — a session doctor had proven dead but nobody had a way to
# clear, which was true for every predecessor UNTIL hooks/session-start.sh started
# clearing them itself (REQ-R2). With the auto-sweep in place, "a dead session's
# residue exists right now" is the ordinary, self-healing state between a `/clear`
# and the next session start — the ✗ `predecessor …` rows above still say so, every
# time, because that is still informative — and firing THIS line on the same fact
# would turn a healthy, temporary gap into a permanent "N problems" count that
# never reaches zero. What is actually worth a fix line now is the auto-sweep
# itself failing, which `checks.sh`'s row answers from session-start.sh's own
# failure marker rather than from `_doctor_dead_n`.
if bionic_check_fires dead-session-state; then
  _doctor_sweep_rc="$(bionic_check_sweep_failed_rc)"
  fix "the automatic dead-session sweep failed (rc=${_doctor_sweep_rc:-?}) → $(bionic_check_hint dead-session-state)"
fi

# LEGACY `.bionic` SYMLINKS (AC-11). spawn-worktree.sh used to plant
# `<wt>/.bionic -> <main>/.bionic`. lib/root.sh now steps OVER such a link and
# never roots on it (design-ledger C2), so one left on disk is a second path to
# the same state that nothing reads and nobody expects. Listed by name; the
# worktree verb that deletes them is the repair, and it is named on the row.
#
# `-L` BEFORE `-d`, because a symlink to a directory satisfies both — the same
# order lib/root.sh's own walk tests them in.
_doctor_links=""; _doctor_link_n=0
for _wt in "${DOCTOR_ROOT}/.worktrees/"*; do
  [ -d "$_wt" ] || continue
  [ -L "${_wt}/.bionic" ] || continue
  _doctor_link_n=$((_doctor_link_n + 1))
  _wt_name="${_wt##*/}"
  _doctor_links="${_doctor_links}${_doctor_links:+, }${_wt_name}"
done
if [ "$_doctor_link_n" -gt 0 ]; then
  _run_add "$(_doctor_item "$DOCTOR_BAD" "legacy .bionic symlinks" \
    "${_doctor_link_n} under .worktrees/ (${_doctor_links})")"
  # THE NAMES STAY ON THE ROW, NOT ON THIS LINE. A fix line in FIX_LINES_OTHER
  # is now bounded by the render loop (AC-6), so a long list here would be
  # ELIDED rather than overflow — which is a worse answer than not putting it
  # here at all. The line carries the count and the command; the row above
  # carries the list, whole.
  fix "${_doctor_link_n} legacy .bionic $(_doctor_plural "$_doctor_link_n" symlink symlinks) under .worktrees/ → spawn-worktree.sh remove"
fi

# RESTART NEEDED (AC-37, fold-in ratified 2026-09-03; the dead-wall incident,
# session b1a850c1 FINDING 2026-09-03T02:06Z, carried in the plan's
# Assumptions). The CLI snapshots hooks.json once, at process start; a hook
# file changing on disk after that moment registers nothing in the process
# already running — every wall this wave built stays inert in that process
# until it exits and a new one starts. This is the one residual way a wall can
# be silently dead after this wave, and nothing else on this page detects it.
#
# THE SAME TREE THE VERSION ROW ALREADY RESOLVED (DOCTOR_INSTALL_PATH,
# DOCTOR/5), never re-derived: the registry's recorded installPath, or the
# plugin root, whichever is a git repository — that is the plugin tree the CLI
# actually loads. A live CLI session in THIS project whose startedAt precedes
# that tree's hooks.json mtime registered it as it stood before the file
# changed.
_doctor_hooks_json="${DOCTOR_INSTALL_PATH}/hooks/hooks.json"
_doctor_hooks_mtime="$(_patrol_mtime "$_doctor_hooks_json" 2>/dev/null)"
case "$_doctor_hooks_mtime" in ''|*[!0-9]*) _doctor_hooks_mtime="" ;; esac

# UTC, SHORT. Everywhere else on this page an absolute time renders as a
# relative age (`_doctor_file_age`) — this is the one row where which SIDE of
# the restart a moment falls on is the fact, so the actual clock reads print
# rather than an elapsed duration.
_doctor_utc_short() {  # <epoch-seconds> -> "2026-09-03 02:06Z", or empty
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  date -u -r "$s" +'%Y-%m-%d %H:%MZ' 2>/dev/null || date -u -d "@${s}" +'%Y-%m-%d %H:%MZ' 2>/dev/null
}

if [ -n "$_doctor_hooks_mtime" ]; then
  while IFS= read -r _rs_line; do
    [ -n "$_rs_line" ] || continue
    # RESOLVED, NOT COMPARED (FIX-DOCTOR/2). A session standing one directory
    # inside this project records that subdirectory as its cwd, and the literal
    # equality this line used to be silently skipped it — a stale registration
    # in the very session the reader is sitting in, never reported.
    _rs_cwd="$(_doctor_pfield "$_rs_line" cwd)"
    _doctor_session_here "$_rs_cwd" || continue
    _rs_pid="$(_doctor_pfield "$_rs_line" pid)"
    _rs_sf="$(claude_home)/sessions/${_rs_pid}.json"
    _rs_started_ms="$(command -v jq >/dev/null 2>&1 && jq -r '.startedAt // empty' "$_rs_sf" 2>/dev/null)"
    case "$_rs_started_ms" in ''|*[!0-9]*) continue ;; esac
    _rs_started_sec=$(( _rs_started_ms / 1000 ))
    [ "$_doctor_hooks_mtime" -gt "$_rs_started_sec" ] || continue
    _rs_started_fmt="$(_doctor_utc_short "$_rs_started_sec")"
    _rs_hooks_fmt="$(_doctor_utc_short "$_doctor_hooks_mtime")"
    _run_add "$(_doctor_item "$DOCTOR_BAD" "restart needed" \
      "pid ${_rs_pid} started ${_rs_started_fmt:-?} — hooks.json changed ${_rs_hooks_fmt:-?}")"
    # THE FACT GOES IN FRONT OF THE ARROW AND THE COMMAND IS THE WHOLE TAIL
    # (wave-01 S4, AC-6's precondition). This line used to carry a second clause
    # AFTER its command — `… start it again — the running process registered
    # hooks.json as it was at <time>` — which put the fact a reader compares
    # against on the far side of the instruction and ran the line to 148
    # columns. `fix` splits on the FIRST arrow, so everything past it is the
    # command, and the render loop protects exactly that: a tail that is half
    # instruction and half evidence cannot be protected, and the 1.4.4 fixit
    # reverted a loop-wide bound (dd07b33) rather than move the evidence. It
    # moves here. The timestamp is the problem's own — which hooks.json this
    # process is holding — and the row above pairs it with the file's mtime.
    fix "pid ${_rs_pid} registered hooks.json as it was at ${_rs_started_fmt:-$_rs_started_ms} → exit claude and start it again"
  done <<EOF
$(patrol_live_sessions 2>/dev/null)
EOF
fi

# ─── The machine, and the budget each live session recorded on it ────────────
#
# THE READER IS THE SCHEMA'S OWNER (AC-25, L-RESOURCES/1). The attestation format
# lives in hooks/preflight-probe.sh, so "which versions are readable" belongs
# beside the writer that produces them rather than copied into doctor, the Step-0
# display and the tick. `--read` is strictly read-only: no lock, no prune, no
# session key, and exit 5 for anything it does not recognise.
#
# A VERSION-1 RECORD IS NOT A FAILURE. preflight-probe loads its resources
# library FAIL-OPEN — resources are a context probe, never a blocking one — so a
# machine whose library could not be read still attests, at version 1, with no
# budget in it. "no budget recorded" is the honest rendering of that; five empty
# fields dressed as a budget would not be.
RESOURCES_ROWS=""
_res_add() { RESOURCES_ROWS="${RESOURCES_ROWS}$1"$'\n'; }

_doctor_probe_line="$(resources_probe 2>/dev/null)"
if [ -n "$_doctor_probe_line" ]; then
  _p_get() { printf '%s' "$_doctor_probe_line" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }
  _res_add "$(_doctor_item "$DOCTOR_NIL" "machine" \
    "$(_p_get cores) cores · $(_p_get mem_gb) GB · $(_p_get disk_free_gb) GB free · load $(_p_get load_1m) · $(_p_get os)")"
else
  _res_add "$(_doctor_item "$DOCTOR_NIL" "machine" "unknown — the resources probe did not answer")"
fi

# THE SET IS THE FILES IN THIS PROJECT, NOT THE MACHINE'S LIVE SESSIONS
# (FIX-DOCTOR/3, T3 finding 2). This loop was keyed on `patrol_live_sessions` —
# every live CLI process anywhere on the machine — and asked of each whether an
# attestation under ITS id existed here. Two wrong sets in one predicate: other
# projects' sessions were iterated at all, and this project's own records were
# dropped the instant their writer exited. A `/clear` re-keys the session, so the
# session that TOOK the attestation is routinely gone by the time anyone runs
# doctor; the driven page said `none has taken an attestation in this project`
# with `preflight-4241a5cd….state` sitting in the directory it was naming.
#
# `<root>/.bionic/tmp/preflight-*.state` IS WHAT THE FALLBACK LINE IS A CLAIM
# ABOUT, so it is what gets read. The path bounds the set to this project by
# construction — no cwd resolution needed, and no other project can contribute a
# row — and liveness stops being part of the question, which is right: an
# attestation is a record of a measurement that happened, not a property of a
# process that is still running.
#
# A GLOB, THE SAME WAY THE PREDECESSOR-ROSTER LOOP ABOVE READS ITS OWN FILES —
# bash sorts a pathname expansion, so the page is stable across runs without
# spending `ls` or `sort` on it. Doctor's header rule is that a diagnosis must
# not need coreutils to run on the broken machine it exists for.
_doctor_probe_sh="${_doctor_payload_root}/hooks/preflight-probe.sh"
_doctor_budgets=0
# The attestations this loop SKIPPED because their session is gone. Counted, not
# discarded: the fallback line below is a claim about the directory, and a claim
# that nothing is here is false while these files are.
_doctor_att_dead=0
for _l_att in "${DOCTOR_ROOT}/.bionic/tmp/"preflight-*.state; do
  [ -f "$_l_att" ] || continue
  _l_sid="${_l_att##*/preflight-}"; _l_sid="${_l_sid%.state}"
  [ -n "$_l_sid" ] || continue
  # A DEAD SESSION'S ATTESTATION IS RESIDUE, NOT A RECORD ANYONE READS (1.5.1
  # T5). It is already one line in the run section above, where the fix line
  # names the verb that removes it; a second line here would report the same
  # session twice and would keep the fallback below from ever saying what it is
  # for. FIX-DOCTOR/3's rule — that an attestation survives its writer exiting —
  # is untouched: that is about a session that is gone from the PROCESS TABLE
  # mid-run, and this drops only the ones whose whole state is being offered for
  # deletion on the same page.
  case "$_doctor_dead_sids" in
    *" ${_l_sid} "*) _doctor_att_dead=$((_doctor_att_dead + 1)); continue ;;
  esac
  _doctor_budgets=$((_doctor_budgets + 1))
  if ! _l_rec="$(bash "$_doctor_probe_sh" --read "$_l_att" 2>/dev/null)"; then
    _res_add "$(_doctor_item "$DOCTOR_NIL" "session ${_l_sid%%-*}" \
      "its attestation is not one this build can read")"
    continue
  fi
  _l_budget="$(printf '%s\n' "$_l_rec" | grep -m1 '^budget=' | cut -d= -f2-)"
  if [ -n "$_l_budget" ]; then
    _res_add "$(_doctor_item "$DOCTOR_OK" "session ${_l_sid%%-*}" "$_l_budget")"
  else
    _res_add "$(_doctor_item "$DOCTOR_NIL" "session ${_l_sid%%-*}" "no budget recorded")"
  fi
done
# THE FALLBACK IS A CLAIM ABOUT THIS DIRECTORY, so it has to survive the collapse
# above (FIX-DOCTOR/3, T3 finding 2: doctor once said "none has taken an
# attestation in this project" with an attestation file sitting in the directory
# it was naming). Dropping a dead session's row would have re-created exactly
# that sentence on a project whose every attestation belongs to a session that
# has since exited — so when that is why this section is empty, the line says so
# and sends the reader to the section that names the repair.
if [ "$_doctor_budgets" -eq 0 ] && [ "$_doctor_att_dead" -gt 0 ]; then
  _res_add "$(_doctor_item "$DOCTOR_NIL" "no live session" \
    "${_doctor_att_dead} $(_doctor_plural "$_doctor_att_dead" attestation attestations) here, every one from a session that is gone — see PATROL")"
elif [ "$_doctor_budgets" -eq 0 ]; then
  _res_add "$(_doctor_item "$DOCTOR_NIL" "no session" "none has taken an attestation in this project")"
fi

# ─── What is left to fix ─────────────────────────────────────────────────────
#
# COLLECTED BEFORE ANYTHING IS PRINTED, because FIX is the second section on the
# page and the facts that fill it are discovered all the way down this file. The
# dependency sweep above has already contributed its lines; what follows is the
# machine-level half — the states that are not about one dependency.
#
# ONE LINE PER PROBLEM, ENDING IN THE COMMAND (AC-15 rule 2). The report used to
# say each of these twice: once in the degradation map as a fact, once in the
# summary as an action. One section now, one line, and the line ends with what to
# type.

# LOAD STATE FIRST, for the reason its section leads: on a machine where the
# plugin did not load, every other line here is advice about a payload nothing is
# running. `unknown` earns no line — nobody can act on "I could not tell", and
# the section names why.
case "$LOAD_STATE" in
  failed)
    fix "bionic is installed but the CLI refused to load it → install what LOAD STATE names" ;;
  absent)
    fix "bionic is not installed for this CLI → claude plugin install ${BIONIC_PLUGIN_ID}" ;;
esac

# Half-uninstalled next: it is the one state /bionic:setup cannot repair, because
# the command surface itself is gone. The curl door is the fix (D5a — the remover
# must not depend on the thing it removes).
#
# THE ONE FIX THAT TAKES TWO LINES, and deliberately. Every other line here fits
# inside 100 columns; this one carries a raw GitHub URL inside a pipefail wrapper
# and cannot. A command the reader has to unwrap from a wrapped line is worse
# than a command on a line of its own, so the problem is stated and the command
# is given whole underneath it.
if [ "$HALF_STATE" = "yes" ]; then
  fix "this machine is half-uninstalled — the CLI no longer knows bionic. Finish with:"
fi
# The command itself is printed by the verdict's render loop, on its own line
# under this one — see the `HALF_STATE` echo there. It was appended to a third
# accumulator here until 1.5.1, which nothing printed, so the copy that reached
# the reader was always that one. The `set -o pipefail` wrapper it carries is not
# decoration: `curl … | bash` reports BASH's status, and bash handed an empty
# stream exits 0, so a fetch that 404s (a moved script, no network, a private
# repo) would leave the user with a command that looked like it worked and
# removed nothing.

# THE RETIRED INSTALLER'S LEFTOVERS, raised HERE rather than beside the rows they
# explain — this whole section runs before anything is printed, and a fix raised
# from inside a render is a fix the verdict has already gone past (AC-23; the
# rows themselves are in ENVIRONMENT, far below).
#
# AND EACH OF THEM IS DECIDED ONCE, HERE (Step-6 recheck part 4, ruling R-2). Five
# of these leftovers were decided TWICE — once for the fix line in this section and
# once for the row in ENVIRONMENT below — by re-applying the table's rule to the
# raw fact instead of asking the table. That is exactly the shape B-1 was in when
# doctor ticked an environment name setup was still offering to repair: two owners
# for one question, agreeing until they didn't. The raw facts stay: the lines and
# rows print COUNTS, NAMES and PATHS out of them, and `unknown` is still read here
# because "we could not look" is a different question from "it fires". What the
# raw facts no longer decide is whether the row fires.
#
# `legacy-alias` is where the two rules had ALREADY drifted, which is why this is
# not only tidiness: `bionic_check_legacy_alias` also fires on the pre-marker
# `alias claude=…--dangerously-skip-permissions` spelling, which no `bionic:start`
# block wraps, and this file's own test read the marker and nothing else. On such
# a machine setup offered the removal and this page said nothing. The two names
# that carried that second rule — and the marker probe behind them, which the
# detector runs itself — are gone from the fact block above with it.
#
# The claude-proxy line 90 lines below is NOT on this list, deliberately; the
# comment above it says why.
HOOK_FILES_FIRES=no;   bionic_check_fires legacy-hook-files   && HOOK_FILES_FIRES=yes
AGENT_COPIES_FIRES=no; bionic_check_fires legacy-agent-copies && AGENT_COPIES_FIRES=yes
LEGACY_ALIAS_FIRES=no; bionic_check_fires legacy-alias        && LEGACY_ALIAS_FIRES=yes
LEGACY_HOOKS_FIRES=no; bionic_check_fires legacy-hooks        && LEGACY_HOOKS_FIRES=yes
SKILL_COPY_FIRES=no;   bionic_check_fires legacy-skill-copy   && SKILL_COPY_FIRES=yes

if [ "$HOOK_FILES_FIRES" = "yes" ]; then
  fix "${HOOK_FILES_COUNT} legacy hook $(_doctor_plural "$HOOK_FILES_COUNT" file files) in the claude-home → run $(bionic_check_hint legacy-hook-files)"
fi
if [ "$AGENT_COPIES_FIRES" = "yes" ]; then
  fix "${INST_AGENT_DRIFT} installed agent $(_doctor_plural "$INST_AGENT_DRIFT" copy copies) differ from the payload → run $(bionic_check_hint legacy-agent-copies)"
fi

# jq next: it gates several of the facts above, so acting on anything else while
# the report is partly unreadable is acting on half a diagnosis.
if [ "$HAVE_JQ" = "no" ]; then
  fix "several facts below read unknown without it → install jq ($(bionic_check_hint tool:jq) does)"
fi

# THE ABSENCES AS ONE LINE, NAMED. The ACTIONABLE absences, not every absence: a
# when-needed tool is absent by design until a route asks for it, and setup would
# not install it if it ran. The names are truncated rather than wrapped — a cold
# machine has eleven of them and the line has 100 columns.
if [ -n "$ABSENT_NAMES" ]; then
  # THROUGH THE ONE TRUNCATOR (wave-01 S4, fixit B-11). This was the last
  # hand-rolled cut on the page: `${#s} -gt 44` then `printf '%.41s'` plus an
  # ellipsis, which is 42 columns and not the 44 it names, counts BYTES where
  # the rest of the report counts columns, and cuts mid-glyph on a multi-byte
  # name — the three failures `bionic_trunc` was written to end. The cap stays
  # 44; what changes is who applies it, and that the line now cuts to the 44 it
  # says. The line itself is a `/bionic:setup` fix, so it lands on the collapsed
  # verdict line, which bounds the whole sentence at 100 a second time.
  _doctor_absent_list="$(bionic_trunc "$ABSENT_NAMES" 44)"
  # AN AGGREGATE LINE READS THE PARTY, NOT A ROW. It stands for many rows at
  # once, so there is no single row to ask; `bionic_check_route` is where the
  # party's own command is spelled, and it is the same string every one of those
  # rows carries.
  fix "${N_ABSENT_ACTIONABLE} $(_doctor_plural "$N_ABSENT_ACTIONABLE" dependency dependencies) absent (${_doctor_absent_list}) → run $(bionic_check_route setup)" \
      "$N_ABSENT_ACTIONABLE"
fi

# THE CORE ABSENCES, ON THEIR OWN LINE AND WITH THEIR OWN COMMAND. Same shape as
# the line above — one line, the names truncated rather than wrapped — and a
# different owner: the CLI installed these alongside bionic, so the route is
# deps.sh's `dep_core_repair_route` and not /bionic:setup. `fix` sorts on the
# suffix, so this line lands in FIX_LINES_OTHER and gets its own line under the
# verdict instead of being folded into the collapsed setup list.
if [ -n "$ABSENT_CORE_NAMES" ]; then
  _doctor_core_route="$(bionic_check_route cli)"
  _doctor_core_head="${N_ABSENT_CORE} core $(_doctor_plural "$N_ABSENT_CORE" dependency dependencies) absent ("
  # THE BUDGET IS THIS LINE'S OWN, AND IT IS MEASURED (1.4.4 fixit phase 4,
  # review-a A-2 / review-c C-2). The first version of this block copied the 44
  # the line above uses, which is what `_doctor_third_row`'s state cell is worth
  # — the wrong number for a line with a different fixed part. This line's fixed
  # part is the render loop's `→ `, the sentence, and the route, and the route
  # grows with the catalog name: at `bionic@bionic` the names may run to 31
  # columns and at a 19-character catalog to 18. Copying 44 put the line at 107
  # columns on the second machine, over the rule width.sh owns.
  #
  # SO IT IS COMPUTED FROM THE STRING, never counted by hand: the sentence is
  # built once, measured with the same `bionic_cols` the wall measures with, and
  # what is left over is what the names get. `bionic_trunc` also drops whole
  # characters, which the `printf '%.41s'` idiom above it does not — a
  # multi-byte dependency name cannot be cut mid-glyph here.
  _doctor_absent_core="$(bionic_trunc "$ABSENT_CORE_NAMES" \
    "$(( BIONIC_LINE_WIDTH - $(bionic_cols "→ ${_doctor_core_head}) → ${_doctor_core_route}") ))")"
  fix "${_doctor_core_head}${_doctor_absent_core}) → ${_doctor_core_route}" "$N_ABSENT_CORE"
fi

# THE TABLE DECIDES WHETHER AN ENVIRONMENT NAME FIRES, and this line counts its
# answers (Step-6 review B-1). This loop used to ask its own question — "does
# `env_get` fail", i.e. is the name absent from settings.json — while
# `bionic_check_env_unwritten` (the predicate setup's environment step runs) asks
# whether the file's value IS the value bionic sets. The two disagree on exactly
# one machine: a name written with some other value. There doctor said ✓ with no
# line while setup offered to rewrite it, which is the 2026-09-05 field defect
# inverted, and it is why the answer is asked once, of the row.
#
# A name live in this process but absent from settings.json still earns this
# line: the value dies with the session, and the next one starts without it. A
# name configured with bionic's own value and merely not live earns NOTHING here
# — that is a restart, which the ENVIRONMENT section names, and setup would find
# nothing to do.
ENV_MISSING=0
for _env_key in $ENV_KEYS; do
  bionic_check_fires "env:${_env_key}" && ENV_MISSING=$((ENV_MISSING + 1))
done
if [ "$ENV_MISSING" -gt 0 ]; then
  fix "${ENV_MISSING} of bionic's environment settings $(_doctor_plural "$ENV_MISSING" is are) not what bionic sets → run $(bionic_check_route setup)" \
      "$ENV_MISSING"
fi

# A STALE PROXY BLOCK IS THE ONE STATE OF THIS ITEM THAT EARNS A FIX LINE.
# Absent is an offer nobody took, and never a problem (see the row itself, in
# ENVIRONMENT below); stale is bionic's OWN block, consented to, carrying a line
# this payload no longer writes. Setup rewrites the block wholesale, so the
# repair is the same command as the offer — but this time there is something
# broken to repair, which is what makes the row ✗ instead of `–`.
# WHICH IS ALSO WHY THIS LINE IS NOT ROUTED THROUGH THE TABLE, alone among the six
# leftovers: the row `claude-proxy` fires on ABSENT and this line fires on STALE,
# so asking `bionic_check_fires` here would print a fix line on every machine that
# declined the offer. Ruling A-T6-2 — upheld by the Step-6 recheck for this site,
# and overturned for the other five, which the block above now decides once each.
[ "$RC_PROXY_STATE" = "stale" ] && fix "the claude() shell proxy is an older line → run $(bionic_check_hint claude-proxy)"

[ "$LEGACY_ALIAS_FIRES" = "yes" ] && fix "the legacy .zshrc alias block is still there → run $(bionic_check_hint legacy-alias)"
if [ "$LEGACY_HOOKS_FIRES" = "yes" ]; then
  fix "${LEGACY_HOOK_COUNT} legacy-channel managed-hook $(_doctor_plural "$LEGACY_HOOK_COUNT" entry entries) in settings.json → run $(bionic_check_hint legacy-hooks)"
fi
# The skill copy, and the hook files and agent copies beside it — all three now have a
# consented removal in setup (steps 9, 10 and 11), so all three fix lines name a command that
# has something to do. Until 1.4.4 only this one did, and the two above it ended `→ run
# /bionic:setup` over a run that then reported "nothing left to do — this machine is set up."
# (.bionic/docs/ideas/bug-doctor-setup-ownership.md). The asymmetry that used to be the point
# here is gone; what remains is that this copy is also DOING something, arming eleven
# registrations a second time, where the files beside it are inert.
# tests/doctor.test.sh Group 14 used to pin the other side — a machine whose only leftover is
# hook files and whose setup summary still reads "nothing to do" — and was deleted at 8582861
# (epic-18 wave-03) with nothing to replace it. The pin is back, in
# tests/cross-gate-agreement.test.sh §DS, on the side that can go red.
[ "$SKILL_COPY_FIRES" = "yes" ] && fix "a legacy skill copy is installed, arming the same walls twice → run $(bionic_check_hint legacy-skill-copy)"

# THE TWO ROWS THAT WERE ONLY EVER SETUP'S (design D-2, 1.5.1). Both are on
# setup's roster and neither had a surface here — no row, no fix line, nothing —
# so the repair was offered for a problem this report never said the machine had.
# Asked ONCE, here, for the same reason every other leftover is: `fix` is
# collected before anything prints, and the rows in ENVIRONMENT below read these
# two answers rather than asking a second time. A row with no fix line would also
# break the rule the headline count is measured against — every ✗ on the page is
# a problem the count stands for (tests/doctor-reads.test.sh 12f18).
PERM_BLOCK_STATE=no; bionic_check_fires legacy-permission-block && PERM_BLOCK_STATE=yes
PERM_MODE_STATE=no;  bionic_check_fires permission-mode         && PERM_MODE_STATE=yes
[ "$PERM_BLOCK_STATE" = "yes" ] && \
  fix "bionic's retired permission block is still in settings.json → run $(bionic_check_hint legacy-permission-block)"
[ "$PERM_MODE_STATE" = "yes" ] && \
  fix "the default permission mode is not ${BIONIC_DEFAULT_PERMISSION_MODE} → run $(bionic_check_hint permission-mode)"

# THE ROW THE REGISTRY LOST WHILE THE PLUGIN'S FILES STAYED (REQ-S0, AC-S0.3).
#
# WHY THE DEPENDENCY TABLE COULD NOT SAY THIS. The row two tables down already
# reports `✗ impeccable  not installed → /bionic:setup`, and that sentence is true
# of this machine and of a machine that never had the plugin alike — one of which
# needs a download and one of which does not. The difference is the whole finding,
# and it does not fit there: the state cell is 44 columns of a 100-column budget
# once the name, version and source columns are paid for, and the route already
# spends 29 of them (lib/width.sh's own arithmetic). A sentence about the cache
# would be truncated away by `bionic_line` exactly where the reader needs it.
#
# So it is a FIX line, which is the surface for a fact that reaches a reader as a
# repair rather than as a cell — the same channel the walls and the dead-session
# rows use. Every such line ending in the setup route is collapsed into the
# verdict's name list, so a machine with one dropped row gets one sentence.
#
# NAMED, NOT COUNTED. Which plugin lost its entry is the actionable half — the
# reader wants to know whether it is the design pack or the skills pack — so the
# rows are printed one per name rather than collapsed into a number, exactly as
# the environment keys are.
# THE TAIL SAYS "NO DOWNLOAD" ONLY WHERE THAT IS TRUE. A row bionic does not
# declare is setup's, and setup writes the entry back from the cache — that is
# the sentence worth reading, and it is why this line exists at all. A `core`
# row is the CLI's: reinstalling bionic restores it, and that DOES fetch, so the
# line carries the route and makes no claim about downloading. A cli route is
# not the setup route, so that line reaches its own line either way; the setup
# one has to earn it by not ENDING in the route, which is `fix`'s own rule for
# what may be collapsed into the verdict's name list.
for _rr_name in $(dep_names_kind native); do
  bionic_check_fires "registry-row:${_rr_name}" || continue
  _rr_hint="$(bionic_check_hint "registry-row:${_rr_name}")"
  if [ "$_rr_hint" = "$DOCTOR_SETUP_ROUTE" ]; then
    fix "${_rr_name} lost its entry but its files are still on disk → ${_rr_hint} restores it, no download"
  else
    fix "${_rr_name} lost its entry but its files are still on disk → ${_rr_hint}"
  fi
done

if [ "$PLUGIN_HOOKS" = "degraded" ] || [ "$PLUGIN_HOOKS" = "absent" ]; then
  # THE HINT IS THE WHOLE TAIL, AND IT KNOWS WHICH STATE IS ASKING (W7 S11,
  # six-axis review axis 2). This used to print `re-converge with:` and then the hint
  # inside backticks — which on a directory-source machine handed a user whose tree is
  # genuinely broken the words "nothing to do" formatted as a command to type.
  # TERSE ON PURPOSE (AC-15): the hint this line ends with is 76 columns of
  # named copy and verbatim command, and the PLUGIN INTEGRITY row two sections
  # down already spells out what "degraded" means. Anything longer here wraps.
  fix "hooks ${PLUGIN_HOOKS} → $(detect_reconverge_hint hooks)"
fi

# F5's fix line, GIT FEED ONLY. A directory feed's lag/not-in-repo states are
# NOMINAL (the CLI runs the tree, not the cache — same doctrine as the header's
# sha choice above), so they earn a report row, never a fix line.
if [ "$FEED_KIND" = "git" ] && [ "$LATEST_STATE" = "lag" ]; then
  fix "bionic ${LATEST_INSTALLED} installed, ${LATEST_LATEST} available → claude plugin update bionic@bionic"
fi

# THE COUNT IS ROWS, NOT CATEGORIES (Chris 2026-08-22: "2 problems" above seven ✗
# rows), and it is finished by the time this line is reached. `N_FIX` is summed
# by `fix` itself, one call at a time, from the row count each call declares —
# see that function's header for why the number lives beside the sentence rather
# than being reconstructed here from the page.
#
# WHAT USED TO BE HERE. Three swaps in a row, each one written the day a
# collapse was found to be miscounted: the two dependency lines exchanged for
# every ✗ dependency row (bionic 1.4.4 fixit phase 3), then the dead-session line
# for the sessions it names (1.5.1 fix-up batch). The environment line never got
# its swap, and the exchange counted `presence is unknown` and `violates
# constraint` rows twice — both measured by the Step-5 walk on one page whose
# total was nevertheless correct, because the two errors were equal and opposite.
# There is nothing to swap now: a line is worth what it says it is worth.

# ─── The report ──────────────────────────────────────────────────────────────
#
# THE HEADER IS A PROVENANCE LINE, and it replaces a sentence that told the
# reader what doctor does. They already know — they typed it. What they cannot
# know without being told is WHICH payload just answered them, and on a machine
# carrying a plugin install, a checkout and a marketplace copy of the same thing,
# that is the fact every other line below is relative to.
echo "Bionic Doctor — payload ${PLUGIN_VERSION} @ ${PAYLOAD_SHA}"

# WHICH CHECKOUT THE CLI ACTUALLY LOADS THE PLUGIN FROM (W4 4/4) — the other half
# of the header's provenance claim, on a machine that can carry more than one
# checkout of this same marketplace name. A directory-source registration resolves
# to a real path on this disk; comparing its realpath against `DOCTOR_REPO_ROOT`
# (also resolved to a realpath, so a relative registration or a symlinked checkout
# reads the same as an absolute one) answers "this checkout" or "OTHER checkout" —
# a git-feed registration names no filesystem path at all and prints as-is,
# never matching either verdict.
#
# THE BRACKET VERDICT MUST SURVIVE TRUNCATION, NOT THE PATH — the opposite of
# every other row on this page. A long path is merely informational; the verdict
# is the one word ("OTHER") a reader on a two-checkout machine cannot afford to
# lose to an ellipsis, so `bionic_line` eats the shortfall out of the path, never
# the bracket.
# THE VERDICT ITSELF COMES FROM ONE SHARED SITE, `detect_checkout_verdict`
# (epic-22 wave-01 slice 14) — the realpath comparison used to live here alone;
# it is now the same function `/bionic:version` calls, so the two surfaces can
# never disagree about what "this checkout" means.
if [ "$MP_SOURCE_STATE" -eq 0 ] && [ -n "$MP_SOURCE_PATH" ]; then
  if [ "$(detect_checkout_verdict "$DOCTOR_REPO_ROOT")" = "this checkout" ]; then
    printf '%s\n' "$(_doctor_rtrim "$(bionic_line "plugin source: " "$MP_SOURCE_PATH" " [this checkout]")")"
  else
    printf '%s\n' "$(_doctor_rtrim "$(bionic_line "plugin source: " "$MP_SOURCE_PATH" \
      " [OTHER checkout — the CLI loads the plugin from THERE]")")"
  fi
else
  echo "plugin source: unregistered"
fi

# ─── The verdict, on the line under it ───────────────────────────────────────
#
# TWO QUESTIONS, ANSWERED BEFORE ANY EVIDENCE: is anything wrong, and what do I
# type. The arrow is not decoration — it marks the only lines in this report that
# are addressed to the reader as instructions rather than as facts, so a reader
# scanning for "what am I supposed to do" has one shape to look for.
#
# THE SETUP-FIXABLE PROBLEMS COLLAPSE INTO ONE LINE and the rest each get their
# own. Eleven absences on a cold machine are eleven problems with one identical
# command; printing that command eleven times teaches a reader to stop reading
# it. A problem setup CANNOT repair — a half-uninstalled machine, a CLI that
# refused to load the plugin — would be buried by that collapse, so it stays a
# line of its own with its own command on it.
if [ "$N_FIX" = "0" ]; then
  echo "→ Nothing to do. This machine is fully set up."
else
  _doctor_verdict="→ ${N_FIX} $(_doctor_plural "$N_FIX" problem problems)."
  if [ -n "$FIX_NAMES_SETUP" ]; then
    _doctor_verdict="${_doctor_verdict} Run ${DOCTOR_SETUP_ROUTE} to fix: ${FIX_NAMES_SETUP}"
    # TRUNCATED RATHER THAN WRAPPED. The names are what makes this line worth
    # reading, and a cold machine has enough of them to run past a terminal's
    # width — where the line would break into a second one and undo the whole
    # rule. The count above is exact either way.
    # Through the shared truncator (lib/width.sh), which is where the budget
    # lives — this line used to carry its own pair of literals, 99 and 96, which
    # were the 100-column rule written a third time in a third unit.
    _doctor_verdict="$(bionic_trunc "$_doctor_verdict" "$BIONIC_LINE_WIDTH")"
  fi
  printf '%s\n' "$_doctor_verdict"
  if [ -n "$FIX_LINES_OTHER" ]; then
    while IFS= read -r _fix_other; do
      [ -n "$_fix_other" ] || continue
      # THE BOUND IS THE LOOP'S, AND THE COMMAND IS WHAT SURVIVES IT (wave-01
      # S4, AC-6; closes DOCTOR/13). These lines were the one part of the report
      # printed with a bare `printf` and no bound — which held only while every
      # one of them was short by construction, and stopped holding when the
      # core-absence line started carrying a variable-length name list and the
      # dependency-unknown line started carrying a spelled-out cause (105
      # columns with the CLI off PATH).
      #
      # THE FIXIT ALREADY TRIED A BOUND HERE AND REVERTED IT (c9f66b5, dd07b33).
      # It failed because it passed the whole line as `bionic_line`'s tail, so
      # the ellipsis ate the END of the line — which is where doctor's first
      # format rule puts the command. The tail is not one string: it is a
      # problem and then a command, split on the same FIRST arrow `fix` itself
      # splits on to name the problem. Passed separately, the problem half
      # absorbs the whole shortfall and the command is printed whole, which is
      # exactly the contract `bionic_line`'s third argument exists for.
      #
      # A command with no room left to protect it in falls back to
      # `bionic_line`'s own documented degenerate case — one bound over the
      # whole tail — and that is the library's ruling, not a new one here.
      _fix_head="${_fix_other%% → *}"
      _fix_cmd="${_fix_other#* → }"
      if [ "$_fix_head" = "$_fix_other" ]; then
        # No arrow: nothing to protect, one bound over the line.
        printf '%s\n' "$(bionic_line '→ ' "$_fix_other")"
      else
        printf '%s\n' "$(bionic_line '→ ' "$_fix_head" " → ${_fix_cmd}")"
      fi
    done <<< "$FIX_LINES_OTHER"
    # The one command that cannot ride on its own line: a raw URL inside a
    # pipefail wrapper, printed whole underneath rather than wrapped by the
    # terminal into something nobody can paste.
    [ "$HALF_STATE" = "yes" ] && \
      echo "   bash -c 'set -o pipefail; curl -fsSL ${BIONIC_REMOVE_RAW_URL} | bash'"
  fi
fi

# ─── Table 1 — what ships inside the plugin ──────────────────────────────────
#
# THE OWNERSHIP SPLIT IS THE ORGANISING IDEA of all three tables, and it answers
# the question the old section list never did: when something here is wrong, whose
# machinery repairs it. Everything in this table arrived with the plugin install
# and is repaired by re-installing the plugin; everything in the next arrived
# through /bionic:setup and is repaired by running it again. A reader who knows
# which table a broken row is in already knows what to type.
echo ""
echo "BIONIC NATIVE — ships inside the plugin"
_doctor_native_row " " "component" "count" "detail"
# F5 — IS THE INSTALLED BUILD THE LATEST, per feed kind (spec AC-F5). A git
# feed compares against the marketplace clone's own plugin.json (detect_
# plugin_latest, above) and names the exact repair command on lag. A
# directory feed has no remote "latest" to compare against — reading the
# same tree's plugin.json against itself would only ever say "current" — so
# it consumes the tree-vs-cache fact and guidance this page already gathers
# (REG_SHA_STATE + detect_reconverge_hint) rather than re-deriving one.
case "$FEED_KIND" in
  git)
    case "$LATEST_STATE" in
      current)
        _doctor_native_row "$DOCTOR_OK" "version" "$LATEST_INSTALLED" "up to date" ;;
      lag)
        _doctor_native_row "$DOCTOR_BAD" "version" "$LATEST_INSTALLED" \
          "${LATEST_LATEST} available" " → claude plugin update bionic@bionic" ;;
      ahead)
        # NEWER THAN THE THING AN UPDATE WOULD FETCH (AC-19). Before
        # `version_compare` landed this compare was a string inequality, which
        # lumped ahead in with lag: doctor printed "0.0.1 available" and an
        # update command at a machine running 1.4.0, and taking that advice
        # would have moved it BACKWARDS. It is `–` and not ✗ for the reason the
        # symbol rules give — true, and not actionable — so no FIX line pairs
        # with it and none should.
        _doctor_native_row "$DOCTOR_NIL" "version" "$LATEST_INSTALLED" \
          "newer than the marketplace copy (${LATEST_LATEST}) — no action" ;;
      *)
        _doctor_native_row "$DOCTOR_NIL" "version" "?" "unknown — ${LATEST_CAUSE}" ;;
    esac ;;
  directory)
    case "$REG_SHA_STATE" in
      match)
        _doctor_native_row "$DOCTOR_OK" "version" "$PLUGIN_VERSION" "tree matches the registered cache" ;;
      lag)
        _doctor_native_row "$DOCTOR_NIL" "version" "$PLUGIN_VERSION" \
          "cache lags this tree — $(detect_reconverge_hint lag)" ;;
      not-in-repo)
        _doctor_native_row "$DOCTOR_NIL" "version" "$PLUGIN_VERSION" \
          "registered build not in this tree — $(detect_reconverge_hint lag)" ;;
      *)
        _doctor_native_row "$DOCTOR_NIL" "version" "?" "unknown — ${REG_SHA_CAUSE}" ;;
    esac ;;
  *)
    _doctor_native_row "$DOCTOR_NIL" "version" "?" \
      "unknown — the marketplace feed kind could not be determined" ;;
esac
if [ "$SKILLS_OK" = "$SKILLS_TOTAL" ] && [ "$SKILLS_TOTAL" -gt 0 ]; then
  _doctor_native_row "$DOCTOR_OK" "skills" "${SKILLS_OK}/${SKILLS_TOTAL}" "$SKILL_NAMES"
else
  _doctor_native_row "$DOCTOR_BAD" "skills" "${SKILLS_OK}/${SKILLS_TOTAL}" \
    "a skill directory carries no SKILL.md → reinstall the plugin"
fi
case "$AGENT_STATE" in
  stock)
    _doctor_native_row "$DOCTOR_OK" "agents" "${AGENT_TOTAL}/${AGENT_TOTAL}" "stock" ;;
  modified)
    # `–`, NOT ✗, and nothing in the verdict above asks for these files back.
    # Editing your own installed role files is allowed; the row says what the
    # machine has and names the undo in the same breath.
    _doctor_native_row "$DOCTOR_NIL" "agents" \
      "$((AGENT_TOTAL - AGENT_MODIFIED))/${AGENT_TOTAL}" \
      "${AGENT_MODIFIED} edited locally (${AGENT_NAMES//,/, }) — reinstall restores stock" ;;
  *)
    _doctor_native_row "$DOCTOR_NIL" "agents" "?/${AGENT_TOTAL}" "unknown — ${AGENT_CAUSE}" ;;
esac
case "$PLUGIN_HOOKS" in
  ok)
    _doctor_native_row "$DOCTOR_OK" "hooks" "${HOOK_RESOLVING}/${HOOK_TOTAL}" "" ;;
  absent)
    _doctor_native_row "$DOCTOR_BAD" "hooks" "0/0" \
      "the payload carries no hooks/hooks.json → reinstall the plugin" ;;
  *)
    _doctor_native_row "$DOCTOR_BAD" "hooks" "${HOOK_RESOLVING}/${HOOK_TOTAL}" \
      "$(detect_reconverge_hint hooks)" ;;
esac
# THE WALLS ROW (AC-15). One row when everything resolves — four healthy walls
# are four lines about nothing, which is format rule 4 — and one row per wall
# that cannot, named, when any of them fails. `intact → clean` is the spec's own
# word for the healthy case, and the ✗ here is matched by the FIX line gathered
# beside the probe, which is the invariant these symbols are worth anything under.
if [ "$WALLS_OK" = "$WALLS_TOTAL" ] && [ "$WALLS_TOTAL" -gt 0 ]; then
  _doctor_native_row "$DOCTOR_OK" "walls" "${WALLS_OK}/${WALLS_TOTAL}" \
    "every wall resolves its library"
else
  _doctor_native_row "$DOCTOR_BAD" "walls" "${WALLS_OK}/${WALLS_TOTAL}" \
    "a wall that cannot read a command refuses it"
  printf '%s' "$WALL_ROWS"
fi
if [ "$COMMANDS_OK" = "$COMMANDS_TOTAL" ] && [ "$COMMANDS_TOTAL" -gt 0 ]; then
  _doctor_native_row "$DOCTOR_OK" "commands" "${COMMANDS_OK}/${COMMANDS_TOTAL}" "$COMMAND_NAMES"
else
  _doctor_native_row "$DOCTOR_BAD" "commands" "${COMMANDS_OK}/${COMMANDS_TOTAL}" \
    "a command file is empty → reinstall the plugin"
fi
# THE TWO STATES THAT MAKE EVERY ROW ABOVE MOOT, and they are printed here only
# when they are true. A payload can be whole on disk and not be running: the CLI
# may have refused to load it, or a teardown may have taken the command surface
# away and left the files. Either way the four rows above describe something this
# session is not executing, and a table that did not say so would be four
# confident answers to the wrong question.
case "$LOAD_STATE" in
  loaded) ;;
  failed)
    _doctor_native_row "$DOCTOR_BAD" "plugin" "—" "the CLI refused to load it: ${LOAD_ERROR}" ;;
  absent)
    _doctor_native_row "$DOCTOR_BAD" "plugin" "—" \
      "not installed for this CLI → claude plugin install ${BIONIC_PLUGIN_ID}" ;;
  *)
    _doctor_native_row "$DOCTOR_NIL" "plugin" "—" "load state unknown — ${LOAD_CAUSE}" ;;
esac
[ "$HALF_STATE" = "yes" ] && \
  _doctor_native_row "$DOCTOR_BAD" "install" "—" "half-uninstalled — the CLI no longer knows bionic"
printf '%s' "$DUP_ROWS"

# ─── Table 2 — the tools and plugins bionic depends on ───────────────────────
echo ""
# THE HEADER NAMES THE TABLE'S SUBJECT, NOT ITS OWNER (bionic 1.4.4 fixit phase
# 4, review-b B-3). It used to read "installed by /bionic:setup", which was true
# of every row under it until a `core` row started saying otherwise — and those
# rows are the FIRST two in the table, because `dep_names_class core` is iterated
# first, so a reader met the contradiction before anything else. Three classes of
# row live here with three different owners; the state cell is the only place
# that can be right for all three, and it now is. The `THIRD PARTY` prefix is
# load-bearing and does not move: tests/cross-gate-agreement.test.sh's
# `ds_third_section` anchors the table on /^THIRD PARTY/, and fresh-home's
# `doctor_section` matches headings by prefix.
echo "THIRD PARTY — tools and plugins bionic depends on"
_doctor_third_row " " "name" "version" "source" "state"
printf '%s' "$THIRD_ROWS"

# ─── Table 3 — the environment this machine runs bionic in ───────────────────
#
# TWO FACTS PER NAME, AND NEITHER ANSWERS THE OTHER. `env_get` reads the CLI's
# settings.json — what a session started from now on will have. `env_live` reads
# THIS process — what the session you are in has. On 2026-08-21 a session ran
# with the task-list name written to disk and absent from the process (the host
# launches its shell with rc files disabled, so the export bionic used to append
# never arrived), and the one line this section carried could not say so.
# Configured-and-not-live is a RESTART; absent is a setup gap; and telling a user
# to run setup over a restart sends them to repair something already repaired.
# Which is also why a restart-pending name is `–` and an absent one is ✗: only
# one of them has a line in the verdict.
echo ""
echo "ENVIRONMENT"
# THREE COLUMNS, LIKE THE TABLES ABOVE (Chris 2026-08-22): setting · value · state.
# An env var's value is the configured one; its state says whether this session
# carries it; the statusline's value is the command.
# The fifth argument is the instruction the cut may not eat (lib/width.sh) — the
# rc rows name a path of unbounded length and then say what to do about it.
_doctor_env3() {  # <symbol> <setting> <value> <state> [<instruction>]
  printf '%s\n' "$(_doctor_rtrim \
    "$(bionic_line "  $1 $(_doctor_cell "$2" 36) $(_doctor_cell "$3" 13) " "${4:-}" "${5:-}")")"
}
printf '    %-36s %-13s %s\n' "setting" "value" "state"
# THE KEYS ARE env.sh's ROSTER and the routes are the table's. `ENV_KEYS` is the
# one place the names are spelled and lib/checks.sh generates its environment rows
# from that same list, so the two cannot come to hold different names; what this
# loop reads from the table is who repairs an unwritten one.
#
# AND WHETHER IT IS UNWRITTEN IS THE ROW'S ANSWER TOO (Step-6 review B-1). This
# loop asked `env_get` and called any configured value ✓; the row's detector asks
# whether the configured value is the one bionic sets. A name written with some
# other value is the machine where those two answers differ, and it is the one
# machine where doctor used to print a tick over a repair setup was still
# offering. `bionic_check_fires` is asked once per name, here, and the three
# branches below are the three shapes a firing name comes in.
for _env_key in $ENV_KEYS; do
  _env_hint="$(bionic_check_hint "env:${_env_key}" 2>/dev/null)" || _env_hint=""
  _env_configured="$(env_get "$_env_key" 2>/dev/null)" || _env_configured=""
  if bionic_check_fires "env:${_env_key}"; then _env_fires=yes; else _env_fires=no; fi
  if _env_live_value="$(env_live "$_env_key" 2>/dev/null)"; then _env_is_live=yes; else _env_is_live=no; fi
  if [ "$_env_fires" = "no" ]; then
    # The row does not fire, which is to say settings.json holds bionic's own
    # value for this name. The only question left is whether THIS session has it.
    if [ "$_env_is_live" = "yes" ]; then
      _doctor_env3 "$DOCTOR_OK" "$_env_key" "${_env_configured:-—}" "live in session"
    else
      _doctor_env3 "$DOCTOR_NIL" "$_env_key" "${_env_configured:-—}" "written, restart to pick it up"
    fi
  elif [ -n "$_env_configured" ]; then
    # Written, and written to something else. Setup's environment step rewrites
    # it wholesale, so the row carries the same route every other firing name does.
    _doctor_env3 "$DOCTOR_BAD" "$_env_key" "$_env_configured" "not the value bionic sets${_env_hint:+ → ${_env_hint}}"
  elif [ "$_env_is_live" = "yes" ]; then
    # Live and not configured: the state the retired shell export leaves behind.
    # It works right now and dies with this session, which is why setup is still
    # named for it in the verdict above.
    _doctor_env3 "$DOCTOR_BAD" "$_env_key" "$_env_live_value" "live in session, not written${_env_hint:+ → ${_env_hint}}"
  else
    _doctor_env3 "$DOCTOR_BAD" "$_env_key" "—" "not set${_env_hint:+ → ${_env_hint}}"
  fi
done
# THE THIRD KIND OF ROW IN THIS TABLE, and the only one whose absence is not a
# fault. The two above are settings bionic needs to work; this is an OFFER — a
# `claude()` function that puts the bypass mode in reach of the command a person
# types — and someone who was asked and said no has a correctly configured
# machine, not a broken one. So absent is `–` with the route to say yes, never
# `✗` with a repair. Presence is env.sh's `rc_get` (through detect.sh), so a
# claude() function a user wrote for themselves — outside bionic's markers — is
# neither claimed here nor removable by /bionic:remove.
#
# AND THE THIRD STATE IS NOT ABSENCE. `stale` is bionic's own block holding a
# line this payload no longer writes, on a machine that already said yes. That
# person is owed the truth and a command, not a green tick: the ✗ here is
# matched by the fix line gathered above, which is the invariant those symbols
# are worth anything under.
_rc_proxy_label="$(bionic_check_label claude-proxy)"
_rc_proxy_hint="$(bionic_check_hint claude-proxy)"
if [ "$RC_PROXY_STATE" = "yes" ]; then
  _doctor_env3 "$DOCTOR_OK" "$_rc_proxy_label" "on" \
    "in $(_detect_shell_rc)" " — new shells pick it up"
elif [ "$RC_PROXY_STATE" = "stale" ]; then
  _doctor_env3 "$DOCTOR_BAD" "$_rc_proxy_label" "stale" \
    "in $(_detect_shell_rc)" " — ${_rc_proxy_hint} rewrites it"
else
  _doctor_env3 "$DOCTOR_NIL" "$_rc_proxy_label" "—" "not set — ${_rc_proxy_hint} offers it"
fi
# THE LEFTOVERS, AND ONLY WHEN THERE ARE ANY. Six checks ask the same kind of
# question — did the retired installer leave something behind — and on a machine
# that never ran it, or has been cleaned once, all six answer no. Silence is the
# right output for that.

# AND EVERY ONE OF THEM READS THE ANSWER GATHERED ABOVE, never its own copy of
# the rule (Step-6 recheck part 4, R-2). The raw facts are still here for the
# counts, names and paths these rows print, and for the `unknown` state, which is
# "we could not look" and not a firing. Whether a row fires was decided once, in
# the leftovers block of the fix section.
[ "$LEGACY_ALIAS_FIRES" = "yes" ] && \
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label legacy-alias)" \
    "present → $(bionic_check_hint legacy-alias)"
if [ "$LEGACY_HOOKS_FIRES" = "yes" ]; then
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label legacy-hooks)" \
    "${LEGACY_HOOK_COUNT} in settings.json → $(bionic_check_hint legacy-hooks)"
fi
# HOOK FILES, WHICH ARE NOT THE SETTINGS ENTRIES ABOVE. The row above counts
# managed-hook ENTRIES in settings.json; this one counts hook SCRIPTS the retired
# installer copied into the claude-home, which the plugin now ships and which
# shadow nothing but still sit there. Both were computed on every run; only the
# first was printed. `detect_legacy_hook_files` also names the directory, which
# is the one thing a reader needs to go look.
if [ "$HOOK_FILES_FIRES" = "yes" ]; then
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label legacy-hook-files)" \
    "${HOOK_FILES_COUNT} in $(_doctor_tilde "$HOOK_FILES_PATH")" " → $(bionic_check_hint legacy-hook-files)"
elif [ "$HOOK_FILES_COUNT" = "unknown" ]; then
  _doctor_env_row "$DOCTOR_NIL" "$(bionic_check_label legacy-hook-files)" "unknown — ${HOOK_FILES_CAUSE}"
fi
# THE INSTALLED ROLE FILES, AND WHICH OF THEM NO LONGER MATCH THE PAYLOAD. The
# probe compares every agent this payload ships against a same-named copy in the
# claude-home and counts the ones that differ; nothing rendered either half. A
# drifted copy is the actionable one — it is what a session will read instead of
# the shipped role — so that is the row, and a clean set of copies stays silent
# under format rule 4.
if [ "$AGENT_COPIES_FIRES" = "yes" ]; then
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label legacy-agent-copies)" \
    "${INST_AGENT_DRIFT}/${INST_AGENT_TOTAL} differ (${INST_AGENT_NAMES//,/, })" " → $(bionic_check_hint legacy-agent-copies)"
elif [ "$INST_AGENT_STATE" = "unknown" ]; then
  _doctor_env_row "$DOCTOR_NIL" "$(bionic_check_label legacy-agent-copies)" \
    "unknown — ${INST_AGENT_CAUSE}"
fi
# AND THE SKILL COPY NAMES ITS DIRECTORY. The path was parsed and dropped; a row
# that says a stale copy arms the same walls twice, without saying where it is,
# leaves the reader to go find it.
[ "$SKILL_COPY_FIRES" = "yes" ] && \
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label legacy-skill-copy)" \
    "$(_doctor_tilde "$SKILL_COPY_PATH")" " → $(bionic_check_hint legacy-skill-copy)"
# THE NPX STATUSLINE COMMAND (epic-21 AC-3, Fix step 5). A machine that ran
# setup before the fix still has `npx ccstatusline@latest` recorded, and
# nothing rewrites it but a person re-running setup.
[ "$STATUSLINE_NPX_STATE" = "yes" ] && \
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label statusline-npx)" \
    "still uses npx — blocks on a network lookup every render" " → $(bionic_check_hint statusline-npx)"
# THE TWO ITEMS THAT HAD NO ROW HERE AT ALL until 1.5.1 (design D-2). Both are on
# setup's roster and neither was ever diagnosed: the only mention of either in
# this file was a comment naming a mutation doctor must never call. A repair with
# no diagnosis is half a pair — the reader is offered a fix for a problem the
# report never told them they had — so both are rows of the check table now, and
# both render here from their own read-only detector. Silence when they do not
# fire, like every other leftover row above.
[ "$PERM_BLOCK_STATE" = "yes" ] && \
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label legacy-permission-block)" \
    "present in $(_doctor_tilde "$(_dep_settings_file)")" " → $(bionic_check_hint legacy-permission-block)"
[ "$PERM_MODE_STATE" = "yes" ] && \
  _doctor_env_row "$DOCTOR_BAD" "$(bionic_check_label permission-mode)" \
    "not ${BIONIC_DEFAULT_PERMISSION_MODE}" " → $(bionic_check_hint permission-mode)"


# ─── The resources the fleet is running on ───────────────────────────────────
#
# TWO KINDS OF FACT, AND THEY ARE NOT THE SAME FACT (AC-27). The first line is
# what this machine IS, probed now. The lines under it are what each live session
# DECIDED, read back out of the attestation that session wrote before its first
# dispatch — and a budget is a decision, taken once, that every wall and every
# brief then quotes. Printing only the probe would invite a reader to re-derive a
# budget in their head and get a different number than the one the fleet is
# actually running under; printing only the attestations would hide the machine
# that has changed under them since.
#
# THE BUDGET IS QUOTED, NEVER RECOMPUTED. It is one string in the attestation, in
# exactly the shape the plan header's `parallel-budget:` carries (L-RESOURCES/2),
# so this page reads a string and no formula lives here.
echo ""
echo "RESOURCES"
printf '%s' "$RESOURCES_ROWS"

# ─── The Patrol ──────────────────────────────────────────────────────────────
#
# RUNNING PATROLS OR NOTHING. See the gathering comment above for the full
# rationale; this is just its render. Doctor still changes nothing here — a
# `CronDelete` fix line is PRINTED, never run, and running it is the reader's
# act in the session that owns the job.
#
# AND IT STAYS THE LAST SECTION OF A DEFAULT RUN. RESOURCES was placed above it
# rather than below for that reason: the Patrol block is read from its header to
# end of output by more than one caller, and a section appended after it would
# arrive inside everything that reads it.
echo ""
echo "PATROL"
if [ "$PATROL_LIVE" = "0" ]; then
  _doctor_item "$DOCTOR_NIL" "none running" ""
else
  printf '%s' "$PATROL_ROWS"
fi
# THE RUN, THE PREDECESSORS AND THE LEGACY LINKS — the three rows that are about
# this PROJECT rather than about this machine, printed under the Patrol because
# the Patrol is what acts on them.
printf '%s' "$RUN_ROWS"


# ─── The one question, and the section it appends ────────────────────────────
#
# EVERYTHING ABOVE THIS LINE IS INSTANT. That is what earns the question its
# place at the end: the report is already complete and already printed, so a user
# who says no has lost nothing and a user who says yes knows exactly what they
# are waiting for. The question states its own cost in the same breath, because a
# prompt that hides a thirty-second wait is not a question, it is a trap.
#
# WHERE THE ANSWER CAN COME FROM. A terminal, a pipe, or a file — the three ways
# a caller can actually answer. Anything else (a closed stream, the socket a tool
# harness hands a script) gets no question at all: printing one there would put
# an unanswerable prompt in a report and then, if this code read anyway, block
# forever waiting for a reply nobody is going to send. Measured, not assumed —
# an unguarded read against a harness-supplied stream does not return.
#
# THE PROMPT SHAPE IS deps.sh's, by eye and not by call: doctor is forbidden to
# reach into the consent machinery (that library's asking function belongs to the
# code that mutates things, and this code mutates nothing), so the shape is
# reproduced here and the ban stays intact.
_doctor_can_ask() {
  [ -t 0 ] && return 0
  [ -p /dev/stdin ] && return 0
  [ -f /dev/stdin ] && return 0
  return 1
}

# The version the dependency sweep already probed. Used only where a package
# manager reports that a row is outdated without saying what is installed — the
# answer is already in this report and asking twice could disagree with itself.
_doctor_row_version() {  # <name>
  local want="${1:-}" n v
  while IFS="$(printf '\t')" read -r n v; do
    [ "$n" = "$want" ] || continue
    printf '%s' "${v:-unknown}"
    return 0
  done <<< "$DEP_VERSIONS"
  printf '%s' "unknown"
}

# INTERSECTED WITH THE TABLE, ALWAYS. Both managers answer about the whole
# machine; bionic reports only on the rows it manages. Anything else would make a
# tool bionic never installed look like bionic's problem — including, on this
# machine's own history, tools this wave deliberately dropped.
_doctor_updates_brew() {
  local out rc name target line cur latest
  if ! command -v brew >/dev/null 2>&1; then
    printf '  %-22s %s\n' "not checked" "— Homebrew is not on this machine"
    return 0
  fi
  # HOMEBREW_NO_AUTO_UPDATE, and it is not a preference. `brew outdated` will
  # otherwise fetch Homebrew's own repositories first — a write to the machine
  # doctor promised not to change, and a fetch slow enough to spend the whole
  # bound before the question even gets answered. The user asked what is
  # outdated, not for Homebrew to update itself.
  out="$(detect_bounded "$(detect_probe_seconds)" env HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --verbose 2>/dev/null)"
  rc=$?
  if [ "$rc" = "124" ] || { [ "$rc" -ne 0 ] && [ -z "$out" ]; }; then
    printf '  %-22s %s\n' "not checked" "— Homebrew offline or timed out"
    return 0
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    target="$(_dep_locator_target "$(dep_field "$name" mechanism)")"
    line="$(printf '%s\n' "$out" | awk -v t="$target" '$1 == t { print; exit }')"
    [ -n "$line" ] || continue
    # `<formula> (<installed>) < <latest>` is the verbose shape. A terser
    # Homebrew that prints the bare name still gets a row — with the version this
    # report already knows and an honest word for the half it was not told.
    case "$line" in
      *" < "*)
        cur="${line%% <*}"; cur="${cur#* (}"; cur="${cur%)*}"
        latest="${line##*< }" ;;
      *)
        cur="$(_doctor_row_version "$name")"; latest="a newer version" ;;
    esac
    printf '  %-22s %-11s → %-13s %s\n' "$name" "$cur" "$latest" "brew upgrade ${target}"
  done < <(dep_names_kind brew-dep)
  return 0
}

_doctor_updates_npm() {
  local out rc parsed name target line cur latest
  if ! command -v npm >/dev/null 2>&1; then
    printf '  %-22s %s\n' "not checked" "— npm is not on this machine"
    return 0
  fi
  out="$(detect_bounded "$(detect_probe_seconds)" npm outdated -g --json 2>/dev/null)"
  rc=$?
  # npm EXITS 1 WHEN IT FINDS SOMETHING OUTDATED. That is the answer, not a
  # failure, and treating it as one would make the section silent on exactly the
  # machines it exists for.
  if [ "$rc" = "124" ] || { [ "$rc" -ne 0 ] && [ -z "$out" ]; }; then
    printf '  %-22s %s\n' "not checked" "— npm offline or timed out"
    return 0
  fi
  [ -n "$out" ] || return 0
  if [ "$HAVE_JQ" = "no" ]; then
    printf '  %-22s %s\n' "not checked" "— npm answers in JSON and jq is not on PATH"
    return 0
  fi
  parsed="$(printf '%s' "$out" | jq -r 'to_entries[] | [.key, (.value.current // "unknown"), (.value.latest // "unknown")] | @tsv' 2>/dev/null)"
  if [ -z "$parsed" ]; then
    printf '  %-22s %s\n' "not checked" "— npm's report could not be read"
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    target="$(_dep_locator_target "$(dep_field "$name" mechanism)")"
    line="$(printf '%s\n' "$parsed" | awk -F'\t' -v t="$target" '$1 == t { print; exit }')"
    [ -n "$line" ] || continue
    cur="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    latest="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
    [ "$cur" != "unknown" ] || cur="$(_doctor_row_version "$name")"
    printf '  %-22s %-11s → %-13s %s\n' "$name" "$cur" "$latest" "npm install -g ${target}@latest"
  done < <(dep_names_kind npm-global)
  return 0
}

_doctor_render_updates() {
  local UPDATES_BREW UPDATES_NPM
  UPDATES_BREW="$(_doctor_updates_brew)"
  UPDATES_NPM="$(_doctor_updates_npm)"
  echo "=== UPDATES ==="
  # THE COMMAND IS THE DELIVERABLE. Doctor diagnoses and never treats, so what a
  # row hands over is the exact line to run, not an offer to run it.
  echo "  Nothing is installed or upgraded here — each row is the command to run."
  echo ""
  if [ -z "$UPDATES_BREW" ] && [ -z "$UPDATES_NPM" ]; then
    echo "  Every managed tool is at its latest version."
  else
    # `printf '%s\n'`, and only when there is something to print: command
    # substitution eats the trailing newline, so the bare `%s` that every other
    # block here uses would run the last brew row into the first npm one.
    [ -n "$UPDATES_BREW" ] && printf '%s\n' "$UPDATES_BREW"
    [ -n "$UPDATES_NPM" ] && printf '%s\n' "$UPDATES_NPM"
  fi
  return 0
}

# No question is asked (Chris 2026-08-22: "There's not much value of that").
# `--updates` remains an explicit opt-in for whoever wants the Homebrew/npm check.
if [ "$DOCTOR_WANT_UPDATES" = "yes" ]; then
  echo ""
  _doctor_render_updates
fi

exit 0
