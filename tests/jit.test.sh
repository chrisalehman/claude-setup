#!/bin/bash
# JIT / DEGRADATION — epic-17 wave-03 slice S10 (spec AC-5).
#
# WHAT THIS SUITE OWNS. payload/scripts/lib/jit.sh: the route-facing
# degradation contract — jit_check (presence + named fix) and jit_offer
# (states the offer, asks ONE consented question via deps.sh's install_dep,
# degrades cleanly on decline).
#
# THE OWNERSHIP-TABLE AGREEMENT (wave-03 spec §Design, "per-dep install" row):
# jit_offer must not grow a private second installer. It has to call install_dep
# BY NAME so the setup loop and a route's JIT offer always reach the identical
# function. Group 3 below proves that dynamically: it OVERRIDES install_dep
# with a recorder stub AFTER sourcing jit.sh and BEFORE calling jit_offer —
# bash resolves a function call by name at call time, so if jit_offer's "yes"
# path lands in the override, jit_offer contains no private copy of the
# install logic.
#
# HERMETIC, same regime tests/plugin-lib.test.sh used to run (deleted at
# 8582861, epic-18 wave-03): no network, no live
# ~/.claude, PATH replaced outright with a controlled bin dir (real coreutils
# symlinked in, everything else a recorder stub).
#
# Usage: bash tests/jit.test.sh
# Registered by name in tests/run.sh (tests/*.test.sh is NOT auto-globbed).

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
JIT_SH="${REPO}/payload/scripts/lib/jit.sh"
DEPS_SH="${REPO}/payload/scripts/lib/deps.sh"

# expect_eq, expect_true, expect_false, expect_match, expect_empty are the
# framework's (tests/lib/assert.sh) — identical semantics to the private
# definitions this suite carried (same argument order, same glob match for
# expect_match, same silencing for expect_true/expect_false) (S7, AC-12).

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture builders (mirrored tests/plugin-lib.test.sh, deleted at 8582861, epic-18 wave-03)
# ---------------------------------------------------------------------------

make_stub() {  # <bindir> <name> [exit-code]
  local bindir="$1" name="$2" rc="${3:-0}"
  mkdir -p "$bindir"
  cat > "${bindir}/${name}" <<STUB
#!/bin/bash
echo "${name} \$*" >> "\$BIONIC_TEST_CALLS"
exit ${rc}
STUB
  chmod +x "${bindir}/${name}"
}

BASE_BIN="$TMP/base-bin"
mkdir -p "$BASE_BIN"
for real in bash sh env cat grep sed awk mkdir rm cp mv chmod ls dirname basename tr head tail sort uniq wc jq python3; do
  p="$(command -v "$real" 2>/dev/null)" && ln -sf "$p" "${BASE_BIN}/${real}" 2>/dev/null
done

mkdir -p "$TMP/home"
CALLS="$TMP/calls.log"; : > "$CALLS"

# jit_run <env-assignments...> -- <function> [args]   — sources jit.sh (which
# sources deps.sh itself), then runs one function in a fresh bash.
jit_run() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift  # drop --
  env -i \
    HOME="$TMP/home" \
    PATH="$BASE_BIN" \
    BIONIC_TEST_CALLS="$CALLS" \
    "${envs[@]}" \
    bash -c '. "$1"; shift; "$@"' _ "$JIT_SH" "$@" 2>&1
}

PRESENT_BIN="$TMP/present-bin"
cp -R "$BASE_BIN/." "$PRESENT_BIN/" 2>/dev/null || { mkdir -p "$PRESENT_BIN"; cp -R "$BASE_BIN/." "$PRESENT_BIN/"; }
make_stub "$PRESENT_BIN" rg
make_stub "$PRESENT_BIN" npm
make_stub "$PRESENT_BIN" brew

section "Group 1: jit.sh exists, sources cleanly, passes bash -n"

