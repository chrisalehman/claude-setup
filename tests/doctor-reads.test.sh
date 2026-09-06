#!/bin/bash
# tests/doctor-reads.test.sh — the facts doctor gathered and never printed, and
# the pnpm-store diagnosis (bionic 1.4.0, wave-bionic-1.4.0-update slice DOCTOR
# handoff 4.6, spec AC-23).
#
# THE TWO CONTRACTS UNDER TEST.
#
#   (a) pnpm-store, UNREADABLE-INDEX DIAGNOSIS. `_dep_check_pnpm_store` answers
#       `unknown` in exactly three situations — pnpm is not on PATH, the store
#       path did not resolve, or the store holds no `index.db` — and doctor
#       answered all three with one sentence: "a cache, no presence surface".
#       That sentence stopped being true at the commit that gave the store a
#       surface (its index names every cached `<name>@<version>`), and a reader
#       told a cache has no surface cannot act, while a reader told which file
#       could not be read can.
#
#   (b) COMPUTED, NEVER PRINTED. Four probes ran on every doctor invocation and
#       reached no reader: the installed agent copies and their drift, the
#       legacy hook files on disk, the duplicate-registry scan, and the path of
#       the legacy installed skill copy. A probe nobody renders is a cost with no
#       benefit and, worse, a fact this machine HAD and did not tell anyone.
#
# HERMETIC. Every fixture is built under one mktemp root: a claude-home whose
# `agents/`, `hooks/` and `skills/` hold planted leftovers, a plugin registry
# written by hand, and a pnpm shim on a prepended PATH so the store branch can be
# driven without this machine's own pnpm.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below.
#
# Usage: bash tests/doctor-reads.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
DOCTOR_SH="${PAYLOAD}/scripts/doctor.sh"

command -v jq >/dev/null 2>&1 || { echo "doctor-reads.test.sh: jq is required"; exit 1; }

# THE 100-COLUMN RULE, MEASURED THE WAY width.sh MEASURES IT — every glyph in
# `_bionic_cols_into`'s closed set substituted for one ASCII character before the
# length is taken. Defined here rather than beside its first caller because two
# sections use it now: Section 8's sweep over the fullest run, and Section 6f's
# pin on the one line whose fixed part grows with the catalog name.
too_wide() {  # <text> -> the offending lines, empty when every line fits
  printf '%s\n' "$1" | awk '
    { s = $0
      gsub(/✓|✗|–|—|≥|…|·|→|•/, ".", s)
      if (length(s) > 100) print length(s) ": " $0 }'
}

# A SHORT ROOT ON PURPOSE. macOS hands `mktemp -d` a ~50-character path under
# /var/folders, and two of the rows below print a PATH inside a 100-column row —
# a fixture path half again longer than a real `~/.claude` would be measures the
# truncator rather than the row. `/tmp/...` is the shape a real machine has.
TMP="$(mktemp -d /tmp/bionic-doctor-reads.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CHOME="${TMP}/claude-home"
mkdir -p "${CHOME}/plugins"
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

