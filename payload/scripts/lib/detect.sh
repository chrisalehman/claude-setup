#!/bin/bash
# detect.sh — machine facts, read-only (epic-17 wave-03, spec AC-3/AC-5).
#
# WHAT THIS FILE OWNS. Every observable truth about the machine bionic is
# running on: is the payload intact, is a dependency there and at what version,
# does the shell rc carry the flag, is there a legacy alias block, are there
# hook registrations still on the legacy settings channel, is this box
# half-uninstalled. One function
# per fact class, and every door — doctor's report, setup's action list, a
# route's just-in-time offer, remove's teardown — reads the SAME function. A
# second implementation of any of these is the defect the ownership table
# exists to prevent.
#
# THE OUTPUT CONTRACT. One line, parseable, exit 0. Always exit 0: a fact
# function's job is to REPORT, and "I could not tell" is a fact with a value
# (`unknown`), not an error. Callers parse fields; they never branch on the
# exit code. The line shapes are fixed and consumed by later slices verbatim:
#
#   plugin: version=<v> hooks=<ok|degraded|absent>
#   agents: state=<stock|modified|unknown> total=<n|unknown> modified=<n|unknown> names=<a.md,b.md|-> cause=<text|->
#   dep:<name> lane=<3a|3b> present=<yes|no|unknown> version=<v|unknown> constraint=<c> verdict=<ok|violation|unknown>
#   env:todo-tools present=<yes|no>
#   env:rc-claude-proxy present=<yes|no|stale>
#   env:zshrc-legacy present=<yes|no>
#   env:legacy-channel-hooks count=<n|unknown>
#   env:legacy-hook-files count=<n|unknown> path=<dir> names=<a.sh,b.sh|-> [cause=<text>]
#   state:half-uninstalled=<yes|no>
#   load-state=<loaded|failed|absent|unknown> error=<CLI error text|-> [cause=<text>]
#   dup=<bare-name> ids=<a@x>,<b@y> fix=<consolidation command>
#   plugin:latest state=<current|lag|unknown> installed=<v|-> latest=<v|-> cause=<text|->
#
# `unknown` APPEARS WHERE HONESTY REQUIRES IT. Two of these values can read
# `unknown` where the spec's table sketched only yes/no: a dependency whose
# mechanism has no presence surface at all (the pnpm store is a cache, not an
# install), and a count that cannot be taken because `jq` — itself one of the
# table's own rows — is missing. The alternative is a confident wrong answer,
# and a doctor that confidently reports a clean machine as dirty is worse than
# one that says it could not look.
#
# READ-ONLY IS A CONTRACT, NOT AN INTENTION. Nothing here writes, creates,
# moves, or removes anything, and `/bionic:doctor` is built entirely on it.
# tests/plugin-lib.test.sh used to fingerprint a fixture tree before and after
# a full sweep to keep that true; it was deleted at 8582861 (epic-18 wave-03)
# and nothing replaced the fingerprint wall.
#
# ROOTS ARE OVERRIDABLE, read at CALL time so one sourced copy can be pointed
# at several roots in turn (the suite does exactly that):
#
#   BIONIC_PLUGIN_ROOT     the payload tree            ${CLAUDE_PLUGIN_ROOT} or this file's ../..
#   BIONIC_CLAUDE_HOME     the CLI's config dir        ${CLAUDE_CONFIG_DIR:-~/.claude}
#   BIONIC_SETTINGS_FILE   user settings.json          <claude-home>/settings.json
#   BIONIC_SHELL_RC        the shell rc bionic edits   ~/.zshrc or ~/.bashrc, per $SHELL
#   BIONIC_PLUGIN_LIST_CMD the CLI's own listing       `claude plugin list`
#
# WHAT THE SCRATCH-HOME KNOBS DO NOT ISOLATE (epic-17 W7, walk finding W-3).
# `BIONIC_CLAUDE_HOME` and its two companions redirect the CLI's CONFIG DIRECTORY and
# nothing else: the global tool probes (`npm -g`, `uv tool`, `brew`) still read the
# real machine, so a plan printed against a scratch home names this machine's actual
# tools and a `y` on a scratch-home `--all` run would install or remove them for real.
# The suites stub those mechanisms, so a hermetic run cannot bite; a person driving a
# scratch home by hand is looking at a plan that is only half scratch.
#
# Sourced, never executed:  . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/detect.sh"

# deps.sh is a sibling; the dependency table and the per-mechanism probes live
# there because they are properties of the DEPENDENCY, not of the machine.
# detect_dep below is their only formatter.
# No `dirname`/`basename` anywhere below, on purpose: a library that cannot be
# SOURCED without coreutils is a library that dies on the machine it is most
# needed on (jq missing, PATH broken, a half-uninstalled box). Bash's own
# parameter expansion does the same work with no process at all.
_detect_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}

if ! declare -F check_dep >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_detect_self_dir)" && pwd -P)/deps.sh"
fi

# env.sh, THE SAME SOFT SOURCE, FOR ITS READ HALF ONLY — `rc_get`, `rc_file` and
# `rc_default`. Those own the question "is bionic's proxy line inside bionic's
# markers", and `detect_rc_claude_proxy` below now asks THEM rather than
# answering it a second way (epic-19 W1 Step-6 DUPLICATION FAIL: the two
# predicates disagreed on every machine carrying an older proxy line). env.sh's
# write half is never called from here, the same way this file never installs a
# dependency it can only report on. No cycle: env.sh sources deps.sh and nothing
# else, so this file loads deps.sh, then env.sh over the top of it, and a caller
# that already has either gets neither again.
if ! declare -F rc_get >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_detect_self_dir)" && pwd -P)/env.sh"
fi

# shell.sh, THE SAME SOFT SOURCE, FOR `shell_rc_file` — the one rc-file resolver
# (L-DETECT/4.4, spec AC-21). `_detect_shell_rc` below used to carry its own copy
# of the zsh/bashrc case split; remove.sh's `_rm_shell_rc` carried a second,
# byte-identical one. Two owners of one answer is the duplication this file's own
# header forbids for every other fact it holds, so this fact gets the same
# single-source treatment as `rc_get`/`rc_file` just above.
if ! declare -F shell_rc_file >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_detect_self_dir)" && pwd -P)/shell.sh"
fi

# roots.sh, THE SAME SOFT SOURCE, FOR `plugin_root` — the one payload-root resolver
# (epic-22 wave-01, N1). This file carried `_detect_plugin_root` and lib/deps.sh carried
# `_dep_plugin_root`, byte-identical, each explaining itself by naming the other. Guarded on
# the function and not on the sibling that usually brings it, because a caller that has
# check_dep already skips the deps.sh source above.
if ! declare -F plugin_root >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_detect_self_dir)" && pwd -P)/roots.sh"
fi


# A thin caller of shell.sh's one resolver — see the source guard above.
_detect_shell_rc() {
  shell_rc_file
}

# ─── Plugin integrity ────────────────────────────────────────────────────────
#
# Two questions in one line: which version of the payload is running, and are
# its hooks wired to files that actually exist. `degraded` is the interesting
# state — hooks.json present but naming a script that is not there is exactly
# what a partial update or a half-copied install leaves behind, and it is
# invisible to any check that only asks whether hooks.json exists.