# (file-exists fixture check removed epic-18 W3 4/6: no production subject -- see ledger-jit.md)
expect_true "jit.sh sources without error" bash -c '. "$1"' _ "$JIT_SH"
expect_true "jit.sh passes bash -n" bash -n "$JIT_SH"
expect_true "jit.sh sourcing defines jit_check" \
  bash -c '. "$1"; declare -F jit_check' _ "$JIT_SH"
expect_true "jit.sh sourcing defines jit_offer" \
  bash -c '. "$1"; declare -F jit_offer' _ "$JIT_SH"
expect_true "sourcing jit.sh also pulls in deps.sh's check_dep (self-source guard)" \
  bash -c '. "$1"; declare -F check_dep' _ "$JIT_SH"

section "Group 2: jit_check — both arms"

expect_true "jit_check rg: present on PATH -> exit 0" \
  bash -c 'env -i HOME="$1" PATH="$2" bash -c ". \"\$1\"; jit_check rg" _ "$3"' _ "$TMP/home" "$PRESENT_BIN" "$JIT_SH"

ABSENT_OUT="$(jit_run PATH="$BASE_BIN" -- jit_check rg)"; ABSENT_RC=$?
expect_true "jit_check rg: absent from PATH -> exit 1" test "$ABSENT_RC" -ne 0


expect_false "jit_check on an unknown dep exits non-zero" \
  bash -c '. "$1"; jit_check no-such-dep' _ "$JIT_SH"

section "Group 3: the ownership-table agreement — jit_offer calls install_dep BY NAME"
#
# Override install_dep AFTER sourcing jit.sh, BEFORE calling jit_offer. If
# jit_offer's "yes" path reaches the override, it has no private installer —
# it dispatches to whatever function is bound to that name, which in
# production is deps.sh's own single mutating entry point.

TRACE="$TMP/install-dep-trace.log"; : > "$TRACE"
env -i HOME="$TMP/home" PATH="$BASE_BIN" BIONIC_TEST_TRACE="$TRACE" \
  bash -c '
    . "$1"
    install_dep() { echo "install_dep-override $*" >> "$BIONIC_TEST_TRACE"; return 0; }
    echo y | jit_offer rg some-route "a capability" "it degrades"
  ' _ "$JIT_SH" >/dev/null 2>&1
expect_match "jit_offer(yes) reaches the function literally named install_dep" \
  "*install_dep-override rg*" "$(cat "$TRACE")"

section "Group 4: jit_offer — consent path invokes the real install_dep (production behavior)"

: > "$CALLS"
env -i HOME="$TMP/home" PATH="$PRESENT_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c 'echo y | { . "$1"; jit_offer rg some-route "fast search" "grep is used instead"; }' \
  _ "$JIT_SH" >/dev/null 2>&1
expect_match "jit_offer(yes) drives the real brew install (via install_dep)" \
  "*brew install ripgrep*" "$(cat "$CALLS")"


section "Group 5: jit_offer — declined path (AC-5's clean-degrade half)"

: > "$CALLS"
DECLINE_ERR="$(env -i HOME="$TMP/home" PATH="$PRESENT_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c '. "$1"; jit_offer rg some-route "fast search" "grep is used instead" </dev/null' _ "$JIT_SH" 2>&1 1>/dev/null)"
: > "$CALLS"
DECLINE_RC="$(env -i HOME="$TMP/home" PATH="$PRESENT_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c '. "$1"; jit_offer rg some-route "fast search" "grep is used instead" </dev/null; echo $?' _ "$JIT_SH" 2>/dev/null | tail -1)"

expect_true "jit_offer(decline, no stdin answer) returns non-zero" test "$DECLINE_RC" -ne 0
expect_empty "jit_offer(decline) writes nothing to stderr (no cryptic failure)" "$DECLINE_ERR"
expect_eq "jit_offer(decline) ran nothing (recorder empty — no mutation)" "0" \
  "$(grep -c . "$CALLS" | tr -d ' ')"