run_doctor() {  # [extra env assignments as NAME=VALUE ...]
  ( cd "$REPO" && env "$@" \
      PATH="$BIN" HOME="$TMP" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
      BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

run_doctor_no_claude() {  # [extra env assignments] — the CLI off PATH
  ( cd "$REPO" && env "$@" \
      PATH="$BIN_NO_CLAUDE" HOME="$TMP" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
      BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

section "Section 1: pnpm-store — the cause names the file that could not be read"

# A store directory with no index.db. `_dep_check_pnpm_store` answers `unknown`
# here, and the row's cause is what this section is about.
EMPTY_STORE="${TMP}/pnpm-store-empty"
mkdir -p "$EMPTY_STORE"

OUT1="$(run_doctor "BIONIC_PNPM_STORE=${EMPTY_STORE}")"
ROW1="$(printf '%s\n' "$OUT1" | awk '/motion/')"

expect_match "1: the row names the missing store index" \
  "*motion*no store index at*" "$ROW1"
expect_no_match "2: the retired 'no presence surface' sentence is gone from the motion row" \
  "*motion*no presence surface*" "$ROW1"

section "Section 2: pnpm-store — a readable index answers, and says nothing extra"

FULL_STORE="${TMP}/pnpm-store-full"
mkdir -p "$FULL_STORE"
# `_dep_check_pnpm_store` runs `strings` over the index and matches
# `<name>@<version>`; a plain file carrying that token is enough of an index.
printf 'some binary-ish preamble\nmotion@12.3.4\nmore\n' > "${FULL_STORE}/index.db"

OUT2="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"
ROW2="$(printf '%s\n' "$OUT2" | awk '/motion/')"

expect_match "3: a readable index reports the cached version" "*motion*12.3.4*" "$ROW2"
expect_no_match "4: and carries no unreadable-index cause" "*index.db*" "$ROW2"

section "Section 3: the installed agent copies, and their drift, reach the page"

# A payload agent copied into the claude-home and then EDITED: the probe's
# `drift` count is exactly this, and nothing rendered it.
mkdir -p "${CHOME}/agents"
_first_agent="$(ls "${PAYLOAD}/agents/"*.md 2>/dev/null | head -1)"
expect_true "5: the payload ships agents to compare against" test -n "$_first_agent"
_agent_name="${_first_agent##*/}"
cp "$_first_agent" "${CHOME}/agents/${_agent_name}"
printf '\n# a local edit\n' >> "${CHOME}/agents/${_agent_name}"

OUT3="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

expect_match "6: the drifted installed copy is named" \
  "*installed agent*${_agent_name}*" "$OUT3"
expect_match "7: and it carries a repair" "*installed agent*/bionic:setup*" "$OUT3"

section "Section 4: legacy hook files on disk reach the page"

mkdir -p "${CHOME}/hooks"
cp "${PAYLOAD}/hooks/protect-main.sh" "${CHOME}/hooks/protect-main.sh" 2>/dev/null
cp "${PAYLOAD}/hooks/stop-guard.sh" "${CHOME}/hooks/stop-guard.sh" 2>/dev/null

OUT4="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

expect_match "8: the count of legacy hook FILES is printed" "*legacy hook file*2*" "$OUT4"
expect_match "9: and it carries a repair" "*legacy hook file*/bionic:setup*" "$OUT4"

section "Section 5: the legacy skill copy names its path"

mkdir -p "${CHOME}/skills/canonical-sdlc"
printf -- "---\nname: canonical-sdlc\n---\n" > "${CHOME}/skills/canonical-sdlc/SKILL.md"

OUT5="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

# HOME-RELATIVE, which is both what fits the row and what a reader would type.
# `run_doctor` sets HOME=$TMP and the claude-home under it, so the row reads
# `~/claude-home/skills/canonical-sdlc`.
expect_match "10: the row names the directory a reader has to go to" \
  "*legacy installed skill copy*~/claude-home/skills/canonical-sdlc*" "$OUT5"

section "Section 6: the duplicate-registry scan reaches the page"

# One plugin registered twice under two marketplaces — the state the probe was
# written for, and whose consolidation command it already computes.
jq -nc '{plugins:{
    "bionic@bionic":[{installPath:"/nonexistent/a", gitCommitSha:"deadbeef"}],
    "bionic@my-fork":[{installPath:"/nonexistent/b", gitCommitSha:"cafebabe"}]
  }}' > "${CHOME}/plugins/installed_plugins.json"

OUT6="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

expect_match "11: the duplicate is named" "*duplicate*bionic*" "$OUT6"
expect_match "12: with the consolidation command the probe computed" \
  "*claude plugin uninstall bionic@my-fork*" "$OUT6"

section "Section 6b: a renderer venv stale against uv.lock renders as a re-sync"

# THE VENV FINDING (wave assumptions, 22:30Z). `_dep_check_uv_project` gained a
# third state — `stale`, a venv built against a DIFFERENT `uv.lock` than the one
# now shipped — and doctor's three `case "$present"` sites folded it into their
# catch-all, so a stale venv rendered like `unknown` with a cause about a
# mechanism that keeps no presence surface. AC-17's whole point is that this state
# is REPAIRED and not re-offered, which it cannot be while nothing names it.
#
# The fixture is the shape the probe reads: a venv at the stable machine-local
# path with a python in it, a shipped `uv.lock` beside the references, and a
# recorded hash that does not match it.
VENV_DIR="${TMP}/.local/share/bionic/excalidraw-venv"
mkdir -p "${VENV_DIR}/bin"
printf '#!/bin/sh\nexit 0\n' > "${VENV_DIR}/bin/python"
chmod +x "${VENV_DIR}/bin/python"
REFS="${TMP}/refs"
mkdir -p "$REFS"
printf 'version = 1\n' > "${REFS}/uv.lock"
printf 'not-the-hash-of-that-lockfile\n' > "${VENV_DIR}.lock.sha256"

OUT6B="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}" "BIONIC_EXCALIDRAW_REFS=${REFS}")"
ROW6B="$(printf '%s\n' "$OUT6B" | awk '/excalidraw-renderer/')"

expect_match "12b1: the row says the venv is stale" "*excalidraw-renderer*stale*" "$ROW6B"
expect_match "12b2: and names a re-sync" "*excalidraw-renderer*re-sync*" "$ROW6B"
expect_no_match "12b3: never the no-presence-surface catch-all" \
  "*excalidraw-renderer*no presence surface*" "$ROW6B"
expect_no_match "12b4: and never 'not installed', which is a different machine" \
  "*excalidraw-renderer*not installed*" "$ROW6B"

# A matching hash is not stale, and says nothing extra.
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${REFS}/uv.lock" | awk '{print $1}' > "${VENV_DIR}.lock.sha256"
  else
    sha256sum "${REFS}/uv.lock" | awk '{print $1}' > "${VENV_DIR}.lock.sha256"
  fi
  OUT6C="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}" "BIONIC_EXCALIDRAW_REFS=${REFS}")"
  ROW6C="$(printf '%s\n' "$OUT6C" | awk '/excalidraw-renderer/')"
  expect_no_match "12b5: a matching lock hash is not reported stale" "*stale*" "$ROW6C"
