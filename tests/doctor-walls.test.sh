#!/bin/bash
# tests/doctor-walls.test.sh — doctor's `walls` row (bionic 1.4.0,
# wave-bionic-1.4.0-update slice DOCTOR handoff 3.1, spec AC-15).
#
# THE CONTRACT UNDER TEST. AC-15: "Doctor verifies every fail-closed wall's
# library resolves and prints a row with a repair-phrased FIX line before the
# first refusal; intact → clean."
#
# The four walls are the four hooks the loader idiom replaced
# (payload/scripts/lib/loader.sh's header names them): protect-main and
# canonical-sdlc-evidence-gate, which refuse when they cannot read a command,
# and farm-out-reminder and background-suite-guard, which classify one. Each
# names the library basenames it sources; doctor resolves those THROUGH THE
# IDIOM ITSELF — `bionic_loader_pin` driven with `$0` set to the hook's own
# path — so this row can never disagree with what the hook will do at fire time.
#
# WHY THE FIXTURE IS A COPIED TREE. The row is about a DAMAGED install, and the
# only honest way to produce one is to damage a real one: the payload is copied
# with `cp -RL` (payload/hooks is a symlink to the top-level hooks/, so the copy
# must dereference), one library is deleted, and doctor is pointed at the copy
# through BIONIC_PLUGIN_ROOT. Nothing under the repo is touched.
#
# HERMETIC. HOME and BIONIC_PLUGINS_DIR are both overridden per run, so the
# loader's candidate (2) and (3) — the marketplace source tree and the plugin
# cache — resolve against an empty fixture registry instead of this machine's
# real ~/.claude, which would otherwise HEAL the damage and turn the row green.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below
# (tests/assert-helper-race.test.sh): containment is bash `[[ == * ]]`.
#
# Usage: bash tests/doctor-walls.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
DOCTOR_SH="${PAYLOAD}/scripts/doctor.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_true "payload/scripts/doctor.sh exists" test -f "$DOCTOR_SH"

# ---------- the fixture plugin tree ----------
#
# `cp -RL`: payload/hooks is a symlink into the repo's top-level hooks/, and a
# copy that preserved the link would leave the fixture's walls pointing at the
# repo — where deleting a library would damage the checkout rather than the
# fixture.
PLUG="${TMP}/plug"
mkdir -p "$PLUG"
cp -RL "${PAYLOAD}/." "$PLUG/" 2>/dev/null

expect_true "the fixture tree carries the four wall hooks" \
  test -f "$PLUG/hooks/protect-main.sh" -a -f "$PLUG/hooks/background-suite-guard.sh"
expect_true "the fixture tree carries its own library" test -f "$PLUG/scripts/lib/git-argv.sh"

# An empty registry: no installed_plugins.json, no known_marketplaces.json, no
# cache. The loader's healing candidates therefore find nothing, which is what
# makes a deleted library actually missing rather than merely misplaced.
EMPTY_PLUGINS="${TMP}/no-plugins"
mkdir -p "$EMPTY_PLUGINS"

FIXTURE_RC="${TMP}/dot.zshrc"
: > "$FIXTURE_RC"


# ─── THE TOOL DIRECTORY IS THE FIXTURE'S, NOT THE MACHINE'S (wave-01 S4, AC-7) ─
#
# WHAT THIS SUITE RENDERED USED TO DEPEND ON WHOSE LAPTOP RAN IT. doctor asks
# `command -v` about the nine `brew-dep` rows of BIONIC_DEP_TABLE, and six of
# them — node, gh, rg, uv, docker, aws — live under /opt/homebrew here and
# nowhere on a stripped PATH. Under the ambient PATH those rows are present;
# under `PATH=/usr/bin:/bin:/usr/sbin:/sbin` six more rows turn absent, the
# dependency roster this file pins shifts by six names, and an assertion fails
# on a page that is perfectly correct. `claude` is the same story one row over,
# and the one that used to hurt: with the CLI off PATH four `mcp-server` rows
# turn `unknown`.
#
# SO THE FIXTURE OWNS THE SET. Every program doctor RUNS is symlinked from the
# real one; every program doctor only ASKS ABOUT is an inert stub answering
# `--version`. PATH is REPLACED, never prepended, so nothing ambient is
# reachable — and `claude` is present or absent because this file says so,
# which is what makes the pair of directories below an experiment rather than
# a reflection of the machine.
_TOOLS_REAL="bash sh env cat grep sed awk mkdir rm cp mv chmod stat readlink ls tr head tail
sort uniq wc cut jq mktemp find xargs shasum uname date touch diff cmp printf true false
sleep dirname basename realpath id ps df sysctl vm_stat git strings"
_TOOLS_STUB="node pnpm gh rg uv docker aws"