detect_plugin_integrity() {
  local root version="unknown" hooks_json hooks_state cmd script tok
  local -a toks
  root="$(plugin_root)"
  hooks_json="${root}/hooks/hooks.json"

  if [ -f "${root}/.claude-plugin/plugin.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      version="$(jq -r '.version // "unknown"' "${root}/.claude-plugin/plugin.json" 2>/dev/null)"
    else
      version="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "${root}/.claude-plugin/plugin.json" 2>/dev/null \
                 | head -1 | grep -oE '"[^"]+"$' | tr -d '"')"
    fi
    [ -n "$version" ] || version="unknown"
  fi

  if [ ! -f "$hooks_json" ]; then
    hooks_state="absent"
  else
    hooks_state="ok"
    # Every command in hooks.json names a script under the plugin root via
    # ${CLAUDE_PLUGIN_ROOT}. Resolve that prefix against the root we are
    # actually inspecting and confirm the file is there.
    #
    # EVERY token, not just the first. Four of the six shipped entries CHAIN
    # two scripts (`agent-context-guard.sh <inner>`), and the inner one is
    # where the evidence gate, the governing-skill gate and the landing gate
    # live. Reading `${cmd%% *}` alone called a payload missing all three
    # healthy. `read -a` splits on whitespace without letting the shell glob
    # the pieces; the `/*` guard then skips anything that is not a resolved
    # absolute path (a flag, a plain argument, an unexpanded env reference).
    while IFS= read -r cmd; do
      [ -n "$cmd" ] || continue
      read -r -a toks <<<"$cmd"
      for tok in "${toks[@]}"; do
        script="${tok//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"
        script="${script//\$CLAUDE_PLUGIN_ROOT/$root}"
        case "$script" in /*) ;; *) continue ;; esac
        [ -f "$script" ] || { hooks_state="degraded"; break 2; }
      done
    done < <(grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]+"' "$hooks_json" 2>/dev/null \
             | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//')
  fi

  echo "plugin: version=${version} hooks=${hooks_state}"
  return 0
}

# HOW MANY HOOK SCRIPTS, AND HOW MANY RESOLVE. `detect_plugin_integrity` answers
# the yes/no question — is the wiring whole — which is the right answer for a
# verdict and the wrong one for a table. The certified BIONIC NATIVE table prints
# a count per component, and "hooks ok" cannot fill an `n/n` cell: a reader
# looking at `16/17` learns both that something is missing and how much of the
# payload is fine, which is the difference between a diagnosis and an alarm.
#
# THE SAME WALK, DELIBERATELY. Every token of every `command`, the same
# `${CLAUDE_PLUGIN_ROOT}` substitution, the same `/*` guard — because a count
# taken by a second, subtly different parse would disagree with the verdict above
# it on exactly the machines where the disagreement matters. The two functions
# stay side by side so a change to one is read against the other.
#
# DISTINCT PATHS, NOT MENTIONS. Four shipped entries chain the same guard script
# in front of an inner one, so counting mentions would report seventeen scripts
# on a payload that carries eleven files. The set is deduplicated.
detect_hook_wiring() {  # -> "hooks: total=<n> resolving=<n>"
  local root hooks_json cmd script tok seen="" total=0 resolving=0
  local -a toks
  root="$(plugin_root)"
  hooks_json="${root}/hooks/hooks.json"
  [ -f "$hooks_json" ] || { echo "hooks: total=0 resolving=0"; return 0; }
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    read -r -a toks <<<"$cmd"
    for tok in "${toks[@]}"; do
      script="${tok//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"
      script="${script//\$CLAUDE_PLUGIN_ROOT/$root}"
      case "$script" in /*) ;; *) continue ;; esac
      case "$seen" in *"|${script}|"*) continue ;; esac
      seen="${seen}|${script}|"
      total=$((total + 1))
      [ -f "$script" ] && resolving=$((resolving + 1))
    done
  done < <(grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]+"' "$hooks_json" 2>/dev/null \
           | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//')
  echo "hooks: total=${total} resolving=${resolving}"
  return 0
}

# ─── Rendered-agent integrity ────────────────────────────────────────────────
#
# Has anything edited the role files this payload installed? The six agent files
# are instructions a dispatched subagent obeys, so a stray edit there changes
# behaviour everywhere and leaves no trace anywhere else — the machine keeps
# working, differently. The payload ships a checksum manifest beside them
# (integrity/rendered.sha256, written by agents-src/render.sh), and this compares
# it against what is on disk.
#
# REPORTING, NOT POLICING. A user who edited a role file may have meant to; that
# is their machine. The fact line says WHICH files differ and stops there — no
# repair, no exit status, no second mention. The caller renders one line.
#
# THE THIRD VALUE MATTERS MOST HERE. Two conditions make the question
# unanswerable: no manifest (an old payload, or a hand-assembled install) and no
# sha256 tool on PATH. Answering `stock` in either case would report the very
# state this function exists to detect as the state it exists to reassure about,
# so both return `unknown` with the cause named.

_detect_sha256() {  # <file> -> hex digest on stdout; nonzero if no tool can answer
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1" 2>/dev/null)" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1" 2>/dev/null)" || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  echo "${out%% *}"
}

detect_agent_integrity() {
  local root manifest line want rel got total=0 modified=0 names=""
  root="$(plugin_root)"
  manifest="${root}/integrity/rendered.sha256"

  if [ ! -f "$manifest" ]; then
    echo "agents: state=unknown total=unknown modified=unknown names=- cause=this payload ships no checksum manifest at integrity/rendered.sha256"
    return 0
  fi
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "agents: state=unknown total=unknown modified=unknown names=- cause=neither shasum nor sha256sum is on PATH, so the agent files cannot be digested"
    return 0
  fi

  # `<digest>  <path>` rows, path relative to the plugin root; `#` comments and
  # blank lines skipped. A row whose file is GONE counts as modified and is
  # named: deleting a role file is a local change like any other, and silently
  # skipping it would report five-of-six as a whole set.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    want="${line%% *}"
    rel="${line#* }"; rel="${rel# }"
    [ -n "$want" ] && [ -n "$rel" ] || continue
    total=$((total + 1))
    got="$(_detect_sha256 "${root}/${rel}")" || got=""
    if [ "$got" != "$want" ]; then
      modified=$((modified + 1))
      names="${names:+${names},}${rel##*/}"
    fi
  done < "$manifest"

  if [ "$total" = 0 ]; then
    echo "agents: state=unknown total=0 modified=unknown names=- cause=the checksum manifest lists no files"
  elif [ "$modified" = 0 ]; then
    echo "agents: state=stock total=${total} modified=0 names=- cause=-"
  else
    echo "agents: state=modified total=${total} modified=${modified} names=${names} cause=-"
  fi
  return 0
}

# ─── Dependencies ────────────────────────────────────────────────────────────
#
# The fact line for one dependency. Everything factual comes from deps.sh —
# the row from the table, the probe from the mechanism — and this function
# only renders. That split is why there is exactly one place a dependency's
# presence is decided.

detect_dep() {  # <name>
  local name="${1:-}" lane constraint raw present version verdict
  lane="$(dep_field "$name" lane)" || return 1
  constraint="$(dep_field "$name" constraint)"
  raw="$(check_dep "$name")" || return 1
  present="${raw#present=}"; present="${present%%|*}"
  version="${raw#*version=}"; version="${version%%|*}"
  verdict="${raw##*verdict=}"
  echo "dep:${name} lane=${lane} present=${present} version=${version} constraint=${constraint} verdict=${verdict}"
  return 0
}

# ─── Environment class ───────────────────────────────────────────────────────

# The flag current CLI builds need for the native task tools. A commented-out
# line does not count: it is the state a user lands in after commenting the
# export out, and reporting it as present would make setup skip the very
# repair that is wanted.
detect_env_todo_tools() {
  local rc present=no
  rc="$(_detect_shell_rc)"
  if [ -f "$rc" ] && grep -qE '^[[:space:]]*export[[:space:]]+CLAUDE_CODE_ENABLE_TODO_TOOLS=1' "$rc" 2>/dev/null; then
    present=yes
  fi
  echo "env:todo-tools present=${present}"
  return 0
}

# The rc item bionic OWNS, as opposed to the two retired ones below it: the
# `claude()` proxy setup writes, inside its own marker pair:
#
#     # ─── bionic:rc:start ───
#     claude() { command claude --allow-dangerously-skip-permissions "$@"; }
#     # ─── bionic:rc:end ───
#
# ONE OWNER FOR THE PREDICATE, AND IT IS env.sh's. `rc_get` — what setup already
# consumes to decide whether the item is done — asks whether `rc_default`'s line
# is INSIDE bionic's markers, and this function asks `rc_get`. It used to grep
# the START MARKER on its own, which agreed with setup only for as long as the
# line between the markers never changed; slice 4/1 changed it
# (`--dangerously-skip-permissions` → `--allow-dangerously-skip-permissions`)
# and every install already on disk became a machine setup called pending and
# doctor called healthy. Two owners of one concept, disagreeing in the field:
# the Step-6 review's DUPLICATION FAIL, closed by deleting the second owner
# rather than by adding a test that watches them drift.
#
# THREE STATES, BECAUSE THERE ARE THREE MACHINES.
#
#   yes    — the markers hold exactly the line this payload writes.
#   stale  — the markers are there and hold something else: an older payload's
#            text, or a hand edit between them. This person CONSENTED; what they
#            carry is bionic's own block gone out of date, which setup rewrites
#            and doctor must not paint green.
#   no     — no markers at all. Never asked, or asked and declined — a correctly
#            configured machine either way.
#
# The `no`/`stale` split is why the marker test survives at all: it is no longer
# the predicate, it is what tells a stale block from an absent one. A `claude()`
# function a user wrote for themselves sits outside the markers and is none of
# these — not claimed here, not removed by /bionic:remove.
detect_rc_claude_proxy() {
  local rc present=no
  if rc_get claude-proxy 2>/dev/null; then
    present=yes
  else
    # The file `rc_get` just looked in, so the two halves of this answer cannot
    # come to be about two different files. Unresolvable (a shell bionic writes
    # no rc for) leaves it empty and the answer `no`, which is the truth: there
    # is no file that could hold bionic's block.
    rc="$(rc_file 2>/dev/null)" || rc=""
    if [ -n "$rc" ] && [ -n "${RC_START:-}" ] && [ -f "$rc" ] && \
       grep -qF "$RC_START" "$rc" 2>/dev/null; then
      present=stale
    fi
  fi
  echo "env:rc-claude-proxy present=${present}"
  return 0
}

# The legacy alias block claude-bootstrap.sh used to write:
#
#     # ─── bionic:start ───
#     alias claude='claude --dangerously-skip-permissions'
#     # ─── bionic:end ───
#
# Auto mode is the default now and the safer equivalent, so the block is
# retired footprint that setup removes. The markers are matched verbatim,
# box-drawing dashes included — they are what makes the block addressable.
detect_zshrc_legacy_block() {
  local rc present=no
  rc="$(_detect_shell_rc)"
  if [ -f "$rc" ] && grep -qF '# ─── bionic:start ───' "$rc" 2>/dev/null; then
    present=yes
  fi
  echo "env:zshrc-legacy present=${present}"
  return 0
}

# Managed-hook entries in USER settings.json that still point at the
# pre-plugin copies under ~/.claude/hooks/. The plugin channel registers hooks
# through the payload's own hooks.json using ${CLAUDE_PLUGIN_ROOT}, so any
# settings.json command naming .claude/hooks/ is registered through the
# SETTINGS channel rather than the plugin channel.
#
# THAT IS ALL THIS COUNTS, and the name says so. The predicate is a path match
# with no staleness term in it: on a machine that has not cut over yet, the
# entries it finds are six LIVE hooks doing their job, and calling them "stale"
# was a claim this function has no evidence for. Which channel a hook is
# registered through is a fact; whether that registration is redundant depends
# on the cutover, which is a later wave's business. Callers that want to say
# more must find the extra evidence themselves.
#
# THE PREDICATE AND THE PROGRAM ARE NAMED, not inline, because remove.sh's
# standalone door carries a second copy of both — legitimately, since that door
# has to run on the machine where these libraries are already gone. A copy that
# is entitled to exist still has to be pinned against its original — no test
# pins this since tests/remove.test.sh was deleted at 8582861. hooks.sh's
# header makes the same argument for the STRIP program; this is the other half
# of the same channel.
DETECT_LEGACY_HOOK_SUBSTR='.claude/hooks/'

DETECT_LEGACY_HOOK_COUNT_JQ='
  [ (.hooks // {}) | to_entries[] | .value[]? | .hooks[]?
    | .command? // empty
    | select(contains("'"${DETECT_LEGACY_HOOK_SUBSTR}"'")) ] | length
'

detect_legacy_channel_hooks() {
  local settings count
  settings="${BIONIC_SETTINGS_FILE:-${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/settings.json}"
  if ! command -v jq >/dev/null 2>&1; then
    echo "env:legacy-channel-hooks count=unknown"
    return 0
  fi
  if [ ! -f "$settings" ]; then
    echo "env:legacy-channel-hooks count=0"
    return 0
  fi
  count="$(jq "$DETECT_LEGACY_HOOK_COUNT_JQ" "$settings" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*) count=unknown ;;
  esac
  echo "env:legacy-channel-hooks count=${count}"
  return 0
}

# ─── The legacy installed skill copy ─────────────────────────────────────────
#
# The retired installer rendered bionic's skills into the CLI's OWN skills
# directory. The plugin ships the same skill inside its payload, so after the
# cutover the installed copy is a SECOND canonical-sdlc — and not an inert one.
# Epic-17 W5 (4/6) measured eleven hook-registration lines in that copy's
# frontmatter, every one of them spelled for the pre-plugin hooks directory: a
# session that loads it arms the same walls twice, once through the channel the
# cutover was supposed to have retired, and nothing in the output says so.
#
# ONE NAME, NOT A WILDCARD. The same installer left copies of bionic's other
# skills behind. 4/6 measured those as registering nothing, and what to do with
# them is the wave's close-out decision — a consented step reading a wildcard
# would remove directories nobody has decided about, which is a larger defect
# than the one it fixes. So the name is stated, and the caller offers exactly
# what this function found.
#
# THE PREDICATE IS THE DIRECTORY PLUS ITS SKILL.md. A bare directory of that
# name is not evidence of a rendered skill, and "present" is about to authorise
# a recursive delete: the file the installer always wrote is what makes the
# claim, not the directory alone.
DETECT_LEGACY_SKILL_NAME='canonical-sdlc'

detect_legacy_skill_copy() {
  local dir present=no
  dir="${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/skills/${DETECT_LEGACY_SKILL_NAME}"
  if [ -d "$dir" ] && [ -f "${dir}/SKILL.md" ]; then
    present=yes
  fi
  echo "env:legacy-skill-copy present=${present} path=${dir}"
  return 0
}

# ─── The legacy installed hook FILES ─────────────────────────────────────────
#
# THE OTHER HALF OF A QUESTION THIS LIBRARY ONLY ANSWERED HALFWAY. The retired installer
# copied every hooks/*.sh into the CLI's own hooks directory and then wired those copies
# into settings.json. `detect_legacy_channel_hooks` above counts the REGISTRATIONS. Nothing
# counted the FILES — so a machine cleaned of every registration and a machine still
# carrying eighteen scripts read identically in the report, and the second one is the one
# whose owner can SEE the directory. A diagnosis that does not mention what a person can
# see with `ls` is the kind a person stops believing.
#
# INERT IS NOT ABSENT, which is why this is worth a line of its own. With the registrations
# gone the files run nothing; they are disk, not behaviour. But they are also an OLDER BUILD
# of every wall this repo ships, sitting under a path that four eras of documentation told
# people to invoke, and the close-out that removes them needs to know they are there.
#
# PAYLOAD-SIDE NAMES ONLY — `detect_installed_agent_copies` states the rule and it binds
# here for a sharper reason: this count is read by a person deciding what to delete. A .sh
# in that directory the payload does not ship is somebody's OWN hook, and reporting it as
# bionic's leftover invites them to delete their own work. Over-reporting and under-
# reporting are not symmetric here, so the error is taken in the safe direction.
#
# `unknown` WHERE THE COMPARISON CANNOT BE MADE. A payload with no hooks/ directory gives
# nothing to match names against, and `0` there would report "nothing was left behind" about
# a machine nobody managed to look at — the same substitution of reassurance for measurement
# the integrity functions above refuse.
detect_legacy_hook_files() {
  local root dir f name count=0 names="" payload_total=0

  root="$(plugin_root)"
  dir="${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/hooks"

  for f in "${root}/hooks/"*.sh; do
    [ -f "$f" ] || continue
    payload_total=$((payload_total + 1))
  done
  if [ "$payload_total" = 0 ]; then
    echo "env:legacy-hook-files count=unknown path=${dir} names=- cause=this payload ships no hooks/ directory to match names against"
    return 0
  fi

  if [ -d "$dir" ]; then
    for f in "${root}/hooks/"*.sh; do
      [ -f "$f" ] || continue
      name="${f##*/}"
      if [ -f "${dir}/${name}" ]; then
        count=$((count + 1))
        names="${names}${names:+,}${name}"
      fi
    done
  fi

  echo "env:legacy-hook-files count=${count} path=${dir} names=${names:--}"
  return 0
}

# ─── The statusLine command still naming npx ─────────────────────────────────
#
# THE NETWORK-PER-RENDER DEFECT (epic-21, bug-ccstatusline-npx-per-render.md).
# `/bionic:setup` used to write `"command": "npx ccstatusline@latest"` into
# settings.json — a command Claude Code runs on EVERY status-line render, and
# `npx pkg@latest` resolves the version over the network before it can print
# anything (measured stalling 73s per render on a network with TLS
# interception). The fix installs the binary once and records its bare name,
# but nothing on a machine rewrites settings.json on its own — only a person
# re-running setup does — so a machine that ran setup before this fix stays
# broken until doctor names it.
#
# A READ, NEVER A REPAIR. This only reports the leading token of the recorded
# command; it never edits settings.json, the same rule every other detector in
# this file follows.
detect_statusline_npx_command() {
  local settings cmd present=no
  settings="$(_dep_settings_file)"
  if [ -f "$settings" ] && _dep_have jq; then
    cmd="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
    case "$cmd" in npx\ *) present=yes ;; esac
  fi
  echo "env:statusline-npx-command present=${present}"
  return 0
}

# ─── The legacy installed agent role files ───────────────────────────────────
#
# The same installer copied the six rendered role files into the CLI's own
# agents directory. Role files are instructions a dispatched subagent obeys, so
# a machine carrying installed copies can be running a build of its own
# dispatch discipline that no plugin update will ever reach — the payload moves,
# the copies do not, and nothing else on the machine reports the gap.
#
# THIS IS THE OTHER QUESTION FROM `detect_agent_integrity`, and the two are
# easy to confuse. That one asks whether the PAYLOAD's files still match the
# checksums the payload shipped: a local-edit question, answered inside the
# plugin. This one asks whether a SECOND, older set exists outside the plugin
# at all. A machine can be perfectly stock by the first measure and two builds
# behind by this one.
#
# DIGESTED, NOT DIFFED, and through the same `_detect_sha256` the integrity
# function uses. A direct `cmp` would have been simpler to read and would have
# added a tool this library does not otherwise require — measured absent from
# the hermetic suite's own PATH, which is the fixture standing in for a machine
# that lacks it. Reusing the digest helper means one dependency for both agent
# questions and one `unknown` arm, phrased the same way, when it is missing.
#
# TWO UNKNOWNS, both real: no digest tool, and a payload with no agents/
# directory to compare against. Answering `absent` for either would report the
# state this function exists to detect as the state it exists to reassure about.
detect_installed_agent_copies() {
  local root dir f name total=0 drift=0 names="" payload_total=0 want got

  root="$(plugin_root)"
  dir="${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/agents"

  for f in "${root}/agents/"*.md; do
    [ -f "$f" ] || continue
    payload_total=$((payload_total + 1))
  done
  if [ "$payload_total" = 0 ]; then
    echo "env:installed-agents state=unknown total=0 drift=0 names=- cause=this payload ships no agents/ directory to compare against"
    return 0
  fi
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "env:installed-agents state=unknown total=0 drift=0 names=- cause=neither shasum nor sha256sum is on PATH, so the installed copies cannot be compared"
    return 0
  fi

  if [ ! -d "$dir" ]; then
    echo "env:installed-agents state=absent total=0 drift=0 names=- cause=-"
    return 0
  fi

  # Payload-side names only. A file in the installed directory that the payload
  # does not ship is somebody else's agent, not bionic's leftover, and counting
  # it would report a machine's own work as bionic drift.
  for f in "${root}/agents/"*.md; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    [ -f "${dir}/${name}" ] || continue
    total=$((total + 1))
    want="$(_detect_sha256 "$f")"           || want=""
    got="$(_detect_sha256 "${dir}/${name}")" || got=""
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
      drift=$((drift + 1))
      names="${names:+${names},}${name}"
    fi
  done

  if [ "$total" = 0 ]; then
    echo "env:installed-agents state=absent total=0 drift=0 names=- cause=-"
  else
    echo "env:installed-agents state=present total=${total} drift=${drift} names=${names:--} cause=-"
  fi
  return 0
}

# ─── Plugin registration ─────────────────────────────────────────────────────
#
# Is bionic registered with the CLI on this machine? This is the fact that says
# whether the PLUGIN channel is live, and it is not the same question as
# `detect_plugin_integrity`, which asks whether a payload tree is on disk and
# well-formed: a machine can carry a perfectly good payload the CLI has never
# been told about, and that machine is exactly the one every user is on before
# the cutover.
#
# It matters to more than the half-uninstall verdict. Anything that offers to
# REMOVE a settings-channel registration is implicitly claiming the plugin
# channel covers what it removes, and that claim is only true when this fact
# says yes — setup's step 6 promised it unconditionally until this line existed
# for it to read.
#
# `unknown` is a real answer, not a hedge. A registry file that is present and
# unparseable supports neither "yes" nor "no", and both lies are expensive in
# opposite directions: `no` tells a covered user their hooks will stop firing,
# `yes` tells an uncovered one they are safe to delete their only enforcement.
# A registry that is simply ABSENT is a different case — the CLI writes that
# file when it installs anything, so its absence means nothing is installed.
# The registry file, named ONCE. Both the registration fact and the root resolver below
# read it through this expression, so a machine whose config dir moves cannot have the two
# answering about different files — the drift that makes a "registered" plugin resolve to a
# root nobody installed.
_detect_installed_plugins_file() {
  printf '%s' "${BIONIC_INSTALLED_PLUGINS_FILE:-${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/plugins/installed_plugins.json}"
}

# The marketplace REGISTRATION file, a sibling of the plugin one above and named the
# same way. `known_marketplaces.json` is keyed by marketplace NAME, and that name is
# not fixed to the literal `bionic` — it is whatever marketplace this particular
# install's feed was registered under, which `_detect_marketplace_name` below reads
# out of the plugin registry rather than assuming. Each entry's `source.source` is the
# CLI's own record of how that feed was registered: `"directory"` for a local checkout
# (what a dogfood install is) or a git kind (`"github"`, `"url"`, …) for anything
# fetched from a repo. `detect_reconverge_hint` below is the one caller.
_detect_known_marketplaces_file() {
  printf '%s' "${BIONIC_KNOWN_MARKETPLACES_FILE:-${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/plugins/known_marketplaces.json}"
}

# THE MARKETPLACE NAME THIS INSTALL ACTUALLY CAME FROM (L-DETECT/4.1, AC-18). Bugfix:
# `detect_marketplace_feed_kind` used to key `known_marketplaces.json` on the literal
# string `bionic`, which is merely bionic's OWN marketplace's usual name — a fork
# registered under any other name (`bionic@my-fork`) has no `bionic` entry in that
# file at all and read `unknown` forever, on a machine whose registry carries every
# fact needed to answer correctly.
#
# THE ORACLE IS installed_plugins.json, the same file `_detect_registry_install_path`
# reads: its keys are `<plugin-name>@<marketplace-name>`, so the marketplace name for
# THIS install is the suffix of whichever key's plugin-name half is `bionic` — the
# same `split("@")` shape `DETECT_PLUGIN_ROOT_JQ` already keys on, one field over.
#
# `bionic` IS STILL THE FALLBACK, not a magic string. When the registry is missing,
# unparsable, or names no `bionic` entry, this returns the literal `bionic` rather
# than propagating a failure into the feed-kind lookup — that is the CLI's documented
# public marketplace name (README.md) and the correct guess for the overwhelmingly
# common case, exactly the same "unknown defaults to the safer common case" posture
# `detect_reconverge_hint` already documents for the neighboring question.
DETECT_MARKETPLACE_NAME_JQ='.plugins // {} | keys[] | select(split("@")[0] == "bionic") | split("@")[1] // empty'

_detect_marketplace_name() {
  local reg name
  reg="$(_detect_installed_plugins_file)"
  [ -f "$reg" ] || { printf 'bionic\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'bionic\n'; return 0; }
  name="$(jq -r "$DETECT_MARKETPLACE_NAME_JQ" "$reg" 2>/dev/null | head -1)"
  case "$name" in ''|null) printf 'bionic\n' ;; *) printf '%s\n' "$name" ;; esac
  return 0
}