else
  no "12b5: neither shasum nor sha256sum is on PATH"
fi

section "Section 6c: setup treats stale as a re-sync, never as a fresh offer"

# STRUCTURAL, AND PINNED TO THE MECHANISM RATHER THAN TO A SENTENCE. AC-17 says a
# stale venv is "re-synced, not re-offered", and the thing that decides whether a
# question is asked is `SETUP_ALL` — `install_dep` skips its `_dep_consent` call
# under it. So the assertion is that `_setup_install_class` has a `stale` arm and
# that the arm raises SETUP_ALL around the install rather than falling into the
# catch-all that offers the row like a fresh one.
SETUP_SH="${PAYLOAD}/scripts/setup.sh"
STALE_ARM="$(awk '/^_setup_install_class\(\)/{f=1} f' "$SETUP_SH" | awk '/^}/{exit} {print}' | awk '/stale\)/{f=1} f' | awk '/;;/{print; exit} {print}')"
if [ -n "$STALE_ARM" ]; then ok "12c1: _setup_install_class has a stale arm"
else no "12c1: _setup_install_class has no stale arm — stale falls into the catch-all"; fi
case "$STALE_ARM" in
  *SETUP_ALL=1*) ok "12c2: the arm suppresses the install question" ;;
  *) no "12c2: the stale arm would ask the install question again" "$(printf '%.300s' "$STALE_ARM")" ;;
esac
case "$STALE_ARM" in
  *_setup_install_one*) ok "12c3: and it actually runs the sync" ;;
  *) no "12c3: the stale arm names no installer" ;;
esac

section "Section 6d: a settings.json still naming npx flags a defect (epic-21 AC-3)"

# THE NETWORK-PER-RENDER DEFECT (bug-ccstatusline-npx-per-render.md, Fix step 5). A
# `statusLine.command` that still starts with `npx ` is the pre-fix shape: Claude Code
# runs that command on every render, and `npx pkg@latest` resolves a registry lookup
# before it can print anything. Nothing rewrites settings.json on its own, so a machine
# written before this fix stays broken until a person re-runs setup — which is exactly
# what doctor has to tell them.
cat > "${CHOME}/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "npx ccstatusline@latest"
  }
}
JSON

# THE WHOLE PRE-1.4.4 MACHINE, NOT HALF OF IT (1.4.4 T5). `_dep_check_statusline` reads two
# halves — the recorded command and the layout file under ~/.config/ccstatusline — and a
# fixture with only the first would report the row absent for the LAYOUT's sake, which is a
# different fact from the one this section is about. Copying the shipped layout in makes the
# recorded command the only thing wrong on this machine, which is the state every machine
# that ran setup before 1.4.4 is actually in.
mkdir -p "${TMP}/.config/ccstatusline"
cp "${PAYLOAD}/ccstatusline/settings.json" "${TMP}/.config/ccstatusline/settings.json"

OUT6D="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

expect_match "12d1: the npx statusLine command is flagged as a defect" \
  "*statusLine command*npx*" "$OUT6D"
# THE HINT IS A PROMISE, AND IT IS KEPT NOW (1.4.4 T5, review-b F-1). This row used to pin a
# false promise: `_dep_check_statusline` accepted the npx string as proof the dependency was
# present, so `tool:ccstatusline` was never pending and the setup run doctor names here
# reported "nothing left to do" with the ✗ still on the screen. The presence check rejects
# the npx form now, which is what puts an item behind the hint —
# tests/cross-gate-agreement.test.sh §DS.2 is the row that proves setup actually offers it.
expect_match "12d2: and the row names re-running setup" \
  "*statusLine command*npx*/bionic:setup*" "$OUT6D"

