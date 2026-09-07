#!/bin/bash
# checks.sh — THE TABLE OF CHECKS (bionic 1.5.1 fixit, epic-21 row 2a).
#
# WHAT THIS FILE OWNS. One row per fact bionic needs true on a machine, and for
# each row: how it is detected, who repairs it, which setup item does the repair
# when the party is setup, and the hint a report must carry so the reader knows
# where to go. Nothing else owns any of those four things. doctor.sh renders
# state from these rows and setup.sh renders its roster and its actions from the
# same rows, so the two cannot come to disagree about what /bionic:setup can fix
# — which is the field defect this file exists to end (bug report
# .bionic/docs/ideas/bug-doctor-setup-ownership.md, filed against payload 1.4.3:
# doctor printed `16 legacy hook files … → /bionic:setup` and the run that
# followed said "nothing left to do").
#
# WHY A TABLE AND NOT A JOIN. The design ruled 2026-09-06 (frame "Option 1"):
# every consumer reads the source of truth DIRECTLY, at the moment of use, and
# nothing ever copies it. So the rows are shell code both scripts source, not
# data one of them parses — a parsed table would be a second thing to keep in
# agreement with the predicate it names, which is the defect one level up.
#
# A ROW NAMES A DETECTOR AND A REPAIR PARTY, NEVER BLANK (design D-2). The party
# is a closed set:
#
#   setup  the item named in the row's `item` field clears it
#   cli    the Claude Code CLI installed it alongside bionic and reinstalls it;
#          deps.sh owns that route (`dep_core_repair_route`), and setup has no
#          second installer for it (deps.sh D1)
#   user   the reader clears it by hand, and the hint is the instruction
#
# A row whose party is `setup` carries the item; a row whose party is anything
# else carries none, and its hint names the party's own route instead. That rule
# is what tests/cross-gate-agreement.test.sh §DS checks in both directions.
#
# THE DETECTORS ARE READ-ONLY, ALL OF THEM. They were setup's `_setup_item_pending`
# arms and they moved here whole; doctor calls them too, and doctor never changes
# anything. Every arm and every function those arms call was scanned for a write
# before the move (14/14 arms, 17/17 callees; record/fixit-1.5.1-one-table-two-renderers/t1-readonly.txt).
# A detector added later that writes anything breaks doctor's central promise, so
# it does not go here — it goes to setup as an action, and its read-only half
# comes here.
#
# WHAT IS NOT HERE. The words setup uses for an ACTION ("install the bionic
# plugin") stay in setup.sh: they are the consent screen's copy, not a fact about
# the machine. The columns, the widths and the collapsed verdict stay in
# doctor.sh: that is presentation. This file holds facts.
#
# Sourced, never executed:  . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/checks.sh"

_bionic_checks_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}

# THE SOFT SOURCE, the same idiom detect.sh uses for deps.sh. detect.sh already
# pulls deps.sh, env.sh and shell.sh in that order, so a caller that has detect.sh
# gets all four and one that has none gets them all here, once.
if ! declare -F detect_legacy_hook_files >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_bionic_checks_self_dir)" && pwd -P)/detect.sh"
fi

# THE SAME SOFT SOURCE FOR patrol.sh, which the dead-session detector reads its
# whole answer out of. doctor already has it loaded and the guard skips; setup
# does not, and a detector that only works for one of its two callers is not a
# detector. Sourcing it defines functions and nothing else — no probe, no read.
if ! declare -F patrol_dead_sessions >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_bionic_checks_self_dir)" && pwd -P)/patrol.sh"
fi

# ─── The two repair routes ───────────────────────────────────────────────────
#
# ONE STRING PER PARTY FOR THE TWO PARTIES THAT HAVE ONE. An aggregate line —
# "3 dependencies absent" over three rows — has no single row to read, so it
# reads the PARTY's route here rather than growing a literal of its own.
#
# `user` RETURNS NOTHING, AND THAT IS THE ANSWER, not a gap. A repair the reader
# takes by hand has no route shared across rows: the instruction IS the row's,
# one verb per fact, so a `user` row carries its verb in its own hint column and
# there is nothing for this function to say about the party in general. Callers
# that print a party's route therefore print nothing for `user`, which is right —
# the row has already said what to type.
bionic_check_route() {  # <setup|cli|user>
  case "${1:-}" in
    setup) printf '/bionic:setup' ;;
    cli)   dep_core_repair_route ;;
    user)  printf '' ;;
    *)     return 1 ;;
  esac
  return 0
}