# Explicit "n" — the other spelling of decline.
: > "$CALLS"
DECLINE_N_OUT="$(env -i HOME="$TMP/home" PATH="$PRESENT_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c 'echo n | { . "$1"; jit_offer rg some-route "fast search" "grep is used instead"; }' _ "$JIT_SH" 2>&1)"
expect_eq "jit_offer(explicit n) ran nothing" "0" "$(grep -c . "$CALLS" | tr -d ' ')"

section "Group 6: no assume-yes knob (S1-8 stands)"
#
# jit.sh must not grow an env-var bypass around consent — the same rule
# tests/plugin-lib.test.sh used to pin for install_dep itself; that suite was
# deleted at 8582861 (epic-18 wave-03) and nothing replaced the pin there.

# Matches an actual env-var-shaped bypass token (BIONIC_..._YES, ASSUME_YES=,
# etc.) — not this file's own prose ("no assume-yes knob"), which is
# lowercase-hyphenated and would false-positive a looser pattern.
expect_true "jit.sh source carries no assume-yes / auto-yes env-var bypass" \
  bash -c '! grep -qE "[A-Z_]*_(ASSUME|AUTO)_?YES|(ASSUME|AUTO)_?YES[A-Z_]*=" "$1"' _ "$JIT_SH"
expect_true "jit.sh reads stdin only through install_dep (no private read of its own)" \
  bash -c '! grep -qE "^[[:space:]]*read " "$1"' _ "$JIT_SH"

section "Group 7: mutation-and-restore — decline mutates NOTHING, proven twice, two mechanisms"
#
# Two independent fixture roots, two different install mechanisms (brew-dep
# and npm-global), fingerprinted before/after a decline each. A single proof
# could coincidentally hold for one mechanism's code path and not the other.

fingerprint() { find "$1" -type f -exec ls -l {} \; 2>/dev/null | awk '{print $5, $9}' | sort; }

# Mutation-and-restore #1: rg (brew-dep).
FP1_ROOT="$TMP/fp1"; mkdir -p "$FP1_ROOT"; cp -R "$PRESENT_BIN/." "$FP1_ROOT/bin/" 2>/dev/null || { mkdir -p "$FP1_ROOT/bin"; cp -R "$PRESENT_BIN/." "$FP1_ROOT/bin/"; }
: > "$CALLS"
FP1_BEFORE="$(fingerprint "$FP1_ROOT")"
env -i HOME="$TMP/home" PATH="$FP1_ROOT/bin" BIONIC_TEST_CALLS="$CALLS" \
  bash -c '. "$1"; jit_offer rg some-route "fast search" "grep is used instead" </dev/null' _ "$JIT_SH" >/dev/null 2>&1
FP1_AFTER="$(fingerprint "$FP1_ROOT")"
expect_eq "mutation-and-restore #1: recorder log still empty" "0" "$(grep -c . "$CALLS" | tr -d ' ')"

# Mutation-and-restore #2: @playwright/cli (npm-global) — the canonical
# environment-class dep this slice was scoped around.
FP2_ROOT="$TMP/fp2"; mkdir -p "$FP2_ROOT"; cp -R "$PRESENT_BIN/." "$FP2_ROOT/bin/" 2>/dev/null || { mkdir -p "$FP2_ROOT/bin"; cp -R "$PRESENT_BIN/." "$FP2_ROOT/bin/"; }
: > "$CALLS"
FP2_BEFORE="$(fingerprint "$FP2_ROOT")"
env -i HOME="$TMP/home" PATH="$FP2_ROOT/bin" BIONIC_TEST_CALLS="$CALLS" \
  bash -c '. "$1"; jit_offer @playwright/cli browser-verify "browser driving" "T2/T3 rows are blocked, not silently skipped" </dev/null' \
  _ "$JIT_SH" >/dev/null 2>&1