# ONE MACHINE, ONE ANSWER (1.4.4 T5, review-a C-4). Doctor's THIRD PARTY table and its
# ENVIRONMENT table are two renderings of the same machine, and on this fixture they used to
# contradict each other seventeen lines apart: `✓ ccstatusline … command set, layout file in
# place` above, `✗ statusLine command … still uses npx` below. A reader cannot act on a
# report that says the thing is fine and broken at once.
ROW6D="$(printf '%s\n' "$OUT6D" | grep -E '^  . +ccstatusline ' | head -1)"
expect_true "12d4: doctor renders a THIRD PARTY row for ccstatusline (the two rows below are not vacuous)" \
  test -n "$ROW6D"
expect_no_match "12d5: the THIRD PARTY row does not call the npx machine's status line healthy" \
  "*command set, layout file in place*" "$ROW6D"
expect_match "12d6: it agrees with the ENVIRONMENT row and sends the reader to the same place" \
  "*not installed → /bionic:setup*" "$ROW6D"

# THE FIXED FORM MUST NOT BE FLAGGED — a bare binary name never blocks on the
# network, so this is not a defect and the row must stay silent (format rule 4).
cat > "${CHOME}/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "ccstatusline"
  }
}
JSON
OUT6E="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"
expect_no_match "12d3: the installed-binary command form is never flagged" \
  "*statusLine command*npx*" "$OUT6E"

echo ""
section "Section 6f: an absent CORE dependency routes to the CLI, not /bionic:setup (1.4.4 fixit)"

# A CORE DEPENDENCY IS BIONIC'S OWN. `payload/.claude-plugin/plugin.json` declares
# superpowers and agent-skills as bionic's dependencies and the CLI installs them alongside
# bionic itself (`"auto": true` in the registry) — no setup item installs one, and deps.sh's
# D1 says setup never installs a native row. So a machine missing one is not a
# `/bionic:setup` repair, and the row that used to end that way sent the reader to a command
# that plans nothing for it (.bionic/docs/ideas/fixit-1.4.4-absent-core-dependency-hint.md;
# the same class the 1.4.4 bug report describes). The repair is the CLI's own verb, measured
# restoring the dependency at record/epic-21-v1-ladder/fixit-dep-repair-measurement.md.
#
# A REGISTRY THAT KNOWS BIONIC AND NEITHER DEPENDENCY is the shape of an install that came
# in incomplete — which is the machine epic-17 W5 F12 §4.1 measured, where `claude plugin
# list` prints `✘ failed to load` and names the missing dependency.
jq -nc '{plugins:{"bionic@bionic":[{installPath:"/nonexistent/a", gitCommitSha:"deadbeef", version:"1.4.4"}]}}' \
  > "${CHOME}/plugins/installed_plugins.json"

# AND THE LEFTOVERS SECTIONS 3-5 PLANTED ARE SWEPT BACK OFF, so the only thing wrong with
# this machine is its dependencies. That is the machine the fixit is about, and it is also
# what makes the two headline rows below load-bearing: the verdict line is truncated at 100
# columns, so while the fixture carries leftover hook files and drifted agent copies those
# names lead the line and the collapsed dependency list is cut off the end of it — an
# assertion about which names reach that line would then pass on a doctor nobody had fixed.
rm -rf "${CHOME}/hooks" "${CHOME}/agents" "${CHOME}/skills"

# THE RENDERER REFS ARE PASSED, and that is what makes the headline rows below
# load-bearing. Section 6c left `${VENV_DIR}.lock.sha256` matching `${REFS}/uv.lock`, so this
# run has no stale-venv fix line — without it that line leads the verdict and the collapsed
# absence list is cut off the end of it before any dependency name is reached, which would
# let 12f5b pass on a doctor that had never been fixed.
OUT6F="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}" "BIONIC_EXCALIDRAW_REFS=${REFS}")"
ROW6F="$(printf '%s\n' "$OUT6F" | grep -E '^  . +superpowers ' | head -1)"
ROW6F2="$(printf '%s\n' "$OUT6F" | grep -E '^  . +agent-skills ' | head -1)"

expect_true "12f1: doctor renders a THIRD PARTY row for the absent core dependency (the rows below are not vacuous)" \
  test -n "$ROW6F"
expect_match "12f2: the row names the CLI verb that re-resolves bionic's dependencies" \
  "*superpowers*absent → claude plugin install bionic@bionic*" "$ROW6F"
expect_no_match "12f3: …and never /bionic:setup, which installs nothing for a core row" \
  "*/bionic:setup*" "$ROW6F"
expect_match "12f4: the second core dependency's row carries the same route" \
  "*agent-skills*absent → claude plugin install bionic@bionic*" "$ROW6F2"

