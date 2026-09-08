#!/bin/bash
# ENVIRONMENT CHECK — the start-side PRODUCER of epic-15's dispatch resilience.
# Design: design/orchestrator-subagent-coordination.md §4 "The environment check", §7, §8.
# [WALL: tests/preflight-probe.test.sh]
#
# This is NOT a hook. It lives in hooks/ for test-harness pairing only; the component
# boundary is the registration list, and this script is never registered. It is run by
# hand, once per session, before dispatching subagents:
#
#     bash ~/.claude/hooks/preflight-probe.sh
#
# It verifies what a fleet dies without, and — only if those checks pass — writes an
# attestation keyed to THIS session. The start gate later reads that file's existence as
# the whole verdict; it parses no check detail, so the contract kept here is the only
# thing standing behind it:
#
#   * blocking probes (any failure => no attestation, and any earlier one destroyed):
#       - a credential is present    (presence, NOT validity — see "Named limit" below)
#       - the repo is writable
#       - the state directory is writable
#   * context probes (recorded, never blocking): git baseline; a warn-only scan for other
#     live sessions working in this same project.
#
# Named limit: this proves a credential is PRESENT, not that it is valid or unexpired —
# expiry detection needs a live API call (backlog, design §4).
#
# Session key: taken from CLAUDE_CODE_SESSION_ID, which Claude Code exports into every
# Bash subprocess and which equals the `session_id` field hook payloads carry (record
# §2.2). Every actor in a fleet shares one session key — that is a known, ratified
# exposure (design D-3), not a defect here.
#
# Attestation record — this script OWNS the schema (spec §Design ownership table); the
# start gate carries its own reader copy, and the two are held together by the agreement
# tests in slice 4/6. Format: `# comment` lines plus `key=value` lines in any order, read
# BY KEY and never by position (checklist A6). A version line is always present so a
# future field addition is a readable change rather than a silent parse break.
#
#     version=2                       kind=preflight-attestation
#     session_id=<session key>        written_at=<epoch>   written_at_iso=<UTC>
#     repo=<resolved repo root>       git_branch= git_head= git_dirty=
#     credential_source=<where the credential was found, never the credential>
#     other_sessions=<count seen by the warn-only scan>
#     cores= mem_gb= disk_free_gb= load_1m= os=        (v2, AC-24's five probe fields)
#     budget=writers=N suites=N worktrees=N test_jobs=N source=probe    (v2)
#
# VERSION 2 (AC-25, wave-bionic-1.4.0-update). The attestation is the only record written
# once per session, before any dispatch, keyed to the session and to the repo — which makes
# it the right place for the machine the fleet is about to run on and the parallel budget
# derived from it. The five probe fields and the budget line come from
# payload/scripts/lib/resources.sh; nothing here re-derives them.
#
#   * The budget VALUE is deliberately the whole `parallel-budget:` string the plan header
#     carries, so Step 0, the dispatch wall and doctor read one string instead of four
#     fields and a formula. `source=probe` distinguishes it from a hand-set override.
#   * A machine where the library cannot be read still takes an attestation, and it is a
#     VERSION 1 one. Resources are a context probe, never a blocking one (§4): a missing
#     library must not stop a dispatch, and an empty-fielded v2 would be a lie about a
#     machine nobody measured. v1 is the honest record of "no budget recorded", which is
#     exactly what doctor prints for it (AC-27).
#
# READING an attestation (`--read <file>`, AC-25). Versions 1 AND 2 are accepted: a v1
# record on disk when a v2 writer lands is the ordinary mid-upgrade state, and refusing it
# would block every session until each repo took a fresh attestation. An UNRECOGNISED
# version is refused, because a record whose schema this script does not know cannot be
# read by key with any confidence. The dispatch wall does not use this path and still reads
# only the record's existence and session key (its own comment at :265 explains why).
#
# The key is spelled `session_id` deliberately: it is the payload field name the reading
# gate receives, and it is what the CURRENTLY INSTALLED old-name gate greps for. Until
# the user's bootstrap replaces that install, a run of this script must not silently
# disarm the live gate by renaming the one field it reads.
#
# State filename — per-session (design D-5, slice 4/2): the attestation is written to
#     .bionic/tmp/preflight-<session_id>.state
# never to the old shared .bionic/tmp/preflight.state slot, so two sessions working the
# same repo hold valid attestations concurrently instead of racing to overwrite a single
# shared file. Every run also prunes: the legacy single-slot file if one is still on
# disk (this script neither writes nor reads it any more), and any per-session
# attestation whose owning session no longer has a live working log (no transcript file
# left anywhere under CLAUDE_CONFIG_DIR/projects). A LIVE foreign session's attestation
# is never touched by another session's run — that is the whole point of D-5.
#
# Exit codes — this list is pinned against the code by preflight-probe.test.sh, because a
# doc/behavior split on exactly this point (checklist A5) is what let a stale pass survive
# a failed write in the discarded run:
#   exit 0 — the attestation for THIS session is present on disk
#   exit 1 — a blocking probe failed; no usable attestation on disk (any prior one was
#            deleted, or emptied where the directory forbade deleting it; if even that
#            failed the message says so and names the file to remove by hand)
#   exit 2 — refused or could not complete; no attestation on disk (prior one deleted)
#   exit 3 — no session key; REFUSED, state left untouched
#   exit 4 — the state lock is held by another writer; state left untouched
#   exit 5 — `--read <file>` only: the named file is not a readable attestation this
#            script's reader recognises (absent, a symlink, no version line, or a version
#            outside the supported set). Nothing is ever written on this path.
#
# Hostile-repo posture (design §8): a repo controls its own .bionic/ contents, so every
# path this script writes is checked for symlink redirection first and the record is
# installed through mktemp + rename. A hostile repo can make this check REFUSE; it cannot
# make it attest.
# Registered on no channel — invoked on demand from the mounted plugin payload.