make_tool_dir() {  # <dir> <claude: yes|no> -> prints the reals it could NOT find
  local d="$1" want="$2" t p missing=""
  mkdir -p "$d"
  for t in $_TOOLS_REAL; do
    if p="$(command -v "$t" 2>/dev/null)"; then ln -sf "$p" "${d}/${t}"
    else missing="${missing}${missing:+ }${t}"; fi
  done
  for t in $_TOOLS_STUB; do
    printf '#!/bin/sh\ncase "$1" in --version) echo 1.0.0 ;; esac\nexit 0\n' > "${d}/${t}"
    chmod +x "${d}/${t}"
  done
  # A CLI THAT ANSWERS "no such thing" to the one question doctor asks it —
  # `claude mcp get <name>` — which is what a real CLI answers on a machine
  # with no MCP server registered. Present-and-negative and absent are
  # different renders, and telling them apart is this suite's AC-7 pair.
  if [ "$want" = yes ]; then
    printf '#!/bin/sh\nexit 1\n' > "${d}/claude"; chmod +x "${d}/claude"
  else
    rm -f "${d}/claude"
  fi
  printf '%s' "$missing"
}

BIN="${TMP}/toolbox"
BIN_NO_CLAUDE="${TMP}/toolbox-no-claude"
_TOOLS_MISSING="$(make_tool_dir "$BIN" yes)$(make_tool_dir "$BIN_NO_CLAUDE" no)"
if [ -z "$_TOOLS_MISSING" ]; then ok "T0: the fixture's tool directory carries every program doctor runs"
else no "T0: a program doctor runs is missing from the fixture's tool directory" "$_TOOLS_MISSING"; fi