# WHICH FEED BIONIC CAME FROM, answered the same oracle-not-guess way as the install
# path above: the file the CLI itself wrote when the marketplace was registered, read
# once, here, under the marketplace name THIS install is actually registered under
# (`_detect_marketplace_name`, immediately above — not a literal). `directory` on a
# local-checkout feed, `git` on anything fetched from a repo, `unknown` when the file
# is missing, unparsable, or names no entry for that marketplace — `jq`-less machines
# get `unknown` too rather than a hand-rolled second reading, since this only feeds an
# advisory hint and a wrong guess there is worse than an honest one.
detect_marketplace_feed_kind() {
  local mp name kind
  mp="$(_detect_known_marketplaces_file)"
  [ -f "$mp" ] || { printf 'unknown\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  name="$(_detect_marketplace_name)"
  kind="$(jq -r --arg n "$name" '.[$n].source.source // empty' "$mp" 2>/dev/null)"
  case "$kind" in
    directory) printf 'directory\n' ;;
    ''|null)   printf 'unknown\n' ;;
    *)         printf 'git\n' ;;
  esac
  return 0
}

detect_plugin_registered() {
  local installed_json count
  installed_json="$(_detect_installed_plugins_file)"

  if [ ! -f "$installed_json" ]; then
    echo "plugin:registered=no"
    return 0
  fi

  # No jq: the key is a literal string in the file, so grep answers this one
  # honestly rather than degrading. `"bionic@` cannot match another plugin —
  # the marketplace suffix follows the name, never precedes it.
  if ! command -v jq >/dev/null 2>&1; then
    if grep -q '"bionic@' "$installed_json" 2>/dev/null; then
      echo "plugin:registered=yes"
    else
      echo "plugin:registered=no"
    fi
    return 0
  fi

  count="$(jq -r '[ (.plugins // {}) | keys[] | select(split("@")[0] == "bionic") ] | length' \
            "$installed_json" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*) echo "plugin:registered=unknown" ;;
    0)           echo "plugin:registered=no" ;;
    *)           echo "plugin:registered=yes" ;;
  esac
  return 0
}