set -u

# THIS SCRIPT'S OWN PATH, so the re-run line it prints names the copy the operator actually
# invoked — identical in a repo checkout, in a bootstrap-installed ~/.claude/hooks/, and in
# an installed plugin payload. Deliberately NOT ${CLAUDE_PLUGIN_ROOT}: this probe is run by
# hand, by hooks/dispatch-preflight.sh, and by the harness outside any plugin context, where
# that variable does not exist. Absolute, so the line runs from any cwd (checklist A1).
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"

# The version a fresh attestation is written AS, and the set a reader ACCEPTS. They differ
# on purpose: a writer emits one schema, a reader must tolerate every schema still on disk.
ATTESTATION_VERSION=2
ATTESTATION_VERSIONS_SUPPORTED="1 2"
# D-3 payload-shape canary (w3 slice 4/4): the same-actor wall in hooks/stop-guard.sh reads
# observer identity from the undocumented top-level `agent_id` field on subagent-invoked
# PostToolUse|Bash payloads (validated .bionic/docs/record/w3-slice1-posttooluse-probe.md,
# CLI 2.1.222, and re-validated .bionic/docs/record/w3-canary-validation.md, CLI 2.1.223). The
# CLI auto-updates and shape drift on that field would open D-3 silently, so every run compares
# the pinned validated version against the installed `claude --version` and warns — never
# blocks, never touches the attestation — on drift. Move this pin only after re-running the
# 4/1 probe method and confirming the field's shape on the new version.
PAYLOAD_SHAPE_VALIDATED_CLI="2.1.223"
STATE_BASENAME_PREFIX="preflight-"
STATE_BASENAME_SUFFIX=".state"
LEGACY_STATE_BASENAME="preflight.state"
LOCK_BASENAME=".preflight.lock"
OTHER_SESSION_WINDOW_MIN=15   # warn-only liveness heuristic; mtime-based, known to
                              # false-positive on recently-dead sessions (spec Not Doing)
# Reader copy of hooks/dispatch-preflight.sh's roster filename constants (slice
# 4/7). This script only reads roster files, byte for byte, so a real prefix
# mismatch is a mislabeled scan, never a write hazard — kept as a copy per TDD
# §9 rather than a source, same precedent as the other cross-script duplicates.
ROSTER_PREFIX="roster-"
ROSTER_SUFFIX=".state"

say()  { printf 'preflight: %s\n' "$1"; }
warn() { printf 'preflight: WARN %s\n' "$1"; }
die()  { printf 'preflight: %s\n' "$1" >&2; }

# ---------------------------------------------------------------- read mode (AC-25)
#
# `bash preflight-probe.sh --read <file>` validates an attestation and echoes its record
# lines (comments stripped) on stdout. STRICTLY READ-ONLY: it takes no lock, prunes
# nothing, writes nothing, and needs no session key — which is why it is handled here,
# before the session-key refusal and every path below it.
#
# It exists because the schema lives in THIS file (ownership table), so the acceptance
# rule "versions 1 and 2" belongs beside the writer that produces them, not copied into
# each of doctor, the Step 0 display and the tick.
#
# A symlink is not followed, for the same reason no other path here follows one: the
# attestation sits inside a repo, and a repo controls its own `.bionic/` contents.
attestation_version_supported() {  # <version string>
  local v
  for v in $ATTESTATION_VERSIONS_SUPPORTED; do
    [ "$v" = "${1:-}" ] && return 0
  done
  return 1
}

if [ "${1:-}" = "--read" ]; then
  _read_target="${2:-}"
  if [ -z "$_read_target" ]; then
    die "REFUSED — --read needs a file path."
    exit 5
  fi
  if [ -L "$_read_target" ]; then
    die "REFUSED — $_read_target is a symbolic link; an attestation is never read through one."
    exit 5
  fi
  if [ ! -f "$_read_target" ] || [ ! -r "$_read_target" ]; then
    die "REFUSED — no readable attestation at $_read_target."
    exit 5
  fi
  # By key, never by position (checklist A6).
  _read_version="$(grep -m1 '^version=' "$_read_target" 2>/dev/null | cut -d= -f2-)"
  if [ -z "$_read_version" ]; then
    die "REFUSED — $_read_target carries no version= line; it is not an attestation record."
    exit 5
  fi
  if ! attestation_version_supported "$_read_version"; then
    die "REFUSED — attestation version $_read_version is not one this reader knows"
    die "(supported: $ATTESTATION_VERSIONS_SUPPORTED). Re-take the attestation with a"
    die "matching build: bash ${HOOK_DIR}/preflight-probe.sh"
    exit 5
  fi
  grep -v '^#' "$_read_target" 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*='
  exit 0
