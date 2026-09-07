# tests/lib/fresh-home.sh — the fresh-HOME rig (epic-22 wave-01 slice 0; REQ-S0, REQ-R3).
#
# WHAT THIS IS, AND WHAT IT IS NOT. `tests/fresh-home.test.sh` answers "does an
# all-yes setup leave the machine in the state the plugin claims", and it answers
# it against a STUBBED `claude`: PATH is replaced, the CLI is a stateful fake, and
# nothing reaches the network. That suite is hermetic and must stay hermetic.
#
# This file is the other half, and the half no suite could own. The questions
# REQ-S0 and REQ-R3 ask are about what the REAL Claude Code CLI does to its own
# plugin registry — which rows it writes, which rows it silently drops — and a
# fake CLI cannot answer either of them, because the fake is written from the
# belief under test. So this rig runs the real binary, against a real marketplace
# registration, over a real clone of this repo, and reads the registry the CLI
# itself wrote.
#
# THE PRICE OF THAT IS HERMETICITY, and it is paid deliberately and in one place:
# a rig, sourced by a protocol script and by a hand-run, NEVER by `tests/run.sh`.
# Sourcing this file from a suite the runner's glob picks up would put a network
# fetch and a multi-second CLI install inside the gate every commit waits on.
#
# WHAT IS ISOLATED, AND WHAT IS NOT.
#
#   isolated   $HOME and $CLAUDE_CONFIG_DIR both point inside a scratch dir, so
#              the registry, settings.json, the plugin cache, the rc file and the
#              skills directory are all fixture state. The real ~/.claude is never
#              read and never written.
#   isolated   the repo under test is a scratch `git clone` checked out at the
#              tree's HEAD — never the live checkout. A directory-source
#              marketplace reads the tree it points at, so pointing it at the
#              live checkout would let an editor's unsaved half-state decide a
#              measurement, and would leave this repo's own working tree inside
#              the CLI's marketplace registry afterwards.
#   isolated   the package managers. `brew`, `npm`, `npx`, `uv` and `pnpm` are
#              shadowed by inert stubs on PATH, because their installs are
#              MACHINE-global, not HOME-scoped: `brew install ripgrep` under a
#              fixture HOME still mutates /opt/homebrew. The stubs record their
#              argv and exit 0. Nothing downstream of them is what this rig
#              measures.
#   NOT        the network. `claude plugin install superpowers@bionic` fetches
#              from GitHub, and that fetch is part of the behaviour under test.
#   NOT        credentials. The fixture HOME has none and none are ever copied
#              into it. Every `claude plugin …` verb works without auth (measured,
#              CLI 2.1.263); anything that needs a signed-in session does not,
#              and a caller that needs one records the gap rather than reaching
#              for a credential.
#
# THE REGISTRY IS THE ORACLE. `$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json`
# is the CLI's own record of what is installed; `snapshot_registry` copies the
# file (never a summary of it) and prints its plugin keys, so a later reading can
# be re-derived from the artifact rather than trusted from a log line.
#
# Usage (bash only):
#
#     . "$(dirname "$0")/lib/fresh-home.sh"
#     fh_init
#     fh_marketplace_add && fh_install_bionic
#     fh_install_plugin impeccable
#     snapshot_registry baseline
#     …
#     registry_diff baseline after-update
#     fh_cleanup

if [ -z "${BASH_SOURCE[0]:-}" ]; then
  echo "fresh-home.sh: BASH_SOURCE unavailable — source this from bash" >&2
  return 1 2>/dev/null || exit 1
fi

# The repo this rig clones. Same seam every suite uses, so an override moves the
# rig and the suites together instead of forking the answer.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/resolve-roots.sh"

# ─── The real CLI, resolved once and by path ─────────────────────────────────
#
# WHY NOT JUST `claude`. On this machine the interactive shell defines a `claude`
# FUNCTION that appends `--allow-dangerously-skip-permissions` (the shell-snapshot
# proxy). A rig that measured that function would be measuring a wrapper nobody
# ships. A bash script does not inherit the zsh function, so `command -v claude`
# is already the binary here — but it is resolved once, into a variable, and every
# call below goes through it, so the surface under measurement is named rather
# than inherited from whatever the caller's shell happened to define.
FH_CLAUDE_BIN="${FH_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"

