#!/bin/bash
# DETECT PROBES — epic-17 wave-06 slice S2 (spec R5/AC-8, AC-9; R8/AC-13).
#
# WHAT THIS SUITE OWNS. The two read-only probes added to
# payload/scripts/lib/detect.sh at W6, and nothing else:
#
#   detect_plugin_load_state <plugin-id>   is the CLI actually loading this plugin
#   detect_plugin_duplicates               two catalogs, one bare name
#
# WHY ITS OWN SUITE RATHER THAN A GROUP IN plugin-lib.test.sh (that suite was deleted
# at 8582861, epic-18 wave-03; the rationale below is historical). Different
# fixture regime. Every other detect function is driven against a fixture
# TREE; these two are driven against a captured CLI TRANSCRIPT and a planted
# registry, and the transcript fixtures are the evidence for the whole slice.
# Same reasoning that split spawn-worktree.test.sh out of plugin-lib.
#
# FIXTURE FIDELITY — THE POINT OF THIS SLICE, AND IT CAUGHT A REAL DEFECT.
#
# The slice was planned to build its fixtures from the `claude plugin list`
# output quoted in record/epic-17-w5/f12-runtime-report.md:84-132. It did, the
# first parser passed 50/50 against them, and then the same parser was pointed
# at the real CLI on this machine and answered `absent` for a plugin that was
# loaded. The report renders each plugin as ONE line; the CLI prints a BLOCK.
# The report's quote is a reflow, not bytes. A fixture derived from a summary is
# a fixture that can pin the test away from the behavior.
#
# So there are two families of listing fixture, and both are parsed:
#
#   tests/fixtures/plugin-list-healthy.txt        MEASURED, VERBATIM BYTES
#       <- `claude plugin list` on this machine, 2026-08-20, with the plugin
#          blocks unrelated to bionic's catalog removed (whole blocks only —
#          every retained byte is the CLI's). The shape under test: id alone on
#          a `❯` line, Version / Scope / Status indented beneath it.
#   tests/fixtures/plugin-list-dep-broken.txt     RECONSTRUCTED, AND LABELLED SO
#       <- the block layout above, carrying the failed status and the dependency
#          Error line VERBATIM from f12-runtime-report.md:131-132. No live
#          dependency-broken machine exists to capture (making one would
#          uninstall bionic mid-wave, plan A-0.3), so the layout is inferred
#          from the healthy capture and only the CLI's own words are quoted.
#          Everything the parser keys on — the `❯` line, `Status:`, `Error:` —
#          is measured; only the indentation of the Error line is inferred, and
#          the parser is indent-agnostic by construction.
#   tests/fixtures/plugin-list-f12-healthy.txt    THE REPORT'S RENDERING
#   tests/fixtures/plugin-list-f12-dep-broken.txt
#       <- f12-runtime-report.md:85-87 and :131-132, de-indented out of the
#          report's four-space code fence and otherwise untouched. Reproduce:
#            sed -n '85,87p'  <report> | sed 's/^    //' | diff - <fixture>
#            sed -n '131,132p' <report> | sed 's/^    //' | diff - <fixture>
#          Kept and asserted because it may equally be an OLDER CLI's real
#          output, and a probe whose wrong answer is a silent `absent` is not
#          worth betting on one release's formatting.
#
# The trailing `…` on the Error line is the REPORT's own elision of a longer CLI
# line, and it is kept: a parser that survives a truncated error line survives
# the real one, and inventing the missing tail would be the one thing fixture
# fidelity forbids.
#
# HERMETIC. No network, no `claude` CLI, no live ~/.claude. The listing command
# is reached only through the BIONIC_PLUGIN_LIST_CMD seam, pointed at a fixture
# file; the registry is reached only through BIONIC_INSTALLED_PLUGINS_FILE. PATH
# is REPLACED, not prefixed, so a real `claude` on this machine cannot be hit by
# accident — and one arm proves that by asserting the unstubbed default is
# `unknown`, not a live answer.
#
# BOTH ARMS, ALWAYS. Every state is asserted with its opposite beside it:
# loaded against failed, present against absent, jq against no-jq, a duplicate
# registry against a clean one.
#
# Usage: bash tests/detect-probes.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
DETECT_SH="${REPO}/payload/scripts/lib/detect.sh"
FIX_DIR="${REPO}/tests/fixtures"
FIX_HEALTHY="${FIX_DIR}/plugin-list-healthy.txt"
FIX_BROKEN="${FIX_DIR}/plugin-list-dep-broken.txt"
FIX_F12_HEALTHY="${FIX_DIR}/plugin-list-f12-healthy.txt"
FIX_F12_BROKEN="${FIX_DIR}/plugin-list-f12-dep-broken.txt"
FIX_DUP="${FIX_DIR}/installed-plugins-dup.json"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