# ─── THE PARSE ──────────────────────────────────────────────────────────────
#
# ONE reading of the registry's schema, for ANY plugin name. Generalized at W5 Step-6
# (review RV-4/RV-7): doctor.sh had grown a second, unpinned parse of the same CLI-internal
# shape, and the pinned one — detect_plugin_root — had no production callsite at all, so the
# copy under test was the copy that did not run. Two readings of a schema we do not own is
# the exact duplication this file's ownership rule exists to forbid: the CLI renames
# `installPath`, one of them gets fixed, and the other keeps answering in the old shape with
# no less confidence.
#
# QUIET, DELIBERATELY, and this is the one place this file's posture splits by CALLER rather
# than by fact. Loudness is a claim about CONSEQUENCE, not about failure. Asking where
# `superpowers` landed and finding it absent is an ORDINARY answer that `/bionic:doctor`
# renders in a table cell twenty times a run; a parse that shouted it would bury the report
# on exactly the half-configured machine the report exists for. So the parse says nothing and
# the SPECIALIZATION below — bionic's own, feeding a path something is about to execute —
# carries the three-line refusal and the named fix.
#
# THE EXIT CODE CARRIES WHAT THE STDERR NO LONGER DOES, so no distinction was lost in the
# move; detect_plugin_root rebuilds its three refusal messages from these:
#
#   0  resolved; the absolute installPath is on stdout
#   2  no registry file at all
#   3  no entry for this name, or the registry could not be parsed
#   4  the entry is there and names a directory that does not exist
#
# THE TWO JQ PROGRAMS ARE ONE PROGRAM. `DETECT_PLUGIN_ROOT_JQ` below stays a bionic-shaped
# one-line literal because it is also the DOCTRINE SEED: skills/canonical-sdlc/SKILL.md
# carries it verbatim for a model to paste at Patrol arming, which is the one moment nothing
# in this file can be sourced yet (resolving the plugin root is precisely what you cannot do
# from inside the plugin). `--arg n` is not pasteable, so the literal cannot simply become
# the general form. tests/dispatch-spans.test.sh §5i used to read it out of here with a `sed`
# that required exactly that spelling (that suite was deleted in an earlier purge, commit
# b959b5e), and tests/plugin-lib.test.sh Group S used to pin the literal to be this general
# program with `$n` bound to "bionic" and nothing else (deleted at 8582861, epic-18 wave-03).
# Neither pin survives; the seed's spelling could now drift to a THIRD parse unnoticed.
DETECT_PLUGIN_INSTALL_PATH_JQ='.plugins // {} | to_entries[] | select(.key | split("@")[0] == $n) | .value[0].installPath // empty'
DETECT_PLUGIN_ROOT_JQ='.plugins // {} | to_entries[] | select(.key | split("@")[0] == "bionic") | .value[0].installPath // empty'

# The raw reading: what the registry RECORDS for this name, with no claim that the
# directory is there. Split out from the public function for one reason — the refusal
# detect_plugin_root prints when a recorded tree has vanished has to NAME the path it could
# not find, and the public function deliberately hands back nothing in that case. One parse,
# two questions: "what is written down" and "is it true".
_detect_registry_install_path() {  # <plugin-name>
  local name="${1:-}" reg path

  [ -n "$name" ] || return 3

  reg="$(_detect_installed_plugins_file)"
  [ -f "$reg" ] || return 2

  if command -v jq >/dev/null 2>&1; then
    path="$(jq -r --arg n "$name" "$DETECT_PLUGIN_INSTALL_PATH_JQ" "$reg" 2>/dev/null | head -1)"
  else
    # No jq: the key is a literal string in the file, and the marketplace suffix follows the
    # name rather than preceding it, so `"<name>@` is a whole-name match — `superpowers-extras@`
    # does not carry the `@` in that position. `index()` and not a regex, on purpose: a plugin
    # name is someone else's string and a `.` or `+` in it must be a character, not a
    # metacharacter. The first installPath after the key is this entry's; `exit` stops before
    # the next plugin's.
    path="$(awk -v key="\"${name}@" '
      index($0, key) { f = 1 }
      f && /"installPath"/ {
        line = $0
        sub(/.*"installPath"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*/, "", line)
        print line
        exit
      }' "$reg" 2>/dev/null)"
  fi

  case "$path" in
    ''|null) return 3 ;;
  esac

  printf '%s\n' "$path"
  return 0
}

detect_plugin_install_path() {  # <plugin-name>
  local path st
  path="$(_detect_registry_install_path "${1:-}")"; st=$?
  [ "$st" -eq 0 ] || return "$st"
  [ -d "$path" ] || return 4
  printf '%s\n' "$path"
  return 0
}