# THE HEADLINE IS THE SAME PROMISE, ONE LINE HIGHER. The collapsed
# `N dependencies absent (…) → run /bionic:setup` verdict is the line a reader acts on
# first, so a core absence folded into it is the same broken remedy in the place it is most
# likely to be read.
VERDICT6F="$(printf '%s\n' "$OUT6F" | grep -F 'Run /bionic:setup to fix:' | head -1)"
# The line is TRUNCATED at 100 columns — it is the one place doctor cuts names rather than
# wrapping them — so the anchor is the FIRST absent name on it, which is the first one setup
# actually installs.
expect_match "12f5a: the collapsed setup verdict is on the page and names what setup DOES install" \
  "*Run /bionic:setup to fix:*dependencies absent (impeccable*" "$VERDICT6F"
expect_no_match "12f5b: …and it never names an absent core dependency, which setup cannot install" \
  "*superpowers*" "$VERDICT6F"
expect_match "12f6: the core absences get their own line, with the route on it" \
  "*core dependencies absent (superpowers, agent-skills) → claude plugin install bionic@bionic*" \
  "$OUT6F"

# THE PROBLEM COUNT IS ROWS, NOT CATEGORIES (Chris 2026-08-22, and doctor.sh's own comment
# at the swap), and adding a class of absence must not change what that sentence means. The
# verdict collapses the setup-fixable absences into one fix line and swaps that line for the
# number of ✗ dependency rows it stands for; the core absences are a SECOND collapsed line
# over rows the same tally already counts, so counting both lines AND all the rows counts
# the core rows twice.
#
# MEASURED AGAINST A SECOND RENDER, NEVER A HARDCODED TOTAL. The expected count depends on
# how many other things are wrong with the fixture — the unwritten environment settings here
# — and writing that total down would pin the fixture instead of the rule. So the same
# machine is rendered twice, once with the two core dependencies in the registry and once
# without, and the rule is the difference: putting two absent core rows on the page adds
# exactly two problems. Everything else about the two machines is identical, so every
# non-dependency fix line cancels out of the subtraction. Before the fix the difference was
# three.
d6f_problems() {  # <doctor report> -> the N in "→ N problems."
  sed -n 's/^→ \([0-9][0-9]*\) problem.*/\1/p' <<<"$1" | head -1
}
# EVERY ✗ ON THE PAGE, whichever table it is in — the unit doctor's own comment
# says the headline is counted in ("THE PROBLEM COUNT IS ROWS, NOT CATEGORIES").
page_bad_rows() {  # <doctor report> -> the count of ✗ rows anywhere in it
  grep -c '^  ✗' <<<"$1" || true
}

d6f_bad_dep_rows() {  # <doctor report> -> the count of ✗ rows in the THIRD PARTY table
  awk '/^THIRD PARTY/ { i = 1; next }
       i && /^[A-Z][A-Z]/ { exit }
       i && /^  ✗ / { n++ }
       END { print n + 0 }' <<<"$1"
}

# The same fixture with both core dependencies present — the only difference between the two
# machines.
jq -nc '{plugins:{
    "bionic@bionic":       [{installPath:"/nonexistent/a", gitCommitSha:"deadbeef", version:"1.4.4"}],
    "superpowers@bionic":  [{installPath:"/nonexistent/s", version:"6.3.0"}],
    "agent-skills@bionic": [{installPath:"/nonexistent/g", version:"0.6.7"}]
  }}' > "${CHOME}/plugins/installed_plugins.json"
OUT6FOK="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}" "BIONIC_EXCALIDRAW_REFS=${REFS}")"

D6F_N_BAD="$(d6f_problems "$OUT6F")";  D6F_ROWS_BAD="$(d6f_bad_dep_rows "$OUT6F")"
D6F_N_OK="$(d6f_problems "$OUT6FOK")"; D6F_ROWS_OK="$(d6f_bad_dep_rows "$OUT6FOK")"

# Anti-vacuity: both renders produced a count, and the core-absent one really does carry the
# two extra rows. Without these the subtraction below could be 0 = 0 over two empty strings.
expect_match "12f9: both renders report a problem count" \
  "[0-9]*|[0-9]*" "${D6F_N_BAD}|${D6F_N_OK}"
expect_eq "12f10: …and the core-absent machine carries exactly two more ✗ dependency rows" \
  "2" "$(( D6F_ROWS_BAD - D6F_ROWS_OK ))"