# A bin dir carrying only what a hermetic run legitimately needs. PATH is
# REPLACED (never prefixed), so the real `claude` on this machine is
# unreachable from every arm below.
BASE_BIN="$TMP/base-bin"
mkdir -p "$BASE_BIN"
for real in bash sh env cat grep sed awk mkdir rm cp mv chmod ls tr head tail sort uniq wc jq; do
  p="$(command -v "$real" 2>/dev/null)" && ln -sf "$p" "${BASE_BIN}/${real}" 2>/dev/null
done
# The same bin dir minus jq — the degradation lane. Built by copying the links
# and deleting one, so the two lanes cannot drift apart.
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
for f in "$BASE_BIN"/*; do ln -sf "$(readlink "$f")" "${NOJQ_BIN}/${f##*/}" 2>/dev/null; done
rm -f "${NOJQ_BIN}/jq"

# probe_run <env-assignments...> -- <function> [args]
# One library function, fresh bash, controlled environment. R_PATH overrides
# the PATH for the no-jq / no-command arms.
#
# `${envs[@]+"${envs[@]}"}`, NEVER A BARE `"${envs[@]}"`. Under `set -u` bash 3.2
# — the /bin/bash every macOS ships, and the floor this suite is run against —
# treats the expansion of an EMPTY array as an unbound variable and aborts:
# `envs[@]: unbound variable`. Bash 4.4 and later special-case it. Every arm
# that passes no `<key>=<value>` before the `--` therefore died here rather than
# running, which is how the hermetic no-claude arm below read as a failure under
# the system interpreter while passing under a 5.x one. The `+` form expands to
# nothing at all when the array is empty and to the elements otherwise.
probe_run() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift  # drop --
  env -i \
    HOME="$TMP/home" \
    PATH="${R_PATH:-$BASE_BIN}" \
    ${envs[@]+"${envs[@]}"} \
    bash -c '. "$1"; shift; "$@"' _ "$DETECT_SH" "$@" 2>/dev/null
}

# Same, but keeps the exit status in P_ST and stderr in P_ERR.
probe_run_st() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  P_OUT=$(env -i HOME="$TMP/home" PATH="${R_PATH:-$BASE_BIN}" ${envs[@]+"${envs[@]}"} \
    bash -c '. "$1"; shift; "$@"' _ "$DETECT_SH" "$@" 2>"$TMP/probe.err")
  P_ST=$?
  P_ERR=$(cat "$TMP/probe.err")
}

section "Group 1: the fixtures are present and the library still sources"

# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)
expect_true "detect.sh passes bash -n" bash -n "$DETECT_SH"
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)

# Fixture fidelity, asserted rather than asserted-in-a-comment: the captured
# lines are still the shapes the parser is written against.
expect_match "healthy fixture carries the enabled status the CLI prints" \
  "*Status: ✔ enabled*" "$(cat "$FIX_HEALTHY")"
expect_match "dep-broken fixture carries the failed status the CLI prints" \
  "*Status: ✘ failed to load*" "$(cat "$FIX_BROKEN")"
expect_match "…and the dependency Error line beneath it" \
  "*Error: Dependency \"superpowers@bionic\" is not installed*" "$(cat "$FIX_BROKEN")"

# The two families are DIFFERENT SHAPES, and the suite says so out loud — if a
# later edit "tidied" one into the other, the reason both exist would vanish
# silently and the regression this slice caught could come straight back.
expect_eq "the measured fixture is a block format: the id line carries no status" \
  "0" "$(/usr/bin/grep -c '❯.*Status:' "$FIX_HEALTHY")"
expect_eq "…and the report's rendering is a one-line format: id and status together" \
  "3" "$(/usr/bin/grep -c '❯.*Status:' "$FIX_F12_HEALTHY")"