fi

# ---------------------------------------------------------------- the resources library
#
# FAIL-OPEN, deliberately, and the only load in this script that is (design D1 fail-closed
# applies to WALLS, not to context probes). A machine whose library is missing must still
# be able to attest and dispatch; what it loses is the budget line, and the record says so
# by staying at version 1 rather than carrying five empty fields.
#
# TWO SPELLINGS OF ONE DIRECTORY, the same pair hooks/farm-out-reminder.sh resolves:
# payload/hooks is a symlink to <repo>/hooks and `$0` is textual, so "../scripts/lib"
# resolves only when this file was reached through ${CLAUDE_PLUGIN_ROOT}/hooks/; the repo
# spelling is the second candidate. -r, not -f: readability is what predicts whether `.`
# succeeds.
RESOURCES_LIB=""
for _cand in "$HOOK_DIR/../scripts/lib/resources.sh" \
             "$HOOK_DIR/../payload/scripts/lib/resources.sh"; do
  [ -r "$_cand" ] && { RESOURCES_LIB="$_cand"; break; }
done
PROBE_CORES=""; PROBE_MEM_GB=""; PROBE_DISK_GB=""; PROBE_LOAD_1M=""; PROBE_OS=""
PROBE_BUDGET=""
if [ -n "$RESOURCES_LIB" ]; then
  # shellcheck disable=SC1090
  . "$RESOURCES_LIB" 2>/dev/null || RESOURCES_LIB=""
fi

# ---------------------------------------------------------------- session key (design §7)

# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16); its source of truth is
# payload/scripts/lib/loader.sh. FAIL OPEN: nothing this script does is irreversible,
# and a reporting verb that refused because a file was missing would take the
# diagnosis down with the thing being diagnosed.
BIONIC_LIB_WANT="root.sh session.sh"
# --- bionic-loader/v2 BEGIN
# Find the bionic library. This text is pasted BYTE-IDENTICALLY into every hook; a
# library cannot load itself, so the duplication is the design and
# tests/cross-gate-agreement.test.sh pins every copy against `bionic_loader_pin` in
# payload/scripts/lib/loader.sh. Behaviour: tests/loader.test.sh.
#
# CONTRACT. Set BIONIC_LIB_WANT to the space-separated basenames this hook sources,
# on a line above this block. Afterwards exactly one of these is non-empty:
#   BIONIC_LIB          a readable directory holding every wanted basename
#   BIONIC_LIB_MISSING  the library this hook wanted and did not get
# BIONIC_LIB_CANDS always lists, in order, every location that was tried.
#
# CANDIDATES. Later classes are evaluated only after the earlier ones fail, so a
# healthy hook pays nothing for the healing path — not a jq, not a registry read.
#  (1) beside the hook. TWO SPELLINGS OF ONE DIRECTORY, because the shipped tree has
#      two real shapes: the installed plugin root, where hooks/ and scripts/ are
#      siblings, and the repo, where payload/hooks is a symlink to the top-level
#      hooks/ and the library lives under payload/scripts/lib. "$0" is textual and
#      `..` is resolved by the kernel AFTER the symlink, so the first spelling alone
#      would find nothing in a directory-source session.
#  (2) the marketplace SOURCE TREE. installed_plugins.json names the marketplace this
#      plugin was installed from; that marketplace's source.path in
#      known_marketplaces.json is the tree. The marketplace is read, never assumed:
#      a fork installs under its own name.
#  (3) the newest version directory in that marketplace's plugin cache, by
#      THREE-INTEGER compare — 1.10.0 beats 1.3.2, which a lexical sort gets backwards.
# (2) and (3) heal a partial breakage: one location damaged, a sibling intact. An
# upstream-broken publish breaks every location equally and is not covered.
#
# TESTS OVERRIDE THE MACHINE, never the reverse. BIONIC_PLUGINS_DIR (default
# "$HOME/.claude/plugins") is the only door to the registry and the cache.
BIONIC_LIB=""; BIONIC_LIB_MISSING=""; BIONIC_LIB_CANDS=""
_bl_dir="$(dirname "$0")"
_bl_want="${BIONIC_LIB_WANT:-}"
_bl_try() {
  [ -n "${1:-}" ] || return 1
  if [ -z "$BIONIC_LIB_CANDS" ]; then BIONIC_LIB_CANDS="$1"; else BIONIC_LIB_CANDS="$BIONIC_LIB_CANDS, $1"; fi
  [ -d "$1" ] || return 1
  for _bl_f in $_bl_want; do [ -r "$1/$_bl_f" ] || return 1; done
  BIONIC_LIB="$1"
}
if ! _bl_try "$_bl_dir/../scripts/lib" && ! _bl_try "$_bl_dir/../payload/scripts/lib"; then
  _bl_pd="${BIONIC_PLUGINS_DIR:-${HOME:-/nonexistent}/.claude/plugins}"
  _bl_mk=""
  if [ -r "$_bl_pd/installed_plugins.json" ]; then
    # First key only, and the prefix stripped by parameter expansion rather than
    # `sed | head`: the block's only external commands are `dirname` and `jq`, and
    # `jq` runs with its stderr closed, so a machine missing jq degrades to
    # BIONIC_LIB_MISSING in silence instead of printing a shell diagnostic.
    _bl_keys="$(jq -r '(.plugins // {}) | keys[] | select(startswith("bionic@"))' "$_bl_pd/installed_plugins.json" 2>/dev/null)"
    _bl_mk="${_bl_keys%%
