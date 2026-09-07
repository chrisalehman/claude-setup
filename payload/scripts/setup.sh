#!/bin/bash
# setup.sh — `/bionic:setup` (epic-17 wave-03, spec AC-2 and AC-6).
#
# WHAT THIS SCRIPT OWNS. The whole of tier 2: everything that has to be true of
# a MACHINE for bionic to work, in one idempotent, re-runnable pass. Tier 2
# contains tier 1 — the native plugin install is this script's first step, not a
# prerequisite the user is expected to have done — so `/bionic:setup` is a
# complete answer to "set this machine up", whether the box is three quarters of
# the way there or has nothing but bionic's marketplace registered.
#
# THAT PRECONDITION IS REAL AND IT IS NOT "COLD". Step 1 installs the plugin; it
# does not ADD the marketplace the plugin comes from, and `claude plugin
# marketplace add` is a mutation nobody consented to at the moment this script
# is reached. A genuinely cold box needs that one command by hand first (the
# Step-5 field walk measured exactly this). It is not machinery worth building:
# in the production story the user reaches `/bionic:setup` through the installed
# plugin, so the only caller who can be on a cold box is a developer running
# this script directly, and they are the person who added the marketplace.
#
# WHAT IT DOES NOT OWN. Facts and mechanisms. Whether a dependency is present is
# `detect.sh`/`deps.sh`'s answer; HOW a dependency installs is `deps.sh`'s
# `install_dep`, the same function a just-in-time offer calls (AC-5: one owner,
# no second installer); how a retired permission block is stripped back out is
# `deps.sh`. This script decides ORDER, asks the questions, and reports. Any
# fact it recomputed itself would be a second implementation of somebody else's
# truth, which is the defect the wave's ownership table exists to prevent.
#
# THE NINE STEPS, in this order and for these reasons:
#
#   1. plugin               tier 1 first: everything after it assumes the payload
#                           is installed, and a machine that skips it gets an
#                           honest action line rather than six confusing ones.
#   2. dependencies         the two plugins bionic declares. The harness installs
#                           these; what it does NOT always do is leave them
#                           enabled (measured: W1 run B landed superpowers
#                           `enabled: false`). Repair is an explicit `claude
#                           plugin enable`, never a reinstall.
#   3. tools                the substrate every machine needs — git, node, jq and
#                           the rest — one row at a time through `install_dep`,
#                           the same function a just-in-time offer calls.
#   4. optional extras      everything offered once with a line of what it is and
#                           a default of No — the conveniences nobody needs, and
#                           (since 2026-08-22) the route tools that used to be
#                           installed lazily mid-run.
#   5. shell environment    CLAUDE_CODE_ENABLE_TODO_TOOLS=1, marker-scoped.
#   6. legacy shell alias   the block claude-bootstrap.sh used to write. Auto
#                           mode is the default now and the safer equivalent, so
#                           the block is retired footprint. Ported here because
#                           the installer retires at W5 and this obligation must
#                           not retire with it.
#   7. legacy-channel hooks settings.json entries still naming the machine's
#                           pre-plugin hooks directory. The plugin registers its
#                           own hooks through the payload's hooks.json, so a
#                           settings entry naming that directory is registered
#                           through the OTHER channel. Also ported from the
#                           retiring installer.
#   8. legacy skill copy    the skill directory claude-bootstrap.sh rendered into
#                           the CLI's own skills directory. The payload ships the
#                           same skill, so the installed copy is a second one that
#                           still registers hooks through the pre-plugin channel.
#                           Named by AC-8; the gap 4/6 found and reported.
#   9. permission mode      whether Claude Code's default permission mode should
#                           be auto (AC-12) — one question, its own consent.
#                           bionic used to apply a managed allow-list here as
#                           well, exempting its own scripts from whatever mode
#                           the user had chosen; that is deleted (epic-18 T13),
#                           and the mode the user picks now governs bionic like
#                           everything else. A machine set up before the change
#                           still carries the old block, so the step opens with
#                           a one-time offer to strip it — same settings file,
#                           same subject, its own consent.
#
# AND TWO THINGS THAT ARE NOT STEPS, both between 1 and 2 (wave-06 S5). The
# LOAD STATE is printed at step 1's indentation with no header of its own,
# because it is not another thing setup does — it is the half of step 1 the
# install's exit code cannot report (AC-13). DUPLICATES is a block that exists
# only on a machine that has some: it carries no number precisely because it is
# usually absent, and a numbered step missing from most transcripts would leave
# a hole in the sequence the nine steps above are counted in (AC-8).
#
# WHICH TOOLS THIS SCRIPT IS ALLOWED TO ASK ABOUT (wave-06 D-B, spec AC-11, as
# narrowed by Chris's 2026-08-22 ruling). Steps 3 and 4 walk `dep_names_class
# basic` and `dep_names_class extra`, and nothing here walks `when-needed`.
# What changed on 2026-08-22 is the membership of those classes, not this rule:
# four rows that were `when-needed` — the browser driver, the devtools server,
# the chromium build and the pnpm-warmed animation library — are `extra` now, so
# step 4 offers them here rather than leaving the first install to happen inside
# the run that needed it. Two rows keep `when-needed` and this script still never
# mentions them: `impeccable` is native-kind, which `install_dep` is required to
# refuse outright, and `excalidraw-renderer` is a venv sync that means nothing to
# a machine which never renders. The classes are read from the table, never
# restated here: a second roster is a second opinion about what bionic depends on.
#
# CONSENT, AND WHY THERE IS ONE PROMPT SHAPE. Every mutation below is gated, per
# item, on an explicit `y` on this script's own standard input, and the gate is
# `deps.sh`'s `_dep_consent`
# — not a second prompt implementation. The plan is printed BEFORE the question
# and executed AFTER it, from the same string, so what the user agreed to is by
# construction what runs. There is no assume-yes knob: an env var that switched
# consent off would be the hole in "consent per event, never silent, never
# unattended". A closed stdin therefore declines everything, which is the
# fail-closed direction.
#
# WARN AND CONTINUE. `set -e` is deliberately absent. A machine that cannot do
# step 3 can still do steps 4-9, and stopping at the first problem is how a user
# ends up running setup five times. Every step that could not finish appends an
# ACTION LINE, and the run ends with all of them together — the summary is the
# interface, not the scroll. Exit status is 0 whenever setup itself worked,
# including a run where the user declined everything; declining is a valid
# answer, not an error.
#
# HONEST UNKNOWNS. `jq` is itself a row in the dependency table, so a cold
# machine may not have it. Where a fact cannot be read without it, this script
# says `unknown` and names jq as the fix rather than guessing — and never
# mutates on an unknown. Running setup twice on such a machine (once to install
# jq, once to use it) is the intended path, which is exactly what idempotence
# buys.
#
# IDEMPOTENT, AND WHAT THAT MEANS PRECISELY. A second run against an
# already-set-up machine performs no mutation and leaves every file it touches
# byte for byte identical. Each step's guard is the fact function that owns the
# question, so "already done" is decided by the same code doctor reports with.
#
# ROOTS ARE OVERRIDABLE, read at CALL time, so the hermetic suite can point the
# whole script at a fixture tree:
#
#   BIONIC_LIB_DIR        where scripts/lib/*.sh live   (default: beside this file)
#   BIONIC_PLUGIN_ROOT    the payload root              (or ${CLAUDE_PLUGIN_ROOT})
#   BIONIC_CLAUDE_HOME    the CLI config dir            (or ${CLAUDE_CONFIG_DIR})
#   BIONIC_SETTINGS_FILE  user settings.json
#   BIONIC_INSTALLED_PLUGINS_FILE  the CLI's install registry
#   BIONIC_SHELL_RC       the shell rc bionic edits
#
# TWO FLAGS, AND NEITHER OF THEM IS AN ANSWER (critic F-1 and F-2):
#
#   --list          print the name of every item this machine can be asked about,
#                   one per line, and exit.
#   --only <name>   ask about exactly that one item. Every other item is neither
#                   run nor asked about, so a single answer on the standard input
#                   can only ever consent to the thing that was named.
#
# See "ADDRESSABLE ITEMS" below the constants for why that second flag exists.
#
# Executed, never sourced:  bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh

set -uo pipefail

# No `dirname` here, same reason the libraries give: a cold or half-broken
# machine is exactly where this script has to run.
_setup_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}

SETUP_LIB_DIR="${BIONIC_LIB_DIR:-$(_setup_self_dir)/lib}"

# CHECKS.SH IS ON THIS LIST BECAUSE IT CARRIES THE WHOLE ROSTER (Step-6 review
# A-1). Every name this script can be asked for comes from `bionic_check_items`,
# so a payload missing that one file answered `--list` with an empty roster and
# exit 0 — the shape a caller reads as "this machine has nothing to set up" —
# instead of the reinstall route this guard exists to print. patrol.sh is here
# for the same reason one level down: checks.sh soft-sources it for the
# dead-session detector, so it is part of what a complete payload means.
for _setup_lib in deps.sh detect.sh hooks.sh jit.sh env.sh width.sh checks.sh patrol.sh; do
  if [ ! -f "${SETUP_LIB_DIR}/${_setup_lib}" ]; then
    echo "setup.sh: cannot find ${SETUP_LIB_DIR}/${_setup_lib} — the payload looks incomplete." >&2
    echo "          reinstall with: claude plugin install bionic@bionic" >&2
    exit 1
  fi
done
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/deps.sh"
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/detect.sh"
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/hooks.sh"
# env.sh, for the environment item below: the `env` object in the CLI's own
# settings.json is the ONE home for the names bionic sets, and setup writes it
# through env_set rather than reaching into the file itself. Doctor reads the
# same names through the same file, remove deletes them through it, and the
# roster they all walk (`ENV_KEYS`) is spelled exactly once, there.
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/env.sh"
# checks.sh, THE TABLE OF CHECKS. Every id this script offers, every predicate
# that decides whether an item is outstanding, and the party that repairs it come
# from there — and doctor reads the same rows. Until 1.5.1 the roster and the
# predicates lived here and doctor carried its own idea of what setup could fix,
# which is the disagreement the field bug report caught (a hint naming a command
# that then reported nothing to do). The words a step uses for its ACTION stay in
# this file: those are the consent screen's copy, not a fact about the machine.
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/checks.sh"
# jit.sh, for ONE function: `_jit_fix_line`, which spells the command that would
# install a row by hand. The summary needs that sentence and so does a route's
# just-in-time offer, and it has to be the SAME sentence — an action line that
# named a different command from the one a "yes" would run is a lie the user
# only discovers by pasting it. Sourcing the route contract to reuse its wording
# is cheaper than a second copy of the same derivation, which is what this
# script printed before: the raw `mechanism` field (`brew:git`), a locator the
# table stores and nobody can type.
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/jit.sh"
# width.sh, for the column budget every line below is held inside. The rule is
# doctor's (spec AC-15, 100 columns) and so is the file — one number and one
# truncator, consumed by both scripts, rather than the copy-per-script this
# wave shipped at slice 4/3 and then broke at slice 4/4.
# shellcheck source=/dev/null
. "${SETUP_LIB_DIR}/width.sh"

# ─── Constants ───────────────────────────────────────────────────────────────