section "Group 2: detect_plugin_load_state — the four states"
#
# The contract (plan §S2):
#   load-state=<loaded|failed|absent|unknown> error=<verbatim Error: text or ->
# `unknown` additionally carries `cause=` — the honesty rule the rest of
# detect.sh already follows; the first two fields keep the plan's shape byte
# for byte, so a caller parsing only those is unaffected.

expect_eq "healthy listing: bionic@bionic is loaded" \
  "load-state=loaded error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_HEALTHY" -- detect_plugin_load_state bionic@bionic)"

expect_eq "…and so is a dependency in the same listing (not a bionic-only parse)" \
  "load-state=loaded error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_HEALTHY" -- detect_plugin_load_state superpowers@bionic)"

# THE ROW THIS SLICE EXISTS FOR (W5 F12): installed, green, and loading nothing.
expect_eq "dep-broken listing: bionic@bionic failed, with the CLI's own error verbatim" \
  'load-state=failed error=Dependency "superpowers@bionic" is not installed — run `claude plugin install superpowers@bionic`, …' \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_BROKEN" -- detect_plugin_load_state bionic@bionic)"

expect_eq "a plugin the listing does not name is absent, not unknown" \
  "load-state=absent error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_HEALTHY" -- detect_plugin_load_state nosuch@bionic)"

# Whole-token match: a longer id that CONTAINS a listed one is still absent.
expect_eq "'bionic@bionic-extras' is not 'bionic@bionic' (id matched whole, not by prefix)" \
  "load-state=absent error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_HEALTHY" -- detect_plugin_load_state bionic@bionic-extras)"

section "Group 2b: the same four states in the report's one-line rendering"
#
# THE REGRESSION THIS GROUP EXISTS FOR. The first cut of this parser was written
# against the one-line rendering alone and passed everything below — while
# answering `absent` against the real CLI, whose listing is the block format
# Group 2 drives. Both families are asserted from here on, and neither is
# allowed to be the only evidence for a state.

expect_eq "one-line rendering: bionic@bionic is loaded" \
  "load-state=loaded error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_F12_HEALTHY" -- detect_plugin_load_state bionic@bionic)"

expect_eq "one-line rendering: the dependency failure, error verbatim" \
  'load-state=failed error=Dependency "superpowers@bionic" is not installed — run `claude plugin install superpowers@bionic`, …' \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_F12_BROKEN" -- detect_plugin_load_state bionic@bionic)"

expect_eq "one-line rendering: a plugin it does not name is absent" \
  "load-state=absent error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_F12_HEALTHY" -- detect_plugin_load_state nosuch@bionic)"

# A listing with no `❯` glyph at all — the shape a future CLI would print into a
# pipe if it dropped its decoration. Still a listing; still parseable.
sed 's/❯ //' "$FIX_F12_HEALTHY" > "$TMP/noglyph.txt"
expect_eq "a glyphless one-line listing is still read, not called garbage" \
  "load-state=loaded error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/noglyph.txt" -- detect_plugin_load_state bionic@bionic)"

section "Group 3: detect_plugin_load_state — every way of not knowing"
#
# A-3.2: any unrecognized shape is `unknown`, NEVER `loaded`. The cheapest
# possible bug in a probe like this is a parser that treats "I could not read
# it" as "it is fine", because that reads green on exactly the broken machine
# the probe was written for.

printf 'this is not a plugin listing\nneither is this\n' > "$TMP/garbage.txt"
GARBAGE="$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/garbage.txt" -- detect_plugin_load_state bionic@bionic)"
expect_match "garbage output is unknown, never loaded and never absent" \
  "load-state=unknown *" "$GARBAGE"
expect_match "…and names its cause" "*cause=*" "$GARBAGE"
expect_no_match "…and does not smuggle a status into the error field" "*error=-*cause=*loaded*" "$GARBAGE"

: > "$TMP/empty.txt"
expect_match "empty output is unknown (no listing was recognized), never absent" \
  "load-state=unknown *" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/empty.txt" -- detect_plugin_load_state bionic@bionic)"

expect_match "a listing command that does not exist is unknown" \
  "load-state=unknown *" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="no-such-command-at-all" -- detect_plugin_load_state bionic@bionic)"

expect_match "a listing command that exits non-zero is unknown" \
  "load-state=unknown *" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/no-such-file" -- detect_plugin_load_state bionic@bionic)"