run_doctor() {  # -> doctor's whole output
  ( cd "$REPO" && HOME="$TMP" PATH="$BIN" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$TMP/claude-home" BIONIC_PLUGIN_ROOT="$PLUG" \
      BIONIC_PLUGINS_DIR="$EMPTY_PLUGINS" BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

run_doctor_no_claude() {  # -> the same page with the CLI off PATH
  ( cd "$REPO" && HOME="$TMP" PATH="$BIN_NO_CLAUDE" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$TMP/claude-home" BIONIC_PLUGIN_ROOT="$PLUG" \
      BIONIC_PLUGINS_DIR="$EMPTY_PLUGINS" BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}
mkdir -p "$TMP/claude-home/plugins"

# LOCALE-SAFE BY CONSTRUCTION. The glyph that opens every row is three BYTES and
# one column, and awk's `.` matches a CHARACTER only under a UTF-8 locale. Under
# `LC_ALL=C` — the locale scripts/lib/width.sh exists for, and the one a stripped
# environment hands a hook — `/^  . wall/` matched nothing, this function returned
# the empty string, and all seven row assertions below failed as "no match … in: ''"
# while the FIX-line assertions kept passing. `[^ ]+` counts bytes or characters
# indifferently, so the filter now says the same thing in either locale.
walls_rows() {  # <full-output> -> the walls summary row and any per-wall rows
  printf '%s\n' "$1" | awk '/^  [^ ]+ wall/'
}

section "Section 1: an intact tree — every wall's library resolves"

OUT1="$(run_doctor)"
ROWS1="$(walls_rows "$OUT1")"

expect_match "1: the walls row is a checkmark at four of four" "*✓ walls*4/4*" "$ROWS1"
expect_no_match "2: no per-wall failure row prints on an intact tree" "*cannot load*" "$ROWS1"
expect_no_match "3: no wall reaches the FIX section on an intact tree" \
  "*wall cannot load*" "$OUT1"

section "Section 2: one library deleted — the two walls that want it go red"

rm -f "$PLUG/scripts/lib/git-argv.sh"

OUT2="$(run_doctor)"
ROWS2="$(walls_rows "$OUT2")"

expect_match "4: the summary row drops to two of four and is a cross" "*✗ walls*2/4*" "$ROWS2"
expect_match "5: protect-main is named with the library it wanted" \
  "*protect-main*git-argv.sh*" "$ROWS2"
expect_match "6: the evidence gate is named with the library it wanted" \
  "*canonical-sdlc-evidence-gate*git-argv.sh*" "$ROWS2"
expect_no_match "7: a wall whose library is intact is not named" \
  "*background-suite-guard*" "$ROWS2"

# THE PARTY THIS LINE NAMES CHANGED AT 1.5.1, and the sentence is the reason. It
# used to end `run /bionic:setup — repair`, and there is no `repair` verb in
# setup's argv (`--all`, `--only`, `--list`): the line named a command that could
# not have worked. A wall that cannot reach its library is a broken install, so
# the party is the CLI, the same one a missing core dependency takes, and the
# route is read from the wall's own row in lib/checks.sh rather than pinned as a
# literal here — a pin that spelled the route again would be the second source
# the table exists to remove.
WALL_ROUTE="$( . "$PLUG/scripts/lib/checks.sh" >/dev/null 2>&1; bionic_check_hint wall-library )"
expect_true "8: the wall's own table row names a repair route (the row below is not vacuous)" \
  test -n "$WALL_ROUTE"
expect_match "8: the FIX section carries the repair-phrased line" \
  "*protect-main*cannot load*git-argv.sh*→ ${WALL_ROUTE}*" "$OUT2"
expect_no_match "8: …and never setup's phantom repair verb" \
  "*/bionic:setup — repair*" "$OUT2"

section "Section 3: the second library deleted — all four go red"

rm -f "$PLUG/scripts/lib/cmd-class.sh"

OUT3="$(run_doctor)"
ROWS3="$(walls_rows "$OUT3")"

expect_match "9: no wall resolves" "*✗ walls*0/4*" "$ROWS3"
expect_match "10: farm-out-reminder is named with cmd-class.sh" \
  "*farm-out-reminder*cmd-class.sh*" "$ROWS3"
expect_match "11: background-suite-guard is named with cmd-class.sh" \
  "*background-suite-guard*cmd-class.sh*" "$ROWS3"

section "Section 4: every line this report printed fits the column budget"

# lib/width.sh's rule, measured in COLUMNS: the glyph set is substituted away
# before the length is taken, exactly as bionic_cols does it.
too_wide() {  # <output> -> the offending lines, if any
  printf '%s\n' "$1" | awk '
    { s = $0
      gsub(/✓|✗|–|—|≥|…|·|→/, ".", s)
      if (length(s) > 100) print length(s) ": " $0 }'
}

for _n in 1 2 3; do
  eval "_out=\$OUT${_n}"
  _over="$(too_wide "$_out")"
  if [ -z "$_over" ]; then ok "12.${_n}: every line of run ${_n} fits 100 columns"
  else no "12.${_n}: a line of run ${_n} exceeds 100 columns" "$_over"; fi
done


section "Section 5: the claude CLI absent, and present, on one fixture (AC-7)"

# THE PAIR IS THE POINT, AND IT IS THE STATE THAT USED TO BREAK THIS SUITE.
# `claude` is the one program on the fixture's PATH whose presence changes what
# this page says: the four `mcp-server` rows are checked with `claude mcp get`,
# so with the CLI gone they turn from a plain absence into an UNKNOWN with a
# cause, and one of the fix lines that renders from that cause measured 105
# columns. Before the tool directory above, which half a run got was whatever
# the runner's PATH happened to hold. Now the fixture says, and both halves are
# asserted here — the absent render, and the present one that proves the absent
# assertion is not matching everything.
OUT_NOCLI="$(run_doctor_no_claude)"
OUT_WITHCLI="$(run_doctor)"

expect_match "13.1: with the CLI off PATH, an MCP row names that as the cause"   "*chrome-devtools*the claude CLI is not on PATH*" "$OUT_NOCLI"
expect_no_match "13.2: …and with the CLI present that cause is nowhere on the page"   "*the claude CLI is not on PATH*" "$OUT_WITHCLI"
expect_match "13.3: …which answers the same row from the CLI instead (the pair is not vacuous)"   "*chrome-devtools*not installed*" "$OUT_WITHCLI"
_over="$(too_wide "$OUT_NOCLI")"
if [ -z "$_over" ]; then ok "13.4: the CLI-absent page still fits 100 columns"
else no "13.4: a line of the CLI-absent page exceeds 100 columns" "$_over"; fi


section "Section 6: the page and the table's row read ONE wall verdict (Step-6 review B-2)"

# TWO IMPLEMENTATIONS OF ONE FACT, until the 1.5.1 fix-up batch. doctor's wall
# loop asked `is the file readable` and `does the loader answer` in its own
# render loop, while `bionic_check_wall_missing` and `bionic_check_wall_unloadable`
# in lib/checks.sh asked the same two questions for the row — and nothing ever
# invoked those two, so the copy this page ran and the copy the row named were
# free to drift with nothing going red. `bionic_check_wall_state` is the one
# implementation now, and this section is where it is asked on the very fixture
# the sections above rendered: both libraries are deleted at this point, so every
# wall is unloadable and none is missing.
wall_ask() {  # <expression> -> what checks.sh answers on THIS fixture's payload root
  ( cd "$REPO" && HOME="$TMP" PATH="$BIN" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$TMP/claude-home" BIONIC_PLUGIN_ROOT="$PLUG" \
      BIONIC_PLUGINS_DIR="$EMPTY_PLUGINS" \
      bash -c '. "$1" >/dev/null 2>&1 || exit 9; eval "$2"' _ \
      "$PLUG/scripts/lib/checks.sh" "$1" 2>/dev/null )
}

expect_eq "14.1: the row's per-wall verdict names the same library the page named" \
  "unloadable=git-argv.sh" "$(wall_ask 'bionic_check_wall_state protect-main')"
expect_match "14.2: …and the page it was taken from said exactly that" \
  "*protect-main*cannot load*git-argv.sh*" "$ROWS3"
expect_match "14.3: the wanted basenames come from the hook itself, not from a list here" \
  "*git-argv.sh*" "$(wall_ask "bionic_check_wall_want '$PLUG/hooks/protect-main.sh'")"
expect_match "14.4: the loader probe answers with an empty library and names the one it wanted" \
  "lib=|missing=git-argv.sh*" "$(wall_ask "bionic_check_wall_probe '$PLUG/hooks/protect-main.sh' git-argv.sh")"
# THE TWO ROW DETECTORS, over the same root: no wall FILE is gone, so the
# payload row is quiet, while every wall fails to load, so the library row fires.
expect_eq "14.5: the wall-payload row is quiet — no wall hook is missing here" \
  "no" "$(wall_ask 'bionic_check_fires wall-payload && echo yes || echo no')"
expect_eq "14.6: …while the wall-library row fires, which is what the page reported" \
  "yes" "$(wall_ask 'bionic_check_fires wall-library && echo yes || echo no')"
# PAIRED POSITIVE: put the library back and the same answers move with it, so
# none of the rows above is a constant.
cp "${PAYLOAD}/scripts/lib/git-argv.sh" "$PLUG/scripts/lib/git-argv.sh"
expect_eq "14.7: restoring the library flips that wall's verdict to ok" \
  "ok" "$(wall_ask 'bionic_check_wall_state protect-main')"
expect_match "14.8: …and doctor's page stops naming that wall on the same tree" \
  "*background-suite-guard*" "$(walls_rows "$(run_doctor)")"
expect_no_match "14.9: …while protect-main is no longer named at all" \
  "*protect-main*" "$(walls_rows "$(run_doctor)")"
# AND THE MISSING ARM, which the sections above never reach: take the hook file
# itself away and the payload row is the one that fires.
rm -f "$PLUG/hooks/protect-main.sh"
expect_eq "14.10: with the hook file itself gone the verdict is missing, not unloadable" \
  "missing" "$(wall_ask 'bionic_check_wall_state protect-main')"
expect_eq "14.11: …and the wall-payload row is what fires for it" \
  "yes" "$(wall_ask 'bionic_check_fires wall-payload && echo yes || echo no')"
expect_match "14.12: …which is the line doctor prints for that state" \
  "*protect-main*not in this payload*" "$(run_doctor)"

finish