*}"
    _bl_mk="${_bl_mk#bionic@}"
  fi
  if [ -n "$_bl_mk" ]; then
    _bl_src=""
    if [ -r "$_bl_pd/known_marketplaces.json" ]; then
      _bl_src="$(jq -r --arg mk "$_bl_mk" '.[$mk].source.path // empty' "$_bl_pd/known_marketplaces.json" 2>/dev/null)"
    fi
    if [ -n "$_bl_src" ]; then _bl_try "$_bl_src/payload/scripts/lib" || :; fi
    if [ -z "$BIONIC_LIB" ]; then
      _bl_best=""; _bl_bestk=""
      for _bl_v in "$_bl_pd/cache/$_bl_mk/bionic"/*; do
        [ -d "$_bl_v" ] || continue
        _bl_n="${_bl_v##*/}"
        case "$_bl_n" in ''|*[!0-9.]*) continue ;; esac
        _bl_x1=""; _bl_x2=""; _bl_x3=""
        IFS=. read -r _bl_x1 _bl_x2 _bl_x3 _bl_rest <<BIONIC_LOADER_VER
$_bl_n
BIONIC_LOADER_VER
        _bl_k="$(printf '%05d%05d%05d' "$((10#${_bl_x1:-0}))" "$((10#${_bl_x2:-0}))" "$((10#${_bl_x3:-0}))" 2>/dev/null)" || continue
        if [ -z "$_bl_bestk" ] || [ "$_bl_k" \> "$_bl_bestk" ]; then _bl_bestk="$_bl_k"; _bl_best="$_bl_n"; fi
      done
      if [ -n "$_bl_best" ]; then _bl_try "$_bl_pd/cache/$_bl_mk/bionic/$_bl_best/scripts/lib" || :; fi
    fi
  fi
fi
if [ -z "$BIONIC_LIB" ]; then
  # The name in the message is the first library this hook asked for. A candidate
  # directory qualifies only when it holds ALL of them, so with none qualifying the
  # first wanted name is the honest thing to hand the reader.
  BIONIC_LIB_MISSING="${_bl_want%% *}"
  [ -n "$BIONIC_LIB_MISSING" ] || BIONIC_LIB_MISSING="scripts/lib"
fi
# FAIL OPEN — for every hook whose work is advisory or reversible. One line, then
# stand aside. Blocking reversible work because a file is missing buys no safety and
# costs the session.
loader_fail_open() {
  echo "$1: library ${BIONIC_LIB_MISSING:-the bionic library} not found at ${BIONIC_LIB_CANDS:-(no candidate)} — hook stepping aside; run /bionic:doctor" >&2
  exit 0
}
# FAIL CLOSED — for a wall over an irreversible action. Refuse, but never lock the
# user out of the repair: four commands are permitted by WHOLE-STRING match, checked
# here, before the hook sources anything. Whole-string and not prefix, so
# `claude plugin update bionic@bionic; git push origin main` is refused like any
# other push. There is no env-var override: a variable an agent turn can set on
# itself is not a wall.
loader_fail_closed() {
  _bl_root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)" || _bl_root=""
  [ -n "$_bl_root" ] || _bl_root="$(dirname "$0")/.."
  case "${2:-}" in
    "claude plugin update bionic@bionic"|\
    "claude plugin install bionic@bionic"|\
    "bash $_bl_root/scripts/doctor.sh"|\
    "bash $_bl_root/scripts/setup.sh") exit 0 ;;
  esac
  # THE ONE LINE, AND THE ONE PLACE IN THE TREE THAT SPELLS IT WITHOUT
  # scripts/lib/refuse.sh. Every other wall calls `refuse`; this one cannot, because
  # refuse.sh is IN the library this function exists to report missing. So the row-1
  # wording (record/wave-01-plugin-only/s12-refusal-wording-draft.md §1) is written
  # out here by hand, in the renderer's exact format, and tests/loader.test.sh §F
  # drives it against AC-E1.3's own regex so the two spellings cannot drift.
  #
  # THE NAME IS BOUNDED IN PURE BASH for the same reason: `bionic_trunc` is in the
  # missing library. 23 columns of prefix, 31 of fact after the name, 3 of brackets
  # and 18 of fix leaves 25 for the hook's name, and the longest caller
  # (`canonical-sdlc-evidence-gate`, 28) is over it — F-8's runtime-width hazard,
  # arriving at the one site that cannot ask the truncator. The ellipsis is spent
  # from inside the budget, exactly as bionic_trunc spends it.
  _bl_who="${1:-a bionic hook}"
  if [ "${#_bl_who}" -gt 25 ]; then _bl_who="${_bl_who:0:24}…"; fi
  printf 'bionic: load refused — %s cannot load the bionic library (run /bionic:doctor)\n' "$_bl_who" >&2
  # THE DETAIL, on the knob only. Ruling D-1: the reader who is interrupted gets one
  # sentence; the rest is for whoever asks. There is no hook log to write here — the
  # library that owns logging is the one that did not load.
  if [ "${BIONIC_WALL_VERBOSE:-}" = "1" ]; then
    cat >&2 <<BIONIC_LOADER_REFUSE
A wall that cannot read a command refuses it rather than waving it through.

Wanted: ${BIONIC_LIB_MISSING:-the bionic library}
Looked in: ${BIONIC_LIB_CANDS:-(no candidate)}

Until the plugin is whole again this wall permits exactly four commands, each matched
as a whole string:

    claude plugin update bionic@bionic
    claude plugin install bionic@bionic
    bash $_bl_root/scripts/doctor.sh
    bash $_bl_root/scripts/setup.sh

Anything else is refused, including one of those four with another command chained
after it. Run one of them, or act from your own terminal.
BIONIC_LOADER_REFUSE
  fi
  exit 2
}
# --- bionic-loader/v2 END
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "preflight-probe"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