# THE DEPTH THIS SCRIPT'S BLOCKS SIT AT, declared once for both files that print
# into them (six-axis review R-2). setup's own `say` lines are written three
# spaces in; deps.sh prints the install prose that lands between them, and until
# this existed it used its own two-space literal, so the seam between the two
# files was visible on the user's screen down the whole of step 4.
BIONIC_DEP_INDENT="   "

SETUP_DEP_MARKETPLACE="${BIONIC_DEP_MARKETPLACE:-bionic}"
# The default is COMPOSED rather than spelled whole, because
# `install_plugin_native` composes the id it installs the same way. A machine
# that re-points bionic's catalog moves both together; two independent defaults
# would move one of them and leave the other naming a plugin nobody installed.
#
# AND deps.sh COMPOSES IT (bionic 1.4.4 fixit phase 4, review-b B-7). This line
# used to expand `${BIONIC_PLUGIN_ID:-bionic@${SETUP_DEP_MARKETPLACE}}` itself,
# which agreed with doctor.sh's and deps.sh's copies on every input and was not
# textually either of them. `dep_plugin_id` is the one owner now; deps.sh is
# sourced at the top of this file, well above this line. `SETUP_DEP_MARKETPLACE`
# above stays — the per-dependency ids further down need the bare catalog.
SETUP_PLUGIN_ID="$(dep_plugin_id)"

# THE ENV RC BLOCK IS GONE FROM THIS FILE, deliberately. Step 5 used to append a
# `# ─── bionic:env:start/end ───` block here; it writes settings.json now (the
# rc export was measured not reaching the session it was written for, 2026-08-21),
# so this script has no marker pair of its own any more. The block a pre-W7
# machine is still carrying is remove.sh's to clean up, and remove.sh owns those
# two literals outright — a copy here would be a marker nothing writes, kept in
# step with nothing.

# The retired alias block's markers, verbatim from claude-bootstrap.sh —
# box-drawing dashes included, because they are what makes the block
# addressable. `BIONIC_LEGACY_ALIAS_PATTERN` is the pre-marker spelling the installer
# itself still migrates (claude-bootstrap.sh's do_install_shell_alias), and it
# is a separate case because a machine that stopped bootstrapping before markers
# existed has the alias with no markers around it at all.
SETUP_ALIAS_START='# ─── bionic:start ───'
SETUP_ALIAS_END='# ─── bionic:end ───'
# The spelling itself now lives in lib/checks.sh as BIONIC_LEGACY_ALIAS_PATTERN,
# because the predicate that reads it does; this file uses that one name.

# ─── Reporting ───────────────────────────────────────────────────────────────
#
# Actions accumulate in one newline-delimited string rather than an array: an
# empty array under `set -u` is an unbound variable on bash 3.2, which is the
# bash a stock macOS box runs this script with.

SETUP_ACTIONS=""
# Set by the statusline step, read by the summary. A note printed unconditionally
# would tell every user to restart over a change they did not make.
SETUP_STATUSLINE_CHANGED=no

# THE INVOCATION A PERSON CAN TYPE (critic F-1). Consent reaches this script
# through its standard input and nowhere else. The model runs it from a tool
# whose stdin carries nothing, so every question declines — and the action lines
# used to answer that by telling the user to "re-run /bionic:setup and answer y",
# which is the one route that cannot work: a second run through the same command
# declines identically, because the interactivity of the SESSION is not an answer
# channel for the SCRIPT. So an action line that asks for an answer names the
# terminal invocation, resolved to a real path rather than left as a variable the
# reader's shell has never heard of.
_setup_self_path() {
  local dir
  dir="$(cd "$(_setup_self_dir)" 2>/dev/null && pwd -P)" || dir="$(_setup_self_dir)"
  echo "${dir}/${BASH_SOURCE[0]##*/}"
}
SETUP_SELF_CMD="bash $(_setup_self_path)"

# ─── ADDRESSABLE ITEMS ───────────────────────────────────────────────────────
#
# THE PROBLEM (critic F-1 and F-2). Consent reaches this script through its own
# standard input and nowhere else. The model that runs it has nothing to put
# there, so a whole pass declines — and the one channel that DOES work, a single
# answer piped in, is POSITIONAL: it is read by the first question asked, which
# is whichever item this machine happens to have unfinished. A user who says
# "yes, set the permission mode" and has that yes relayed the obvious way gets
# whatever question came first instead. The answer channel worked; it just could
# not be aimed.
#
# THE FIX IS AN ADDRESS, NOT A SWITCH. `--only <name>` runs exactly one item —
# the one named — and asks about nothing else, so an answer delivered that way
# can only consent to the thing the user said yes to. `--list` prints the names.
#
# WHAT DID NOT CHANGE, AND MUST NOT. The answer is still one explicit `y` read
# from this script's own standard input, per item, and a closed input still
# declines. There is no assume-yes flag and no environment knob: `--only`
# narrows WHICH question gets asked, never whether it is asked. A flag that
# answered a question would be the hole in "consent per event, never silent,
# never unattended".
#
# ONE TABLE, TWO READERS. `_setup_item_ids` is the only place the roster is
# spelled. `--list` prints it and `--only` is checked against it, so a name a
# reader can see is a name the dispatcher takes, and a name it will not take is
# not printed anywhere. The rows that come from the dependency table are READ
# from it rather than restated here — a second roster is a second opinion about
# what bionic depends on, which is the defect the ownership table exists to
# prevent. It is also why `--list` names only the tools steps 3 and 4 are
# allowed to ask about: the names come from the same two classes those steps
# walk, so the flag cannot reach a row the full pass would never offer.
#
# THE NAMES ARE THE USER'S WORDS. Each one names the item as the question that
# gates it names it — `permission-mode`, `environment`, `tool:git` — never the
# function, the step number or the class behind it.

SETUP_ONLY=""

# ─── One answer over a printed plan ──────────────────────────────────────────
#
# 1 once the user has said yes to the plan `--all` printed. It is not an
# assume-yes: nothing is set here until a person has read every item the run
# would do and typed `y` at a question about that page. What it removes is the
# SECOND, third and ninth question about a decision already made — see the note
# above `_setup_print_plan` for why the plan, and not the flag, is the consent.
SETUP_ALL=0
SETUP_PLUGIN_CHANGED=no
# BOTH NAMES, NOT JUST THIS SCRIPT'S (epic-17 W7 S11, six-axis review axis 4).
# `_dep_consent` grants consent on `SETUP_ALL` OR `RM_ALL`, and every question this
# script asks goes through it. Zeroing only the name this script sets left the other
# one readable straight from the environment: `RM_ALL=1 bash setup.sh --only
# environment < /dev/null` wrote both settings keys with nobody there to ask.
# Whatever the environment carries for either name dies here, before the first
# question, so the only value this run can ever see is one this script wrote itself.
RM_ALL=0

_setup_item_ids() {
  bionic_check_items
}

# True during a whole pass, and during a narrowed run only for the item named.
# Every step below asks this before it prints its own header, so a narrowed run
# is silent about the items it is not doing rather than listing them as skipped.
_setup_wants() {  # <name>
  [ -z "$SETUP_ONLY" ] || [ "$SETUP_ONLY" = "$1" ]
}

# True when a tools step should run at all: always during a whole pass, and
# during a narrowed run only for the step that holds the named tool. Without it
# a narrowed run would print both tools headers and one of them would have
# nothing under it. The class is read from the dependency table, never guessed.
_setup_class_wanted() {  # <class>
  [ -z "$SETUP_ONLY" ] && return 0
  case "$SETUP_ONLY" in tool:*) ;; *) return 1 ;; esac
  [ "$(dep_field "${SETUP_ONLY#tool:}" class)" = "$1" ]
}

# ─── The plan `--all` prints ─────────────────────────────────────────────────
#
# WHY A PLAN AND NOT AN ASSUME-YES FLAG. Nine questions is a bad experience for
# someone who has already decided to set the whole machine up, and the obvious
# fix — a flag that answers them — is the hole in "consent per event, never
# silent, never unattended": a row added to the roster next year would then run
# on a machine whose owner never saw it named. So the whole run is made into ONE
# event instead. Every item that would be asked about is printed with what it
# changes, one line each, and the single question is asked over that page. The
# user consents to a list they can read, and nothing runs that was not on it.
#
# ONE ROSTER, READ TWICE. The plan walks `_setup_item_ids` — the same list
# `--list` prints and `--only` is checked against — and asks
# `_setup_item_pending` the same question each step asks itself before it
# prompts. A plan built from its own idea of what is outstanding would come to
# disagree with the run it is a plan FOR, which is the one defect a consent
# screen must not have.

# What one item changes, in the words the item's own question uses. Product
# words only: this lands on a person's screen, and it is the only description
# of that item they get before they answer.
_setup_item_verb() {  # <name>
  case "${1:-}" in
    plugin)             say "install the bionic plugin (claude plugin install)" ;;
    duplicate:*)        say "settle the two copies of ${1#duplicate:} installed from different catalogs" ;;
    dependency:*)       say "enable the plugin ${1#dependency:}, which is installed but switched off" ;;
    tool:*)
      # A STALE ROW IS A RE-SYNC IN THE PLAN TOO (AC-17). The page a user consents
      # from is where "not re-offered" is first visible, and "install X" over a
      # renderer already on the machine is the offer the spec rules out.
      # AND A RESTORE IS NOT AN INSTALL ON THE PAGE EITHER (REQ-S0, A-S9.5). A
      # machine whose plugin files are all still in the cache and has only lost
      # its registry entry is offered a repair, not a download — and this page is
      # the one place the user decides, so "install impeccable" there would be
      # asking consent for an act that is not the act. Asked of the dependency
      # mechanism, exactly as the stale arm below asks `check_dep`: the page must
      # never carry a second opinion about the state.
      if dep_registry_row_restorable "${1#tool:}"; then
        say "restore ${1#tool:}'s entry from the plugin cache, downloading nothing"
        return 0
      fi
      _setup_verb_present="$(check_dep "${1#tool:}" 2>/dev/null)" || _setup_verb_present=""
      _setup_verb_present="${_setup_verb_present#present=}"
      _setup_verb_present="${_setup_verb_present%%|*}"
      if [ "$_setup_verb_present" = "stale" ]; then
        say "re-sync ${1#tool:}, which is stale against the shipped lockfile"
      else
        say "install ${1#tool:}"
      fi ;;
    environment)        say "write bionic's environment settings to $(_dep_settings_file)" ;;
    claude-proxy)       say "add bionic's claude() shell function to $(rc_file 2>/dev/null || echo 'the shell rc')" ;;
    legacy-alias)       say "remove the retired shell alias block from $(_detect_shell_rc)" ;;
    legacy-hooks)       say "remove the retired hook entries from $(_dep_settings_file)" ;;
    legacy-skill-copy)  say "remove the pre-plugin skill copy at $(_setup_legacy_skill_dir)" ;;
    legacy-hook-files)
      _setup_verb_line="$(detect_legacy_hook_files)"
      _setup_verb_count="${_setup_verb_line#*count=}"; _setup_verb_count="${_setup_verb_count%% *}"
      _setup_verb_dir="${_setup_verb_line#*path=}";    _setup_verb_dir="${_setup_verb_dir%% *}"
      say "remove ${_setup_verb_count} pre-plugin hook file(s) from ${_setup_verb_dir}" ;;
    legacy-agent-copies)
      _setup_verb_line="$(detect_installed_agent_copies)"
      _setup_verb_count="${_setup_verb_line#*drift=}"; _setup_verb_count="${_setup_verb_count%% *}"
      say "remove ${_setup_verb_count} installed agent role file(s) that no longer match the payload, from $(_setup_agent_copies_dir)" ;;
    legacy-permission-block) say "remove bionic's retired permission block from $(_dep_settings_file)" ;;
    permission-mode)    say "set Claude Code's default permission mode to ${BIONIC_DEFAULT_PERMISSION_MODE}" ;;
    *)                  return 1 ;;
  esac
  return 0
}