# ─── The walls, which are facts about the payload and not about the machine ──
#
# The four hooks that stand over actions that cannot be taken back. Their roster
# lived in doctor.sh until 1.5.1; it is a list of things bionic needs true, so it
# is here, and doctor reads it.
BIONIC_WALL_HOOKS="protect-main canonical-sdlc-evidence-gate farm-out-reminder background-suite-guard"

bionic_check_payload_root() { _detect_plugin_root; }

# THE WANTED BASENAMES COME FROM THE HOOK, not from a list kept here. A hook that
# adopts the loader idiom declares them on a `BIONIC_LIB_WANT=` line above the
# block; one that has not yet adopted it names its library in the `lib/<name>.sh`
# path it sources. Either way the answer is the hook's own.
bionic_check_wall_want() {  # <hook-file> -> space-separated library basenames
  local f="${1:-}" want=""
  want="$(grep -m1 '^[[:space:]]*BIONIC_LIB_WANT=' "$f" 2>/dev/null \
          | sed -e 's/^[[:space:]]*BIONIC_LIB_WANT=//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
  if [ -z "$want" ]; then
    want="$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null \
            | grep -oE 'lib/[A-Za-z0-9_.-]+\.sh' \
            | sed 's|^lib/||' | sort -u | tr '\n' ' ')"
  fi
  printf '%s' "$want"
}

# ASKED THROUGH THE IDIOM ITSELF, never through a copy of it. `bionic_loader_pin`
# prints the canonical block; it runs in a child shell whose `$0` is the HOOK'S
# OWN PATH, which is the single input the block's candidate list is a function of.
# Built on first use, not at source time: setup never asks this question, and a
# library that paid for a heredoc and a subshell on every setup run would be
# charging the wrong script.
_BIONIC_CHECKS_LOADER_PROBE=""
bionic_check_wall_probe() {  # <hook-file> <wanted basenames> -> lib=…|missing=…|cands=…
  if [ -z "$_BIONIC_CHECKS_LOADER_PROBE" ]; then
    if ! declare -F bionic_loader_pin >/dev/null 2>&1; then
      # shellcheck source=/dev/null
      . "$(cd "$(_bionic_checks_self_dir)" && pwd -P)/loader.sh" 2>/dev/null || return 1
    fi
    _BIONIC_CHECKS_LOADER_PROBE="$(bionic_loader_pin 2>/dev/null)
printf 'lib=%s|missing=%s|cands=%s\\n' \"\$BIONIC_LIB\" \"\$BIONIC_LIB_MISSING\" \"\$BIONIC_LIB_CANDS\""
  fi
  BIONIC_LIB_WANT="${2:-}" bash -c "$_BIONIC_CHECKS_LOADER_PROBE" "$1" 2>/dev/null
}