expect_match "no plugin id at all is unknown, not a guess about bionic" \
  "load-state=unknown *" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_HEALTHY" -- detect_plugin_load_state)"

# A recognized row whose status word is neither of the two we know.
printf '  ❯ bionic@bionic  0.1.0  user  Status: ✽ reticulating\n' > "$TMP/oddstatus.txt"
expect_match "an unrecognized status word is unknown, never loaded" \
  "load-state=unknown *" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/oddstatus.txt" -- detect_plugin_load_state bionic@bionic)"

# Installed and switched off. Not a failure, not loaded, and not one of the
# four states — so it is unknown, named for what it is.
printf '  ❯ bionic@bionic  0.1.0  user  Status: ✘ disabled\n' > "$TMP/disabled.txt"
DIS="$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/disabled.txt" -- detect_plugin_load_state bionic@bionic)"
expect_match "an installed-but-disabled plugin is unknown, never loaded" "load-state=unknown *" "$DIS"

# A block that names our plugin and then stops — truncated output, a listing
# interrupted. Named but statusless is not the same as enabled.
printf 'Installed plugins:\n\n  ❯ bionic@bionic\n    Version: 0.1.0\n' > "$TMP/nostatus.txt"
NOSTATUS="$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/nostatus.txt" -- detect_plugin_load_state bionic@bionic)"
expect_match "an entry with no Status line is unknown, never loaded" "load-state=unknown *" "$NOSTATUS"

# A neighbouring block's status must not be read as ours (block format).
{ printf 'Installed plugins:\n\n  ❯ bionic@bionic\n    Status: ✔ enabled\n\n'
  printf '  ❯ other@elsewhere\n    Status: ✘ failed to load\n'
  printf '    Error: Dependency "nope@nope" is not installed\n'; } > "$TMP/twoblocks.txt"
expect_eq "block format: a neighbour's failure is not ours" \
  "load-state=loaded error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/twoblocks.txt" -- detect_plugin_load_state bionic@bionic)"
expect_eq "block format: …and the neighbour keeps its own status and error" \
  'load-state=failed error=Dependency "nope@nope" is not installed' \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/twoblocks.txt" -- detect_plugin_load_state other@elsewhere)"

# `failed to load` with no Error: line beneath it — the state is still known.
printf '  ❯ bionic@bionic  0.1.0  user  Status: ✘ failed to load\n' > "$TMP/failed-bare.txt"
expect_eq "a failure with no Error line beneath it still reports failed, error=-" \
  "load-state=failed error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/failed-bare.txt" -- detect_plugin_load_state bionic@bionic)"

# An Error line belonging to the NEXT plugin must not be attributed to ours.
{ printf '  ❯ bionic@bionic  0.1.0  user  Status: ✔ enabled\n'
  printf '  ❯ other@elsewhere  1.0.0  user  Status: ✘ failed to load\n'
  printf '    Error: Dependency "nope@nope" is not installed\n'; } > "$TMP/twoplugins.txt"
expect_eq "another plugin's Error line is not attributed to ours" \
  "load-state=loaded error=-" \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/twoplugins.txt" -- detect_plugin_load_state bionic@bionic)"
expect_match "…and the neighbour keeps its own error" \
  'load-state=failed error=Dependency "nope@nope" is not installed' \
  "$(probe_run BIONIC_PLUGIN_LIST_CMD="cat $TMP/twoplugins.txt" -- detect_plugin_load_state other@elsewhere)"

# THE SEAM ITSELF. Unstubbed, on a PATH with no `claude`, the default command
# is unreachable — so the answer is unknown. This is what proves the hermetic
# claim above: nothing in this suite can reach the live CLI.
expect_match "with no seam set and no claude on PATH, the default is unknown (hermetic proof)" \
  "load-state=unknown *" \
  "$(probe_run -- detect_plugin_load_state bionic@bionic)"
expect_true "detect.sh names 'claude plugin list' as the seam's default" \
  /usr/bin/grep -q 'BIONIC_PLUGIN_LIST_CMD-claude plugin list' "$DETECT_SH"