# THE HEADLINE COUNT AGAINST THE ROWS IT STANDS FOR (1.4.4 A-10, folded in at
# wave-01 S4 as this slice's one agreement assertion). The 1.4.4 walk measured a
# machine whose headline said 21 while 24 ✗ rows were printed under it — the
# collapse arithmetic subtracting one line per collapsed CLASS while the rows it
# stood for were counted somewhere else. Two numbers on one page, disagreeing,
# and nothing said so.
#
# THE GENERAL RULE IS `count >= rows`: every ✗ row is a problem, so the headline
# can never be the smaller number, and the 1.4.4 defect is exactly that
# inequality broken. ON THIS FIXTURE IT IS EQUALITY, which is the sharper pin
# and the one taken here, because every problem this machine has renders as a
# row — no stale proxy, no legacy block, no degraded plugin, none of the states
# that earn a fix line without a table row. A fixture change that adds one of
# those turns this into a legitimate inequality and this assertion into the
# place to say so.
expect_eq "12f18: the headline count agrees with the ✗ rows it stands for" \
  "$(page_bad_rows "$OUT6F")" "$D6F_N_BAD"

expect_eq "12f11: …so it reports exactly two more problems, not three" \
  "$(( D6F_ROWS_BAD - D6F_ROWS_OK ))" "$(( D6F_N_BAD - D6F_N_OK ))"

# Back to the core-absent registry, which is what the rows below read.
jq -nc '{plugins:{"bionic@bionic":[{installPath:"/nonexistent/a", gitCommitSha:"deadbeef", version:"1.4.4"}]}}' \
  > "${CHOME}/plugins/installed_plugins.json"

# THE PAIRED POSITIVE, so neither scan above is a constant: `impeccable` is an `extra` native
# row, absent from the same registry, and setup's install arms DO install it — so its row
# still ends where it always did.
ROW6FX="$(printf '%s\n' "$OUT6F" | grep -E '^  . +impeccable ' | head -1)"
expect_true "12f7: doctor renders a THIRD PARTY row for the absent extra dependency too" \
  test -n "$ROW6FX"
expect_match "12f8: a basic/extra absence still routes to /bionic:setup on the same fixture" \
  "*impeccable*not installed → /bionic:setup*" "$ROW6FX"

# THE CATALOG IS DERIVED ON EVERY SURFACE, NEVER SPELLED (1.4.4 fixit phase 4, review-b
# B-10). Three files compose the plugin id this route names — deps.sh's `dep_plugin_id`,
# doctor.sh's `BIONIC_PLUGIN_ID`, setup.sh's `SETUP_PLUGIN_ID` — and every assertion above
# pins the rendered default `bionic@bionic`. Nothing in the tree re-pointed the catalog, so
# any one of those three could have been edited back to a literal and the whole suite stayed
# green. This render moves the catalog and asserts the moved name reaches both of doctor's
# surfaces, which is the one thing a literal cannot do.
#
# NINETEEN CHARACTERS ON PURPOSE. The headline's fixed part grows with the route, so the
# name length is what decides whether that line obeys the report's own 100-column rule — and
# a cap copied from another line's budget passes at `bionic` and overflows here (review-a
# A-2, review-c C-2). The row is a different story and is asserted differently below.
OUT6FMK="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}" "BIONIC_EXCALIDRAW_REFS=${REFS}" \
  "BIONIC_DEP_MARKETPLACE=chrisalehman-bionic")"
ROW6FMK="$(printf '%s\n' "$OUT6FMK" | grep -E '^  . +superpowers ' | head -1)"
HEAD6FMK="$(printf '%s\n' "$OUT6FMK" | grep -F 'core dependencies absent' | head -1)"

expect_true "12f12: the re-pointed catalog still renders a core row (the rows below are not vacuous)" \
  test -n "$ROW6FMK"
expect_true "12f13: …and a headline core line (the rows below are not vacuous)" \
  test -n "$HEAD6FMK"

# THE ROW carries the moved catalog, and only its first thirteen columns: at this name
# length `bionic_line` has no budget left for the instruction slot and truncates the route
# with the rest of the tail (review-a A-1, promoted out of this slice — the row still tells
# the truth about which catalog it means, and the headline below carries the command whole).
# What this row pins is the derivation, which is what B-10 found unpinned.
expect_match "12f14: the row's route names the re-pointed catalog" \
  "*claude plugin install bionic@chris*" "$ROW6FMK"
expect_no_match "12f15: …and never the default one, which is what a literal would still have printed" \
  "*bionic@bionic*" "$ROW6FMK"
# THE HEADLINE carries it whole, and the pattern ends where the line does: the route is the
# last thing on it, so a cap that ate the command instead of the names would fail here.
expect_match "12f16: the headline core line ends with the re-pointed catalog, whole" \
  "*core dependencies absent (*) → claude plugin install bionic@chrisalehman-bionic" "$HEAD6FMK"
# AND IT STILL FITS. The names on this line are capped, and the cap has to be THIS line's
# budget — 100 columns less its own fixed part, which the route is part of — not the 44 the
# THIRD PARTY row's state cell is worth. Both numbers leave the line whole at `bionic`; at
# this catalog the 44 overflows by seven columns.
expect_eq "12f17: …and the whole line still fits 100 columns" "" "$(too_wide "$HEAD6FMK")"