# THE SESSION KEY, from the library (design §1): the environment value is primary. The
# attestation filename is built from it and the dispatch wall reconstructs that filename
# from its own reading, so both sides have to ask the same reader or the wall re-takes an
# attestation that was already good.
SESSION_ID=$(session_id "" 2>/dev/null) || SESSION_ID=""
if [ -z "$SESSION_ID" ]; then
  die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
  die "An unkeyed attestation validates nothing, so none is written and existing state is"
  die "left untouched. Run this from inside a Claude Code session."
  exit 3
fi

# Hoisted here (rather than beside its sole prior use in the other-sessions scan) so the
# D-5 pruning step below can also resolve other sessions' transcript directories.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ---------------------------------------------------------------- where state lives

# THE PINNED ROOT (epic-16 wave-02, R5/AC-4).
#
# DELIBERATELY DUPLICATED, byte for byte, from hooks/canonical-sdlc-governing-skill.sh —

# THE ROOT (spec AC-10, lib/root.sh). `rev-parse --show-toplevel` answers with whatever
# tree the SHELL stands in; inside a linked worktree that is not where the state lives,
# and the reader and the writer then disagree about which `.bionic` is real. This was a
# byte-identical private copy — one of eight — held together by an agreement suite;
# there is one answer now, and it maps a worktree onto its main repository before it
# walks for the nearest real `.bionic`.
REPO="$(project_root "$PWD")"
[ -n "$REPO" ] || REPO="$PWD"
REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
if [ -z "$REPO_REAL" ]; then
  die "REFUSED — cannot resolve the working directory."
  exit 2
fi

BIONIC_DIR="$REPO_REAL/.bionic"
STATE_DIR="$BIONIC_DIR/tmp"
STATE_FILE="$STATE_DIR/${STATE_BASENAME_PREFIX}${SESSION_ID}${STATE_BASENAME_SUFFIX}"
LEGACY_STATE_FILE="$STATE_DIR/$LEGACY_STATE_BASENAME"
LOCK_DIR="$STATE_DIR/$LOCK_BASENAME"

# Path safety BEFORE anything is created or written: a planted symlink anywhere on the
# way to the state directory redirects every later write out of the repo.
for _component in "$BIONIC_DIR" "$STATE_DIR"; do
  if [ -L "$_component" ]; then
    die "REFUSED — $_component is a symbolic link."
    die "The state directory must be a real directory inside the repo. Remove the link"
    die "and re-run; nothing was written."
    exit 2
  fi
done

# ---------------------------------------------------------------- blocking probes

BLOCKING_FAILED=0
STATE_DIR_OK=1

fail_probe() {  # <message>
  printf 'preflight: FAIL  %s\n' "$1"
  BLOCKING_FAILED=1
}
pass_probe() { printf 'preflight: ok    %s\n' "$1"; }

# 1. credential present (presence only). Three sources, cheapest first. Nothing here ever
#    reads or prints credential material — only its existence.
CRED_SOURCE=""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  CRED_SOURCE="environment"
elif [ -s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]; then
  CRED_SOURCE="credentials file"
elif command -v security >/dev/null 2>&1 &&
     security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  CRED_SOURCE="login keychain"
fi
if [ -n "$CRED_SOURCE" ]; then
  pass_probe "credential present ($CRED_SOURCE)"
else
  fail_probe "credential absent — no ANTHROPIC_API_KEY, no credentials file, no keychain entry"
fi

# 2. repo writable — proven by writing, not by mode bits
_probe_file="$(mktemp "$REPO_REAL/.preflight-write-check.XXXXXX" 2>/dev/null)"
if [ -n "$_probe_file" ] && [ -f "$_probe_file" ]; then
  rm -f "$_probe_file"
  pass_probe "repo writable ($REPO_REAL)"
else
  fail_probe "repo NOT writable ($REPO_REAL)"
fi

# 3. state dir writable — created if absent, then proven by writing
mkdir -p "$STATE_DIR" 2>/dev/null
if [ -d "$STATE_DIR" ]; then
  _probe_file="$(mktemp "$STATE_DIR/.preflight-write-check.XXXXXX" 2>/dev/null)"
  if [ -n "$_probe_file" ] && [ -f "$_probe_file" ]; then
    rm -f "$_probe_file"
    pass_probe "state dir writable ($STATE_DIR)"
  else
    STATE_DIR_OK=0
    fail_probe "state dir NOT writable ($STATE_DIR)"
  fi