# ─── The installed plugin root ───────────────────────────────────────────────
#
# WHERE THE PLUGIN ACTUALLY IS, answered out of the CLI's own record rather than guessed.
# Bionic's specialization of the parse above; the reading is shared, the POSTURE is this
# function's own.
#
# THE PROBLEM THIS RETIRES. Payload-native scripts are typed into a model's own shell as
# often as they are registered as commands, and `${CLAUDE_PLUGIN_ROOT}` is substituted only
# in the latter. The old spelling covered the gap with `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}`
# — which always resolves, and resolves to a bootstrap-era copy that can be an OLDER BUILD
# than the plugin the CLI loaded. A stale hook that runs is worse than a missing one: it
# enforces a doctrine nobody is following and reports success doing it.
#
# THE ORACLE IS THE REGISTRY, ratified 2026-08-19 (design ledger D-B). Not because we own
# it — we do not, its schema is CLI-internal — but because it is the record the CLI's own
# install wrote, which is the only property that makes an answer here true.
#
# AND THAT HOLDS BY TWO DIFFERENT ROUTES, which is worth a sentence because the difference
# is what a stale-looking root turns on (measured W5 S7 §4.1/4.2). On a GIT-SOURCE feed —
# the public install — the cache directory the registry names is exactly what the CLI
# loads, so the registry is right by construction. On a DIRECTORY-SOURCE MARKETPLACE — a
# local checkout registered as a feed, which is what every dogfood install is — the CLI
# reads the marketplace SOURCE tree and never opens that cache at all; the two are the same
# build only as of the last (re)install, and a reinstall is what re-converges them. The
# answer this function gives is correct on both paths. What differs is what a divergence
# means: on the first there cannot be one, on the second it means the source tree has moved
# since the install.
#
# The schema being someone else's is why the parse is pinned by tests and why an unreadable
# file REFUSES instead of degrading.
#
# THIS IS THE ONE FUNCTION IN THIS FILE THAT DOES NOT ANSWER `unknown`, and the deviation is
# the point. Every other fact here feeds a REPORT, where "I could not tell" is a legitimate
# and useful value. This one feeds a PATH that something is about to execute, and there is
# no honest degraded form of that: a caller handed a plausible directory cannot tell it
# apart from a resolved one. So the contract is: the absolute installPath on stdout and exit
# 0, or NOTHING on stdout, a named fix on stderr, and exit 1. No fallback exists anywhere in
# this function, deliberately — including the one it was written to replace.

# THE REFUSAL IS A LINE FOR A PERSON. It used to open `detect_plugin_root: REFUSED — …`,
# which names this function and an internal verdict word at whoever ran /bionic:setup —
# the same class the three payload scripts have had banned since W6 S11, found live here
# by S12's own vocabulary sweep (§6 hit #4, A-6.6 (a)). The line now says what is wrong
# and what to do; the exit code and the empty stdout, which are what the CALLERS read, are
# untouched. Used to be pinned by tests/plugin-lib.test.sh Group R against the shared banned
# list; that suite was deleted at 8582861 (epic-18 wave-03) and nothing replaced the pin.
_detect_plugin_root_refuse() {  # <what went wrong>
  echo "bionic could not find its own installed files — $1" >&2
  echo "  Fix: claude plugin install bionic@bionic" >&2
  echo "  bionic will not guess a location instead: a guessed one can be an older copy than" >&2
  echo "  the plugin your session is running, and a stale copy that runs is worse than none." >&2
  return 1
}

detect_plugin_root() {
  local root st reg

  # The refusals name the file and the path, so the registry expression is re-read here for
  # the MESSAGE only — never for a second answer. The parse below is the only reading that
  # decides anything.
  reg="$(_detect_installed_plugins_file)"

  root="$(detect_plugin_install_path bionic)"
  st=$?
  [ "$st" -eq 0 ] && { printf '%s\n' "$root"; return 0; }

  case "$st" in
    2) _detect_plugin_root_refuse "no plugin registry at ${reg} — bionic is not installed." ;;
    4) _detect_plugin_root_refuse "the registry names $(_detect_registry_install_path bionic) as bionic's install path, and no such directory exists — the install is broken or half-removed." ;;
    *) _detect_plugin_root_refuse "no bionic entry in ${reg}, or the registry could not be read — bionic is not installed." ;;
  esac
  return 1
}

# ─── The installed build vs this repo's tip ──────────────────────────────────
#
# WHICH COMMIT IS ACTUALLY RUNNING, asked of a machine that is developing the plugin it is
# running. The CLI records the commit each install came from (`gitCommitSha`); a checkout
# knows its own HEAD; nothing until now compared them. Epic-17 W5 paid for that twice —
# once at Step 5 and again at the Step-6 tip, 20 files apart — with a green suite, green
# walls and a doctor reporting a healthy machine each time, because every one of those
# reads the REPO while the harness runs the INSTALL.
#
# REPORTS, NEVER POLICES — the posture of the agent-files line, and for the same reason: an
# install behind the tip is a completely ordinary state (you have not reinstalled since your
# last commit), and a doctor that treated it as a fault would cry wolf on every developer
# machine between two commits. So: one line, four states, no exit-code effect, no repair.
#
# `unknown` IS THE ORDINARY ANSWER FOR ORDINARY USERS, and it is correct rather than
# apologetic. Installed from the public feed, there is no repo to compare against, and the
# question genuinely has no answer here. Every `unknown` carries its cause, like every
# other one in this file.
#
# TWO STATES FOR "NOT THE TIP", because they take different actions. `lag` — the recorded
# sha IS a commit in this repo — means reinstall and you are current. `not-in-repo` means
# the installed build came from somewhere this checkout has never seen, and reinstalling
# would change what is running rather than refresh it.
#
# NO jq, NO ANSWER: unlike the installPath parse, there is no awk fallback here. That one
# has a caller that must resolve a PATH or refuse; this one feeds a report line, where
# `unknown` with a named cause is a legitimate value and a second hand-rolled reading of
# someone else's schema is not worth its weight.
DETECT_PLUGIN_SHA_JQ='.plugins // {} | to_entries[] | select(.key | split("@")[0] == $n) | .value[0].gitCommitSha // empty'

detect_registry_sha_lag() {  # [<repo-dir>] -> one line, always exit 0
  local dir="${1:-$PWD}" reg sha head

  reg="$(_detect_installed_plugins_file)"
  if [ ! -f "$reg" ]; then
    echo "plugin:registry-sha state=unknown registry=- repo=- cause=no plugin registry at ${reg}"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "plugin:registry-sha state=unknown registry=- repo=- cause=jq is not on PATH, so the registry cannot be read"
    return 0
  fi

  sha="$(jq -r --arg n bionic "$DETECT_PLUGIN_SHA_JQ" "$reg" 2>/dev/null | head -1)"
  case "$sha" in
    ''|null)
      echo "plugin:registry-sha state=unknown registry=- repo=- cause=the registry's bionic entry records no gitCommitSha"
      return 0 ;;
  esac

  if ! command -v git >/dev/null 2>&1; then
    echo "plugin:registry-sha state=unknown registry=${sha} repo=- cause=git is not on PATH, so this tree's tip cannot be read"
    return 0
  fi

  head="$( cd "$dir" 2>/dev/null && git rev-parse HEAD 2>/dev/null )"
  case "$head" in
    ''|*[!0-9a-f]*)
      echo "plugin:registry-sha state=unknown registry=${sha} repo=- cause=not run inside a git repository, so there is no tip to compare against"
      return 0 ;;
  esac

  if [ "$head" = "$sha" ]; then
    echo "plugin:registry-sha state=match registry=${sha} repo=${head} cause=-"
  elif ( cd "$dir" 2>/dev/null && git cat-file -e "${sha}^{commit}" 2>/dev/null ); then
    echo "plugin:registry-sha state=lag registry=${sha} repo=${head} cause=-"
  else
    echo "plugin:registry-sha state=not-in-repo registry=${sha} repo=${head} cause=-"
  fi
  return 0
}

# ONE OWNER FOR THE RE-CONVERGE SENTENCE (epic-17 W7 S2/S2b, AC-3). `claude plugin
# install <id>` is the CLI's FIRST-time verb — on an id already registered it reports
# "already installed" and does not refresh anything, so `update` is the re-converge verb
# on a feed where the cache is what runs. That is true on a GIT-SOURCE feed, where the
# cache the registry names is exactly what the CLI loads. It is NOT true on a
# DIRECTORY-SOURCE marketplace (a local checkout registered as a feed, which is what a
# dogfood install is): there `${CLAUDE_PLUGIN_ROOT}` resolves to the tree itself, the
# cache is a side artifact nothing reads, and `update` at an unchanged plugin.json
# version reports "already at the latest version" and touches nothing — measured
# 2026-08-21, `.bionic/docs/record/epic-17-w7/ac2-relay-drive.md`. So S2's single literal
# was right for one feed and false for the other; this stays the one function every site
# that reports this state reads, and it now answers per feed instead of by one guess.
# Sites that report bionic NOT INSTALLED at all keep `install` — that is the correct
# first-time verb for them and stays a separate, uncoupled literal (setup.sh, remove.sh,
# detect_plugin_root_refuse above). `unknown` feed kind (registry unreadable, no `jq`,
# no bionic entry) defaults to the git-source line: that is the CLI's documented public
# install path (README.md), so a wrong guess there is the rarer, safer failure.
#
# A WHOLE SENTENCE, PER FEED AND PER STATE (epic-17 W7 S11, six-axis review axis 2).
# This used to return a FRAGMENT and let each caller frame it, and the framing was
# wrong at both callers. doctor's lag line printed `… the cache copy is behind this
# tree, which the CLI runs — nominal; re-converge with: nothing to do — the CLI runs
# this tree directly; …`: the same clause twice, and a prefix promising a command in
# front of the words "nothing to do". Its hook-wiring line printed the fragment in
# BACKTICKS, so a directory-source machine with genuinely broken wiring was handed
# "nothing to do" formatted as something to type.
#
# Two different states ask this question and they do not have one answer. On a
# directory source a lagging copy is NOMINAL — the CLI reads the tree, not the copy —
# but broken hook wiring in that same tree is real, and telling that user nothing is
# to be done would be false. So the state is an argument, the answer is a finished
# clause, and the callers print it with nothing in front of it.
#
# SHORTENED TO FIT THE LINE IT RIDES ON (epic-18 T7, spec AC-15). All four answers
# were two-clause sentences ending in "then re-run /bionic:doctor", which put
# doctor's own installed-commit row at 209 columns on a real machine — three
# wrapped lines for one fact, which is the complaint AC-15 exists to answer. Each
# now says the one thing a reader acts on, and the caller's line stays inside 100
# columns. Nothing actionable was dropped: the command is still named verbatim
# where there is one, and re-running doctor after a repair needed saying once, not
# in every hint.
detect_reconverge_hint() {  # <lag|hooks> -> the whole sentence for that state, on this feed
  local state="${1:-lag}"
  case "$(detect_marketplace_feed_kind)" in
    directory)
      case "$state" in
        hooks)
          printf 'repair hooks.json in this tree — the CLI reads this tree, not the copy\n' ;;
        *)
          printf 'nominal, the CLI runs this tree\n' ;;
      esac ;;
    *)
      case "$state" in
        hooks)
          printf 'the installed copy is what the CLI reads — claude plugin update bionic@bionic\n' ;;
        *)
          printf 'claude plugin update bionic@bionic\n' ;;
      esac ;;
  esac
}