# The directory steps 11 names. `detect_installed_agent_copies` reports state, counts and
# names but no path — doctor's row does not print one — so the one place that already owns
# "where is the claude-home" answers it, rather than a fourth copy of the env-var chain.
_setup_agent_copies_dir() {
  printf '%s/agents' "$(_dep_claude_home)"
}

# The one directory step 9 offers to remove, read from the fact function that
# owns it so the plan names the path the step will name.
_setup_legacy_skill_dir() {
  local line
  line="$(detect_legacy_skill_copy)"
  printf '%s' "${line##*path=}"
}

# Whether this item would ask a question on this machine — the predicate each
# step below runs before it prints anything, asked from the outside so the plan
# and the run cannot come to differ about what is outstanding. Read-only: every
# branch here is a file test or a listing, never a change.
_setup_item_pending() {  # <name> -> 0 when the item has something to ask about
  bionic_check_item_pending "${1:-}"
}

# The whole page. Non-zero means there was nothing to print, which is a machine
# with nothing left to set up rather than an error.
_setup_print_plan() {
  local id verb prefix lines=""
  prefix="  • "
  # fd 3: the standard input belongs to the question this page is printed for.
  while IFS= read -r id <&3; do
    [ -n "$id" ] || continue
    _setup_item_pending "$id" || continue
    verb="$(_setup_item_verb "$id")" || continue
    lines="${lines}$(bionic_line "$prefix" "$verb")"$'\n'
  done 3< <(_setup_item_ids)
  [ -n "$lines" ] || return 1
  say "bionic would:"
  printf '%s' "$lines"
  say ""
  return 0
}

# ONE OWNER FOR THE SENTENCE THAT TELLS SOMEONE HOW TO SAY YES. Every declined
# item ends up quoting this, and it must name a route that works: the item's own
# name, and an invocation that delivers one answer to that one question. Written
# once here so an action line and the summary cannot come to differ about what
# the user should run — the same reason the install prose has one owner.
SETUP_YES_PIPE="printf 'y\\n' | "

_setup_answer_yes() {  # <name>
  printf 'answer yes to %s with: %s%s --only %s' "$1" "$SETUP_YES_PIPE" "$SETUP_SELF_CMD" "$1"
}

say()    { printf '%s\n' "$*"; }
# ONE LINE PER ITEM, WITH A SYMBOL IN COLUMN ONE (spec AC-15, approved
# 2026-08-22). Every step below reports what it did, skipped or asked about
# through this one function, so a row added by a future arm inherits the format
# without knowing it exists. ✓ done or already true · ✗ could not · – skipped,
# declined or nothing to do. All three glyphs are three bytes, so the label
# column stays straight; padding the SYMBOL would not be safe, because printf
# pads to a byte count.
SETUP_OK='✓'
SETUP_BAD='✗'
SETUP_NIL='–'
# THE FOURTH STATE, AND IT IS NOT A FAILURE. Where the stream cannot carry an
# answer, setup prints the question and moves on rather than blocking on a reply
# nobody is going to send. That item was neither done nor declined — it is
# OUTSTANDING, and the person relaying this output is the one who can settle it.
# Rendering that as `–` alongside the items a user actively said no to would
# lose the only distinction that matters here: one of them is a decision and the
# other is a decision still waiting to be made.
SETUP_ASK='?'

# THE COLUMN BUDGET IS NOT THIS FILE'S (epic-19 AC-F4, grounding §4(a); moved
# out at S9). item()'s third field and the --all plan's verb lines both
# interpolate absolute paths — settings.json, a shell rc, the legacy skill
# directory — with no bound, and none of them wrap cleanly inside the command
# relay's fenced block. The rule they answer to is doctor's: spec AC-15 holds
# every line doctor prints to 100 columns, and this script has the identical
# reason to.
#
# SO THE NUMBER AND THE TRUNCATOR LIVE IN lib/width.sh, sourced above, and both
# scripts consume them. Slice 4/3 built this budget for setup.sh alone and slice
# 4/4 then broke it in doctor.sh in the same wave — the same number written
# twice in two files with nothing binding them, which is what the Step-6 review
# called out and what one owner ends. `bionic_line` is where the prefix-aware
# arithmetic lives now; nothing about the shape below changed except who owns it.

item() { printf '%s\n' "$(bionic_line "$(printf '   %s %-22s ' "$1" "$2")" "${3:-}")"; }
action() { SETUP_ACTIONS="${SETUP_ACTIONS}${1}"$'\n'; }
# deps.sh owns the one prompt shape — and the one short-circuit, because
# `install_dep` and `install_plugin_native` ask through it directly and a
# wrapper here could only cover the gates this file spells itself.
consent() { _dep_consent "$1"; }

# AC-12: `consent`'s non-zero used to mean one thing everywhere it was checked
# — an explicit no — so every gate below printed the identical "declined —"
# sentence whether a person typed n or a non-interactive first pass hit EOF on
# the very first question. `_dep_consent` now tells the two apart (2 vs 1);
# this is the one place each gate turns that code into the right leading word,
# keeping its own tail sentence unchanged either way. Call with the consent
# call's own `$?` as the first argument, captured before anything else runs.
_setup_say_declined() {  # <rc> <tail sentence, already worded for "declined —">
  local rc="$1" tail="$2"
  if [ "$rc" = "2" ]; then
    say "   ${SETUP_ASK} not asked — ${tail}"
  else
    say "   ${SETUP_NIL} declined — ${tail}"
  fi
}

# ─── rc block surgery ────────────────────────────────────────────────────────
#
# Ported from claude-reset.sh's alias removal, with one deliberate difference:
# reset deletes the rc file when only whitespace is left, and this script must
# not — step 4 writes to the same file, and a setup that can delete a user's
# shell rc is a setup nobody should run.

# THE MODE TRAVELS WITH THE CONTENT (critic F2). Both rc rewriters in this script
# stage the new file beside the old one and `mv` it into place, and `mv` replaces
# the inode: without this, a shell rc the user deliberately kept at 0600 comes
# back at whatever the umask says, because setup answered one question about a
# retired alias block. That is the same defect `_dep_settings_write_jq` guards for
# settings.json (see lib/env.sh's header), and an rc is if anything the likelier
# of the two to hold plaintext tokens — it is where people put `export …_API_KEY=`.
#
# TWO HARMS, NOT ONE, WHICH IS WHY THE ORDER MATTERS. Repairing the mode after the
# rename fixes the published file and still leaves the staged copy — the whole rc,
# secrets included, under a predictable name — at the umask's mode for the span
# before it, and makes the widening PERMANENT if the process dies in that window.
# So the tmp is CREATED under `umask 077` and chmodded to the original's mode
# BEFORE a single line is written into it — remove.sh's `_rm_stage_tmp` order,
# spelled the same way here so the two doors cannot drift again. An absent `stat`
# degrades to "write, don't chmod" rather than to a refusal to write at all.
#
# AND IT IS THE TARGET, NOT THE LINK — THE FILE AS WELL AS ITS MODE (critic delta
# D1, then delta 2 N1). A `~/.zshrc` symlinked into a dotfiles repo is the
# commonest way people manage an rc. A bare `stat` on a symlink reports the LINK's
# own mode — 755 — never the file's, so capturing that and handing it to `chmod`
# publishes the rc as `rwxr-xr-x`; `-L` is what makes the capture mean the file.
# But the RENAME had the mirror-image bug: `mv` replaces the link with a regular
# file, so setup wrote a detached copy at the link's path and left the dotfiles
# repo holding the block it had just reported removing — one `stow` from being
# back. `bionic_link_target` (lib/deps.sh) resolves the chain first and the write
# lands on the target, so the link survives and the managed file is what changes.
#
# `-L` ALONE STILL LIES ABOUT ONE INPUT (delta 2 N4): on a DANGLING link BSD
# `stat -L` falls back to the link and exits 0, reporting 755. `[ -e ]` turns that
# into the empty "unknowable" answer the callers already handle.
_setup_file_mode() {  # <file> — the mode of what <file> RESOLVES to, empty if unknowable
  local mode
  mode="$(stat -L -f '%Lp' "$1" 2>/dev/null || stat -L -c '%a' "$1" 2>/dev/null)"
  [ -e "$1" ] || mode=""
  printf '%s' "$mode"
}

# ONE STAGING ORDER, AND THE CHMOD IS AT THE END OF IT (critic delta 2 N5).
# Create the tmp under `umask 077`, let the caller write the content into it, and
# only then widen it to the target's mode and rename. Measured, that keeps the
# staged copy at 0600 for the whole span in which it holds the user's rc — the
# span that matters, because that is when the tmp is worth reading — and gives it
# the target's mode at the instant of publication and not one moment sooner. The
# order S13 shipped (chmod, THEN write) had the tmp already wearing a 0644 rc's
# mode while the rc's own contents, tokens and all, were being written into it,
# which is what the header above says the order exists to prevent. remove.sh's
# `_rm_stage_tmp`/`_rm_publish_tmp` carry the same pair, spelled the same way, so
# the two doors cannot drift again.
#
# A tmp left by an earlier interrupted run is REMOVED rather than truncated: `>`
# on an existing file keeps that file's mode, so truncating one would carry a
# stale width through the window `umask 077` exists to close.
_setup_stage_tmp() {  # <tmp> — created empty at 0600; the caller writes, then publishes
  local tmp="$1"
  rm -f "$tmp"
  (umask 077; : > "$tmp") || return 1
  return 0
}

# The other half: widen <tmp> to <file>'s mode and rename it over <file>. <file>
# is the RESOLVED target, so its mode is still readable here — the rename is what
# replaces it.
_setup_publish_tmp() {  # <tmp> <file>
  local tmp="$1" file="$2" mode
  mode="$(_setup_file_mode "$file")"
  [ -n "$mode" ] && chmod "$mode" "$tmp"
  mv "$tmp" "$file"
}