else
  STATE_DIR_OK=0
  fail_probe "state dir could not be created ($STATE_DIR)"
fi

# Containment backstop. This deliberately OVERLAPS the component checks above: with those
# present, no reachable input makes this fire, so it carries no RED of its own in the
# suite. It is kept as the second layer that still refuses an out-of-repo redirect if a
# future edit weakens the first — mutation-proven: removing the -L loop leaves the
# out-of-repo cases refused by this check alone.
if [ "$STATE_DIR_OK" -eq 1 ]; then
  STATE_DIR_REAL="$(cd "$STATE_DIR" 2>/dev/null && pwd -P)"
  case "${STATE_DIR_REAL:-}/" in
    "$REPO_REAL"/*) : ;;
    *)
      die "REFUSED — the state directory resolves outside the repo (${STATE_DIR_REAL:-unresolvable})."
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------- D-5 pruning (slice 4/2)
#
# On every run where the state directory is usable — independent of whether THIS
# session's own blocking probes above passed — remove: (a) the legacy single-slot file,
# which this script no longer writes or reads, so a repo mid-transition to per-session
# filenames must not go on trusting a stale shared record; (b) any per-session
# attestation whose owning session no longer has a live working log (its own transcript
# file is gone from every project directory this config dir knows about). A LIVE foreign
# session's attestation — its transcript still exists — is never touched here or by any
# other session's run; that concurrency is the entire point of D-5.
session_transcript_exists() {  # <session id>
  local sid="$1" d
  [ -n "$sid" ] || return 1
  [ -d "$CONFIG_DIR/projects" ] || return 1
  for d in "$CONFIG_DIR"/projects/*/; do
    [ -f "${d}${sid}.jsonl" ] && return 0
  done
  return 1
}

prune_stale_attestations() {
  [ -e "$LEGACY_STATE_FILE" ] && rm -f "$LEGACY_STATE_FILE" 2>/dev/null
  local f base sid
  for f in "$STATE_DIR"/"$STATE_BASENAME_PREFIX"*"$STATE_BASENAME_SUFFIX"; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    sid="${base#"$STATE_BASENAME_PREFIX"}"
    sid="${sid%"$STATE_BASENAME_SUFFIX"}"
    [ "$sid" = "$SESSION_ID" ] && continue
    session_transcript_exists "$sid" || rm -f "$f" 2>/dev/null
  done
}

[ "$STATE_DIR_OK" -eq 1 ] && prune_stale_attestations

# ---------------------------------------------------------------- context probes

GIT_BRANCH="-"; GIT_HEAD="-"; GIT_DIRTY="-"
if git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null)"; [ -n "$GIT_BRANCH" ] || GIT_BRANCH="-"
  GIT_HEAD="$(git rev-parse --short HEAD 2>/dev/null)";          [ -n "$GIT_HEAD" ]   || GIT_HEAD="-"
  GIT_DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"; [ -n "$GIT_DIRTY" ] || GIT_DIRTY="-"
  say "git baseline: branch $GIT_BRANCH @ $GIT_HEAD, $GIT_DIRTY uncommitted path(s)"
else
  say "git baseline: not a git working tree (context only, not blocking)"
fi

# Other live sessions in this project. Warn-only by design (§4, UC-6): detection, never
# prevention. The project directory is located by finding the one that holds THIS
# session's own transcript, so no filename-encoding scheme has to be guessed.
# (CONFIG_DIR is set earlier, beside the session-key check, so D-5 pruning above can use it.)
OTHER_SESSIONS=0
PROJ_DIR=""
if [ -d "$CONFIG_DIR/projects" ]; then
  for _d in "$CONFIG_DIR"/projects/*/; do
    [ -d "$_d" ] || continue
    if [ -f "$_d$SESSION_ID.jsonl" ]; then PROJ_DIR="${_d%/}"; break; fi
  done
fi
# Rostered-vs-unrostered (spec Design: "its other-live-session scan reports
# rostered-vs-unrostered"). Two additions per detected live foreign session,
# both display/warn only — this is a context probe, never a blocking one, and
# starts stay fail open whatever it finds:
#   (a) whether that session carries a roster file at .bionic/tmp/roster-<sid>.state;
#   (b) any agent-*.meta.json under that session's OWN subagents directory whose
#       id no roster file on disk names (by `agent_id=` field) is UNROSTERED.
# The roster file is the ONE covering fact (design ownership table); this reads
# it, never writes it.
report_roster_coverage() {  # <foreign session id> <that session's transcript dir>
  local sid="$1" tdir="$2" has_roster="absent"
  [ -f "$STATE_DIR/${ROSTER_PREFIX}${sid}${ROSTER_SUFFIX}" ] && has_roster="present"
  warn "another live session on this project: $sid (transcript touched within ${OTHER_SESSION_WINDOW_MIN}m; roster: ${has_roster})"

  local sub="$tdir/$sid/subagents"
  [ -d "$sub" ] || return 0
  local meta base aid rf covered
  for meta in "$sub"/agent-*.meta.json; do
    [ -f "$meta" ] || continue
    base="${meta##*/}"; base="${base%.meta.json}"; aid="${base#agent-}"
    covered=0
    for rf in "$STATE_DIR"/"${ROSTER_PREFIX}"*"${ROSTER_SUFFIX}"; do
      [ -f "$rf" ] || continue
      if grep -qF "|agent_id=${aid}|" "$rf" 2>/dev/null; then covered=1; break; fi
    done
    [ "$covered" -eq 0 ] && warn "UNROSTERED live subagent metadata: ${aid} (session ${sid})"
  done
}