FP2_AFTER="$(fingerprint "$FP2_ROOT")"
expect_eq "mutation-and-restore #2: recorder log still empty" "0" "$(grep -c . "$CALLS" | tr -d ' ')"

section "Group 8: jit_check absence-vs-presence, driven against @playwright/cli too"

expect_true "jit_check @playwright/cli: present -> exit 0" \
  bash -c 'env -i HOME="$1" PATH="$2" BIONIC_TEST_CALLS="$3" bash -c ". \"\$1\"; jit_check @playwright/cli" _ "$4"' \
  _ "$TMP/home" "$PRESENT_BIN" "$CALLS" "$JIT_SH"
PW_ABSENT_OUT="$(jit_run PATH="$BASE_BIN" -- jit_check @playwright/cli)"; PW_ABSENT_RC=$?
expect_true "jit_check @playwright/cli: absent -> exit 1" test "$PW_ABSENT_RC" -ne 0
expect_match "jit_check @playwright/cli absent: names a fix (npm install -g)" \
  "*npm install -g @playwright/cli*" "$PW_ABSENT_OUT"

section "Group 9: route wiring — the two owner SKILL.md files name the contract"
#
# S2's dispatch-paragraph precedent: name the contract, let the script bind —
# no restated mechanics. One sentence each, at the point an environment-class
# dependency is assumed.

CANONICAL_SKILL="${REPO}/skills/canonical-sdlc/SKILL.md"
BROWSER_SKILL="${REPO}/skills/browser-verify/SKILL.md"
EXCALIDRAW_SKILL="${REPO}/payload/skills/excalidraw-diagram/SKILL.md"

expect_true "canonical-sdlc SKILL.md names jit_check" grep -q 'jit_check' "$CANONICAL_SKILL"
expect_true "canonical-sdlc SKILL.md names jit_offer" grep -q 'jit_offer' "$CANONICAL_SKILL"
expect_true "browser-verify SKILL.md names jit_check" grep -q 'jit_check' "$BROWSER_SKILL"
expect_true "browser-verify SKILL.md names jit_offer" grep -q 'jit_offer' "$BROWSER_SKILL"
expect_true "excalidraw-diagram SKILL.md names jit_check" grep -q 'jit_check' "$EXCALIDRAW_SKILL"
expect_true "excalidraw-diagram SKILL.md names jit_offer" grep -q 'jit_offer' "$EXCALIDRAW_SKILL"

section "Group 9b: the native when-needed row — ONE question, ONE installer (AC-11)"
#
# THE RULING THIS PINS (plan A-4.S4.4-RULING). `impeccable` is `when-needed` AND
# `native`: the moment to install it is the moment the design route asks, and
# `install_dep` refuses every native row by design. S4 resolved that by printing
# a command and asking nothing, which narrowed AC-11's "one question at the
# moment of need" for exactly one row. The ruling put the fix at the layer it
# lives instead — ONE native-plugin installer in deps.sh, called by BOTH setup's
# first step and this offer — so AC-11 holds literally and jit.sh is still not a
# second installer. This group asserts all three halves: the question is asked,
# the CLI is what installs, and the function reached is deps.sh's by NAME.
#
# The offer still returns NON-ZERO on a successful install, and that is not a
# leftover: a plugin the CLI installed mid-session is not loaded into the
# session that asked for it until the plugins are re-read. Telling the route
# "you have it now" would be the one lie this contract exists to prevent.

NATIVE_BIN="$TMP/native-bin"; mkdir -p "$NATIVE_BIN"
cp -R "$PRESENT_BIN/." "$NATIVE_BIN/"
make_stub "$NATIVE_BIN" claude

: > "$CALLS"
NATIVE_YES_OUT="$(env -i HOME="$TMP/home" PATH="$NATIVE_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c 'echo y | { . "$1"; jit_offer impeccable design-route "design work" "the route continues without it"; }' \
  _ "$JIT_SH" 2>&1)"