section "Section 7: nothing this file gathers is left unrendered"

# THE STRUCTURAL HALF, and it is the one that keeps this class of defect from
# coming back: a top-level assignment in doctor.sh whose name is never read
# anywhere else in the file is a probe that ran for nobody. Four such reads are
# what this slice was dispatched about; the assertion is that the count does not
# GROW, which is what a hardcoded allow-list gives and a bare zero would not
# (the roster-footprint block and the dependency tallies are dead too, are out of
# this slice, and are named here so the wall is honest about what it tolerates).
# WHAT THIS WALL DELIBERATELY TOLERATES, and it is a bigger list than the four
# reads this slice was dispatched about. `DEP_ROWS` is the whole DEPENDENCIES
# table and `ROSTER_ROWS` the whole roster-footprint table: both are built row by
# row on every invocation and NEITHER IS EVER PRINTED — doctor's own header still
# describes "three tables", and only two of them reach the page. The five
# dependency tallies and `TODO_STATE` are dead beside them. Rendering or deleting
# those is a decision about what the report IS, not a cosmetic read, so this slice
# names them here rather than settling them quietly (DOCTOR report, concerns).
KNOWN_DEAD="N_PRESENT N_ABSENT N_UNKNOWN N_VIOLATION N_ABSENT_WHEN_NEEDED ROSTER_TOTAL ROSTER_TOTAL_KNOWN ROSTER_ZERO TODO_STATE DEP_ROWS ROSTER_ROWS"
if ! command -v python3 >/dev/null 2>&1; then
  no "13: python3 is needed for the never-read sweep"
else
  UNREAD="$(python3 - "$PAYLOAD/scripts/doctor.sh" "$KNOWN_DEAD" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
allowed = set(sys.argv[2].split())
names = set(re.findall(r'^([A-Z_][A-Z0-9_]*)=', src, re.M))
names |= set(re.findall(r';\s*([A-Z_][A-Z0-9_]*)=', src))
# STATEMENTS, NOT LINES. `FACT="$(probe)"; STATE="${FACT#...}"` is two statements
# on one line, and at line granularity the second one's read of FACT is masked by
# the first one's assignment to it.
stmts = [st for ln in src.splitlines() for st in ln.split(';')]
dead = []
for n in sorted(names):
    if n in allowed:
        continue
    # Every line that ASSIGNS to n is dropped first, so `n=$((n + 1))` — a
    # counter incrementing itself — does not count as somebody reading it.
    read_somewhere = False
    for ln in stmts:
        targets = set(re.findall(r'(?:^|;|\s)([A-Z_][A-Z0-9_]*)=', ln))
        # `$n` / `${n}` is a read wherever it appears; a BARE `n` counts only on
        # a line that does not assign to n, which is what tells a counter
        # incrementing itself apart from somebody else consuming it.
        if re.search(r'\$\{?' + n + r'\b', ln) and n not in targets:
            read_somewhere = True; break
        if n not in targets and re.search(r'\b' + n + r'\b', ln):
            read_somewhere = True; break
    if not read_somewhere:
        dead.append(n)
print(' '.join(dead))
PY
)"
  if [ -z "$UNREAD" ]; then ok "13: every fact doctor gathers is read by something"
  else no "13: a fact is computed and never read" "$UNREAD"; fi
fi

section "Section 8: the column budget"

_over="$(too_wide "$OUT6")"
if [ -z "$_over" ]; then ok "15: every line of the fullest run fits 100 columns"
else no "15: a line exceeds 100 columns" "$_over"; fi


section "Section 9: the claude CLI absent, and present, on one fixture (AC-7)"

# THE PAIR IS THE POINT, AND IT IS THE STATE THAT USED TO BREAK THIS SUITE.
# `claude` is the one program on the fixture's PATH whose presence changes what
# this page says: the four `mcp-server` rows are checked with `claude mcp get`,
# so with the CLI gone they turn from a plain absence into an UNKNOWN with a
# cause, and one of the fix lines that renders from that cause measured 105
# columns. Before the tool directory above, which half a run got was whatever
# the runner's PATH happened to hold. Now the fixture says, and both halves are
# asserted here — the absent render, and the present one that proves the absent
# assertion is not matching everything.
OUT_NOCLI="$(run_doctor_no_claude "BIONIC_PNPM_STORE=${FULL_STORE}")"
OUT_WITHCLI="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