# ─── Installed vs the marketplace's latest (git-feed installs only) ──────────
#
# THE GENUINE ABSENCE THIS CLOSES (F5, epic-19 wave-01, spec AC-F5; grounding
# item 5, record/epic-19/step1-fixes-grounding.md, found no plugin-version-vs-
# latest check anywhere in the shipped surface). On a GIT-SOURCE feed the CLI
# already keeps a cached clone of the marketplace repo at
# `known_marketplaces.json`'s `installLocation` — that clone IS the CLI's own
# record of what the marketplace currently offers, so reading its
# `plugin.json` answers "what's latest" from a file already on disk. No
# network fetch, no timeout to design, no request that can hang doctor —
# exactly the local-registry route the epic's grounding preferred over a live
# check (detect_reconverge_hint's `installLocation`/`gitCommitSha` reads are
# the precedent this follows).
#
# NOT FOR DIRECTORY FEEDS, and this function does not self-guard that: on a
# directory-source marketplace `installLocation` names the SAME tree the CLI
# already runs (detect_reconverge_hint's doctrine, above), so comparing its
# plugin.json against itself would report "current" unconditionally and
# answer nothing. Callers branch on `detect_marketplace_feed_kind` themselves
# and reach for `detect_registry_sha_lag` + `detect_reconverge_hint` on that
# feed instead (doctor.sh's version row does exactly this) — a caller that
# gets the branch wrong fails LOUD, as an always-"current" row, rather than
# silently degrading to `unknown`.
#
# A CACHED ANSWER, NOT A LIVE ONE. The clone updates on `claude plugin
# marketplace update` (or a fresh install), not on every doctor run, so a
# `lag` verdict here can also mean "the cache itself is stale" — one layer
# removed from "you are behind the true latest". That is still strictly more
# honest than no check at all, and it costs zero network round-trips.
DETECT_MARKETPLACE_SOURCE_JQ='.plugins[]? | select(.name == $n) | .source // empty'

# A SEMVER-SHAPED ORDERING PRIMITIVE (L-DETECT/4.2, bugfix, AC-19). `detect_
# plugin_latest` below used to decide "current" or "lag" by STRING inequality —
# `[ "$installed" = "$latest" ]`, unconditionally else `lag` — so an installed
# build NEWER than the marketplace's cached clone (a developer's own tree,
# ahead of the last published release) was reported as behind it. Three
# states, not two: `ahead`, `current`, `lag`.
#
# THREE INTEGERS, LEXICAL DRIFT REFUSED. String comparison would rank `1.10.0`
# behind `1.9.0` — `"1"` ties, then `"1"` (from "10") sorts before `"9"` — which
# is exactly the class of bug this primitive exists to retire. Each side is
# read as major.minor.patch and compared numerically, most-significant field
# first.
#
# A PRERELEASE SUFFIX COMPARES BY ITS RELEASE NUMBERS. `9.9.9-rc.1` and
# `10.0.0` differ from their first non-digit-non-dot character onward; the
# suffix is dropped for ordering purposes rather than parsed, the same
# tolerance `detect_plugin_latest`'s shape guard already extends to a version
# carrying letters and dashes.
#
# MISSING OR NON-NUMERIC FIELDS READ AS ZERO. Neither caller today hands this
# anything but a validated, version-shaped token, but a partial one (`"1.4"`)
# should order by what it has rather than fail outright — `1.4` vs `1.4.0` is
# `current`, not a crash.
version_compare() {  # <a> <b> -> ahead|current|lag
  local a="${1:-}" b="${2:-}" a_rest b_rest a1 a2 a3 b1 b2 b3

  a_rest="${a%%[!0-9.]*}"
  b_rest="${b%%[!0-9.]*}"
  a1="${a_rest%%.*}"; a_rest="${a_rest#*.}"
  a2="${a_rest%%.*}"; a_rest="${a_rest#*.}"
  a3="${a_rest%%.*}"
  b1="${b_rest%%.*}"; b_rest="${b_rest#*.}"
  b2="${b_rest%%.*}"; b_rest="${b_rest#*.}"
  b3="${b_rest%%.*}"

  case "$a1" in ''|*[!0-9]*) a1=0 ;; esac
  case "$a2" in ''|*[!0-9]*) a2=0 ;; esac
  case "$a3" in ''|*[!0-9]*) a3=0 ;; esac
  case "$b1" in ''|*[!0-9]*) b1=0 ;; esac
  case "$b2" in ''|*[!0-9]*) b2=0 ;; esac
  case "$b3" in ''|*[!0-9]*) b3=0 ;; esac

  if   [ "$a1" -gt "$b1" ]; then printf 'ahead\n'
  elif [ "$a1" -lt "$b1" ]; then printf 'lag\n'
  elif [ "$a2" -gt "$b2" ]; then printf 'ahead\n'
  elif [ "$a2" -lt "$b2" ]; then printf 'lag\n'
  elif [ "$a3" -gt "$b3" ]; then printf 'ahead\n'
  elif [ "$a3" -lt "$b3" ]; then printf 'lag\n'
  else printf 'current\n'
  fi
  return 0
}

detect_plugin_latest() {  # -> one line, always exit 0
  local mp loc mp_json source_field plugin_json latest fact installed

  if ! command -v jq >/dev/null 2>&1; then
    echo "plugin:latest state=unknown installed=- latest=- cause=jq is not on PATH, so the marketplace clone cannot be read"
    return 0
  fi

  mp="$(_detect_known_marketplaces_file)"
  if [ ! -f "$mp" ]; then
    echo "plugin:latest state=unknown installed=- latest=- cause=no marketplace registry at ${mp}"
    return 0
  fi

  loc="$(jq -r '.bionic.installLocation // empty' "$mp" 2>/dev/null)"
  if [ -z "$loc" ]; then
    echo "plugin:latest state=unknown installed=- latest=- cause=known_marketplaces.json has no bionic entry"
    return 0
  fi

  mp_json="${loc}/.claude-plugin/marketplace.json"
  if [ ! -f "$mp_json" ]; then
    echo "plugin:latest state=unknown installed=- latest=- cause=no marketplace.json in the cached clone at ${loc}"
    return 0
  fi

  source_field="$(jq -r --arg n bionic "$DETECT_MARKETPLACE_SOURCE_JQ" "$mp_json" 2>/dev/null | head -1)"
  case "$source_field" in
    ''|null)
      echo "plugin:latest state=unknown installed=- latest=- cause=marketplace.json names no bionic plugin entry"
      return 0 ;;
    \{*)
      # A source OBJECT (url/github kind) names a SEPARATE repo this clone does
      # not itself contain — bionic's own manifest uses a plain relative path
      # ("./payload") because the plugin ships from the same repo as the
      # marketplace; a fork that re-points the plugin at another repo has no
      # local answer without a second fetch.
      echo "plugin:latest state=unknown installed=- latest=- cause=bionic's marketplace entry names a separate-repo source; no local clone to read"
      return 0 ;;
  esac

  plugin_json="${loc}/${source_field#./}/.claude-plugin/plugin.json"
  if [ ! -f "$plugin_json" ]; then
    echo "plugin:latest state=unknown installed=- latest=- cause=no plugin.json at ${plugin_json}"
    return 0
  fi

  latest="$(jq -r '.version // empty' "$plugin_json" 2>/dev/null)"
  if [ -z "$latest" ]; then
    echo "plugin:latest state=unknown installed=- latest=- cause=the marketplace's plugin.json has no version field"
    return 0
  fi
  # THE ONE FIELD ON THIS PAGE THAT COMES OUT OF SOMEBODY ELSE'S FILE AND IS
  # PRINTED VERBATIM. It reaches doctor's FIX section and, from there, a relayed
  # block a person is invited to paste from. This line's own grammar is
  # `key=value` separated by spaces, and every reader of it splits on that — so
  # a `version` carrying a space, a newline or a backtick does not need an
  # author with bad intent to fabricate a second fact line or break out of a
  # fence; a typo in a fork's manifest does it. A version is a short token of
  # digits, letters, dots and dashes. Anything else is not a version bionic can
  # report, and `unknown` with a cause is the honest answer — the same answer
  # every other unreadable input on this page gets.
  case "$latest" in
    *[!0-9A-Za-z.-]*|????????????????????????????????*)
      echo "plugin:latest state=unknown installed=- latest=- cause=the marketplace's plugin.json version is not a version-shaped token"
      return 0 ;;
  esac

  fact="$(detect_plugin_integrity)"
  installed="${fact#plugin: version=}"; installed="${installed%% *}"
  case "$installed" in
    ''|unknown)
      echo "plugin:latest state=unknown installed=- latest=${latest} cause=the installed plugin's own version could not be read"
      return 0 ;;
  esac

  echo "plugin:latest state=$(version_compare "$installed" "$latest") installed=${installed} latest=${latest} cause=-"
  return 0
}