expect_match "native row (yes): the install reaches the CLI, scoped to the marketplace id" \
  "*plugin install impeccable@bionic*" "$(cat "$CALLS")"

NATIVE_YES_RC="$(env -i HOME="$TMP/home" PATH="$NATIVE_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c 'echo y | { . "$1"; jit_offer impeccable design-route "design work" "the route continues without it"; }; echo $?' \
  _ "$JIT_SH" 2>/dev/null | tail -1)"
expect_true "native row (yes): returns non-zero — installed is not loaded in THIS session" \
  test "$NATIVE_YES_RC" -ne 0

: > "$CALLS"
NATIVE_NO_OUT="$(env -i HOME="$TMP/home" PATH="$NATIVE_BIN" BIONIC_TEST_CALLS="$CALLS" \
  bash -c '. "$1"; jit_offer impeccable design-route "design work" "the route continues without it" </dev/null' \
  _ "$JIT_SH" 2>&1)"
expect_eq "native row (decline): nothing ran — no install, no CLI call" "0" \
  "$(grep -c . "$CALLS" | tr -d ' ')"

# The ownership agreement, the same way Group 3 proves it for install_dep:
# override the installer AFTER sourcing and watch the yes path land in it.
NATIVE_TRACE="$TMP/native-installer-trace.log"; : > "$NATIVE_TRACE"
env -i HOME="$TMP/home" PATH="$NATIVE_BIN" BIONIC_TEST_TRACE="$NATIVE_TRACE" BIONIC_TEST_CALLS="$CALLS" \
  bash -c '
    . "$1"
    install_plugin_native() { echo "install_plugin_native-override $*" >> "$BIONIC_TEST_TRACE"; return 0; }
    echo y | jit_offer impeccable design-route "design work" "it degrades"
  ' _ "$JIT_SH" >/dev/null 2>&1
expect_match "jit_offer reaches the function literally named install_plugin_native" \
  "*install_plugin_native-override impeccable*" "$(cat "$NATIVE_TRACE")"

# deps.sh keeps its refusal: the shared installer is a SIBLING of install_dep,
# not a way in through it. If this ever passed, the kludge D1 rejected would be
# back and the refusal would be decoration.

section "Group 11: excalidraw-diagram route fixes (epic-17 w4 S10, AC-10)"
#
# AC-10 pinned the skill as a default-off opt-in living outside the payload, with a
# config-dir-aware render path because that is where a manually-copied personal skill lands.
#
# EPIC-18 T3 (AC-6) MOVED THE SKILL INTO THE PAYLOAD, and both halves of that pin invert with
# it. The skill is no longer opt-in — installing bionic installs it — so a doc still calling
# itself default-off would be telling users to copy a directory they already have. And
# `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/excalidraw-diagram/references` is now the WRONG
# render path on every plugin-installed machine: nothing puts the skill there, so the `cd`
# fails and the renderer looks broken. `${CLAUDE_PLUGIN_ROOT}` is where the files actually
# are, and it is the idiom the rest of the payload's prose already uses.
#
# What does NOT change: uv and playwright-chromium are still dependency-table rows the render
# workflow must not assume, and they still get Group 9's one-sentence JIT treatment. The
# renderer's own venv joins them as a third row (`excalidraw-renderer`) — the `uv sync` half
# of the old First-Time Setup block, now a when-needed arm with the normal consent treatment
# rather than a command block the user was expected to run by hand.

EXCALIDRAW_README="${REPO}/payload/skills/excalidraw-diagram/README.md"

expect_true "excalidraw-diagram SKILL.md names uv's dependency-table row" grep -q '\buv\b' "$EXCALIDRAW_SKILL"
expect_true "excalidraw-diagram SKILL.md names playwright-chromium" grep -q 'playwright-chromium' "$EXCALIDRAW_SKILL"
expect_true "excalidraw-diagram SKILL.md names the excalidraw-renderer row" \
  grep -q 'excalidraw-renderer' "$EXCALIDRAW_SKILL"