# ─── The CLI's own view of a plugin ──────────────────────────────────────────
#
# Presence of a core dependency is `check_dep`'s answer (it reads the install
# registry, and it is the one owner of that fact). ENABLED-ness is not in that
# registry at all — it lives in the CLI's settings — so it is asked of the CLI
# itself, the same tool that would repair it. Matching is on the NAME half of
# `name@marketplace`, exactly as `_dep_check_native` does, so a dependency
# re-pointed at a different marketplace still resolves.
#
# Prints `<state>|<id>` where state is enabled | disabled | absent | unknown.
# `unknown` is a real answer here: without the CLI or without jq there is no
# honest way to look, and a confident `absent` would make setup offer to install
# a plugin that is already there. Moved out of setup.sh at 1.5.1 — doctor's rows
# read the same predicate now, and two copies of it would be the drift this file
# exists to prevent.
bionic_cli_plugin_state() {  # <name>
  local name="${1:-}" json row
  command -v claude >/dev/null 2>&1 || { echo "unknown|"; return 0; }
  command -v jq >/dev/null 2>&1     || { echo "unknown|"; return 0; }
  json="$(claude plugin list --json 2>/dev/null)" || { echo "unknown|"; return 0; }
  [ -n "$json" ] || { echo "unknown|"; return 0; }
  row="$(jq -r --arg n "$name" '
      [ .[]? | select(((.id // "") | split("@")[0]) == $n) ] as $m
      | if ($m | length) == 0 then "absent|"
        else (if ($m[0].enabled // false) then "enabled|" else "disabled|" end) + ($m[0].id // "")
        end' <<< "$json" 2>/dev/null)" || row=""
  case "$row" in
    enabled*|disabled*|absent*) echo "$row" ;;
    *)                          echo "unknown|" ;;
  esac
}

# THE DUPLICATE PROBE, ASKED ONCE PER PROCESS. It shells out to the CLI under a
# timeout bound, and both renderers need its answer — the roster names a row per
# duplicate and doctor prints one row per duplicate. Cached here so the table's
# own build and the render that follows it are one call and not two.
_BIONIC_CHECKS_DUPS=""
_BIONIC_CHECKS_DUPS_READ=""
bionic_check_duplicate_lines() {  # -> zero or more `dup=` lines, always exit 0
  if [ -z "$_BIONIC_CHECKS_DUPS_READ" ]; then
    _BIONIC_CHECKS_DUPS="$(detect_plugin_duplicates)"
    _BIONIC_CHECKS_DUPS_READ=1
  fi
  [ -n "$_BIONIC_CHECKS_DUPS" ] && printf '%s\n' "$_BIONIC_CHECKS_DUPS"
  return 0
}

# ─── The detectors ───────────────────────────────────────────────────────────
#
# Every one of these returns 0 when the check FIRES — when the fact is NOT true
# on this machine and there is something to say about it. That is the sense
# `_setup_item_pending` had, and doctor's rows read it the same way. Each takes
# the ROW ID as its argument, so one function serves a whole generated family.

bionic_check_plugin_absent() {  # <row id>
  local state id
  IFS='|' read -r state id <<< "$(bionic_cli_plugin_state bionic)"
  [ "$state" = "absent" ]
}

# The roster only names a duplicate this machine actually carries, so a row that
# exists at all is a question the run would ask.
bionic_check_duplicate() { return 0; }  # <row id>

bionic_check_plugin_disabled() {  # <row id: dependency:<name>>
  local state id
  IFS='|' read -r state id <<< "$(bionic_cli_plugin_state "${1#*:}")"
  [ "$state" = "disabled" ]
}

# An `unknown` presence is OFFERED, not skipped — some mechanisms have no surface
# to read and the step asks anyway, so the plan names them too.
bionic_check_dep_absent() {  # <row id: tool:<name> | dep:<name>>
  local present
  present="$(check_dep "${1#*:}")" || return 1
  present="${present#present=}"; present="${present%%|*}"
  [ "$present" != "yes" ]
}

# THE ROW THE REGISTRY LOST WHILE THE FILES STAYED (REQ-S0). Two facts about one
# plugin: the CLI's list of installed plugins has no entry for it, and the
# directory the CLI unpacked it into is still there. Apart, neither is a finding
# — an absent entry is the ordinary state of a plugin nobody installed, and a
# cache directory is what every installed plugin has. Together they are the state
# the field report describes and the one a probe reading the registry alone
# cannot see: `bionic_check_dep_absent` above answers `absent` for it and for
# never-installed alike, so the report offered a fresh install and setup paid for
# a download of bytes that were already correct on disk
# (record/wave-01-plugin-only/s00-registry-drop.md §4).
#
# THE PREDICATE IS deps.sh's, NOT A SECOND READING OF THE SAME FILES. The
# registry parse and the cache walk both belong to the mechanism that installs a
# native row, and the repair party reads the same two answers before it writes;
# a copy here would be free to drift from the repair it is a diagnosis for.
bionic_check_registry_row_dropped() {  # <row id: registry-row:<name>>
  dep_registry_row_restorable "${1#registry-row:}"
}

bionic_check_env_unwritten() {  # <row id: env:<KEY>>
  local key="${1#env:}" want have
  want="$(env_default "$key")" || return 1
  have="$(env_get "$key" 2>/dev/null)" || have=""
  [ "$have" != "$want" ]
}

# A shell bionic writes no rc for is not a question: the step says so and changes
# nothing, so nothing must name it either.
bionic_check_claude_proxy() {  # <row id>
  rc_file >/dev/null 2>&1 || return 1
  rc_get claude-proxy && return 1
  return 0
}

# THE PRE-MARKER SPELLING, and the one place it is written down. setup.sh carried
# it as `SETUP_ALIAS_PATTERN` until 1.5.1; the predicate that reads it lives here
# now, and setup's removal step reads this same name rather than a second copy.
# Declared BEFORE the function that uses it, so a caller who sources this file
# under `set -u` and reaches the removal step first still finds it.
BIONIC_LEGACY_ALIAS_PATTERN='alias claude=.*dangerously-skip-permissions'

bionic_check_legacy_alias() {  # <row id>
  local line settings
  line="$(detect_zshrc_legacy_block)"
  [ "${line#*present=}" = "yes" ] && return 0
  settings="$(_detect_shell_rc)"
  [ -f "$settings" ] && grep -qE "$BIONIC_LEGACY_ALIAS_PATTERN" "$settings" 2>/dev/null && return 0
  return 1
}

bionic_check_legacy_hooks() {  # <row id>
  local line count
  line="$(detect_legacy_channel_hooks)"; count="${line#*count=}"
  case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

bionic_check_legacy_skill_copy() {  # <row id>
  local line present
  line="$(detect_legacy_skill_copy)"
  present="${line#*present=}"; present="${present%% *}"
  [ "$present" = "yes" ]
}

# `unknown` is not a question: the step says so and changes nothing.
bionic_check_legacy_hook_files() {  # <row id>
  local line count
  line="$(detect_legacy_hook_files)"; count="${line#*count=}"; count="${count%% *}"
  case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

bionic_check_legacy_agent_copies() {  # <row id>
  local line present count
  line="$(detect_installed_agent_copies)"
  present="${line#*state=}"; present="${present%% *}"
  [ "$present" = "present" ] || return 1
  count="${line#*drift=}"; count="${count%% *}"
  case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

bionic_check_legacy_permission_block() {  # <row id>
  bionic_has_permission_block "$(_dep_settings_file)"
}

# No jq is not a question: the step says so and changes nothing.
bionic_check_permission_mode() {  # <row id>
  local settings mode
  command -v jq >/dev/null 2>&1 || return 1
  settings="$(_dep_settings_file)"
  if [ -f "$settings" ]; then
    mode="$(jq -r '.permissions.defaultMode // ""' "$settings" 2>/dev/null)" || mode=""
  else
    mode=""
  fi
  [ "$mode" != "$BIONIC_DEFAULT_PERMISSION_MODE" ]
}

# The recorded status-line command is one of the two halves `_dep_check_statusline`
# reads, so a machine whose command still says `npx` is a machine where
# ccstatusline is not installed the way setup installs it — which is why this
# row's repair item is the dependency's own.
bionic_check_statusline_npx() {  # <row id>
  local line
  line="$(detect_statusline_npx_command)"
  [ "${line##*present=}" = "yes" ]
}

# ONE VERDICT PER WALL, AND EVERYONE READS IT (Step-6 review B-2). Doctor's page
# used to ask these two questions again in its own render loop — is the file
# readable, does the loader probe answer with a library — while the two detectors
# below asked them here and were never invoked by anything. Two implementations
# of one fact, free to drift in either direction with nothing going red. Now this
# function is the implementation: doctor's loop reads it per wall for the row it
# prints, and the two row detectors read it across the roster for the fix line.
#
# THE ANSWER IS A WORD PLUS THE ONE THING THE RENDERER NEEDS: `missing`, `ok`, or
# `unloadable=<library>` — the first basename the hook asked for and did not get,
# falling back to what the hook declared when the probe itself could not run, so
# a row names a library either way rather than an empty string.
bionic_check_wall_state() {  # <wall hook name> -> missing | ok | unloadable=<lib>
  local w="${1:-}" root f want probe lib miss
  root="$(bionic_check_payload_root)"
  f="${root}/hooks/${w}.sh"
  [ -r "$f" ] || { printf 'missing'; return 0; }
  want="$(bionic_check_wall_want "$f")"
  probe="$(bionic_check_wall_probe "$f" "$want")"
  lib=""; miss=""
  while IFS= read -r _bcw_f; do
    case "$_bcw_f" in
      lib=*)     lib="${_bcw_f#lib=}" ;;
      missing=*) miss="${_bcw_f#missing=}" ;;
    esac
  done <<<"$(printf '%s' "$probe" | tr '|' '\n')"
  [ -n "$lib" ] && { printf 'ok'; return 0; }
  [ -n "$miss" ] || miss="${want%% *}"
  [ -n "$miss" ] || miss="the bionic library"
  printf 'unloadable=%s' "$miss"
  return 0
}

bionic_check_wall_missing() {  # <row id>
  local w
  for w in $BIONIC_WALL_HOOKS; do
    [ "$(bionic_check_wall_state "$w")" = "missing" ] && return 0
  done
  return 1
}

bionic_check_wall_unloadable() {  # <row id>
  local w
  for w in $BIONIC_WALL_HOOKS; do
    case "$(bionic_check_wall_state "$w")" in (unloadable=*) return 0 ;; esac
  done
  return 1
}

# DEAD-SESSION STATE UNDER .bionic/tmp — the one PROJECT-scoped row in this
# table, and the one whose party is `user` (fixit 1.5.2 defect; plan D-4/D-5;
# REWORDED for R2, ticket-30, plan D-4/D-5 amended). Every other row is a fact
# about the machine; this one is a fact about the tree doctor was run in, which
# is why it renders in doctor's project sections rather than in either
# machine-state table.
#
# WHAT THIS ROW USED TO FIRE ON, AND WHY THAT IS GONE. Before R2 the detector was
# `[ -n "$(patrol_dead_sessions …)" ]` — any dead session's leftover state, every
# time — which is exactly the shape ticket-30 filed against: doctor named the raw
# script `session-poker.sh sweep` as the fix, and nothing in the product could
# invoke it, so the row was permanent nagging with no button behind it. Now
# hooks/session-start.sh calls that same verb itself, silently, once per session
# start (REQ-R2) — so a dead session's residue is routinely gone again within one
# Patrol interval, and a row that still fired on "any dead session exists" would
# be reporting the NORMAL, SELF-HEALING gap between a `/clear` and the next
# session start as a standing problem. The fact worth a row now is not "residue
# exists" — it is "the thing that is supposed to clear it did not".
#
# THE ENUMERATION IS THE HOOK'S OWN MARKER, NOT A RE-WALK. session-start.sh writes
# `.bionic/tmp/sweep-failed.state` only when its own bounded `sweep` call answered
# something other than "swept" or "nothing to sweep, everyone here is live" (rc 0
# or 1) — a genuine refusal, or its own bound expiring. Read-only, like every
# detector here: it stats one path and, on the positive case, reads one line back.
bionic_check_dead_session_state() {  # <row id>
  local f
  f="$(_bionic_check_sweep_failed_marker)"
  [ -f "$f" ] && [ ! -L "$f" ]
}

# THE MARKER'S PATH, for the detector above and for the rc reader below — one
# spelling, because a second copy of `<root>/.bionic/tmp/sweep-failed.state` is
# exactly the drift this file exists to prevent elsewhere.
_bionic_check_sweep_failed_marker() {  # -> the marker path for the project at $PWD
  local root
  root="$(_patrol_repo_root "$PWD" 2>/dev/null)" || root=""
  [ -n "$root" ] || root="$PWD"
  printf '%s/.bionic/tmp/sweep-failed.state' "$root"
}

# THE RC A READER PUTS IN WORDS (scope constraint: "naming that the automatic
# sweep failed and the rc"). Read here, once, rather than doctor re-parsing the
# marker's own line — the same "one reader" rule every fielded value in this file
# follows. Empty when the marker is absent or unreadable; the caller decides what
# an empty rc renders as.
bionic_check_sweep_failed_rc() {  # -> the rc session-start.sh recorded, or empty
  local f
  f="$(_bionic_check_sweep_failed_marker)"
  [ -f "$f" ] && [ ! -L "$f" ] || { printf ''; return 1; }
  sed -n 's/.*|rc=\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1
}

# ─── The table ───────────────────────────────────────────────────────────────
#
# ONE FUNCTION EMITS EVERY ROW — the static ones and the ones generated from the
# dependency catalog and the environment catalog alike — so there is exactly one
# place a row can come from. A second emitter would be a second source, which is
# the whole thing this file replaces.
#
# THE ORDER IS THE ROSTER'S ORDER. setup's `--list` is this table's `item` column
# with the blanks dropped and the repeats collapsed, so the order rows are
# emitted in IS the order a user reads on the consent page.
#
# Fields, `|`-separated:  id | label | detector | party | item | hint
#
#   id        unique; the name doctor and setup ask for a row by
#   label     the label doctor's row carries, empty when doctor renders no row
#             for this check (`plugin`, the duplicates and the core-enable rows
#             reach a reader through a FIX line instead, which is a different
#             surface and not a row).
#             THE TWO RENDERERS ARE NOT SYMMETRIC, and this is where a reader
#             adding a row finds that out (Step-6 review C-1). Setup's roster is
#             DERIVED: give a row an `item` and it appears on `--list` with no
#             other edit. Doctor's rows are not — doctor owns presentation, so
#             each labelled row is rendered by a call site written by hand in the
#             section that row belongs in (the environment loop, the dependency
#             walk, the leftover block at doctor.sh's ENVIRONMENT table), and a
#             labelled row with no call site renders nowhere at all. What keeps
#             that from being silent is the agreement test, not this comment:
#             §DS of tests/cross-gate-agreement.test.sh walks every labelled row
#             that fires on the fixture and fails if doctor's page does not carry
#             it, with its hint, wherever its section puts it.
#   detector  read-only, returns 0 when the check fires
#   party     setup | cli | user
#   item      the setup item that clears it; empty unless party is setup
#   hint      the repair clause the report must carry — the party's route, except
#             under party `user`, where it is the instruction (contract at the top)
_bionic_checks_emit() {  # <id> <label> <detector> <party> <item> <hint>
  printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

_bionic_checks_build() {
  local n line bare key r_setup r_cli
  r_setup="$(bionic_check_route setup)"
  r_cli="$(bionic_check_route cli)"

  _bionic_checks_emit "plugin" "" "bionic_check_plugin_absent" "setup" "plugin" "$r_setup"

  # fd 3 throughout: these lists must never be read on the standard input, which
  # belongs to setup's questions.
  while IFS= read -r line <&3; do
    [ -n "$line" ] || continue
    bare="${line#dup=}"; bare="${bare%% *}"
    [ "$bare" = "unknown" ] && continue
    _bionic_checks_emit "duplicate:${bare}" "" "bionic_check_duplicate" "setup" "duplicate:${bare}" "$r_setup"
  done 3< <(bionic_check_duplicate_lines)

  # TWO FACTS ABOUT ONE CORE DEPENDENCY, and they have different owners. "It is
  # installed but switched off" is setup's — the CLI's settings hold the switch
  # and setup flips it. "It is not there at all" is the CLI's: it installed the
  # dependency alongside bionic and deps.sh's D1 forbids setup a second
  # installer, so that row names `dep_core_repair_route` and never setup. Both
  # facts are true of the same name, which is why they are two rows and not one.
  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    _bionic_checks_emit "dependency:${n}" "" "bionic_check_plugin_disabled" "setup" "dependency:${n}" "$r_setup"
    _bionic_checks_emit "dep:${n}" "$n" "bionic_check_dep_absent" "cli" "" "$r_cli"
  done 3< <(dep_names_class core)

  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    _bionic_checks_emit "tool:${n}" "$n" "bionic_check_dep_absent" "setup" "tool:${n}" "$r_setup"
  done 3< <(dep_names_class basic)
  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    _bionic_checks_emit "tool:${n}" "$n" "bionic_check_dep_absent" "setup" "tool:${n}" "$r_setup"
  done 3< <(dep_names_class extra)

  # ONLY ON A MACHINE THAT HAS THE STATE, the same way a `duplicate:` row exists
  # only for a duplicate this machine actually carries. A row emitted for every
  # native plugin would put five permanent entries on setup's roster that a
  # healthy machine has nothing to do about; the roster is what a user reads, and
  # a fact that is almost never true does not belong on it as a standing line.
  # The detector is asked here AND kept on the row: the table is built once per
  # process, and a repair that lands inside that process must be able to make the
  # row stop firing without the build being redone.
  #
  # WHO REPAIRS IT DEPENDS ON WHICH ROW IT IS, and both answers were measured. A
  # row bionic does not declare — `impeccable`, and the two anthropic skill packs
  # — is reachable from setup's own extras item, and that item now restores the
  # entry from the cache instead of re-installing (deps.sh `restore_plugin_row`).
  # A `core` row is the CLI's: reinstalling bionic restores `superpowers` and
  # `agent-skills` because bionic declares them (ruling §1), and D1 gives setup no
  # item for either, so the row names the CLI's route exactly as `dep:<name>` does.
  while IFS= read -r n <&3; do
    [ -n "$n" ] || continue
    bionic_check_registry_row_dropped "registry-row:${n}" || continue
    if [ "$(dep_field "$n" class 2>/dev/null)" = "core" ]; then
      _bionic_checks_emit "registry-row:${n}" "" "bionic_check_registry_row_dropped" "cli" "" "$r_cli"
    else
      _bionic_checks_emit "registry-row:${n}" "" "bionic_check_registry_row_dropped" "setup" "tool:${n}" "$r_setup"
    fi
  done 3< <(dep_names_kind native)

  # ONE ROW PER SETTING, ONE ITEM FOR ALL OF THEM. doctor prints a row per name
  # and setup writes them in one step, so the rows are per-name and they share an
  # item — which is exactly what the `item` column being its own field is for.
  # A `when-needed` dependency gets no row at all: it is absent by design until a
  # route asks for it, doctor says so, and setup would not install it.
  for key in $ENV_KEYS; do
    _bionic_checks_emit "env:${key}" "$key" "bionic_check_env_unwritten" "setup" "environment" "$r_setup"
  done

  _bionic_checks_emit "claude-proxy" "claude() shell proxy" "bionic_check_claude_proxy" "setup" "claude-proxy" "$r_setup"
  _bionic_checks_emit "legacy-alias" "legacy .zshrc alias block" "bionic_check_legacy_alias" "setup" "legacy-alias" "$r_setup"
  _bionic_checks_emit "legacy-hooks" "legacy-channel managed hooks" "bionic_check_legacy_hooks" "setup" "legacy-hooks" "$r_setup"
  _bionic_checks_emit "legacy-skill-copy" "legacy installed skill copy" "bionic_check_legacy_skill_copy" "setup" "legacy-skill-copy" "$r_setup"
  _bionic_checks_emit "legacy-hook-files" "legacy hook files" "bionic_check_legacy_hook_files" "setup" "legacy-hook-files" "$r_setup"
  _bionic_checks_emit "legacy-agent-copies" "legacy installed agent copies" "bionic_check_legacy_agent_copies" "setup" "legacy-agent-copies" "$r_setup"

  # THE TWO ITEMS THAT HAD NO DOCTOR SURFACE AT ALL until 1.5.1 (step-0 map §B.4:
  # the only mention of either in doctor.sh was a comment naming a mutation doctor
  # must never call). A setup item nobody can see the need for is a repair with no
  # diagnosis, so both get a row, and the row's detector is the item's own
  # predicate rather than a second reading of the same file.
  _bionic_checks_emit "legacy-permission-block" "legacy permission block" "bionic_check_legacy_permission_block" "setup" "legacy-permission-block" "$r_setup"
  _bionic_checks_emit "permission-mode" "default permission mode" "bionic_check_permission_mode" "setup" "permission-mode" "$r_setup"

  _bionic_checks_emit "statusline-npx" "statusLine command" "bionic_check_statusline_npx" "setup" "tool:ccstatusline" "$r_setup"

  # THE PROJECT-STATE ROW, and the only one whose party is the reader. No item:
  # setup is machine-scoped and has no project concept, so there is nothing for
  # it to offer. No label either: like `plugin` and the two wall rows, this check
  # reaches a reader through a FIX line rather than through a row of its own name.
  # R2 (ticket-30) narrowed WHAT fires it — session-start.sh's own auto-sweep is
  # the ordinary cure now, so this row is silent unless that auto-sweep itself
  # failed — but the hint stays the manual verb: it is the one thing left for a
  # reader to type when the automatic cure did not work on its own.
  _bionic_checks_emit "dead-session-state" "" "bionic_check_dead_session_state" "user" "" "session-poker.sh sweep"

  # THE WALLS ARE THE CLI'S TO REPAIR, not setup's. A wall missing from the
  # payload, or one that cannot reach its library, is a broken install — the same
  # reinstall route a missing core dependency takes (1.4.4 fixit). Until 1.5.1
  # both fix lines said `run /bionic:setup — repair`, and `repair` is not a verb
  # setup takes: the line named a command that could not have worked.
  _bionic_checks_emit "wall-payload" "" "bionic_check_wall_missing" "cli" "" "$r_cli"
  _bionic_checks_emit "wall-library" "" "bionic_check_wall_unloadable" "cli" "" "$r_cli"
}

# BUILT ONCE PER PROCESS, IN THE PROCESS — and this is not an optimisation, it is
# the only place the build can go. Every reader below is called from inside a
# command substitution (`"$(bionic_check_hint legacy-hook-files)"` is what a
# renderer writes), and a cache filled inside `$( )` dies with the subshell that
# filled it. A lazy build therefore does not run once; it runs once per READ, and
# the build asks the CLI for this machine's duplicate registrations under a
# timeout bound. Measured on doctor before this was moved: 73 seconds against 10,
# almost all of it waiting on that probe, and long enough that a test fixture's
# live session pid expired between two runs.
#
# So the table is built HERE, at source time, in the shell that sources this file.
# A subshell inherits the variable and reads it without asking anything. Both
# scripts that source this file already asked the same probe once on their own
# before 1.5.1, so nothing on either page got slower than it was.
_BIONIC_CHECKS_TABLE=""
_bionic_checks_ensure() {
  [ -n "$_BIONIC_CHECKS_TABLE" ] && return 0
  # THE PROBE IS ASKED OUT HERE, not inside the build. The build itself runs in a
  # command substitution, so a cache it fills is thrown away with it — and the
  # duplicate probe is the one input that costs a bounded CLI call. Asked in this
  # shell, the answer is inherited by the build AND by every later reader,
  # including doctor's own duplicates block, so the machine is asked exactly once.
  bionic_check_duplicate_lines >/dev/null
  _BIONIC_CHECKS_TABLE="$(_bionic_checks_build)"
}

bionic_check_rows() {  # -> the whole table, one row per line
  _bionic_checks_ensure
  printf '%s\n' "$_BIONIC_CHECKS_TABLE"
}

# READ WITH THE SHELL'S OWN SPLITTER, never `cut`. A field read that forks is
# forty rows' worth of processes per lookup and the renderers do dozens of
# lookups; `IFS='|' read` is the same answer with no process at all.
_bionic_check_field() {  # <id> <field index 2..6>
  local id="${1:-}" want="${2:-}" f1 f2 f3 f4 f5 f6
  _bionic_checks_ensure
  while IFS='|' read -r f1 f2 f3 f4 f5 f6; do
    [ "$f1" = "$id" ] || continue
    case "$want" in
      2) printf '%s' "$f2" ;;
      3) printf '%s' "$f3" ;;
      4) printf '%s' "$f4" ;;
      5) printf '%s' "$f5" ;;
      6) printf '%s' "$f6" ;;
      *) return 1 ;;
    esac
    return 0
  done <<<"$_BIONIC_CHECKS_TABLE"
  return 1
}

# ONE ACCESSOR PER FIELD A CALLER ASKS FOR BY ID, AND NO MORE (Step-6 review
# B-3). `bionic_check_party` (field 4 by id) and `bionic_check_dep_row` (a
# dependency name to its row id) were written for callers that were never
# written: doctor asks `bionic_check_dep_hint` for the dependency question, and
# nothing asks a row's party by id — §DS reads party off a row it already holds.
# An accessor with no caller is a claim the code makes about itself that nothing
# checks, so the two are gone rather than kept for a future that has not arrived.
bionic_check_label()    { _bionic_check_field "${1:-}" 2; }
bionic_check_detector() { _bionic_check_field "${1:-}" 3; }
bionic_check_item()     { _bionic_check_field "${1:-}" 5; }
bionic_check_hint()     { _bionic_check_field "${1:-}" 6; }

# The hint a dependency row carries, empty for a dependency no row covers. One
# pass, not two: the row is found and its hint read in the same walk.
bionic_check_dep_hint() {  # <dependency name>
  local n="${1:-}" f1 f2 f3 f4 f5 f6
  _bionic_checks_ensure
  while IFS='|' read -r f1 f2 f3 f4 f5 f6; do
    case "$f1" in
      "tool:${n}"|"dep:${n}") printf '%s' "$f6"; return 0 ;;
    esac
  done <<<"$_BIONIC_CHECKS_TABLE"
  return 1
}

# ─── What setup reads ────────────────────────────────────────────────────────
#
# THE ROSTER IS THE `item` COLUMN. Blanks dropped — a row the CLI or the reader
# repairs is not something to ask setup for — and repeats collapsed, because the
# three environment rows are one step and the status-line row is cleared by the
# dependency item that already appears above it. First appearance wins, so the
# order a user reads is the order the table is written in.
bionic_check_items() {  # -> every setup item, once, in table order
  local f1 f2 f3 f4 f5 f6 seen=""
  _bionic_checks_ensure
  while IFS='|' read -r f1 f2 f3 f4 f5 f6; do
    [ -n "$f5" ] || continue
    case "$seen" in *"|${f5}|"*) continue ;; esac
    seen="${seen}|${f5}|"
    printf '%s\n' "$f5"
  done <<<"$_BIONIC_CHECKS_TABLE"
  return 0
}

# WOULD SETUP OFFER THIS ITEM ON THIS MACHINE. An item is outstanding when ANY of
# its rows fires: the environment step has three rows and one unwritten name is
# enough to make the step worth running, which is the sense setup's own predicate
# always had.
bionic_check_item_pending() {  # <setup item>
  local want="${1:-}" f1 f2 f3 f4 f5 f6
  _bionic_checks_ensure
  while IFS='|' read -r f1 f2 f3 f4 f5 f6; do
    [ "$f5" = "$want" ] || continue
    [ -n "$f3" ] || continue
    "$f3" "$f1" && return 0
  done <<<"$_BIONIC_CHECKS_TABLE"
  return 1
}

# Does one named row fire — the same question, asked of a row rather than an item.
bionic_check_fires() {  # <row id>
  local detector
  detector="$(bionic_check_detector "${1:-}")" || return 1
  [ -n "$detector" ] || return 1
  "$detector" "$1"
}

# ─── Built now, in the sourcing shell ────────────────────────────────────────
#
# See the note above `_bionic_checks_ensure`: a build deferred to the first read
# is a build that happens inside a command substitution and is thrown away again,
# once per read. This is the one line that makes the cache a cache.
_bionic_checks_ensure