_setup_rc_strip_block() {  # <file> <start-marker> <end-marker>
  local file="${1:-}" start="${2:-}" end="${3:-}" tmp target
  [ -f "$file" ] || return 0
  grep -qF "$start" "$file" 2>/dev/null || return 0
  target="$(bionic_link_target "$file")"
  tmp="${target}.bionic.tmp"
  if _setup_stage_tmp "$tmp" \
     && awk -v start="$start" -v end="$end" '
        $0 == start { skip=1; next }
        $0 == end   { skip=0; next }
        !skip { print }
      ' "$file" > "$tmp" \
     && _setup_publish_tmp "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# ─── Step 1 — the native plugin install (tier 2 ⊃ tier 1) ────────────────────

setup_plugin_install() {
  _setup_wants plugin || return 0
  say ""
  say "1. Plugin"
  local state id
  IFS='|' read -r state id <<< "$(bionic_cli_plugin_state bionic)"

  case "$state" in
    enabled|disabled)
      item "$SETUP_OK" "plugin" "already installed (${id}) — nothing to do"
      return 0 ;;
    unknown)
      item "$SETUP_NIL" "plugin" "install state unknown — the claude CLI or jq could not read it"
      action "install jq (and make sure the claude CLI is on PATH), then re-run /bionic:setup — the plugin install state read as unknown"
      return 0 ;;
  esac

  # THE QUESTION AND THE INSTALL BOTH BELONG TO deps.sh NOW (wave-06 S5). This
  # step used to carry its own copy of "name the command, ask, run it", which was
  # fine while it was the only place a plugin got installed — and stopped being
  # fine the moment a just-in-time offer needed the same three lines for a
  # when-needed native row and had nothing to call. There is one such function
  # and both callers reach it, so what a user is asked here and what a route asks
  # mid-session cannot drift into two different conversations.
  if ! install_plugin_native bionic; then
    action "run: claude plugin install ${SETUP_PLUGIN_ID} --scope user --yes (add bionic's marketplace first if it is not registered) — $(_setup_answer_yes plugin)"
  fi
  return 0
}

# ─── After step 1 — is the CLI actually LOADING us? (AC-13, setup half) ──────
#
# THE FACT THE INSTALL'S OWN EXIT CODE CANNOT GIVE. Epic-17 W5 measured it four
# times: `claude plugin install` exits 0, prints a success line and writes the
# registry, and if a dependency is missing the plugin then loads NOTHING — no
# hook, no command, no error anywhere a user would look. Every registry-reading
# check on this machine stays green through it. So the step that installs is
# followed by the one question the install cannot answer itself, asked of the
# only surface that knows: the CLI's own listing.
#
# This prints at the install step's indentation and carries no header of its own,
# because it is not another thing setup DOES — it is what step 1 amounts to.
#
# FOUR STATES, FOUR SENTENCES, and the two that are not good news carry the fix.
# `unknown` renders its cause verbatim: the probe names why it could not look
# (A-4.S2.4), and an unknown with no reason is a shrug the user cannot act on.

#
# BOUNDED, BECAUSE THIS ONE SHELLS OUT (critic F-3). Every other fact step 1
# reads is a file; this one runs the CLI's own listing, and a CLI mid-update or
# a listing waiting on a lock never answers. Unbounded it hung setup here —
# after the install, with the report half-printed, where a user cannot tell a
# wedge from a crash. `detect_bounded` is the same bound doctor uses, from the
# same owner; a timeout arrives as the `unknown` state with the wait named as
# its cause, which is the shape the four-state case below already handles.
setup_load_state() {
  # Not an item: it asks nothing and changes nothing. It is what step 1 amounts
  # to, so it belongs to the whole pass and not to a narrowed one.
  [ -z "$SETUP_ONLY" ] || return 0
  local line state err cause rc
  line="$(detect_bounded "$(detect_probe_seconds)" detect_plugin_load_state "$SETUP_PLUGIN_ID")"
  rc=$?
  if [ "$rc" = "124" ] || [ -z "$line" ]; then
    line="load-state=unknown error=- cause=the plugin listing did not answer within $(detect_probe_seconds) seconds"
  fi
  state="${line#load-state=}"; state="${state%% *}"
  err="${line#*error=}";       err="${err%% cause=*}"
  case "$line" in *cause=*) cause="${line#*cause=}" ;; *) cause="" ;; esac

  case "$state" in
    loaded)
      item "$SETUP_OK" "load state" "loaded"
      ;;
    failed)
      # A real error, so it is reported the way the contract requires: the CLI's
      # own words first, unedited, then one line naming what to do about them.
      #
      # THE FOURTH RENDERER OF ONE ROUTE (bionic 1.4.4 fixit, phase 2). This line
      # used to spell the repair by hand — "reinstall bionic with: claude plugin
      # install <id> --scope user --yes" — which is the wording A-1 refutes:
      # bionic is installed and registered, and a dependency is missing. The verb
      # coincides, the description does not — which is why the object of the verb
      # is the dependencies and never bionic (phase 4, review-c C-3: "reinstall"
      # reads plainer than the "re-resolve" this line carried between, and the
      # object was always the point). It comes from deps.sh now, like the
      # three renderers beside it, so a machine that re-points bionic's catalog
      # moves all four together. What did NOT change is the order: the CLI's own
      # error is still printed first and unedited, and this is still one line
      # under it. Pinned by tests/fresh-home.test.sh Group 14.
      say "   bionic is installed but did not load. The CLI reports:"
      say "   ${err}"
      say "   Fix: install what the message names, then start a new session — or reinstall bionic's dependencies: $(dep_core_repair_route)"
      action "bionic did not load: ${err}"
      ;;
    absent)
      # Step 1 already owns the install and its action line; saying so twice
      # would make one problem look like two.
      item "$SETUP_NIL" "load state" "not in the plugin list, so nothing is loaded here yet"
      ;;
    *)
      item "$SETUP_NIL" "load state" "unknown — ${cause}"
      action "check that bionic is loading: run claude plugin list and read the Status line for bionic"
      ;;
  esac
  return 0
}

# ─── After the load state — two catalogs, one name (AC-8) ────────────────────
#
# WHY THIS COMES BEFORE ANYTHING IS INSTALLED. A machine can hold
# `superpowers@bionic` and `superpowers@claude-plugins-official` at once, and
# nothing tells the user which one a session loads. Installing more things beside
# an unsettled duplicate just adds to the pile, so the question is asked here —
# after the plugin is in place and before the dependency steps run.
#
# SILENT WHEN THERE IS NOTHING TO SAY. No duplicate means no header, no question,
# no line: on the machines this will mostly run on, this step does not exist.
# That is also why it carries no step NUMBER — a numbered step absent from most
# transcripts leaves a hole in the sequence, and the numbers belong to the nine
# things setup does every time.
#
# THE THREE ANSWERS, AND WHY THE PROMPT IS deps.sh's ONE SHAPE. Chris named
# consolidate / coexist / skip. Setup persists no state of its own, so coexist
# and skip leave the machine in the identical condition and are asked again on
# the next run — two names for one outcome. Rather than invent a second prompt
# mechanism to tell them apart, all three answers are named in the prose and the
# gate is the same `[y/N]` every other question here uses: yes consolidates, no
# leaves both installed and says so.
#
# `dup=unknown` IS NOT A DUPLICATE. It is the probe reporting that it could not
# read the registry, and there is nothing to consolidate — so nothing is offered.
# It is not silence either: silence is the claim "no duplicates", which a reader
# that could not look has not earned.

# The ids to uninstall, one per line, derived from the probe's own fix clause and
# only when every piece of it is exactly `claude plugin uninstall <id>`. This is
# what keeps the consented plan and the executed command the same text without
# ever handing a composed string to a shell: an id is a registry key, and a
# registry key is not something this script gets to trust into `eval`. Anything
# else — notably the "choose one: …" clause the probe returns when bionic has no
# standing to pick a winner — fails the shape test and is reported, not run.
_setup_dup_uninstall_ids() {  # <fix-clause>
  local fix="${1:-}" piece id out=""
  [ -n "$fix" ] || return 1
  while IFS= read -r piece; do
    [ -n "$piece" ] || continue
    case "$piece" in
      "claude plugin uninstall "*) id="${piece#claude plugin uninstall }" ;;
      *) return 1 ;;
    esac
    case "$id" in
      ''|*[!A-Za-z0-9@._-]*) return 1 ;;
    esac
    out="${out}${id}
"
  done <<< "${fix//; /$'\n'}"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

setup_duplicates() {
  case "$SETUP_ONLY" in ''|duplicate:*) ;; *) return 0 ;; esac
  local line bare ids fix cause header=0 id losers
  # fd 3, not stdin — the consent prompt below reads stdin, and a loop that fed
  # its own list into it would answer every question with the next duplicate.
  while IFS= read -r line <&3; do
    [ -n "$line" ] || continue
    bare="${line#dup=}"; bare="${bare%% *}"
    ids="${line#*ids=}"; ids="${ids%% *}"
    fix="${line#*fix=}"; fix="${fix%% cause=*}"
    case "$line" in *cause=*) cause="${line#*cause=}" ;; *) cause="" ;; esac
    _setup_wants "duplicate:${bare}" || continue

    if [ "$header" = "0" ]; then say ""; say "Duplicates"; header=1; fi

    if [ "$bare" = "unknown" ]; then
      # THE ACTION CARRIES THE CAUSE, it does not guess it (W6 S15, A-6.S15.3). This line
      # used to say "install jq", which was the only way the read could fail when it was
      # written. The read is bounded now, so a stalled registry is a second cause — and
      # telling that user to install a tool they already have is worse than saying nothing.
      item "$SETUP_NIL" "duplicates" "could not check — ${cause}"
      action "duplicate copies were not checked for — ${cause}; /bionic:doctor lists them once bionic can read the plugin registry"
      continue
    fi

    say "   ${bare} is installed twice (${ids}) — a session loads one, and you did not choose which."
    if ! losers="$(_setup_dup_uninstall_ids "$fix")"; then
      # Both copies are somebody else's catalog: bionic has no standing to pick
      # a winner, so it names the choice and does not offer to make it.
      say "   ${fix}"
      action "settle the duplicate copies of ${bare}: ${fix}"
      continue
    fi
    say "   bionic would run: ${fix}   (no lets them coexist; bionic asks again next run)"
    consent "   Consolidate — remove the copy bionic did not install?"; _setup_consent_rc=$?
    if [ "$_setup_consent_rc" -ne 0 ]; then
      _setup_say_declined "$_setup_consent_rc" "left as they are."
      action "settle the duplicate copies of ${bare}: ${fix} — $(_setup_answer_yes "duplicate:${bare}")"
      continue
    fi
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if claude plugin uninstall "$id"; then
        item "$SETUP_OK" "duplicate" "removed ${id}"
      else
        item "$SETUP_BAD" "duplicate" "${id} could not be removed"
        action "remove the duplicate copy by hand: claude plugin uninstall ${id}"
      fi
    done <<< "$losers"
  done 3< <(bionic_check_duplicate_lines)
  return 0
}

# ─── Step 2 — the core dependencies: present AND enabled ─────────────────────
#
# The harness installs these; the measured failure mode is that it can leave one
# `enabled: false`, which looks installed to every check that only counts rows.
# Repair is an explicit enable — never a reinstall, which would be the second
# installer the native install mechanism exists to avoid.