# ─── State ───────────────────────────────────────────────────────────────────
FH_ROOT=""        # the scratch dir; everything below hangs off it
FH_HOME=""        # $FH_ROOT/home  — exported as HOME
FH_CLONE=""       # $FH_ROOT/repo  — the scratch clone, the marketplace source
FH_SNAPDIR=""     # $FH_ROOT/snapshots — one JSON per snapshot_registry label
FH_BIN=""         # $FH_ROOT/bin — the package-manager stubs, prepended to PATH
FH_LOG=""         # $FH_ROOT/rig.log — every CLI invocation, argv and output
FH_CALLS=""       # $FH_ROOT/calls.log — every stubbed package-manager argv
FH_REAL_HOME=""   # the caller's own HOME, kept only so fh_cleanup can restore it
FH_SRC_SHA=""     # the HEAD the clone is checked out at

# `yes` as an answer stream, not as the program: `yes | script` leaves a SIGPIPE
# on a pipefail run. 400 lines outlasts every consent page setup or remove prints.
FH_YES="$(for _i in $(seq 1 400); do echo y; done)"

fh_log() { printf '%s\n' "$*" >> "$FH_LOG"; }

# ─── fh_init [<parent-dir>] ──────────────────────────────────────────────────
#
# Builds the fixture and points HOME at it. Every later function refuses to run
# before this one has: the guards below are the reason a mistake here cannot
# reach the real ~/.claude.
fh_init() {
  local parent="${1:-${TMPDIR:-/tmp}}" src sha

  [ -n "$FH_CLAUDE_BIN" ] && [ -x "$FH_CLAUDE_BIN" ] || {
    echo "fresh-home.sh: the Claude Code CLI is not on PATH — this rig runs the REAL binary" >&2
    return 1
  }
  command -v git >/dev/null 2>&1 || { echo "fresh-home.sh: git is required" >&2; return 1; }
  command -v jq  >/dev/null 2>&1 || { echo "fresh-home.sh: jq is required — the registry is read with it" >&2; return 1; }

  FH_REAL_HOME="$HOME"
  FH_ROOT="$(mktemp -d "${parent%/}/bionic-fresh-home.XXXXXX")" || return 1
  FH_HOME="$FH_ROOT/home"
  FH_CLONE="$FH_ROOT/repo"
  FH_SNAPDIR="$FH_ROOT/snapshots"
  FH_BIN="$FH_ROOT/bin"
  FH_LOG="$FH_ROOT/rig.log"
  FH_CALLS="$FH_ROOT/calls.log"
  mkdir -p "$FH_HOME" "$FH_SNAPDIR" "$FH_BIN" || return 1
  : > "$FH_LOG"; : > "$FH_CALLS"

  # THE GUARD THAT MATTERS. A fixture HOME that resolved to the real one would
  # make every write below a write to Chris's machine. Asserted, not assumed.
  case "$FH_HOME" in "$FH_REAL_HOME"|"$FH_REAL_HOME"/*)
    echo "fresh-home.sh: refusing — the fixture HOME resolved inside the real HOME ($FH_HOME)" >&2
    return 1 ;;
  esac

  export HOME="$FH_HOME"
  export CLAUDE_CONFIG_DIR="$FH_HOME/.claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"

  # The package-manager stubs. Shadow, not replace: PATH keeps every real tool
  # the CLI and the payload legitimately need (node, git, jq, shasum, …) and
  # loses only the five programs whose installs escape the fixture.
  local pm
  for pm in brew npm npx uv pnpm; do
    cat > "$FH_BIN/$pm" <<STUB
#!/bin/bash
# inert stub — fresh-home.sh. Records the call; installs nothing.
printf '%s\n' "\$0 \$*" >> "$FH_CALLS"
exit 0
STUB
    chmod +x "$FH_BIN/$pm"
  done
  export PATH="$FH_BIN:$PATH"

  # The scratch clone. `--no-hardlinks` so the clone's object store cannot share
  # inodes with this repo's; a detached checkout at the tree's HEAD so the
  # measurement names a commit rather than "whatever was checked out".
  src="$(git -C "$BIONIC_SCRIPTS_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$src" in /*) ;; *) src="$BIONIC_SCRIPTS_DIR/$src" ;; esac
  sha="$(git -C "$BIONIC_SCRIPTS_DIR" rev-parse HEAD)" || return 1
  FH_SRC_SHA="$sha"
  git clone --quiet --no-hardlinks "$src" "$FH_CLONE" >> "$FH_LOG" 2>&1 || {
    echo "fresh-home.sh: clone of $src failed — see $FH_LOG" >&2; return 1; }
  git -C "$FH_CLONE" checkout --quiet --detach "$sha" >> "$FH_LOG" 2>&1 || {
    echo "fresh-home.sh: checkout of $sha in the clone failed — see $FH_LOG" >&2; return 1; }

  fh_log "# fresh-home rig"
  fh_log "# root=$FH_ROOT"
  fh_log "# HOME=$HOME"
  fh_log "# CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
  fh_log "# clone=$FH_CLONE @ $sha"
  fh_log "# cli=$FH_CLAUDE_BIN $("$FH_CLAUDE_BIN" --version 2>&1 | head -1)"
  return 0
}

fh_ready() { [ -n "$FH_ROOT" ] && [ -d "$FH_ROOT" ]; }

# ─── fh_claude <args…> ───────────────────────────────────────────────────────
#
# One entry point to the CLI. Logs the argv and the whole output, returns the
# CLI's rc, and prints the output so a caller can read it too. stdin is /dev/null:
# a prompt nobody can see is a hang, and this rig must never wait on one.
fh_claude() {
  fh_ready || { echo "fresh-home.sh: fh_init has not run" >&2; return 1; }
  local rc=0 out
  fh_log "\$ claude $*"
  out="$("$FH_CLAUDE_BIN" "$@" </dev/null 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$FH_LOG"
  fh_log "rc=$rc"
  printf '%s\n' "$out"
  return $rc
}

# ─── The install path a stranger walks ───────────────────────────────────────
#
# `marketplace add <dir>` then `install bionic@bionic` is exactly the two-command
# sequence README.md gives a new machine, and AC-R3.1 is the assertion that both
# exit 0 on a HOME with nothing in it.
fh_marketplace_add() { fh_claude plugin marketplace add "$FH_CLONE"; }

fh_install_bionic() { fh_claude plugin install bionic@bionic --scope user --yes; }

# A dependent row, installed the way the product installs one: `install_plugin_native`
# in payload/scripts/lib/deps.sh composes precisely this argv.
fh_install_plugin() { fh_claude plugin install "${1}@bionic" --scope user --yes; }

fh_update_bionic() { fh_claude plugin update bionic@bionic --scope user --yes; }

# ─── Driving the payload ─────────────────────────────────────────────────────
#
# From the CLONE, not from this checkout: the rig measures the tree it registered
# as a marketplace, and a payload read from somewhere else would be a different
# product than the one the CLI installed.
fh_payload() { printf '%s' "$FH_CLONE/payload"; }

fh_setup_all() {
  fh_ready || return 1
  fh_log "\$ setup.sh --all  (all-yes)"
  local rc=0 out
  out="$(printf '%s' "$FH_YES" | bash "$(fh_payload)/scripts/setup.sh" --all 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$FH_LOG"; fh_log "rc=$rc"
  printf '%s\n' "$out"
  return $rc
}

fh_remove_all() {
  fh_ready || return 1
  fh_log "\$ remove.sh --all  (all-yes)"
  local rc=0 out
  out="$(printf '%s' "$FH_YES" | bash "$(fh_payload)/scripts/remove.sh" --all 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$FH_LOG"; fh_log "rc=$rc"
  printf '%s\n' "$out"
  return $rc
}

# ─── The registry ────────────────────────────────────────────────────────────
fh_registry_file() { printf '%s' "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }

# snapshot_registry <label>
#
# Copies the registry file to $FH_SNAPDIR/<label>.json and prints its plugin keys,
# one per line, sorted. THE COPY IS THE EVIDENCE: a reading printed to a log can
# be disputed, a file cannot, and a later `registry_diff` re-derives its answer
# from the files rather than from anything this function said at the time.
#
# An absent registry file is a legitimate state (before the first install, and
# after a teardown), and it prints nothing while still writing a snapshot — an
# empty object — so the diff of "nothing" against "something" is a real diff and
# not a missing artifact.
snapshot_registry() {
  local label="${1:-}" reg
  [ -n "$label" ] || { echo "snapshot_registry: needs a label" >&2; return 1; }
  fh_ready || { echo "fresh-home.sh: fh_init has not run" >&2; return 1; }
  reg="$(fh_registry_file)"
  if [ -f "$reg" ]; then
    cp "$reg" "$FH_SNAPDIR/${label}.json"
  else
    printf '%s\n' '{"plugins":{}}' > "$FH_SNAPDIR/${label}.json"
  fi
  jq -r '.plugins // {} | keys[]' "$FH_SNAPDIR/${label}.json" 2>/dev/null | sort
  return 0
}

# The keys of an existing snapshot, without taking a new one.
registry_rows() {
  local label="${1:-}"
  [ -f "$FH_SNAPDIR/${label}.json" ] || return 1
  jq -r '.plugins // {} | keys[]' "$FH_SNAPDIR/${label}.json" 2>/dev/null | sort
}

# registry_diff <a> <b> — `- key` for a row present in a and gone in b, `+ key`
# for one that appeared. Prints nothing when the two agree, which is the shape a
# caller tests with `[ -z "$(registry_diff …)" ]`.
registry_diff() {
  local a="${1:-}" b="${2:-}" ta tb
  [ -f "$FH_SNAPDIR/${a}.json" ] || { echo "registry_diff: no snapshot '$a'" >&2; return 1; }
  [ -f "$FH_SNAPDIR/${b}.json" ] || { echo "registry_diff: no snapshot '$b'" >&2; return 1; }
  ta="$FH_ROOT/.diff-a"; tb="$FH_ROOT/.diff-b"
  registry_rows "$a" > "$ta"; registry_rows "$b" > "$tb"
  comm -23 "$ta" "$tb" | sed 's/^/- /'
  comm -13 "$ta" "$tb" | sed 's/^/+ /'
  rm -f "$ta" "$tb"
  return 0
}

# The full entry for one row, for a record that has to show what changed inside a
# row rather than only which rows exist (the `auto` marker, installPath, version).
registry_entry() {
  local label="${1:-}" key="${2:-}"
  [ -f "$FH_SNAPDIR/${label}.json" ] || return 1
  jq --arg k "$key" '.plugins[$k] // null' "$FH_SNAPDIR/${label}.json" 2>/dev/null
}

# ─── fh_cleanup ──────────────────────────────────────────────────────────────
#
# Restores HOME first and deletes second, so an interrupted delete cannot leave a
# caller pointed at a directory that is half gone.
fh_cleanup() {
  local keep="${1:-}"
  [ -n "$FH_REAL_HOME" ] && export HOME="$FH_REAL_HOME"
  unset CLAUDE_CONFIG_DIR
  if [ "$keep" = "keep" ]; then
    echo "fresh-home.sh: kept $FH_ROOT"
    return 0
  fi
  case "$FH_ROOT" in
    /*/bionic-fresh-home.*) rm -rf "$FH_ROOT" ;;
    *) [ -n "$FH_ROOT" ] && echo "fresh-home.sh: refusing to delete an unexpected root: $FH_ROOT" >&2 ;;
  esac
  FH_ROOT=""
  return 0
}