# AN EXPLICITLY-EMPTY SEAM IS HONOURED AS EMPTY (six-axis review C-3). `${VAR:-d}`
# treats "" as unset and falls back to the default, so a suite that CLEARED the
# variable instead of pointing it at a fixture reached the real CLI and passed —
# the guard at the top of the probe was unreachable through its own seam. `${VAR-d}`
# is the one-character difference: set-but-empty stays empty and meets the guard.
EMPTY_SEAM="$(probe_run BIONIC_PLUGIN_LIST_CMD="" -- detect_plugin_load_state bionic@bionic)"
expect_match "an explicitly-empty seam reaches the empty-command guard" \
  "load-state=unknown *" "$EMPTY_SEAM"
# The negative half: an empty seam must not fall back to the real listing. PATH here
# carries no `claude` at all, so the fallback's own cause sentence is the tell.
expect_no_match "…and never falls back to the shipped default command" \
  "*claude plugin list*" "$EMPTY_SEAM"

section "Group 4: detect_plugin_load_state exits 0 and writes nothing"
#
# The file's output contract: fact functions REPORT. Callers parse fields;
# they never branch on the exit code.

for arm in "$FIX_HEALTHY" "$FIX_BROKEN" "$TMP/garbage.txt"; do
  probe_run_st BIONIC_PLUGIN_LIST_CMD="cat $arm" -- detect_plugin_load_state bionic@bionic
  expect_eq "exit 0 even for ${arm##*/}" "0" "$P_ST"
done
probe_run_st BIONIC_PLUGIN_LIST_CMD="no-such-command-at-all" -- detect_plugin_load_state bionic@bionic
expect_eq "exit 0 even when the listing command is missing" "0" "$P_ST"
expect_eq "…and says nothing on stderr (doctor renders this in a table cell)" "" "$P_ERR"

section "Group 5: detect_plugin_duplicates — bare-name collisions across catalogs"
#
# Bare-name collision = two registry keys whose split(\"@\")[0] match. The loser
# in `fix=` is the non-@bionic copy when one side is @bionic; with no @bionic
# side the fix names both ids and says to choose one.

DUP_OUT="$(probe_run BIONIC_INSTALLED_PLUGINS_FILE="$FIX_DUP" -- detect_plugin_duplicates)"
expect_eq "the planted registry yields exactly two duplicate rows" \
  "2" "$(printf '%s\n' "$DUP_OUT" | /usr/bin/grep -c '^dup=')"
expect_eq "bionic's own duplicate names the foreign copy as the loser" \
  "dup=bionic ids=bionic@bionic,bionic@claude-plugins-official fix=claude plugin uninstall bionic@claude-plugins-official" \
  "$(printf '%s\n' "$DUP_OUT" | /usr/bin/grep '^dup=bionic ')"
expect_eq "superpowers' duplicate names the foreign copy as the loser" \
  "dup=superpowers ids=superpowers@bionic,superpowers@claude-plugins-official fix=claude plugin uninstall superpowers@claude-plugins-official" \
  "$(printf '%s\n' "$DUP_OUT" | /usr/bin/grep '^dup=superpowers ')"
expect_no_match "the non-colliding row in the same file is silent" "*agent-skills*" "$DUP_OUT"

# NO @bionic SIDE: bionic has no standing to pick a winner, so it does not.
NEUTRAL="$TMP/neutral.json"
cat > "$NEUTRAL" <<'JSON'
{ "version": 2, "plugins": {
  "foo@alpha": [ { "scope": "user", "installPath": "/tmp/a", "version": "1.0.0" } ],
  "foo@beta":  [ { "scope": "user", "installPath": "/tmp/b", "version": "2.0.0" } ] } }
JSON
expect_eq "two foreign copies: the fix names both and says to choose" \
  "dup=foo ids=foo@alpha,foo@beta fix=choose one: claude plugin uninstall foo@alpha, or claude plugin uninstall foo@beta" \
  "$(probe_run BIONIC_INSTALLED_PLUGINS_FILE="$NEUTRAL" -- detect_plugin_duplicates)"

section "Group 6: detect_plugin_duplicates — the negative arms"

CLEAN="$TMP/clean.json"
cat > "$CLEAN" <<'JSON'
{ "version": 2, "plugins": {
  "agent-skills@bionic": [ { "scope": "user", "installPath": "/tmp/as", "version": "0.6.7" } ],
  "bionic@bionic":       [ { "scope": "user", "installPath": "/tmp/b",  "version": "0.1.0" } ],
  "superpowers@bionic":  [ { "scope": "user", "installPath": "/tmp/sp", "version": "6.3.0" } ] } }