setup_dep_enable_verify() {
  case "$SETUP_ONLY" in ''|dependency:*) ;; *) return 0 ;; esac
  say ""
  say "2. Dependencies"
  local name line present state id
  # The list is read on fd 3, NEVER on stdin. A `while read ... done < <(list)`
  # loop redirects the BODY's stdin too, so the consent prompt inside it would
  # read the next dependency NAME as the user's answer and decline every item
  # while consuming the rest of the list.
  while IFS= read -r name <&3; do
    [ -n "$name" ] || continue
    _setup_wants "dependency:${name}" || continue
    line="$(detect_dep "$name")" || continue
    present="${line#*present=}"; present="${present%% *}"
    IFS='|' read -r state id <<< "$(bionic_cli_plugin_state "$name")"
    [ -n "$id" ] || id="${name}@${SETUP_DEP_MARKETPLACE}"

    case "$state" in
      enabled)
        item "$SETUP_OK" "$name" "installed and enabled"
        ;;
      disabled)
        item "$SETUP_BAD" "$name" "installed but DISABLED — bionic would run: claude plugin enable ${id}"
        consent "   Enable ${name} now?"; _setup_consent_rc=$?
        if [ "$_setup_consent_rc" -ne 0 ]; then
          _setup_say_declined "$_setup_consent_rc" "${name} stays disabled."
          action "run: claude plugin enable ${id} — $(_setup_answer_yes "dependency:${name}")"
        elif claude plugin enable "$id"; then
          item "$SETUP_OK" "$name" "enabled"
        else
          action "run: claude plugin enable ${id}"
        fi
        ;;
      absent)
        # TEXT ONLY, AND THE TEXT COMES FROM deps.sh (bionic 1.4.4 fixit, A-2).
        # This arm installs nothing and never has — D1 rules that setup is not a
        # second installer for a native row — so what it owes the reader is an
        # accurate sentence, and the one it carried was not: a bare "reinstall
        # bionic" says bionic is broken when bionic is installed and registered
        # and a dependency is missing. The verb was never the problem — it is the
        # verb the CLI actually takes — so what this line fixes is the OBJECT,
        # which is the dependencies. It is the same route doctor's THIRD PARTY row, doctor's
        # headline and step 1's load-failure Fix line render, from the same
        # function, so the four surfaces cannot drift.
        item "$SETUP_BAD" "$name" "not installed — it shipped with bionic, so this install is incomplete"
        action "reinstall bionic's dependencies: $(dep_core_repair_route) (${name} is missing)"
        ;;
      *)
        item "$SETUP_NIL" "$name" "enabled-state unknown — the claude CLI or jq could not read it"
        action "install jq, then re-run /bionic:setup — ${name}'s enabled-state read as unknown"
        ;;
    esac
  done 3< <(dep_names_class core)
  return 0
}

# ─── Steps 3 and 4 — one row at a time, through the one installer ────────────
#
# ONE BODY, TWO STEPS. The basics and the extras differ in what the user is told
# before the question, not in what the question does: both consent per item,
# both mutate through `install_dep`, both accept "no" as a complete answer. So
# the walk is one function taking a class, and the difference is one line of
# prose printed ahead of each extra.
#
# `unknown` presence gets an OFFER, not a skip. Some mechanisms genuinely have
# no presence surface to read (the pnpm store is a cache, not an install; the
# statusline lives in a settings file jq may not be there to parse), and the
# installer these steps replaced re-warmed those unconditionally — skipping them
# would quietly drop coverage the old installer had. The offer is consented like
# every other, and the unknown is named in the same breath so the user is
# deciding with the real state in front of them.

# WHICH INSTALLER A ROW GOES TO, and why this branch exists here as well as in
# jit.sh. `install_dep` REFUSES every native row by design — installing a plugin
# is the CLI's own act — so a loop that hands one to it prints a library's
# refusal at a user who did nothing wrong. Until epic-18 T4 no native row was
# ever offered by setup (impeccable is when-needed, and jit.sh carried the only
# branch); `document-skills` and `example-skills` are native AND `extra`, so this
# step needs the same two-line routing. It is deliberately not folded into
# `install_dep`: the two installers differ in who runs the install and what the
# result is in this session, and merging them is the kludge the ownership table
# exists to prevent. Callers choose their entry point; there are now two callers.
_setup_install_one() {  # <name>
  if [ "$(dep_field "$1" kind)" = "native" ]; then
    install_plugin_native "$1"
  else
    install_dep "$1"
  fi
}

_setup_install_class() {  # <class>
  local name raw present _setup_prev_all
  # fd 3, not stdin — see the note in setup_dep_enable_verify. install_dep
  # prompts, so this loop must leave stdin alone.
  while IFS= read -r name <&3; do
    [ -n "$name" ] || continue
    _setup_wants "tool:${name}" || continue
    raw="$(check_dep "$name")" || continue
    present="${raw#present=}"; present="${present%%|*}"
    # ONE LINE PER ITEM (Chris 2026-08-22: "Step 4 is very difficult to read").
    # The why-sentence is the question's context, so it prints only where a
    # question is live — the per-item pass. Under --all the page already carried
    # it and the item reports its result in one line.
    [ "$present" != "yes" ] && [ "$(dep_field "$name" class)" = "extra" ] && [ "$SETUP_ALL" != "1" ] \
      && say "   ${name} — $(_setup_extra_why "$name")"
    case "$present" in
      yes)
        item "$SETUP_OK" "$name" "present"
        ;;
      stale)
        # RE-SYNCED, NOT RE-OFFERED (AC-17). A venv built against a different
        # `uv.lock` than the one now shipped is a machine that plainly HAS the
        # renderer, one lockfile behind. Asking "install it now?" over that is the
        # question the spec forbids: the user already said yes to this item, and
        # what is owed them is the repair, not the offer again.
        #
        # SETUP_ALL IS RAISED AND PUT BACK, because it is the flag `install_dep`
        # reads to skip its consent call, and this arm is the one place in the
        # per-item pass that legitimately does not ask. Saved and restored by hand
        # rather than set as a command prefix: in bash a prefix assignment on a
        # FUNCTION call does not reliably unset afterwards, and a SETUP_ALL left
        # raised would answer yes to every remaining row in this loop.
        item "$SETUP_NIL" "$name" "stale against the shipped uv.lock — re-syncing"
        _setup_prev_all="$SETUP_ALL"
        SETUP_ALL=1
        if _setup_install_one "$name"; then
          SETUP_ALL="$_setup_prev_all"
          item "$SETUP_OK" "$name" "re-synced"
        else
          SETUP_ALL="$_setup_prev_all"
          action "re-sync ${name} by hand: $(_jit_fix_line "$name")"
        fi
        ;;
      unknown)
        [ "$SETUP_ALL" = "1" ] || item "$SETUP_NIL" "$name" "presence unknown — bionic cannot read whether this one is here"
        if _setup_install_one "$name"; then
          [ "$SETUP_ALL" = "1" ] && item "$SETUP_OK" "$name" "installed — $(_setup_extra_why "$name")"
        else
          action "install ${name} by hand: $(_jit_fix_line "$name") — bionic could not confirm whether it is already there; $(_setup_answer_yes "tool:${name}")"
        fi
        ;;
      *)
        if _setup_install_one "$name"; then
          [ "$SETUP_ALL" = "1" ] && item "$SETUP_OK" "$name" "installed — $(_setup_extra_why "$name")"
          # THE ONE ITEM WHOSE RESULT THIS SESSION CANNOT SHOW. Everything else
          # setup installs is on PATH the moment it lands. The statusline is a
          # key in settings.json that the CLI read when it started, so a user who
          # just said yes looks at the bottom of their terminal, sees nothing
          # different, and reasonably concludes it did not work.
          [ "$(dep_field "$name" kind)" = "statusline" ] && SETUP_STATUSLINE_CHANGED=yes
        else
          action "install ${name} by hand: $(_jit_fix_line "$name") — $(_setup_answer_yes "tool:${name}")"
        fi
        ;;
    esac
  done 3< <(dep_names_class "$1")
  return 0
}

# WHAT AN EXTRA IS, IN ONE SENTENCE. D-B's rule for this class is "asked once,
# default No, one line of why each", and the why is the only part the dependency
# table cannot supply: `consumer` answers which route needs a tool, and the
# whole point of an extra is that no route does. So the sentences live here,
# beside the step that prints them, rather than as an eighth column nothing else
# would read. A row with no sentence says so plainly instead of printing an
# empty dash — the table is the roster, and this function must never become a
# second one that can silently disagree with it.
_setup_extra_why() {  # <name>
  case "${1:-}" in
    ccstatusline)    echo "a status line in Claude Code showing the model, context use and session cost." ;;
    notebooklm)      echo "a command-line client for Google NotebookLM, for research passes over sources." ;;
    context7)        echo "up-to-date documentation for libraries, fetched on demand inside a session." ;;
    '@pencil.dev/cli') echo "the Pencil design tool's command line, for turning design files into code." ;;
    # The four rows the 2026-08-22 ruling promoted out of when-needed. Each one
    # names the work it unblocks, because that is what a user is deciding about
    # — a package name tells them nothing about which run stops without it.
    '@playwright/cli') echo "the browser driver bionic's verification route uses; without it, browser checks are skipped rather than run." ;;
    chrome-devtools) echo "the deep-inspection browser server (Lighthouse, traces, profiling) the verification route escalates to." ;;
    playwright-chromium) echo "the headless Chromium build the diagram renderer drives; without it, diagrams cannot be rendered." ;;
    motion)          echo "an animation library pre-warmed into the pnpm store so design work does not stop to fetch it." ;;
    impeccable)      echo "the design skill pack every UI route uses; without it, design work runs on defaults." ;;
    excalidraw-renderer) echo "the synced uv project that renders excalidraw diagrams to PNG, kept at a stable machine-local path that survives a plugin update; without it, diagrams cannot be rendered." ;;
    humanizer)       echo "a skill that rewrites text so it stops reading as though a model wrote it." ;;
    document-skills) echo "skills for reading and writing Word, Excel, PowerPoint and PDF files." ;;
    example-skills)  echo "Anthropic's own example skills — art, canvas design, brand guidelines and more." ;;
    *)               echo "an optional extra; bionic ships no description for it." ;;
  esac
}

setup_tools_loop() {
  _setup_class_wanted basic || return 0
  say ""
  say "3. Tools"
  _setup_install_class basic
}

setup_extras_loop() {
  _setup_class_wanted extra || return 0
  say ""
  say "4. Workflow tools"
  [ "$SETUP_ALL" = "1" ] || say "   Each is offered once with a line of what it is; the answer is No unless you say yes."
  _setup_install_class extra
}

# ─── Step 5 — bionic's environment settings ──────────────────────────────────
#
# ONE HOME, AND WHY IT MOVED. This step used to append `export
# CLAUDE_CODE_ENABLE_TODO_TOOLS=1` to the user's shell rc inside a marker block.
# On 2026-08-21 that export was measured NOT REACHING the session it was written
# for: the host that launches the CLI runs its shell with rc files disabled, so
# the value was on disk, absent from the process, and nothing bionic printed
# could tell those apart. settings.json is read by the CLI itself however the
# session was started — it is the one home that reaches every session. This step
# no longer writes to a shell rc at all; the block a pre-W7 machine is carrying
# is footprint /bionic:remove cleans up.
#
# ONE QUESTION FOR THE WHOLE SET. The names are one decision — "let bionic
# configure the environment it needs" — not one decision per name, and asking
# twice for one decision is how a user ends up half-configured. What gets
# written is stated before the question, so the single answer is still an
# informed one.
#
# THE ROSTER IS ENV.SH'S. This function loops `ENV_KEYS` and asks `env_default`
# for each value; a third name added there arrives here with no edit. It reads
# what is already configured through `env_get`, so a machine that has both
# already is told there is nothing to do rather than being asked to re-consent
# to a write that would change no bytes.