expect_false "excalidraw-diagram SKILL.md carries no hardcoded ~/.claude/skills/ literal" \
  grep -q '~/\.claude/skills/' "$EXCALIDRAW_SKILL"
expect_false "excalidraw-diagram README.md carries no hardcoded ~/.claude/skills/ literal" \
  grep -q '~/\.claude/skills/' "$EXCALIDRAW_README"

# The config-dir form is now as wrong as the hardcoded one, and for the same reason: it
# addresses a directory the plugin never writes to.
expect_false "excalidraw-diagram SKILL.md no longer routes the renderer through CLAUDE_CONFIG_DIR" \
  grep -q 'CLAUDE_CONFIG_DIR' "$EXCALIDRAW_SKILL"
expect_false "excalidraw-diagram README.md no longer routes the renderer through CLAUDE_CONFIG_DIR" \
  grep -q 'CLAUDE_CONFIG_DIR' "$EXCALIDRAW_README"

expect_true "excalidraw-diagram SKILL.md addresses the renderer through CLAUDE_PLUGIN_ROOT" \
  grep -q 'CLAUDE_PLUGIN_ROOT' "$EXCALIDRAW_SKILL"
expect_true "excalidraw-diagram README.md addresses the renderer through CLAUDE_PLUGIN_ROOT" \
  grep -q 'CLAUDE_PLUGIN_ROOT' "$EXCALIDRAW_README"

section "Group 12: Step-0 model_plan derivation is mechanical, not invented (epic-19 F1)"
#
# AC-F1: the orchestrator reads agents/*.md frontmatter for the six dispatched-role
# tiers; the confirmation display cites each line's source. Before this fix the whole
# derivation rule was "model_plan from multi_agent and the detected session model" —
# no route to the role files existed anywhere in the skill (grounding:
# .bionic/docs/record/epic-19/step1-fixes-grounding.md §1). Reuses $CANONICAL_SKILL
# from Group 9 above rather than re-deriving the path — this suite is otherwise about
# jit/degradation, but it is the one place in the roster already set up to pin literal
# prose spans of this SKILL.md.

expect_true "canonical-sdlc SKILL.md: model_plan derivation is never invented or recalled from memory" \
  grep -q 'never invented or recalled from memory' "$CANONICAL_SKILL"
expect_true "canonical-sdlc SKILL.md: model_plan derivation names the rendered role files as the source" \
  grep -q 'rendered role files' "$CANONICAL_SKILL"
expect_eq "canonical-sdlc SKILL.md: all 6 dispatched-role lines in the confirmation display cite a role-file source" \
  "6" "$(grep -c 'role-file default: agents/' "$CANONICAL_SKILL")"

section "Group 13: README roster table agrees with agents/*.md frontmatter (epic-19 F9)"
#
# AC-F9: README.md's roster table (step1-model-surfaces.md §6) is the one copy render.sh's
# AGENT-ROSTER directive does not reach — it is hand-written and had already drifted
# (researcher/test-runner both wrong). This pin reads the model value FROM each role file's
# own frontmatter and checks README's row for the SAME role names it — never a restated
# literal here — so a future role-file change and a stale README both go red without
# touching this test.

README="${REPO}/README.md"
AGENTS_DIR="${REPO}/agents"

for role in researcher test-runner implementor senior-implementor auditor critic; do
  role_file="${AGENTS_DIR}/${role}.md"
  model_raw="$(awk -F': *' '/^model:/ { print $2; exit }' "$role_file")"
  model_title="$(printf '%s' "$model_raw" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }')"
  readme_row="$(grep "| \`${role}\` " "$README")"
  expect_match "README roster table: \`${role}\` row names its agents/${role}.md model" \
    "*${model_title}*" "$readme_row"
done

finish