# ─── Bounded execution ───────────────────────────────────────────────────────
#
# THE THINGS BIONIC RUNS THAT IT DOES NOT CONTROL. Almost every fact in this file
# is a file read. A few are other people's programs — the CLI, Homebrew, npm —
# and any of them can wedge: a network mirror that never answers, a package
# manager waiting on its own lock, a CLI mid-update. Unbounded, whatever asked
# the question wedges with them.
#
# ONE OWNER, TWO CALLERS (epic-17 W6 S11, critic F-3). This lived in doctor.sh,
# so doctor's plugin listing was bounded and setup's — the SAME probe, the same
# `claude plugin list` — was not. Setup is the command a stranger runs first, and
# it ran it after the install with the report half-printed, where a wedge is
# indistinguishable from a crash. A bound that only one of two callers has is a
# bound the product does not have, so it lives here now, beside the probe, and
# both scripts call it.
#
# ONE MECHANISM, ONE BOUND: a background job in its own process group, plus a
# poll that signals the group when the limit is up. It runs shell functions and
# external commands alike, which `timeout(1)` cannot, and it reaches a forked
# grandchild, which `timeout(1)` also cannot — see `detect_bounded` below for
# why that second one is the difference between a bound and a bound that binds.
#
# KILLING IS THE POINT, so the child is started in a way that can be killed AND
# in a way that cannot hold the caller open: its stdout is a file this function
# reads afterwards — never the caller's command-substitution pipe — and its stdin
# is closed, so a probe can never eat the answer to a question the caller asks
# later.
#
# NO `sleep`, NO BOUND — deliberately, and stated rather than hidden. On a
# machine so bare that coreutils is missing, waiting on the probe is a better
# failure than spinning a hot loop against it.
#
# THE SEAM KEEPS ITS NAME. `BIONIC_DOCTOR_PROBE_SECONDS` was named when doctor
# was the only caller. It is cited by the Step-5 captures and by the suites that
# accelerate it, and renaming it would invalidate evidence to buy nothing a
# reader of this file cannot see in one line.
detect_probe_seconds() { echo "${BIONIC_DOCTOR_PROBE_SECONDS:-15}"; }

# WHAT A BOUND OWES, AND THE HALF THE FIRST CUT DID NOT PAY (six-axis review C-1).
# A bound has to release the CALLER on time, not merely stop waiting on its own
# child. The first cut did the second only, and the two come apart on exactly the
# shape both real probes have: `brew` is a shell script that runs Ruby, `npm` a
# shim that runs node. The child forks a grandchild, the grandchild inherits the
# stdout it was started with — the caller's `$(…)` pipe — and killing the child
# leaves that pipe open. Measured: `rc=124 elapsed=45s` against a three-second
# bound. The row said "not checked" honestly and printed it forty-two seconds late.
#
# SO THE PROBE NEVER WRITES TO THE CALLER'S PIPE. Its stdout goes to a file that
# this function alone reads, after the wait is over: whatever the grandchild does
# next, it does to a file nobody is waiting on. That is what makes the bound bind.
#
# AND THE GROUP IS WHAT GETS SIGNALLED. `set -m` puts the job in a process group
# of its own (pgid == pid), so `kill -TERM -$pid` reaches the grandchild too and
# a probe that timed out is not left running on the machine afterwards. Monitor
# mode is restored immediately: it is on for the launch, not for the script.
#
# ONE MECHANISM, NOT TWO. This used to hand external commands to `timeout` when
# one existed. `timeout(1)` signals the child and not the group, so it carries
# the same defect this function was just fixed for, and on bionic's platform it
# never ran at all (`command -v timeout` is empty on stock macOS). A second
# mechanism that cannot honour the contract is worse than no second mechanism.
# Supersedes A-4.S6.5's two-mechanism note.
#
# THE TEMPORARY FILE IS NOT A CHANGE TO THIS MACHINE. It lives under $TMPDIR,
# carries the pid so two callers cannot collide, and is removed as it is read.
# "Nothing on this machine is changed" is a claim about the user's configuration
# — settings, plugins, dependencies — and no probe output ever reaches one.
_DETECT_BOUND_SEQ=0

_detect_bound_read() {  # <file> — pass on what the probe managed to say, then forget it
  local file="${1:-}" payload
  # `$(<file)` is bash's own read: no `cat`, so a machine missing coreutils
  # still gets the probe's answer rather than an empty one.
  if [ -s "$file" ]; then payload="$(<"$file")"; printf '%s\n' "$payload"; fi
  rm -f "$file" 2>/dev/null || true
  return 0
}

detect_bounded() {  # <seconds> <command...> — passes stdout through; 124 on timeout
  local limit="${1:-15}"; shift
  local pid waited=0 rc out_file had_monitor

  _DETECT_BOUND_SEQ=$((_DETECT_BOUND_SEQ + 1))
  out_file="${TMPDIR:-/tmp}/bionic-probe.$$.${_DETECT_BOUND_SEQ}"
  : > "$out_file" 2>/dev/null || out_file="/dev/null"

  case "$-" in *m*) had_monitor=yes ;; *) had_monitor=no ;; esac
  set -m
  "$@" </dev/null > "$out_file" &
  pid=$!
  [ "$had_monitor" = "yes" ] || set +m

  if ! command -v sleep >/dev/null 2>&1; then
    wait "$pid"; rc=$?
    _detect_bound_read "$out_file"
    return $rc
  fi
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      # The group first — `-$pid` is the process group `set -m` gave this job —
      # and the bare pid as the fallback for a kernel that refused the group.
      kill -TERM "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      _detect_bound_read "$out_file"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  _detect_bound_read "$out_file"
  return $rc
}

# ─── Is the CLI actually LOADING us? ─────────────────────────────────────────
#
# THE FACT NOTHING IN THIS FILE COULD ANSWER UNTIL NOW, and the most expensive
# one to get wrong. Epic-17 W5's F12 measurement: `claude plugin install
# bionic@bionic` exits 0, prints a green success line, writes the registry entry
# — and if a dependency is missing the plugin loads NOTHING. No hook fires, no
# command exists, and the only surface on the whole machine that says so is
# `claude plugin list`. Four reproductions, all silent. Every other fact in this
# file was measured healthy on that machine while the plugin was completely
# inert, because they all read the REGISTRY and the registry was right: bionic
# was installed. Installed and loaded are two different questions.
#
# WHY A COMMAND AND NOT A FILE. The load decision is the CLI's, taken at session
# start from the dependency graph, and it is not written anywhere we can read.
# The listing is the CLI reporting its own conclusion, which makes it the only
# honest source — so this is the one fact function that SHELLS OUT.
#
# THE SEAM IS THE COMMAND ITSELF. `BIONIC_PLUGIN_LIST_CMD` (default
# `claude plugin list`), split on whitespace and executed as argv — not `eval`,
# which would make an env var a code-execution channel for no gain. The suite
# points it at captured CLI transcripts; production never sets it.
#
# UNRECOGNIZED IS `unknown`, NEVER `loaded` (plan A-3.2). This probe exists to
# be believed on a machine where everything else reads healthy, so the one
# failure it must never have is optimism: a parser that shrugs at an output it
# does not understand and calls it fine would report green on exactly the box
# that is broken. Three separate honesty gates below — the command must run, the
# output must be recognizable as a listing at all, and the status word must be
# one of the two we have actually seen — and every one of them falls to
# `unknown` with its cause named.
#
# ABSENT vs UNKNOWN is the distinction that gate two buys. "This listing is real
# and your plugin is not in it" and "I cannot tell what I am reading" are
# different answers with different fixes, and collapsing them would let a
# garbled listing masquerade as a clean uninstall.

detect_plugin_load_state() {  # <plugin-id> -> one line, always exit 0
  local id="${1:-}" cmd out st parsed rows found status err
  local -a argv=()

  if [ -z "$id" ]; then
    echo "load-state=unknown error=- cause=no plugin id was given"
    return 0
  fi

  # `${VAR-default}`, NOT `${VAR:-default}` (six-axis review C-3). With the colon,
  # an explicitly-empty seam counts as unset and falls back to the real CLI — so
  # the empty-command guard three lines down was unreachable through the seam that
  # is supposed to reach it, and a suite that CLEARED the variable instead of
  # pointing it at a fixture would have run the live `claude plugin list` and
  # passed. Without the colon, set-but-empty stays empty and meets the guard.
  cmd="${BIONIC_PLUGIN_LIST_CMD-claude plugin list}"
  # Whitespace split into argv. A command string is not a shell program here:
  # no quoting, no operators, no eval. That is a deliberate ceiling on what a
  # seam can do, and everything the seam is FOR fits under it.
  read -r -a argv <<<"$cmd" || true
  if [ "${#argv[@]}" -eq 0 ]; then
    echo "load-state=unknown error=- cause=the plugin listing command is empty, so nothing could be asked"
    return 0
  fi

  out="$( "${argv[@]}" 2>/dev/null )"
  st=$?
  if [ "$st" -ne 0 ]; then
    echo "load-state=unknown error=- cause=\`${cmd}\` exited ${st}, so the plugin listing could not be read"
    return 0
  fi

  # THE LISTING IS A BLOCK FORMAT, AND THIS WAS MEASURED, NOT ASSUMED. What the
  # CLI prints today (measured on this machine, 2026-08-20) is one BLOCK per
  # plugin — the id alone on a `❯` line, with Version / Scope / Status indented
  # beneath it:
  #
  #   Installed plugins:
  #
  #     ❯ bionic@bionic
  #       Version: 0.1.0
  #       Scope: user
  #       Status: ✔ enabled
  #
  # W5's F12 report renders the same listing as one line per plugin
  # (`❯ bionic@bionic  0.1.0  user  Status: ✔ enabled`). That rendering is the
  # report's own reflow, not CLI bytes — the first cut of this parser was
  # written against it and answered `absent` for a plugin this machine had
  # loaded, which is precisely the confident wrong answer this file forbids.
  # BOTH shapes are parsed, because the elided one may equally be an older CLI's
  # real output and neither is worth betting a silent `absent` on.
  #
  # ONE pass, four answers, on separate lines rather than tab-joined: a status
  # line is someone else's string and may hold tabs, and `read` splitting on a
  # whitespace IFS silently collapses empty fields. Line-per-field cannot.
  #
  #   rows    how many plugin entries were seen at all (gate two)
  #   found   1 if one of them names this id
  #   status  that entry's Status line, verbatim
  #   error   the first Error: line inside that entry, prefix stripped
  #
  # `inblock` is what keeps a failing NEIGHBOUR's status and error off our
  # answer: both belong to the last entry opened, and an entry that is not ours
  # closes the block rather than leaving it open.
  parsed="$(awk -v id="$id" '
    {
      isheader  = (index($0, "❯") > 0)
      hasstatus = (index($0, "Status:") > 0)

      # An entry opens on a `❯` line — or, if this listing has no glyph at all,
      # on a Status line that carries its own id (the one-line shape).
      if (isheader || (hasstatus && !anyheader)) {
        rows++
        hit = 0
        n = split($0, f, /[ \t]+/)
        for (i = 1; i <= n; i++) if (f[i] == id) hit = 1
        inblock = hit
        if (hit) found = 1
      }
      if (isheader) anyheader = 1

      if (inblock && hasstatus && status == "") status = $0
      if (inblock && err == "" && index($0, "Error:") > 0) {
        line = $0
        sub(/^[ \t]*/, "", line)
        sub(/^Error:[ \t]*/, "", line)
        err = line
      }
    }
    END {
      printf "%d\n%d\n%s\n%s\n", rows + 0, found + 0, status, err
    }
  ' <<<"$out")"

  { IFS= read -r rows; IFS= read -r found; IFS= read -r status; IFS= read -r err; } <<<"$parsed"

  if [ "${found:-0}" != "1" ]; then
    if [ "${rows:-0}" -eq 0 ] 2>/dev/null; then
      echo "load-state=unknown error=- cause=the output of \`${cmd}\` is not a plugin listing"
    else
      echo "load-state=absent error=-"
    fi
    return 0
  fi

  # Order matters: `failed to load` is checked before anything else because a
  # status that says both is a failure, and `not enabled`/`disabled` are ruled
  # out before the `enabled` substring can catch them.
  if [ -z "$status" ]; then
    echo "load-state=unknown error=- cause=the listing names ${id} but reports no status for it"
    return 0
  fi

  case "$status" in
    *"failed to load"*)
      if [ -n "$err" ]; then
        echo "load-state=failed error=${err}"
      else
        echo "load-state=failed error=-"
      fi ;;
    *"not enabled"*|*disabled*)
      # Installed and switched off is a deliberate choice, not a failure — but
      # it is not one of the four states either, and it is certainly not
      # `loaded`. Named for what it is so the renderer can say so.
      echo "load-state=unknown error=- cause=the CLI reports ${id} as not enabled: ${status}" ;;
    *enabled*)
      echo "load-state=loaded error=-" ;;
    *)
      echo "load-state=unknown error=- cause=the CLI reports ${id} in a state this reader does not know: ${status}" ;;
  esac
  return 0
}