setup_environment() {
  _setup_wants environment || return 0
  say ""
  say "5. Environment"
  local settings key want have missing="" wrote=0
  settings="$(_dep_settings_file)"

  for key in $ENV_KEYS; do
    want="$(env_default "$key")" || continue
    have="$(env_get "$key" 2>/dev/null)" || have=""
    [ "$have" = "$want" ] && continue
    missing="${missing}${missing:+ }${key}"
  done

  # ONE LINE, ON PURPOSE. Both gates below are single lines carrying a named
  # tag, because tests/setup.test.sh used to prove each is load-bearing by DELETING its
  # line from a copy of this file and re-running: a gate spread over an if/fi
  # pair cannot be deleted that way without breaking the copy's syntax, and a
  # mutation that turns the script into a parse error proves nothing. That suite
  # was deleted at 8582861 (epic-18 wave-03) and nothing replaced the mutation proof.
  [ -n "$missing" ] || { item "$SETUP_OK" "environment" "already written to ${settings} — nothing to do"; return 0; }  # idempotence guard: settings env

  say "   ${settings} does not carry all of bionic's environment settings:"
  for key in $missing; do
    say "   ${key}=$(env_default "$key") — $(_setup_env_why "$key")"
  done
  consent "   Write bionic's environment settings to ${settings}?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then _setup_say_declined "$_setup_consent_rc" "${settings} is unchanged."; action "write bionic's environment settings to ${settings} — $(_setup_answer_yes environment)"; return 0; fi  # consent gate: settings env

  for key in $missing; do
    if env_set "$key" "$(env_default "$key")"; then
      wrote=$((wrote + 1))
    else
      item "$SETUP_BAD" "environment" "could not write ${settings}"
      action "write bionic's environment settings to ${settings} (bionic could not write the file)"
      return 0
    fi
  done
  # A value written now reaches the NEXT session and not this one — the same
  # gap doctor reports as "live in this session: no". Saying so here is what
  # stops a user re-running setup to fix something already fixed, and it rides
  # on the result line rather than under it.
  item "$SETUP_OK" "environment" "set — takes effect in a new session"
  return 0
}

# What each name is for, in the words the user reads. Kept beside the step
# rather than in env.sh: env.sh owns the VALUES, this file owns the prose that
# lands on a person's screen, and the vocabulary wall reads only this side.
_setup_env_why() {  # <key>
  case "${1:-}" in
    CLAUDE_CODE_ENABLE_TODO_TOOLS)        echo "the task list a plan's steps are tracked in" ;;
    BASH_MAX_TIMEOUT_MS)                  echo "how long a command may run before it is taken away from whoever started it" ;;
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS) echo "the channel a dispatched agent reports back through" ;;
    *)                                    echo "a setting bionic needs" ;;
  esac
}

# ─── Step 6 — the claude() shell function ────────────────────────────────────
#
# THE ONE THING settings.json CANNOT HOLD. Every name step 5 writes is a value in
# a JSON object the CLI reads for itself. This is a LINE OF SHELL — `claude` has
# to become a function in the user's own interactive shell, or the flag never
# reaches the command they type — and the rc file is the only place that can
# happen. The channel was retired for exports at W7 because they did not reach
# the session; it comes back here for the one thing only it can carry.
#
# ASKED, AND ASKED WITH ITS REASON. A flag that lets a session skip permission
# prompts is a decision about how someone's own machine behaves, so it is offered
# with one line of what it does and written only on an explicit yes. Declining
# writes nothing at all — not an empty block, not a commented line.
#
# THE ROSTER AND THE WRITE ARE ENV.SH'S. This step loops `RC_ITEMS`, asks
# `rc_default` for the line and `rc_get` whether it is already there, and writes
# through `rc_set`. A second item added to that roster arrives here with no edit,
# and nothing in this file matches the rc itself.

setup_claude_proxy() {
  _setup_wants claude-proxy || return 0
  say ""
  say "6. Shell function"
  local rc item_name missing="" wrote=0

  # A shell bionic has no rc name for is reported, never guessed at: writing a
  # bash function into a fish rc would break the shell it was meant to help.
  if ! rc="$(rc_file 2>/dev/null)"; then
    item "$SETUP_NIL" "claude() function" "${SHELL:-the shell} is not one bionic writes an rc for"
    return 0
  fi

  for item_name in $RC_ITEMS; do
    rc_default "$item_name" >/dev/null 2>&1 || continue
    rc_get "$item_name" && continue
    missing="${missing}${missing:+ }${item_name}"
  done

  # ONE LINE, ON PURPOSE — the same discipline step 5's gates carry, and for the
  # same reason: tests prove a gate load-bearing by DELETING its line from a copy
  # of this file, and a gate spread over an if/fi pair cannot be deleted that way
  # without turning the copy into a parse error.
  [ -n "$missing" ] || { item "$SETUP_OK" "claude() function" "already in ${rc} — nothing to do"; return 0; }  # idempotence guard: rc item

  say "   ${rc} does not carry bionic's claude() shell function:"
  for item_name in $missing; do
    say "   $(rc_default "$item_name")"
    say "   — $(_setup_rc_why "$item_name")"
  done
  consent "   Add it to ${rc}?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then _setup_say_declined "$_setup_consent_rc" "${rc} is unchanged."; action "add bionic's claude() shell function to ${rc} — $(_setup_answer_yes claude-proxy)"; return 0; fi  # consent gate: rc item

  for item_name in $missing; do
    if rc_set "$item_name"; then
      wrote=$((wrote + 1))
    else
      item "$SETUP_BAD" "claude() function" "could not write ${rc}"
      action "add bionic's claude() shell function to ${rc} (bionic could not write the file)"
      return 0
    fi
  done
  # Same gap step 5 reports: an rc is read when a shell STARTS, so the function
  # is in the next terminal and not in the one running this.
  item "$SETUP_OK" "claude() function" "added to ${rc} — takes effect in a new shell"
  return 0
}

# What each rc item is for, in the words the user reads. Beside the step for
# _setup_env_why's reason: env.sh owns the LINE, this file owns the prose that
# lands on a person's screen.
_setup_rc_why() {  # <item>
  case "${1:-}" in
    # WRITTEN TO RIDE ON THE LINE IT PRINTS ON (AC-F4/AC-15). Its caller is a
    # bare `say "   — …"`, five columns of lead-in and no truncator between this
    # string and the screen, so the budget is kept HERE, by the length of the
    # sentence: 93 characters, 98 columns printed. Slice 4/1 replaced the old
    # 55-character line ("launches claude with bypass available in the mode
    # cycle") with this longer and more exact one — the flag stopped starting
    # the session in bypass and started only offering it — which is what spends
    # most of the room. There is none left for another clause.
    claude-proxy) echo "keeps bypass selectable in the shift+tab cycle; the session still starts in your default mode" ;;
    *)            echo "a shell line bionic needs" ;;
  esac
}

# ─── Step 7 — the retired alias block ────────────────────────────────────────

setup_legacy_alias() {
  _setup_wants legacy-alias || return 0
  say ""
  say "7. Legacy shell alias"
  local rc line present tmp rc_target
  rc="$(_detect_shell_rc)"
  line="$(detect_zshrc_legacy_block)"; present="${line#*present=}"

  if [ "$present" = "yes" ]; then
    say "   ${rc} carries the retired bionic alias block — auto mode is the safer equivalent now."
    consent "   Remove the legacy alias block from ${rc}?"; _setup_consent_rc=$?
    if [ "$_setup_consent_rc" -ne 0 ]; then
      _setup_say_declined "$_setup_consent_rc" "the block stays."
      action "remove the legacy bionic alias block from ${rc} — $(_setup_answer_yes legacy-alias)"
      return 0
    fi
    _setup_rc_strip_block "$rc" "$SETUP_ALIAS_START" "$SETUP_ALIAS_END"
    if grep -qF "$SETUP_ALIAS_START" "$rc" 2>/dev/null; then
      item "$SETUP_BAD" "legacy alias block" "could not be removed"
      action "remove the legacy bionic alias block from ${rc} by hand"
    else
      item "$SETUP_OK" "legacy alias block" "removed"
    fi
    return 0
  fi

  if [ -f "$rc" ] && grep -qE "$BIONIC_LEGACY_ALIAS_PATTERN" "$rc" 2>/dev/null; then
    say "   ${rc} carries the legacy UNMARKED alias — the spelling that predates the marker block."
    consent "   Remove the legacy alias line from ${rc}?"; _setup_consent_rc=$?
    if [ "$_setup_consent_rc" -ne 0 ]; then
      _setup_say_declined "$_setup_consent_rc" "the alias stays."
      action "remove the legacy 'alias claude=...--dangerously-skip-permissions' line from ${rc} — $(_setup_answer_yes legacy-alias)"
      return 0
    fi
    rc_target="$(bionic_link_target "$rc")"
    tmp="${rc_target}.bionic.tmp"
    # Same discipline as _setup_rc_strip_block above, and for the same file — the
    # same two helpers too, so there is one staging order in this script rather
    # than a second one that has to be kept in step by hand, and one place that
    # decides a symlinked rc is rewritten rather than detached.
    if _setup_stage_tmp "$tmp" \
       && grep -vE "$BIONIC_LEGACY_ALIAS_PATTERN" "$rc" > "$tmp" \
       && _setup_publish_tmp "$tmp" "$rc_target"; then
      item "$SETUP_OK" "legacy alias" "removed (the unmarked spelling)"
    else
      rm -f "$tmp"
      item "$SETUP_BAD" "legacy alias" "could not rewrite ${rc}"
      action "remove the legacy 'alias claude=...--dangerously-skip-permissions' line from ${rc} by hand"
    fi
    return 0
  fi

  item "$SETUP_NIL" "legacy alias block" "none in ${rc} — nothing to remove"
  return 0
}

# ─── Step 8 — legacy-channel managed-hook entries ────────────────────────────
#
# COUNT here, REWRITE in hooks.sh. This step decides whether to ask and what to
# say; it does not carry a jq program of its own, because it used to and
# remove.sh's differently-shaped copy of the same rewrite drifted away from it
# unpinned. The count that decides to prompt and the edit that clears it are the
# same question, so they spell the same predicate — and the one caller with a
# real excuse for a second copy is remove.sh's standalone door, not this script,
# which refuses to start without the libraries beside it.
#
# Foreign hooks — anything not pointing into the pre-plugin directory — are
# untouched: this is bionic's leftover being removed, not the machine's hook
# config being taken over.

