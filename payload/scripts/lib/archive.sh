#!/bin/bash
# payload/scripts/lib/archive.sh — Step 9's move: a closed run's directory into the
# archive (epic-22 wave-01, REQ-C; ADR-003 decision 2/3; design ledger D5).
#
# WHAT IT OWNS. One function:
#
#   archive_run <run-dir> -> moves <run-dir>'s epic-slug subtree out of the project and
#                            into the archive, or explains on stdout why it did not.
#
# <run-dir> IS THE PLAN'S OWN DIRECTORY under `<docs-root>/plans/` — the parent
# directory of the plan file Step 9 just wrote `delivered:` into (its basename is the
# epic slug, e.g. `epic-22-plugin-only`). Everything else is derived: the project root
# from `project_root` (cwd, per every other bionic script's convention — Step 9 runs
# with the project as cwd), and from there `docs_root`, `bionic_root`, `archive_root`
# and `config_value`, all `lib/roots.sh`'s.
#
# THE OWNERSHIP RULE (stated once, pinned by tests/archive.test.sh). A run does not own
# one directory, it owns THREE — `specs/<slug>`, `plans/<slug>`, `adrs/<slug>` under the
# docs root, one per artifact tree, all sharing the epic slug that names <run-dir>.
# `record/<slug-or-otherwise>` is NEVER moved: it is the wave's own evidence trail, and
# an archived run's report/log/progress files stay where the next reader of THIS project
# would look for them, not where the closed run went. AC-C.1/AC-C.2's fixtures build
# exactly these three trees (never a fourth) and assert `record/` survives untouched.
#
# THE EPIC-CLOSE / STANDALONE-RUN / OPEN-EPIC DISTINCTION IS ONE CHECK, NOT THREE
# (D5; ADR-003 "an epic directory at epic close, a standalone run at its close, never a
# wave inside an open epic"). This library does not tell those three cases apart by
# shape — a standalone run's directory and an epic directory with one wave are
# structurally identical, and inventing a second signal to distinguish them would be a
# second answer to a question `lib/run.sh` already answers. Instead: every `*.plan.md`
# directly under `<docs-root>/plans/<slug>/` is asked `run_open` (lib/run.sh, already
# sourced here); if ANY of them is open, this call moves nothing — the epic is not done,
# whether the closing wave is one of several or the sole one nobody happened to nest
# beside. This is exactly AC-C.2's fixture and, run over a slug with no open siblings
# left (including the trivial case: a single wave, itself just closed), exactly AC-C.1's.
#
# REFUSALS, ALL-OR-NOTHING ACROSS THE THREE TREES (AC-C.3, AC-C.4). Two refusal classes,
# both checked before any `mv`, so a refusal never leaves a partial move behind:
#   - occupied slot: any of the three destinations already exists.
#   - origin mismatch: `<archive-root>/<project-basename>/origin` exists and does not
#     hold this project's own absolute root — two different projects sharing a basename,
#     the collision ADR-003 and the plan's AC-C.4 both name. The origin file is WRITTEN
#     (once, if absent) only once every check has passed and a move is about to happen —
#     never as a side effect of a call that goes on to refuse or no-op.
#
# `archive-on-close: false` (AC-C.5) is checked first and short-circuits everything
# else, including the open-run scan: a project that opted out never has this library
# read its plan tree at all.
#
# EVERY REFUSAL AND EVERY MOVE PRINTS EXACTLY ONE LINE ON STDOUT — the line Step 9's
# `archived:` evidence line is built from (agents-src/templates/skills/canonical-sdlc/
# SKILL.md.tmpl, this slice). Exit status: 0 for a move or a benign no-op (opt-out, an
# open sibling, nothing under specs/plans/adrs for the slug); 1 for a refusal. A caller
# that only checks "did anything go wrong" needs nothing but the exit status; a caller
# that reports to a human takes the line too.
#
# BASH 3.2. No associative arrays, no `${var^^}`, no `mapfile`. Ordinary indexed arrays
# only, and never `"${arr[@]}"` on a possibly-empty array under `set -u` (bash 3.2 raises
# unbound-variable on that specific expansion) — this file loops by index throughout.
#
# [WALL: tests/archive.test.sh]

# roots.sh (which soft-sources root.sh) and run.sh, THE SOFT SOURCE — the idiom
# lib/detect.sh uses for lib/deps.sh and lib/checks.sh for lib/patrol.sh. Guarded on the
# function, so a caller that already has either pays nothing. run.sh soft-sources
# roots.sh itself, so sourcing it here is sufficient for both.
_archive_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}
if ! declare -F run_open >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_archive_self_dir)" && pwd -P)/run.sh"
fi

# _archive_leaf <path> -> the last path segment. Never `basename`, for lib/detect.sh's
# reason restated in roots.sh: a library that cannot be sourced without coreutils dies on
# the half-broken machine it is most needed on.
_archive_leaf() {
  case "$1" in
    */) _archive_leaf "${1%/}" ;;
    */*) printf '%s\n' "${1##*/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# archive_run <run-dir> -> see the file header. Prints one line, returns 0 (moved or a