if [ -n "$PROJ_DIR" ]; then
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    _other="$(basename "$_t" .jsonl)"
    [ "$_other" = "$SESSION_ID" ] && continue
    OTHER_SESSIONS=$((OTHER_SESSIONS + 1))
    report_roster_coverage "$_other" "$PROJ_DIR"
  done <<EOF
$(find "$PROJ_DIR" -maxdepth 1 -name '*.jsonl' -mmin "-$OTHER_SESSION_WINDOW_MIN" 2>/dev/null)
EOF
  [ "$OTHER_SESSIONS" -eq 0 ] && say "no other live session detected on this project"
else
  say "session roster: this session's transcript directory was not found (context only)"
fi

# The machine, and the budget derived from it (AC-24, AC-25). A CONTEXT probe: it records,
# it never blocks. The probe runs FROM THE REPO ROOT because its disk term bounds worktrees
# and worktrees are cut beside the repo, not beside whatever directory the operator stood in.
if [ -n "$RESOURCES_LIB" ]; then
  _probe_line="$( cd "$REPO_REAL" 2>/dev/null && resources_probe 2>/dev/null )"
  # Read by key, never by position — the same rule the attestation itself is read under.
  _pf() { printf '%s\n' "$_probe_line" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }
  PROBE_CORES="$(_pf cores)"; PROBE_MEM_GB="$(_pf mem_gb)"
  PROBE_DISK_GB="$(_pf disk_free_gb)"; PROBE_LOAD_1M="$(_pf load_1m)"; PROBE_OS="$(_pf os)"
  if [ -n "$PROBE_CORES" ] && [ -n "$PROBE_MEM_GB" ] && [ -n "$PROBE_DISK_GB" ] &&
     [ -n "$PROBE_LOAD_1M" ] && [ -n "$PROBE_OS" ]; then
    _budget="$(resources_budget "$PROBE_CORES" "$PROBE_MEM_GB" "$PROBE_DISK_GB" 2>/dev/null)"
    if [ -n "$_budget" ]; then
      PROBE_BUDGET="$_budget source=probe"
      say "machine: ${PROBE_CORES}c, ${PROBE_MEM_GB} GB, ${PROBE_DISK_GB} GB free, load ${PROBE_LOAD_1M} (${PROBE_OS})"
      say "budget: $PROBE_BUDGET"
    fi
  fi
  # Any gap in the five fields or the budget leaves PROBE_BUDGET empty, and the write below
  # falls back to a version 1 record rather than attesting to a half-measured machine.
  [ -n "$PROBE_BUDGET" ] || say "resources: not measured on this run (attestation stays at version 1)"
else
  say "resources: library not found beside this script (attestation stays at version 1)"
fi

# D-3 payload-shape canary (w3 slice 4/4): compare the pinned validated CLI version against
# what's actually installed. Warn only — never blocking, never written into the attestation —
# because the last-known-good behavior (the discriminator holding) is what the pin records,
# not a live re-check of the discriminator itself (that needs a full probe run, not a version
# string compare).
_installed_cli_version="$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -n "$_installed_cli_version" ] && [ "$_installed_cli_version" != "$PAYLOAD_SHAPE_VALIDATED_CLI" ]; then
  warn "payload shape (agent_id/D-3 discriminator) unvalidated on $_installed_cli_version; re-run the 4/1 probe method — record/w3-slice1-posttooluse-probe.md — and move the pin"
fi

# An END-OF-RUN ACTION LINE naming the command that arms this session's watcher stood here
# until epic-16 wave-02. The watcher is deleted: supervision reads facts off disk at the
# moment a decision needs them, so there is no process for this probe to point an operator
# at, and nothing here to keep alive.

# ---------------------------------------------------------------- state mutation