JSON
probe_run_st BIONIC_INSTALLED_PLUGINS_FILE="$CLEAN" -- detect_plugin_duplicates
expect_eq "a registry with no collision prints nothing at all" "" "$P_OUT"
expect_eq "…and exits 0" "0" "$P_ST"
expect_eq "…and says nothing on stderr" "" "$P_ERR"

probe_run_st BIONIC_INSTALLED_PLUGINS_FILE="$TMP/no-such-registry.json" -- detect_plugin_duplicates
expect_eq "no registry file means nothing is installed, so no duplicates" "" "$P_OUT"
expect_eq "…and exits 0" "0" "$P_ST"

# Present and unparseable is NOT the same as absent: it supports no claim.
printf '%s' '{"plugins": {' > "$TMP/malformed.json"
MAL="$(probe_run BIONIC_INSTALLED_PLUGINS_FILE="$TMP/malformed.json" -- detect_plugin_duplicates)"
expect_match "an unparseable registry is unknown, never a clean bill of health" \
  "dup=unknown ids=- fix=- cause=*" "$MAL"

# No jq: the registry cannot be read honestly, so it is not read.
NOJQ="$(R_PATH="$NOJQ_BIN" probe_run BIONIC_INSTALLED_PLUGINS_FILE="$FIX_DUP" -- detect_plugin_duplicates)"
expect_match "without jq the answer is unknown, not silence" "dup=unknown ids=- fix=- cause=*" "$NOJQ"

# The seam chain is detect.sh's existing one, unchanged.
CH_DIR="$TMP/ch-dup"; mkdir -p "$CH_DIR/plugins"
cp "$FIX_DUP" "$CH_DIR/plugins/installed_plugins.json"
expect_match "BIONIC_CLAUDE_HOME reaches the same registry (the shared chain)" \
  "*dup=bionic ids=bionic@bionic,bionic@claude-plugins-official*" \
  "$(probe_run BIONIC_CLAUDE_HOME="$CH_DIR" -- detect_plugin_duplicates)"
expect_match "CLAUDE_CONFIG_DIR is honoured when BIONIC_CLAUDE_HOME is not set" \
  "*dup=superpowers *" \
  "$(probe_run CLAUDE_CONFIG_DIR="$CH_DIR" -- detect_plugin_duplicates)"

section "Group 6b: detect_plugin_duplicates is BOUNDED, by the same runner (A-6.6 (b))"
#
# WHAT WAS UNBOUNDED. W6 S11 gave the load-state probe a bound and gave it ONE owner
# (`detect_bounded`), on the stated ground that a probe bionic does not control can wedge
# and take its caller with it. This probe was left out because it reads a file rather than
# running the CLI — but the READ is `jq`, an external program, over a path that can sit on
# a stalled mount, and S12 then put the probe on setup's `--list` path where a stranger
# meets it before anything else has printed. A bound one of two probes has is a bound the
# product does not have.
#
# WHAT THE ANSWER MUST BE. Not silence: silence means "no duplicates", which is a claim a
# probe that could not look has not earned (A-4.S2.8, the same rule the no-jq lane obeys).
# So a timeout renders as the `dup=unknown … cause=` line S2 established, and every caller
# already knows that shape.

SLOWJQ_BIN="$TMP/slowjq-bin"
mkdir -p "$SLOWJQ_BIN"
for f in "$BASE_BIN"/*; do ln -sf "$(readlink "$f")" "${SLOWJQ_BIN}/${f##*/}" 2>/dev/null; done
# `sleep` is what the bound polls with, and BASE_BIN does not carry it — without it on PATH
# `detect_bounded` degrades to an unbounded `wait` by design, which would make this arm
# measure the degradation instead of the bound.
SLEEP_REAL="$(command -v sleep 2>/dev/null)"
[ -n "$SLEEP_REAL" ] && ln -sf "$SLEEP_REAL" "${SLOWJQ_BIN}/sleep"
# (fixture-only check removed epic-18 W3 4/6: no production subject -- see ledger-detect-probes.md)