# benign no-op) or 1 (refused).
archive_run() {
  local run_dir="$1"
  if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
    printf 'bionic: archive refused — %s is not a directory\n' "$run_dir"
    return 1
  fi
  run_dir="$(cd "$run_dir" && pwd -P)"

  local root
  root="$(project_root)"
  if [ -z "$root" ]; then
    printf 'bionic: archive refused — no project root from the current directory\n'
    return 1
  fi

  # AC-C.5: the opt-out, checked FIRST and short-circuiting everything below.
  local enabled
  enabled="$(config_value "$root" "archive-on-close" "true")"
  if [ "$enabled" = "false" ]; then
    printf 'bionic: archive skipped — archive-on-close: false\n'
    return 0
  fi

  local droot slug
  droot="$(docs_root "$root")"
  slug="$(_archive_leaf "$run_dir")"

  # <run-dir> is expected under <docs-root>/plans/ (see header) — a caller that hands
  # this something else gets a named refusal rather than a silent wrong answer.
  case "$run_dir" in
    "$droot"/plans/*/) ;;
    "$droot"/plans/*) ;;
    *)
      printf 'bionic: archive refused — %s is not under %s/plans\n' "$run_dir" "$droot"
      return 1
      ;;
  esac

  # THE ONE OPEN-RUN CHECK (see header: this is the whole epic-close/standalone/
  # open-epic distinction). Every *.plan.md directly under plans/<slug>/, asked
  # run_open — sourced from run.sh above. Depth 1: a plan lives directly in its slug
  # directory (plans/<epic-slug>/<wave>.plan.md), matching lib/run.sh's own layout.
  local plans_dir="$droot/plans/$slug" f
  if [ -d "$plans_dir" ]; then
    while IFS= read -r -d '' f; do
      if run_open "$f"; then
        printf 'bionic: archive skipped — %s still has an open run (%s)\n' "$slug" "$f"
        return 0
      fi
    done < <(find "$plans_dir" -maxdepth 1 -type f -name '*.plan.md' -print0 2>/dev/null)
  fi

  local aroot broot project_name dest_base origin_file
  aroot="$(archive_root "$root")"
  broot="$(bionic_root "$root")"
  project_name="$(_archive_leaf "$root")"
  dest_base="$aroot/$project_name"
  origin_file="$dest_base/origin"

  # AC-C.4: the origin file, read-only at this point — see the header for why the
  # write happens later, only once a move is actually about to proceed.
  if [ -f "$origin_file" ]; then
    local recorded
    recorded="$(cat "$origin_file" 2>/dev/null)"
    if [ "$recorded" != "$root" ]; then
      printf 'bionic: archive refused — origin mismatch at %s (names %s; this project is %s)\n' \
        "$origin_file" "$recorded" "$root"
      return 1
    fi
  fi

  # THE THREE TREES. Indexed arrays, bash-3.2-safe: looped by index, never
  # "${arr[@]}" on a possibly-empty array under set -u.
  local -a leaders=(specs plans adrs)
  local -a srcs=()
  local -a dests=()
  local i leader src rel dest
  i=0
  while [ "$i" -lt 3 ]; do
    leader="${leaders[$i]}"
    src="$droot/$leader/$slug"
    i=$((i + 1))
    [ -d "$src" ] || continue
    # relative path from bionic_root — the "<same relative path>" ADR-003 and ac-C.1
    # both name. Falls back to the absolute source when docs-root: has been configured
    # outside bionic_root entirely (an edge case no AC exercises; recorded here rather
    # than silently mishandled).
    case "$src" in
      "$broot"/*) rel="${src#"$broot"/}" ;;
      *) rel="${src#/}" ;;
    esac
    dest="$dest_base/.bionic/$rel"
    srcs[${#srcs[@]}]="$src"
    dests[${#dests[@]}]="$dest"
  done

  if [ "${#srcs[@]}" -eq 0 ]; then
    printf 'bionic: archive skipped — nothing under specs/plans/adrs for %s\n' "$slug"
    return 0
  fi

  # AC-C.3: occupied-slot pre-check over ALL destinations, before any mv — a refusal
  # here leaves every source untouched, not just the one that collided.
  i=0
  while [ "$i" -lt "${#dests[@]}" ]; do
    if [ -e "${dests[$i]}" ]; then
      printf 'bionic: archive refused — occupied slot at %s (source untouched)\n' "${dests[$i]}"
      return 1
    fi
    i=$((i + 1))
  done

  mkdir -p "$dest_base" || {
    printf 'bionic: archive refused — could not create %s\n' "$dest_base"
    return 1
  }
  [ -f "$origin_file" ] || printf '%s\n' "$root" > "$origin_file"

  local moved=""
  i=0
  while [ "$i" -lt "${#srcs[@]}" ]; do
    mkdir -p "$(dirname "${dests[$i]}")"
    if mv "${srcs[$i]}" "${dests[$i]}"; then
      printf 'bionic: archived %s -> %s\n' "${srcs[$i]}" "${dests[$i]}"
      moved="yes"
    else
      printf 'bionic: archive refused — mv failed for %s -> %s\n' "${srcs[$i]}" "${dests[$i]}"
      return 1
    fi
    i=$((i + 1))
  done

  [ -n "$moved" ] && return 0
  return 1
}