# An unusable state directory does NOT mean the directory is empty: it can be readable
# and non-writable (or full) while holding a perfectly readable prior attestation, and the
# start gate would read that file and pass — a stale pass outliving the environment it
# described (§7 row 5, checklist A5). So the delete-on-fail obligation holds on THIS path
# too, even though the lock below is unreachable from here.
#
# `rm` needs write permission on the DIRECTORY and can fail here; truncation needs it only
# on the FILE, and an emptied attestation carries no `session_id=` line, which the start
# gate refuses as "not a valid attestation record". A symlink is never truncated — that
# would write through the redirect a hostile repo planted (§8) — only unlinked.
if [ "$STATE_DIR_OK" -eq 0 ]; then
  if [ -L "$STATE_FILE" ]; then
    rm -f "$STATE_FILE" 2>/dev/null
  elif [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE" 2>/dev/null
    [ -f "$STATE_FILE" ] && : > "$STATE_FILE" 2>/dev/null
  fi
  if [ -e "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
    die "BLOCKED — a blocking probe failed, and the prior attestation at $STATE_FILE could"
    die "NEITHER be deleted nor emptied. It may still admit dispatches. Remove it by hand:"
    die "  rm -f $STATE_FILE"
  else
    die "BLOCKED — a blocking probe failed. No attestation was written, and any earlier"
    die "attestation has been deleted or emptied."
  fi
  die "Fix the failure above and re-run: bash ${HOOK_DIR}/preflight-probe.sh"
  exit 1
fi

# Lock before any read-modify-write, so two sessions racing on the single-slot state file
# (design D-5) serialize instead of interleaving.
LOCK_HELD=0
release_lock() { [ "$LOCK_HELD" -eq 1 ] && rmdir "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }
trap release_lock EXIT

# A lock left behind by a killed run would wedge every later run; break clearly stale ones.
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
  rmdir "$LOCK_DIR" 2>/dev/null
fi
_tries=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  _tries=$((_tries + 1))
  if [ "$_tries" -ge 20 ]; then
    die "BUSY — another writer holds $LOCK_DIR. State left untouched; re-run in a moment."
    exit 4
  fi
  sleep 0.1
done
LOCK_HELD=1

# The attestation path itself, now that the write is imminent.
if [ -L "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
  die "REFUSED — the attestation path was a symbolic link; it was removed, not followed."
  die "Nothing was written through it, and no attestation is present."
  exit 2
fi
if [ -d "$STATE_FILE" ]; then
  die "REFUSED — the attestation path is occupied by a directory ($STATE_FILE)."
  die "Remove it and re-run; no attestation is present."
  exit 2
fi

if [ "$BLOCKING_FAILED" -eq 1 ]; then
  # A stale pass must not outlive the environment it described (design §7).
  rm -f "$STATE_FILE"
  die "BLOCKED — a blocking probe failed. No attestation was written, and any earlier"
  die "attestation has been deleted. Fix the failure above and re-run:"
  die "  bash ${HOOK_DIR}/preflight-probe.sh"
  exit 1
fi

tmp=""
abort_write() {  # <message> — leaves no attestation of any kind behind
  [ -n "${tmp:-}" ] && rm -f "$tmp"
  rm -f "$STATE_FILE" 2>/dev/null
  die "FAILED — $1"
  die "No attestation is present (any earlier one was deleted). Fix the cause and re-run."
  exit 2
}

# Delete first, then install atomically. The ordering is the point: every failure after
# this line leaves NO attestation rather than a surviving stale one (checklist A5).
rm -f "$STATE_FILE" 2>/dev/null

tmp="$(mktemp "$STATE_FILE.XXXXXX" 2>/dev/null)"
[ -n "$tmp" ] && [ -f "$tmp" ] || abort_write "could not create a temporary file in $STATE_DIR"
chmod 600 "$tmp" 2>/dev/null || abort_write "could not restrict permissions on the temporary file"

# A record is version 2 only when it can actually carry what version 2 promises. With no
# budget measured, the honest record is the version 1 schema — which the reader above still
# accepts and doctor renders as "no budget recorded" (AC-27).
if [ -n "$PROBE_BUDGET" ]; then
  RECORD_VERSION="$ATTESTATION_VERSION"
else
  RECORD_VERSION=1
fi

{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=%s\n'      "$RECORD_VERSION"
  printf 'kind=%s\n'         "preflight-attestation"
  printf 'session_id=%s\n'   "$SESSION_ID"
  printf 'written_at=%s\n'   "$(date -u +%s)"
  printf 'written_at_iso=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'repo=%s\n'         "$REPO_REAL"
  printf 'git_branch=%s\n'   "$GIT_BRANCH"
  printf 'git_head=%s\n'     "$GIT_HEAD"
  printf 'git_dirty=%s\n'    "$GIT_DIRTY"
  printf 'credential_source=%s\n' "$CRED_SOURCE"
  printf 'other_sessions=%s\n'    "$OTHER_SESSIONS"
  if [ "$RECORD_VERSION" -ge 2 ]; then
    # The five probe fields (AC-24), then the budget as ONE string in exactly the shape the
    # plan header's `parallel-budget:` carries, so every reader takes a string rather than
    # re-deriving a formula (spec Design §3, ownership table).
    printf 'cores=%s\n'        "$PROBE_CORES"
    printf 'mem_gb=%s\n'       "$PROBE_MEM_GB"
    printf 'disk_free_gb=%s\n' "$PROBE_DISK_GB"
    printf 'load_1m=%s\n'      "$PROBE_LOAD_1M"
    printf 'os=%s\n'           "$PROBE_OS"
    printf 'budget=%s\n'       "$PROBE_BUDGET"
  fi
} > "$tmp" 2>/dev/null || abort_write "could not write the attestation record"

mv -f "$tmp" "$STATE_FILE" 2>/dev/null || abort_write "could not install the attestation at $STATE_FILE"
tmp=""

# Read back what was installed: the file must exist and carry THIS session's key, looked
# up by key rather than by position (checklist A6).
_readback="$(grep -m1 '^session_id=' "$STATE_FILE" 2>/dev/null | cut -d= -f2-)"
[ "$_readback" = "$SESSION_ID" ] || abort_write "the installed attestation did not read back correctly"

say "attestation written for session $SESSION_ID"
say "  $STATE_FILE"
release_lock
exit 0