# A jq that stalls on THE DUPLICATES PROGRAM ONLY. Every other jq call in the library — the
# registry parses the same run makes — is the real one, so the arm measures this probe's
# bound and not a PATH that broke everything at once.
JQ_REAL="$(command -v jq 2>/dev/null)"
rm -f "${SLOWJQ_BIN}/jq"
cat > "${SLOWJQ_BIN}/jq" <<STUB
#!/bin/bash
case "\$*" in
  *'group_by(split("@")[0])'*) /bin/sleep 45; echo "too late"; exit 0 ;;
  *) exec "${JQ_REAL}" "\$@" ;;
esac
STUB
chmod +x "${SLOWJQ_BIN}/jq"

DUP_START="$(date +%s)"
R_PATH="$SLOWJQ_BIN" probe_run_st BIONIC_DOCTOR_PROBE_SECONDS=2 \
  BIONIC_INSTALLED_PLUGINS_FILE="$FIX_DUP" -- detect_plugin_duplicates
DUP_ELAPSED=$(( $(date +%s) - DUP_START ))
unset R_PATH

expect_true "a stalled registry read does not wedge the caller: it returns inside 10s" \
  bash -c '[ "$1" -le 10 ]' _ "$DUP_ELAPSED"
expect_match "…and the answer is unknown, carrying its cause" \
  "dup=unknown ids=- fix=- cause=*" "$P_OUT"
expect_eq "…and exits 0, like every other lane of this probe" "0" "$P_ST"
# NEVER INVENTS ONE. The fixture registry holds two real collisions; a probe that was cut
# off mid-parse must hand back none of them, not a half-read line.
expect_eq "…and reports no duplicate it did not finish reading" "1" \
  "$(printf '%s\n' "$P_OUT" | /usr/bin/grep -c .)"
expect_no_match "…specifically not the collision the fixture holds" "*dup=bionic *" "$P_OUT"
echo "      (bounded duplicates arm: elapsed=${DUP_ELAPSED}s, bound=2s, probe sleeps 45s)"

# ONE OWNER. The bound is `detect_bounded`'s, reached from this probe — not a second
# implementation beside it.
expect_true "the duplicates probe reaches the shared bound rather than carrying its own" \
  /usr/bin/grep -q 'detect_bounded "$(detect_probe_seconds)" _detect_plugin_duplicates_probe' \
  "$DETECT_SH"

# The unwedged lanes are unchanged by the bound: same lines, same silence.
expect_match "with a jq that answers, the duplicate is still found" \
  "*dup=bionic ids=bionic@bionic,bionic@claude-plugins-official*" \
  "$(probe_run BIONIC_INSTALLED_PLUGINS_FILE="$FIX_DUP" -- detect_plugin_duplicates)"

section "Group 7: read-only is a contract, not an intention"
#
# Same wall the rest of detect.sh lives under: fingerprint the inputs, run
# every probe, fingerprint again.

fingerprint() {  # <path...> -> one digest line per file
  local f
  for f in "$@"; do
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" 2>/dev/null
    else echo "no-digest-tool $f"; fi
  done
}
BEFORE="$(fingerprint "$FIX_HEALTHY" "$FIX_BROKEN" "$FIX_F12_HEALTHY" "$FIX_F12_BROKEN" "$FIX_DUP" "$CH_DIR/plugins/installed_plugins.json")"
probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_HEALTHY" -- detect_plugin_load_state bionic@bionic >/dev/null
probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_BROKEN" -- detect_plugin_load_state bionic@bionic >/dev/null
probe_run BIONIC_INSTALLED_PLUGINS_FILE="$FIX_DUP" -- detect_plugin_duplicates >/dev/null
probe_run BIONIC_CLAUDE_HOME="$CH_DIR" -- detect_plugin_duplicates >/dev/null
probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_F12_HEALTHY" -- detect_plugin_load_state bionic@bionic >/dev/null
probe_run BIONIC_PLUGIN_LIST_CMD="cat $FIX_F12_BROKEN" -- detect_plugin_load_state bionic@bionic >/dev/null
AFTER="$(fingerprint "$FIX_HEALTHY" "$FIX_BROKEN" "$FIX_F12_HEALTHY" "$FIX_F12_BROKEN" "$FIX_DUP" "$CH_DIR/plugins/installed_plugins.json")"
expect_eq "neither probe changed a byte of anything it read" "$BEFORE" "$AFTER"
expect_eq "…and neither created a file beside the registry" \
  "installed_plugins.json" "$(ls "$CH_DIR/plugins")"

finish