expect_match "16.1: with the CLI off PATH, an MCP row names that as the cause"   "*chrome-devtools*the claude CLI is not on PATH*" "$OUT_NOCLI"
expect_no_match "16.2: …and with the CLI present that cause is nowhere on the page"   "*the claude CLI is not on PATH*" "$OUT_WITHCLI"
expect_match "16.3: …which answers the same row from the CLI instead (the pair is not vacuous)"   "*chrome-devtools*not installed*" "$OUT_WITHCLI"
_over="$(too_wide "$OUT_NOCLI")"
if [ -z "$_over" ]; then ok "16.4: the CLI-absent page still fits 100 columns"
else no "16.4: a line of the CLI-absent page exceeds 100 columns" "$_over"; fi

section "Section 10: the headline moves by the rows a collapse stands for (Walk-D1)"

# THE WALK'S DRIVE 1e, TURNED INTO A WALL. The Step-5 walk rendered a machine
# whose headline said 17 over 19 lines carrying ✗, wrote the three environment
# names into settings.json, and watched three ✗ rows disappear while the headline
# moved by ONE. Two collapsed lines on that page were swapped for the rows they
# stood for and the third — `N of bionic's environment settings … → run
# /bionic:setup` — was not, so it counted as one problem over three rendered
# rows.
#
# WHY THIS IS A DELTA AND NOT A TOTAL. Section 6f already pins headline against
# ✗ rows on its own fixture, and equality held there while this defect was live:
# the same page carried two `presence is unknown` fix lines whose ✗ dependency
# rows were counted a second time by the dependency tally, and +2 cancelled the
# environment line's -2 exactly. A page-total assertion cannot see a pair of
# errors that sum to zero. The DIFFERENCE between two renders of one machine
# can: everything that is not the environment block is identical across the two,
# so it subtracts out, and what is left is the question this section asks.
_env_settings="${CHOME}/settings.json"
D10_BEFORE="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

# The three names written with bionic's OWN values — `env_default`'s, which is
# what `bionic_check_env_unwritten` compares against — merged into whatever
# settings.json already holds, so the statusLine row above is untouched and the
# environment block is the only difference between the two machines.
jq '.env = ((.env // {}) + {
      "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1",
      "BASH_MAX_TIMEOUT_MS": "1800000",
      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
    })' "$_env_settings" > "${TMP}/settings-env.json" && mv "${TMP}/settings-env.json" "$_env_settings"
D10_AFTER="$(run_doctor "BIONIC_PNPM_STORE=${FULL_STORE}")"

d10_env_rows() {  # <doctor report> -> the count of ✗ rows for the three env names
  grep -cE '^  ✗ (CLAUDE_CODE_ENABLE_TODO_TOOLS|BASH_MAX_TIMEOUT_MS|CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS) ' <<<"$1" || true
}

D10_ENV_BEFORE="$(d10_env_rows "$D10_BEFORE")"
D10_ENV_AFTER="$(d10_env_rows "$D10_AFTER")"
D10_ROWS_BEFORE="$(page_bad_rows "$D10_BEFORE")"
D10_ROWS_AFTER="$(page_bad_rows "$D10_AFTER")"
D10_N_BEFORE="$(d6f_problems "$D10_BEFORE")"
D10_N_AFTER="$(d6f_problems "$D10_AFTER")"

# ANTI-VACUITY, THREE WAYS: the environment rows really were ✗ before, really are
# not after, and the whole-page ✗ count moved by exactly those three. Without
# these the delta assertion below could be 0 = 0 over two identical pages.
expect_eq "18.1: the three environment names render ✗ before they are written" \
  "3" "$D10_ENV_BEFORE"
expect_eq "18.2: …and none of them after" "0" "$D10_ENV_AFTER"
expect_eq "18.3: …so the page carries exactly three fewer ✗ rows" \
  "3" "$(( D10_ROWS_BEFORE - D10_ROWS_AFTER ))"
expect_match "18.4: both renders report a problem count" \
  "[0-9]*|[0-9]*" "${D10_N_BEFORE}|${D10_N_AFTER}"

# THE ASSERTION. The environment line is a collapse like the dependency lines and
# the dead-session line, so it is worth the rows it stands for and the headline
# moves with them. Before the fix this read 1 against 3.
expect_eq "18.5: the headline moves by the number of ✗ rows the collapse stands for" \
  "$(( D10_ROWS_BEFORE - D10_ROWS_AFTER ))" "$(( D10_N_BEFORE - D10_N_AFTER ))"

# AND THE TOTAL, ON A FIXTURE WHERE IT IS AN EQUALITY. Section 6f takes this over
# a page whose two errors cancelled; here the same rule is asked of a page where
# the environment block is the only collapse left with anything to collapse.
expect_eq "18.6: the headline agrees with the ✗ rows it stands for, before" \
  "$D10_ROWS_BEFORE" "$D10_N_BEFORE"
expect_eq "18.7: …and after" "$D10_ROWS_AFTER" "$D10_N_AFTER"

finish