# ─── Two catalogs, one name ──────────────────────────────────────────────────
#
# SILENT DUPLICATION IS THE DEFECT (spec R5). Nothing stops a machine holding
# `superpowers@bionic` and `superpowers@claude-plugins-official` at once — or two
# `bionic`s — and nothing tells the user, so which copy a session actually loads
# becomes a coin flip they never saw tossed. The registry knows; nobody asked it.
#
# BARE NAME IS THE COLLISION, not the key. Registry keys are `<name>@<catalog>`
# and are unique by construction, so the duplicate is invisible to any check that
# compares keys. Two keys whose `split("@")[0]` match ARE the finding.
#
# REPORTS, NEVER RESOLVES. This hands back the consolidation command and stops.
# Setup asks (consolidate / coexist / skip) and doctor lists; neither is this
# function's business, and coexistence is a legitimate choice a user may make
# deliberately — which is exactly why the answer is a question and not an action.
#
# WHO LOSES. When one side is `@bionic`, bionic's own catalog is the copy this
# machine's install chose, so the fix names the OTHER one. With no `@bionic`
# side, bionic has no standing to pick a winner and does not pretend to: the fix
# names both and says to choose.
#
# NO jq, NO ANSWER — and specifically not silence. Zero lines means "no
# duplicates", which is a claim; a reader that cannot parse the registry has not
# earned it. So the honest degradation is one `dup=unknown` line carrying its
# cause, and the same for a registry that is present and unparseable. A registry
# that is simply ABSENT is different: the CLI writes that file when it installs
# anything, so nothing installed means nothing duplicated, and zero lines is true.
DETECT_PLUGIN_DUPLICATES_JQ='[ (.plugins // {}) | keys[] ]
  | group_by(split("@")[0])
  | map(select(length > 1))[]
  | "\(.[0] | split("@")[0])\t\(join(","))"'

_detect_duplicate_fix() {  # <comma-separated ids> -> the fix clause
  local ids="$1" id bionic_side=0 losers="" all="" out=""

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    all="${all}${id}
"
    case "$id" in
      *@bionic) bionic_side=$((bionic_side + 1)) ;;
      *)        losers="${losers}${id}
" ;;
    esac
  done <<<"${ids//,/$'\n'}"

  if [ "$bionic_side" -ge 1 ] && [ -n "$losers" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      out="${out}${out:+; }claude plugin uninstall ${id}"
    done <<<"$losers"
    printf '%s' "$out"
    return 0
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -z "$out" ]; then
      out="choose one: claude plugin uninstall ${id}"
    else
      out="${out}, or claude plugin uninstall ${id}"
    fi
  done <<<"$all"
  printf '%s' "$out"
  return 0
}

# BOUNDED, THROUGH THE ONE RUNNER (epic-17 W6 S15, A-6.6 (b) / A-6.S15.2). The reading
# below is a file read, which is why it was left unbounded when S11 bounded the load-state
# probe — but the READER is `jq`, someone else's program, over a path that can sit on a
# stalled mount, and S12 put this probe on `/bionic:setup --list`, where a stranger meets
# it before anything else has printed. So the bound lives at the CALLEE: there are three
# call sites (setup's roster, setup's duplicates step, doctor's report) and no single site
# they share, and a bound only some callers take is the asymmetry S11 was dispatched to
# end. The probe body is `_detect_plugin_duplicates_probe`; this is the only thing that
# runs it.
#
# A TIMEOUT IS `unknown`, NEVER SILENCE. Zero lines means "no duplicates", which is a claim
# a probe that could not look has not earned (A-4.S2.8). Whatever the cut-off probe managed
# to write is DISCARDED rather than passed on: a half-read line is the one answer worse
# than none. Every caller already reads the `dup=unknown … cause=` shape — setup's roster
# skips it, setup's step prints the cause, doctor renders it — so nothing downstream needed
# a new branch.
detect_plugin_duplicates() {  # -> zero or more lines, always exit 0
  local out st
  out="$(detect_bounded "$(detect_probe_seconds)" _detect_plugin_duplicates_probe)"
  st=$?
  if [ "$st" -eq 124 ]; then
    echo "dup=unknown ids=- fix=- cause=the plugin registry did not answer within $(detect_probe_seconds) seconds"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

_detect_plugin_duplicates_probe() {  # -> zero or more lines, always exit 0
  local reg out bare ids

  reg="$(_detect_installed_plugins_file)"
  [ -f "$reg" ] || return 0

  if ! command -v jq >/dev/null 2>&1; then
    echo "dup=unknown ids=- fix=- cause=jq is not on PATH, so the plugin registry cannot be read"
    return 0
  fi

  if ! out="$(jq -r "$DETECT_PLUGIN_DUPLICATES_JQ" "$reg" 2>/dev/null)"; then
    echo "dup=unknown ids=- fix=- cause=the plugin registry at ${reg} could not be parsed"
    return 0
  fi

  [ -n "$out" ] || return 0

  # Exactly two fields, neither ever empty, so a tab IFS is safe here in a way
  # it would not be for the load-state parse above.
  while IFS="$(printf '\t')" read -r bare ids; do
    [ -n "$bare" ] || continue
    echo "dup=${bare} ids=${ids} fix=$(_detect_duplicate_fix "$ids")"
  done <<<"$out"
  return 0
}

# ─── Half-uninstalled ────────────────────────────────────────────────────────
#
# The plugin is gone but its machine footprint is not. This is the state
# `/bionic:remove`'s standalone door (AC-4) exists to serve, which fixes how
# the question must be asked: NOT "does this payload tree exist" — in the case
# being detected the payload tree is exactly what is missing — but "is bionic
# still registered with the CLI, and is there anything left behind".
#
# All three pieces of footprint are detect.sh's own: the legacy rc block, stale
# managed-hook entries, and the todo-tools export setup writes.
#
# THERE USED TO BE A FOURTH, softly consulted through `declare -F`: the applied
# permission marker block, which was profile.sh's fact. The managed allow-list is
# gone from the product entirely (epic-18 T13 — the user's permission MODE
# governs bionic like anything else), so the block is no longer footprint bionic
# creates, and the term went with it. remove.sh still offers to strip a block
# left behind by an older install; that is a one-time cleanup, not a state this
# verdict has to reach.
detect_half_uninstalled() {
  local registered footprint=no line

  # The registration probe used to live inline here, which made it a fact only
  # this verdict could see. It is `detect_plugin_registered` now; nothing about
  # the disjunction below changed, including that an `unknown` registration is
  # NOT treated as "gone" — this verdict tells the user their machine is broken
  # and points them at the standalone remove door, and it must not say that on
  # a registry it could not read.
  line="$(detect_plugin_registered)"
  case "$line" in
    "plugin:registered=no") registered=no ;;
    *)                      registered=yes ;;
  esac

  if [ "$registered" = "no" ]; then
    line="$(detect_zshrc_legacy_block)";   [ "$line" = "env:zshrc-legacy present=yes" ] && footprint=yes
    line="$(detect_env_todo_tools)";       [ "$line" = "env:todo-tools present=yes" ] && footprint=yes
    line="$(detect_legacy_channel_hooks)"
    case "$line" in *"count=0"|*"count=unknown") ;; *) footprint=yes ;; esac
  fi

  if [ "$registered" = "no" ] && [ "$footprint" = "yes" ]; then
    echo "state:half-uninstalled=yes"
  else
    echo "state:half-uninstalled=no"
  fi
  return 0
}

# ─── Sweep ───────────────────────────────────────────────────────────────────
#
# Every fact, once, in a stable order. doctor renders this; it does not
# recompute any of it.
detect_all() {
  local name
  detect_plugin_integrity
  detect_env_todo_tools
  detect_rc_claude_proxy
  detect_zshrc_legacy_block
  detect_legacy_channel_hooks
  detect_legacy_hook_files
  detect_legacy_skill_copy
  detect_installed_agent_copies
  detect_plugin_registered
  detect_half_uninstalled
  while IFS= read -r name; do
    [ -n "$name" ] && detect_dep "$name"
  done < <(dep_names)
  return 0
}