setup_legacy_channel_hooks() {
  _setup_wants legacy-hooks || return 0
  say ""
  say "8. Legacy-channel managed-hook entries"
  local line count settings registered
  line="$(detect_legacy_channel_hooks)"; count="${line#*count=}"
  settings="$(_dep_settings_file)"
  line="$(detect_plugin_registered)";    registered="${line#*registered=}"

  case "$count" in
    0)
      item "$SETUP_NIL" "legacy-channel hooks" "no legacy-channel managed-hook entries — nothing to remove"
      return 0 ;;
    unknown)
      item "$SETUP_NIL" "legacy-channel hooks" "count unknown — jq is unavailable, so ${settings} was not parsed"
      action "install jq, then re-run /bionic:setup — legacy-channel managed-hook entries could not be counted"
      return 0 ;;
  esac

  # The pre-plugin hooks directory is named without a path literal on purpose:
  # tests/plugin-paths.test.sh used to forbid an installed-path literal on any
  # executable line in the payload, and a user-facing string is still one. That
  # suite was deleted at 8582861 (epic-18 wave-03) and nothing replaced the
  # forbid; the discipline is kept here on trust, not enforcement.
  say "   ${count} hook entr(ies) in ${settings} still point into the pre-plugin hooks directory."
  # WHAT THIS PROMPT IS ALLOWED TO PROMISE. Offering to delete a user's only
  # live hook registrations is safe when the plugin channel already carries the
  # same hooks and destructive when it does not, and which of those is true is a
  # machine fact — not a property of this script. It was stated unconditionally
  # until `detect_plugin_registered` existed to condition it on, which made the
  # sentence false on every machine before the plugin is installed. `unknown`
  # falls to the cautious branch on purpose: an unreadable registry is not
  # evidence of coverage.
  if [ "$registered" = "yes" ]; then
    say "   The plugin registers its own copy of each, so the same hooks keep firing once these are gone."
  else
    say "   The plugin is NOT registered here, so removing these leaves those hooks not firing at all."
  fi
  consent "   Remove the legacy-channel entries from ${settings}?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then
    _setup_say_declined "$_setup_consent_rc" "${settings} is unchanged."
    action "remove ${count} legacy-channel managed-hook entr(ies) from ${settings} — $(_setup_answer_yes legacy-hooks)"
    return 0
  fi

  if hooks_strip_legacy_channel "$settings"; then
    item "$SETUP_OK" "legacy-channel hooks" "removed"
  else
    item "$SETUP_BAD" "legacy-channel hooks" "could not rewrite ${settings}"
    action "remove ${count} legacy-channel managed-hook entr(ies) from ${settings} by hand"
  fi
  return 0
}

# ─── Step 9 — the legacy installed skill copy ────────────────────────────────
#
# The third ported obligation, and the one the installer never had: it CREATED
# this. `claude-bootstrap.sh` rendered bionic's skills into the CLI's own
# skills directory, and the plugin ships the same skill inside its payload — so
# after the cutover the installed copy is a second canonical-sdlc whose
# frontmatter still registers hooks through the pre-plugin channel. A session
# that loads it arms the same walls twice, silently, from a build no plugin
# update will ever move.
#
# W5 4/6 hit exactly this and removed the copy by hand to keep its live-fire
# attribution clean, then reported the gap rather than closing it quietly. This
# step is the gap closed: the removal is the shipped migration's own act.
#
# WHAT THE PROMPT NAMES IS WHAT GOES. `detect_legacy_skill_copy` resolves one
# directory; this step prints that path, asks about that path, and removes that
# path. Sibling copies the same installer left are a separate decision and are
# not offered here — see the library's note.

setup_legacy_skill_copy() {
  _setup_wants legacy-skill-copy || return 0
  say ""
  say "9. Legacy installed skill copy"
  local line present dir
  line="$(detect_legacy_skill_copy)"
  present="${line#*present=}"; present="${present%% *}"
  dir="${line##*path=}"

  if [ "$present" != "yes" ]; then
    item "$SETUP_NIL" "legacy skill copy" "no pre-plugin skill copy — nothing to remove"
    return 0
  fi

  say "   ${dir} is a pre-plugin copy of a skill this payload ships — a session that loads it"
  say "   arms the same walls twice, once from the plugin and once from the retired copy."
  # The gate is one line so a mutation arm can delete it whole and watch the
  # decline stop protecting anything. tests/setup.test.sh Group 12, mutation 4
  # used to run exactly that arm; it was deleted at 8582861 (epic-18 wave-03)
  # and nothing replaced it.
  consent "   Remove ${dir} and everything under it?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then _setup_say_declined "$_setup_consent_rc" "${dir} is unchanged."; action "remove the pre-plugin skill copy at ${dir} — $(_setup_answer_yes legacy-skill-copy)"; return 0; fi  # consent gate: legacy skill copy

  # The guard is not decoration. This is the only recursive delete in the
  # script, and the path it takes comes from an environment the caller controls;
  # re-reading the two conditions the fact function used means a resolution that
  # went wrong between then and now removes nothing.
  if [ -n "$dir" ] && [ -d "$dir" ] && [ -f "${dir}/SKILL.md" ]; then
    rm -rf "$dir" 2>/dev/null
  fi
  if [ ! -e "$dir" ]; then
    item "$SETUP_OK" "legacy skill copy" "removed ${dir}"
  else
    item "$SETUP_BAD" "legacy skill copy" "could not remove ${dir}"
    action "remove the pre-plugin skill copy at ${dir} by hand"
  fi
  return 0
}

# ─── Step 10 — the legacy installed hook FILES ───────────────────────────────
#
# THE STEP DOCTOR'S HINT ALREADY PROMISED. `detect_legacy_hook_files` has counted these for
# as long as doctor has had a row for them, and that row ends ` → /bionic:setup`. Until this
# function existed the suffix named a command which then reported "nothing left to do — this
# machine is set up." over sixteen files the reader could see with `ls`
# (.bionic/docs/ideas/bug-doctor-setup-ownership.md, filed 2026-09-05 against payload 1.4.3;
# Chris: "That's inconsistent, and very confusing"). A hint naming a remedy nobody owns is
# worse than no hint — it teaches the reader to stop believing the report. Doctor was not
# changed for this: its row was true about the machine all along, and what was missing is the
# thing it pointed at.
#
# WHAT GOES IS WHAT THE FACT FUNCTION NAMED. The removal walks the `names=` list the detector
# built by matching THIS payload's own hooks/ directory against the installed one; nothing
# here globs the claude-home. A `.sh` in that directory the payload does not ship is the
# machine owner's own hook, and deleting somebody's work while claiming to clean up after
# bionic is the one mistake this step may not make.
#
# INERT IS NOT ABSENT. With the settings-channel entries gone (step 8) these files run
# nothing — they are disk, not behaviour. They are also an older build of every wall this
# repo ships, sitting under a path four eras of documentation told people to invoke, which is
# why the machine keeps them until somebody says yes.

setup_legacy_hook_files() {
  _setup_wants legacy-hook-files || return 0
  say ""
  say "10. Legacy installed hook files"
  local line count dir names left removed=0
  line="$(detect_legacy_hook_files)"
  count="${line#*count=}"; count="${count%% *}"
  dir="${line#*path=}";    dir="${dir%% *}"
  names="${line##*names=}"

  case "$count" in
    0)
      item "$SETUP_NIL" "legacy hook files" "no pre-plugin hook files — nothing to remove"
      return 0 ;;
    unknown)
      item "$SETUP_NIL" "legacy hook files" "count unknown — ${line##*cause=}"
      return 0 ;;
  esac

  say "   ${count} file(s) in ${dir} are pre-plugin copies of hooks this payload ships."
  say "   They fire nothing while the plugin channel is live, and they are an older build of"
  say "   every wall bionic ships, under a path the retired installer told people to invoke."
  consent "   Remove those ${count} file(s) from ${dir}?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then
    _setup_say_declined "$_setup_consent_rc" "${dir} is unchanged."
    action "remove ${count} pre-plugin hook file(s) from ${dir} — $(_setup_answer_yes legacy-hook-files)"
    return 0
  fi

  # ONE NAME AT A TIME, AND ONLY FROM THE LIST. `_dep_rm_named_files` (deps.sh) re-splits
  # the detector's own comma-separated list into positional parameters under a `set -f`
  # guard, so a glob character in a payload filename cannot expand against this process's
  # $PWD on the way through — the same guard every one of the four teardown call sites now
  # shares (review-d D-2).
  removed="$(_dep_rm_named_files "$dir" "$names")"

  # THE VERDICT IS RE-MEASURED, NOT ASSUMED. The same fact function that decided to ask is
  # asked again; a file that would not delete is then a `✗` with a by-hand action, never a
  # green row over a directory that still carries what it named.
  line="$(detect_legacy_hook_files)"; left="${line#*count=}"; left="${left%% *}"
  if [ "$left" = "0" ]; then
    item "$SETUP_OK" "legacy hook files" "removed ${removed} file(s) from ${dir}"
  else
    item "$SETUP_BAD" "legacy hook files" "${left} of ${count} are still in ${dir}"
    action "remove the remaining pre-plugin hook file(s) from ${dir} by hand"
  fi
  return 0
}

# ─── Step 11 — the legacy installed agent role files ─────────────────────────
#
# THE SAME DEBT IN THE DIRECTORY NEXT DOOR, and this one is not inert. Role files are
# instructions a dispatched subagent obeys, so while `~/.claude/agents/auditor.md` exists the
# session's agent-type list carries both `auditor` and `bionic:auditor` with different bodies
# — a build of bionic's own dispatch discipline that no plugin update will ever reach, and
# nothing else on the machine reports the gap.
#
# THE DRIFTED COPIES, WHICH IS EXACTLY WHAT DOCTOR'S ROW COUNTS.
# `detect_installed_agent_copies` digests every role file this payload ships against a
# same-named copy in the claude-home and names the ones that differ; doctor prints
# `N/M differ → /bionic:setup` from that number, and this step offers those N. A copy that
# still matches the payload byte for byte is on neither surface: the two are allowed to say
# different things about different machines, never about the same one.
#
# PAYLOAD-SIDE NAMES ONLY, for the reason step 10 states — a `.md` in that directory the
# payload does not ship is somebody's own agent.

setup_legacy_agent_copies() {
  _setup_wants legacy-agent-copies || return 0
  say ""
  say "11. Legacy installed agent copies"
  local line state total drift names dir left removed=0
  line="$(detect_installed_agent_copies)"
  state="${line#*state=}"; state="${state%% *}"
  total="${line#*total=}"; total="${total%% *}"
  drift="${line#*drift=}"; drift="${drift%% *}"
  names="${line#*names=}"; names="${names%% *}"
  dir="$(_setup_agent_copies_dir)"

  case "$state" in
    unknown)
      item "$SETUP_NIL" "legacy agent copies" "state unknown — ${line##*cause=}"
      return 0 ;;
    absent)
      item "$SETUP_NIL" "legacy agent copies" "no installed agent copies — nothing to remove"
      return 0 ;;
  esac
  if [ "$drift" = "0" ]; then
    item "$SETUP_NIL" "legacy agent copies" "${total} installed copy(ies), all matching this payload"
    return 0
  fi

  say "   ${drift} of the ${total} role file(s) in ${dir} no longer match the ones this payload"
  say "   ships. A dispatched agent reads the installed copy, so the stale one is what runs."
  consent "   Remove those ${drift} file(s) from ${dir}?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then
    _setup_say_declined "$_setup_consent_rc" "${dir} is unchanged."
    action "remove ${drift} drifted agent role file(s) from ${dir} — $(_setup_answer_yes legacy-agent-copies)"
    return 0
  fi

  # Same guard, same helper (review-d D-2) — see step 10 above.
  removed="$(_dep_rm_named_files "$dir" "$names")"

  line="$(detect_installed_agent_copies)"; left="${line#*drift=}"; left="${left%% *}"
  if [ "$left" = "0" ]; then
    item "$SETUP_OK" "legacy agent copies" "removed ${removed} file(s) from ${dir}"
  else
    item "$SETUP_BAD" "legacy agent copies" "${left} of ${drift} are still in ${dir}"
    action "remove the remaining drifted agent role file(s) from ${dir} by hand"
  fi
  return 0
}

# ─── Step 12 — the permission mode ───────────────────────────────────────────
#
# THE STEP IS TWO DECISIONS, SO IT IS TWO FUNCTIONS, and they are independent: a
# machine with no leftover block still has a mode question to answer, and the
# cleanup half returns early on exactly that machine. Left inline, the second
# question would have been unreachable on most machines — the ones least likely
# to notice.

setup_permission_mode() {
  _setup_wants legacy-permission-block || _setup_wants permission-mode || return 0
  say ""
  say "12. Permission mode"
  _setup_wants legacy-permission-block && _setup_legacy_permission_block
  _setup_wants permission-mode && _setup_default_mode
  return 0
}

# ─── The retired permission block, stripped once ─────────────────────────────
#
# bionic used to render a managed allow-list into this same settings file so its
# own scripts ran without a prompt. That is deleted (epic-18 T13): the mode
# below is the user's answer to how much they want to be asked, and a product
# that exempts itself from it has overridden the choice rather than honoured it.
#
# NOTHING WRITES THE BLOCK ANY MORE, so this is cleanup and only cleanup — the
# upgrade path's half of it, with /bionic:remove carrying the teardown path's.
# Without it a machine set up before the change would keep granting permissions
# under a marker nothing in the product would ever name again. deps.sh owns the
# strip; this asks the question. On a machine that never carried one, the whole
# arm is silent rather than reporting a clean state nobody asked about.
_setup_legacy_permission_block() {
  local settings
  settings="$(_dep_settings_file)"
  bionic_has_permission_block "$settings" || return 0

  say "   ${settings} carries bionic's retired permission block — an allow-list bionic no"
  say "   longer ships. Removing it leaves every rule outside the block untouched."
  consent "   Remove the retired permission block from ${settings}?"; _setup_consent_rc=$?
  if [ "$_setup_consent_rc" -ne 0 ]; then _setup_say_declined "$_setup_consent_rc" "${settings} is unchanged."; action "remove the retired permission block from ${settings} — $(_setup_answer_yes legacy-permission-block)"; return 0; fi  # consent gate: legacy permission block

  if bionic_strip_permission_block "$settings"; then
    item "$SETUP_OK" "retired permission block" "removed"
  else
    item "$SETUP_BAD" "retired permission block" "could not be removed"
    action "remove the retired permission block from ${settings} by hand (jq is required to edit it safely)"
  fi
  return 0
}

# ─── The default permission mode (AC-12) ─────────────────────────────────────
#
# ONE QUESTION, NEVER ASSUMED. It decides whether the machine asks about
# everything once or every time — bionic's own commands included, now that
# nothing carves them out.
#
# ALREADY-AUTO ASKS NOTHING. Every other step here is guarded by the fact that
# owns its question, and this is no different: a machine already in auto has
# nothing to decide, and asking anyway would be the interrogation this wave is
# removing. Without jq the value cannot be read at all, so the honest answer is
# to say so and change nothing — never to write over a mode we could not see.
_setup_default_mode() {
  local settings mode want
  settings="$(_dep_settings_file)"
  want="$BIONIC_DEFAULT_PERMISSION_MODE"

  if ! command -v jq >/dev/null 2>&1; then
    item "$SETUP_NIL" "permission mode" "unknown — jq is unavailable, so ${settings} was not parsed"
    action "install jq, then re-run /bionic:setup — the default permission mode could not be read"
    return 0
  fi

  if [ -f "$settings" ]; then
    mode="$(jq -r '.permissions.defaultMode // ""' "$settings" 2>/dev/null)" || mode=""
  else
    mode=""
  fi

  # THE VALUE IS DEPS.SH'S, NOT THIS FILE'S (six-axis review D-1). remove.sh
  # offers to reset exactly the value bionic wrote and leaves any other alone,
  # so the two scripts are one decision; this used to be a bare literal here and
  # a second bare literal there, agreeing by luck. Written with `--arg` so a
  # value with a quote in it could never become part of the jq program.
  if [ "$mode" = "$want" ]; then item "$SETUP_OK" "permission mode" "already ${want} — nothing to do"; return 0; fi  # idempotence guard: default mode

  consent "   Set Claude Code's default permission mode to ${want}? Recommended — you approve once, not on every command."; _setup_consent_rc=$?
  # item 1: the note follows the question itself, whichever way it was
  # answered — a Remote Control session overrides this either way, so a
  # decline that leaves the setting unchanged and a yes that writes it both
  # need the same one sentence.
  say "   ${BIONIC_PERMISSION_MODE_RC_NOTE}"
  if [ "$_setup_consent_rc" -ne 0 ]; then _setup_say_declined "$_setup_consent_rc" "the default permission mode is unchanged."; action "set Claude Code's default permission mode to ${want} in ${settings} — $(_setup_answer_yes permission-mode)"; return 0; fi  # consent gate: default mode

  # Created only AFTER consent: a declined run must leave a machine that has no
  # settings file without one.
  [ -f "$settings" ] || echo '{}' > "$settings"
  if _dep_settings_write_jq "$settings" '.permissions.defaultMode = $m' --arg m "$want"; then
    item "$SETUP_OK" "permission mode" "set to ${want}"
  else
    item "$SETUP_BAD" "permission mode" "could not be set"
    action "set Claude Code's default permission mode to ${want} in ${settings} by hand"
  fi
  return 0
}

# ─── The summary ─────────────────────────────────────────────────────────────

setup_summary() {
  say ""
  say "Summary"
  # THE RESTART NOTE COMES FIRST, and only when something this run did needs one.
  # It is not an action line: there is nothing left for the user to fix, and
  # filing it among the failures would say the statusline did not get installed.
  [ "${SETUP_PLUGIN_CHANGED:-}" = "yes" ] && \
    say "   newly installed plugins take effect after /reload-plugins or a new session."
  if [ -z "$SETUP_ACTIONS" ]; then
    # A NARROWED RUN MAY NOT CLAIM THE WHOLE MACHINE (the RV-6 class: a summary
    # that overreaches teaches the reader to stop reading it). One item finished
    # is one item finished; the other eight were never looked at.
    if [ -n "$SETUP_ONLY" ]; then
      say "   nothing left to do for ${SETUP_ONLY}."
    else
      say "   nothing left to do — this machine is set up."
    fi
    return 0
  fi
  local a
  while IFS= read -r a; do
    [ -n "$a" ] && say "   - ${a}"
  done <<< "$SETUP_ACTIONS"
  return 0
}

# ─── Run ─────────────────────────────────────────────────────────────────────

# THE FLAGS ARE READ HERE, not in a wrapper, because the roster they are checked
# against is built from the dependency table this script has already sourced. An
# unrecognised name stops the run before anything is printed at it: a narrowed
# run that silently did nothing would look exactly like a machine with nothing
# left to do, which is the one report this script must never fake.
SETUP_LIST=0
setup_all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      SETUP_LIST=1; shift ;;
    --all)
      setup_all=1; shift ;;
    --only)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        say "setup: --only needs the name of the one item to set up."
        say "       run ${SETUP_SELF_CMD} --list to see the names."
        exit 2
      fi
      SETUP_ONLY="$2"; shift 2 ;;
    --only=*)
      SETUP_ONLY="${1#--only=}"; shift ;;
    *)
      say "setup: ${1} is not something this command takes."
      say "       run ${SETUP_SELF_CMD} --list to see what can be set up one item at a time."
      exit 2 ;;
  esac
done

# TWO NARROWINGS THAT CANNOT BOTH APPLY. `--only` runs one item; `--all` runs
# every item over one answer. Together they would have to mean something, and
# whatever that something was, half the people who typed it would mean the other
# one — so it stops here, before anything is printed at the machine.
if [ "$setup_all" = "1" ] && [ -n "$SETUP_ONLY" ]; then
  say "setup: --all and --only cannot be combined — --all does every item, --only does exactly one."
  say "       run ${SETUP_SELF_CMD} --list to see the names --only takes."
  exit 2
fi

if [ "$SETUP_LIST" = "1" ]; then
  _setup_item_ids
  exit 0
fi

if [ -n "$SETUP_ONLY" ]; then
  setup_known=""
  while IFS= read -r setup_id <&3; do
    [ "$setup_id" = "$SETUP_ONLY" ] && { setup_known=1; break; }
  done 3< <(_setup_item_ids)
  if [ -z "$setup_known" ]; then
    say "setup: there is nothing called ${SETUP_ONLY} to set up on this machine."
    say "       run ${SETUP_SELF_CMD} --list to see the names."
    exit 2
  fi
fi

# THE HEADER SAYS WHICH MODE THIS IS (Chris 2026-08-22: "it's NOT installing one
# at a time; it's installing all in one go!"). Under --all there is one question
# over the whole list; without it, one question per item.
if [ "$setup_all" = "1" ]; then
  say "bionic setup"
else
  say "bionic setup — every change below is asked for first, one item at a time."
fi

# THE ONE EVENT, BEFORE ANY STEP SPEAKS. Under `--all` the whole page is printed
# and answered here; every question below then finds the answer already given.
# A no — or nobody there to answer — leaves the machine exactly as it was, which
# is the same floor a per-item pass holds to.
if [ "$setup_all" = "1" ]; then
  say ""
  # THE PAGE IS BUILT WITH THE ANSWER CHANNEL CLOSED. Every predicate behind it
  # shells out — the CLI's listing, the dependency probes — and a child that
  # reads its inherited stdin eats the one `y` this run is about to ask for.
  # Nothing here needs stdin, so nothing here gets it.
  if ! _setup_print_plan < /dev/null; then
    say "   nothing left to do — this machine is set up."
    exit 0
  fi
  consent "Do all of the above?"; setup_all_rc=$?
  case "$setup_all_rc" in
    0) SETUP_ALL=1 ;;
    2) exit 0 ;;   # nobody could answer: the question stands on screen for the
                   # relaying command to put to the user — no "nothing changed"
                   # under it (Chris 2026-08-22: that line read as a refusal)
    *) say "   nothing changed."; exit 0 ;;
  esac
fi

setup_plugin_install
setup_load_state
setup_duplicates
setup_dep_enable_verify
setup_tools_loop
setup_extras_loop
setup_environment
setup_claude_proxy
setup_legacy_alias
setup_legacy_channel_hooks
setup_legacy_skill_copy
setup_legacy_hook_files
setup_legacy_agent_copies
setup_permission_mode
setup_summary

exit 0
