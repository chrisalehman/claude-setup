#!/bin/bash
# DOCS PINS — one file, one section per slice that owns a doc-text agreement pin
# (spec AC-36 for RELEASE; WALLS and SCHED append their own numbered sections here
# in later slices of this wave — this file is shared harness, not RELEASE-owned).
#
# SECTION 1 — RELEASE (spec AC-36, `.bionic/docs/plans/wave-bionic-1.4.0-update/`).
# WHAT THIS SECTION OWNS. The "version pair": `payload/.claude-plugin/plugin.json`'s
# `.version` field is the single owner of the plugin's version number, and
# `payload/commands/help.md` restates it in its opening line, `bionic <version>
# (installed)`. That restatement used to be read from disk at runtime (so it could
# not drift), then baked at render time by `agents-src/render.sh` substituting
# `@@PLUGIN_VERSION@@` in `agents-src/templates/commands/help.md.tmpl` (see that
# script's own "WHY THE VERSION IS BAKED AT RENDER TIME" note). The suite-level pin
# that enforced this — `version-ssot.test.sh` — was deleted at 8582861 (epic-18
# wave-03, MEDIUM/LOW-reliability cut) and nothing replaced it: render.sh --check
# still CATCHES a stale pair when run, but nothing in tests/run.sh's roster ever
# runs it for that reason, so a hand-edit to either half of the pair goes undetected
# by `bash tests/run.sh`. This section is that replacement, scoped to the pair only
# (render.sh --check's five other unrelated agreement classes are not this section's
# concern; assertion 7 below calls it directly rather than re-implementing it).
#
# ANTI-VACUITY, per tests/cross-gate-agreement.test.sh §N.1's differential-control pattern (that
# suite's §G): a pin that only ever reads two already-agreeing files could be
# vacuously true by extractor bug (e.g. a regex that always reports "match"). So
# this section also re-runs its own extractors against DOCTORED copies — a help.md
# with a different version, a plugin.json with a different version — and asserts
# the SAME extractors now report a mismatch. That is proven fresh on every run
# rather than taken on faith from a report.
#
# WHAT THIS SECTION STILL CANNOT SEE, and it is not a gap to be closed here (wave-01
# verification-cannot-lie, AC-17). Every assertion below is an AGREEMENT: it holds when
# every surface says the same thing. A version that is WRONG but AGREEING — a release that
# bumped nothing, or bumped every surface to the same wrong number — passes all of it, at
# every surface, in silence. That is FOG in this wave's sense: a class of defect no
# assertion here can turn red, named rather than claimed away. Its cure is canon R0.1,
# render every surface from one source (wave 02), which removes the several-surfaces
# problem instead of testing around it. This section's power is over DISAGREEMENT, and
# that is what it is claimed to have.
#
# HERMETIC. Reads the two committed files and the template by path; doctored copies
# live under a mktemp dir removed on exit. Nothing in the repo tree is mutated.
# The one subprocess this section shells out to, `agents-src/render.sh --check`, is
# itself read-only in --check mode (see that script).
#
# Usage: bash tests/docs-pins.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PLUGIN_JSON="${REPO}/payload/.claude-plugin/plugin.json"
HELP_MD="${REPO}/payload/commands/help.md"
HELP_TMPL="${REPO}/agents-src/templates/commands/help.md.tmpl"
RENDER_SH="${REPO}/agents-src/render.sh"

command -v jq >/dev/null 2>&1 || { echo "docs-pins.test.sh: jq is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# plugin_version_of <plugin.json path> -> the .version field, empty if absent/unparseable.
plugin_version_of() { jq -r '.version // empty' "$1" 2>/dev/null; }

# help_version_of <help.md path> -> the version token on the "bionic <version>
# (installed)" opening line, empty if that line is absent.
help_version_of() {
  grep -m1 -E '^bionic [^ ]+ \(installed\)$' "$1" 2>/dev/null | awk '{print $2}'
}

section "Section 1: the help version pair equals plugin.json's version (RELEASE, AC-36)"

PLUGIN_VERSION="$(plugin_version_of "$PLUGIN_JSON")"
if [ -n "$PLUGIN_VERSION" ]; then
  ok "1: payload/.claude-plugin/plugin.json declares a non-empty .version"
else
  no "1: payload/.claude-plugin/plugin.json declares a non-empty .version" "file: $PLUGIN_JSON"
fi

HELP_VERSION="$(help_version_of "$HELP_MD")"
if [ -n "$HELP_VERSION" ]; then
  ok "2: payload/commands/help.md opens with a 'bionic <version> (installed)' line"
else
  no "2: payload/commands/help.md opens with a 'bionic <version> (installed)' line" "file: $HELP_MD"
fi

expect_eq "3: help.md's version equals plugin.json's version" "$PLUGIN_VERSION" "$HELP_VERSION"

# The template carries the version GENERATIVELY (render.sh substitutes it from
# plugin.json), never as a hand-typed literal — a hardcoded version in the template
# would still render correctly today and drift silently the next time plugin.json
# is bumped without a matching template edit.
if grep -qF 'bionic @@PLUGIN_VERSION@@ (installed)' "$HELP_TMPL" 2>/dev/null; then
  ok "4: agents-src/templates/commands/help.md.tmpl carries @@PLUGIN_VERSION@@, not a literal"
else
  no "4: agents-src/templates/commands/help.md.tmpl carries @@PLUGIN_VERSION@@, not a literal" \
     "file: $HELP_TMPL"
fi

# --- Anti-vacuity: the same extractors must discriminate a real mismatch ---

# WHOLE-LINE ERE, because the sed two lines down is `^...$`-anchored. A fixed-string
# anchor is a substring test: it survives a reindent of this line while the sed does
# not, leaving a "mutant" byte-identical to the shipped help.md — see plant 2 of
# s19c-planted-move.log, where exactly that hid a broken mutation. The version's dots
# are escaped so a literal `1.4.4` cannot match `1x4x4`.
anchor -E "$HELP_MD" "^bionic ${PLUGIN_VERSION//./\\.} \\(installed\\)$" 1
DOCTORED_HELP="$TMP/help-mismatched.md"
sed "s/^bionic ${PLUGIN_VERSION} (installed)\$/bionic 0.0.0-mismatch (installed)/" \
  "$HELP_MD" > "$DOCTORED_HELP"
DOCTORED_HELP_VERSION="$(help_version_of "$DOCTORED_HELP")"
expect_ne "5: a doctored help.md with a different version reads as a different version (pin discriminates)" \
  "$PLUGIN_VERSION" "$DOCTORED_HELP_VERSION"

anchor "$PLUGIN_JSON" '"version"' 1
DOCTORED_PLUGIN="$TMP/plugin-mismatched.json"
jq --arg v "0.0.0-mismatch" '.version = $v' "$PLUGIN_JSON" > "$DOCTORED_PLUGIN"
DOCTORED_PLUGIN_VERSION="$(plugin_version_of "$DOCTORED_PLUGIN")"
expect_ne "6: a doctored plugin.json with a different version reads as a different version (pin discriminates)" \
  "$HELP_VERSION" "$DOCTORED_PLUGIN_VERSION"

# The construction-level guarantee behind assertion 3: a fresh render of the
# template against the committed plugin.json must byte-match the committed
# help.md. Called directly rather than assumed — render.sh --check also covers
# five other unrelated agreement classes this section does not own.
if bash "$RENDER_SH" --check >/dev/null 2>&1; then
  ok "7: agents-src/render.sh --check reports every rendered final clean"
else
  no "7: agents-src/render.sh --check reports every rendered final clean" \
     "run 'bash agents-src/render.sh --check' directly for the diff"
fi

# ── AC-17: the version is one truth rendered at MANY surfaces ────────────────
#
# Assertions 1-8 pin ONE pair, plugin.json and help.md. The version is restated at more
# surfaces than that, and until this slice nothing looked at the rest: the marketplace
# manifest the CLI reads, the `payload/.version` file the plan named, and doctor's own
# header line. Each is asserted against `payload/.claude-plugin/plugin.json`, the single
# owner — and each pin carries the doctored control that proves its extractor discriminates,
# for §N.1's differential-control reason.

MARKETPLACE="${REPO}/.claude-plugin/marketplace.json"
VERSION_FILE="${REPO}/payload/.version"
DOCTOR_SH="${REPO}/payload/scripts/doctor.sh"
DETECT_SH="${REPO}/payload/scripts/lib/detect.sh"

# version_file_of <path> -> the version on the first line, empty if the file is absent.
version_file_of() { [ -f "$1" ] || return 0; head -1 "$1" 2>/dev/null | tr -d '[:space:]'; }

# mkt_version_of <manifest> -> the bionic ENTRY's own .version, empty when it declares none.
mkt_version_of() { jq -r '(.plugins // []) | map(select(.name == "bionic")) | .[0].version // empty' "$1" 2>/dev/null; }

# mkt_source_of <manifest> -> the bionic entry's source, as a string when it is one.
mkt_source_of() { jq -r '(.plugins // []) | map(select(.name == "bionic")) | .[0].source | if type == "string" then . else empty end' "$1" 2>/dev/null; }

# detect_version_of <plugin root> -> what detect_plugin_integrity reports for that root.
# THIS IS DOCTOR'S OWN READER, not a re-implementation of it: doctor.sh:528 takes
# PLUGIN_VERSION out of this line and its header prints that value.
detect_version_of() {
  ( . "$DETECT_SH" >/dev/null 2>&1
    BIONIC_PLUGIN_ROOT="$1" detect_plugin_integrity 2>/dev/null ) \
  | sed -n 's/^plugin: version=\([^ ]*\).*/\1/p'
}

# doctor_header_line <doctor.sh> -> the one line that renders the report header.
doctor_header_line() { grep -m1 -F 'Bionic Doctor — payload' "$1" 2>/dev/null; }

# declaring_sites <root> -> "<path>|<version>" for every file in the tree that DECLARES a
# bionic version, sorted. Declaring, not mentioning: a `"version": "1.2.3"` key in the
# plugin payload or the marketplace manifest, and the `bionic <v> (installed)` line the
# help command opens with. Prose that names a past release ("the 1.4.4 fixit", of which
# there are two dozen) declares nothing and is not swept up.
#
# /usr/bin/grep, not `grep`: the shell grep on this machine is ugrep with --ignore-files,
# which skips hidden directories — and BOTH declaring sites live under one
# (`payload/.claude-plugin`, `.claude-plugin`). The same trap tests/cross-gate-agreement.test.sh
# names at its own expect_absent_ug.
#
# Candidates come from `git ls-files`, not a filesystem walk — an UNTRACKED file (scratch
# tooling debris, a stray virtualenv, anything nobody committed) is not a declaring surface
# just because it happens to sit on disk under payload/. A-48(a): the 2026-09-06 residual
# was an untracked `.venv`'s `package.json` making the census see three surfaces instead of
# two in a polluted checkout, while every committed/archived tree only ever saw two. When
# `$r` is not a git worktree at all (the sweep's own synthetic scratch-tree control below,
# built with plain `mkdir`/`cp`), there is no tracked/untracked distinction to make, so every
# file on disk is a candidate — same as before.
declaring_sites() {
  local r="$1" f v version_candidates installed_candidates
  if git -C "$r" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    version_candidates=$(cd "$r" && git ls-files -- payload .claude-plugin 2>/dev/null)
    installed_candidates=$(cd "$r" && git ls-files -- payload agents-src 2>/dev/null)
  else
    version_candidates=$(cd "$r" && find payload .claude-plugin -type f 2>/dev/null)
    installed_candidates=$(cd "$r" && find payload agents-src -type f 2>/dev/null)
  fi
  {
    for f in $version_candidates; do
      /usr/bin/grep -qE '^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' "$r/$f" 2>/dev/null || continue
      v=$(/usr/bin/grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$r/$f" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
      printf '%s|%s\n' "$f" "$v"
    done
    for f in $installed_candidates; do
      /usr/bin/grep -qE '^bionic [0-9]+\.[0-9]+\.[0-9]+[^ ]* \(installed\)$' "$r/$f" 2>/dev/null || continue
      v=$(/usr/bin/grep -m1 -E '^bionic [^ ]+ \(installed\)$' "$r/$f" 2>/dev/null | awk '{print $2}')
      printf '%s|%s\n' "$f" "$v"
    done
  } | LC_ALL=C sort
}

# --- surface: payload/.version -----------------------------------------------
#
# The plan named this file as a version-bearing surface. It does not exist in this tree, so
# plugin.json is the sole FILE owner — asserted as the absence it is, with the extractor
# proven able to read one so that "empty" cannot mean "the reader is broken".
expect_empty "9: payload/.version declares nothing — plugin.json is the sole file owner" \
  "$(version_file_of "$VERSION_FILE")"
printf '%s\n' "$PLUGIN_VERSION" > "$TMP/dot-version"
expect_eq "10: …and the same extractor DOES read a .version file that exists (not a broken reader)" \
  "$PLUGIN_VERSION" "$(version_file_of "$TMP/dot-version")"

# --- surface: the marketplace manifest ---------------------------------------
#
# `.claude-plugin/marketplace.json` is what `claude plugin marketplace add` reads, and it is
# where a second version number would be most invisible: nothing renders it beside the
# plugin's own. It carries none, and it must not — its bionic entry points at `./payload`,
# whose plugin.json is the owner. The pin is therefore that this surface RESTATES NOTHING.
expect_eq "11: the marketplace manifest sources bionic from ./payload — the owner's directory" \
  "./payload" "$(mkt_source_of "$MARKETPLACE")"
expect_empty "12: …and declares no version of its own, so there is nothing here to drift" \
  "$(mkt_version_of "$MARKETPLACE")"
# The jq below selects the bionic plugin entry BY NAME, so that name is this mutation's
# anchor. TWO is the measured truth, not a slack bound: the manifest carries its own
# `"name": "bionic"` at the top level and the plugins[] entry carries a second. Either one
# moving turns this row red and says which count it found.
anchor "$MARKETPLACE" '"name": "bionic"' 2
DOCTORED_MKT="$TMP/marketplace-mismatched.json"
jq '(.plugins[] | select(.name == "bionic")) |= (. + {version: "0.0.0-mismatch"})' \
  "$MARKETPLACE" > "$DOCTORED_MKT"
expect_eq "13: …and a manifest that DID carry one is read as carrying it (pin discriminates)" \
  "0.0.0-mismatch" "$(mkt_version_of "$DOCTORED_MKT")"

# --- surface: doctor's header line -------------------------------------------
#
# `Bionic Doctor — payload <v> @ <sha>` is the version most users ever see. It is not an
# independent surface: doctor.sh:528 reads detect_plugin_integrity's `version=` and prints
# that. So the pin has two halves — the header renders the variable rather than a literal,
# and the reader behind the variable really does report plugin.json's value.
DOCTOR_HEADER="$(doctor_header_line "$DOCTOR_SH")"
expect_contains "14: doctor's header renders \${PLUGIN_VERSION}, never a typed-in version" \
  '${PLUGIN_VERSION}' "$DOCTOR_HEADER"
expect_no_regex "15: …and carries no version literal of its own" \
  '[0-9]+\.[0-9]+\.[0-9]+' "$DOCTOR_HEADER"
expect_contains "16: …and PLUGIN_VERSION comes from detect_plugin_integrity, not a second parse" \
  'PLUGIN_VERSION="${PLUGIN_FACT#plugin: version=}"' "$(cat "$DOCTOR_SH")"
expect_eq "17: …and that reader reports plugin.json's version for the shipped payload root" \
  "$PLUGIN_VERSION" "$(detect_version_of "${REPO}/payload")"
anchor "$PLUGIN_JSON" '"version": "' 1
DOCTORED_ROOT="$TMP/doctored-root"
mkdir -p "$DOCTORED_ROOT/.claude-plugin"
jq --arg v "0.0.0-mismatch" '.version = $v' "$PLUGIN_JSON" > "$DOCTORED_ROOT/.claude-plugin/plugin.json"
expect_eq "18: …and reports the DOCTORED version for a doctored root (the header would show it)" \
  "0.0.0-mismatch" "$(detect_version_of "$DOCTORED_ROOT")"

# --- the census: no THIRD surface appears unnoticed ---------------------------
#
# The four pins above are a fixed list, and a fixed list goes stale the moment somebody adds
# a fifth surface. The sweep is the pin that notices: exactly two files in this tree DECLARE
# a bionic version, and both of them agree with the owner.
SITES="$(declaring_sites "$REPO")"
expect_eq "19: exactly two surfaces in the tree DECLARE a version, and they are the known two" \
  "payload/.claude-plugin/plugin.json|${PLUGIN_VERSION}
payload/commands/help.md|${PLUGIN_VERSION}" "$SITES"

SITE_DISAGREEMENTS="$(printf '%s\n' "$SITES" | awk -F'|' -v v="$PLUGIN_VERSION" '$2 != v')"
expect_empty "20: …and every one of them agrees with plugin.json" "$SITE_DISAGREEMENTS"

# The sweep's own controls, over a scratch tree: a THIRD declaring surface is found, and a
# disagreeing one is reported as a disagreement. Without these, an empty sweep and a broken
# sweep look identical.
SWEEP_TREE="$TMP/sweep-tree"
mkdir -p "$SWEEP_TREE/payload/.claude-plugin" "$SWEEP_TREE/payload/commands" \
         "$SWEEP_TREE/payload/scripts" "$SWEEP_TREE/.claude-plugin" "$SWEEP_TREE/agents-src"
cp "$PLUGIN_JSON" "$SWEEP_TREE/payload/.claude-plugin/plugin.json"
cp "$HELP_MD" "$SWEEP_TREE/payload/commands/help.md"
printf '{\n  "name": "bionic-thing",\n  "version": "0.0.0-mismatch"\n}\n' \
  > "$SWEEP_TREE/payload/scripts/third-surface.json"
SWEEP_SITES="$(declaring_sites "$SWEEP_TREE")"
expect_contains "21: the sweep FINDS a third declaring surface planted in a scratch tree" \
  "payload/scripts/third-surface.json|0.0.0-mismatch" "$SWEEP_SITES"
expect_nonempty "22: …and the disagreement filter reports it as a disagreement" \
  "$(printf '%s\n' "$SWEEP_SITES" | awk -F'|' -v v="$PLUGIN_VERSION" '$2 != v')"

# ── SECTION 2 — WALLS (spec AC-14/AC-26, `.bionic/docs/plans/wave-bionic-1.4.0-update/`).
#
# WHAT THIS SECTION OWNS. Four instruction-surface sentences that no hook can check,
# each of which a machine downstream depends on:
#
#   (a) Step 0's probe act in `payload/skills/canonical-sdlc/SKILL.md` — the run's
#       `parallel-budget:` comes from `resources_probe`/`resources_budget` and is
#       recorded verbatim, never re-derived. hooks/dispatch-preflight.sh's budget arm
#       reads that one string; a Step 0 that stopped writing it makes the arm inert.
#   (b) the "fill the budget" dispatch rule in the same file — the sentence that turns
#       a budget from a ceiling into an instruction.
#   (c) the `BIONIC_TEST_JOBS=<test_jobs>` sentence in `agents-src/blocks/survival.md`,
#       which must reach every dispatched writer — so it is asserted in the BLOCK and
#       again in all six rendered `agents/*.md`, which is what proves the render ran.
#   (d) the `/clear` paragraph, which lives in ONE canonical copy — `agents-src/blocks/
#       survival.md`, rendered into all six `agents/*.md` — since S7 (AC-13) retired the
#       second copy that used to live in `.claude/rules/agent-discipline.md`. Two copies
#       of a paragraph is exactly the drift a pin used to exist for; now the pin is over
#       the SINGLE home instead: the block carries it, the six role files match it
#       byte-for-byte, and the rules file is asserted to carry it no longer.
#
# ANTI-VACUITY, same discriminate-a-doctored-copy pattern §1 uses: every extractor here
# is re-run against a mutated copy and must report the mutation.
#
# HERMETIC. Reads committed files by path; doctored copies live under $TMP.

section "Section 2: the WALLS instruction-surface pins (AC-14, AC-26)"

SKILL_MD="${REPO}/payload/skills/canonical-sdlc/SKILL.md"
SURVIVAL_BLOCK="${REPO}/agents-src/blocks/survival.md"
AGENT_RULES="${REPO}/.claude/rules/agent-discipline.md"

# The four pinned strings, spelled here exactly as they must appear on disk.
PIN_PROBE='`resources_probe` and `resources_budget` from `<plugin-root>/scripts/lib/resources.sh` yield the run'"'"'s `parallel-budget:` — one string, recorded verbatim in plan frontmatter, printed in the display, and never re-derived downstream.'
# RE-POINTED AT THE CORRECTED DOCTRINE (Step-6 architecture A-2). The old needle pinned
# `dispatches in one batch up to `writers`` — the ceiling, unregulated — while the tick fills
# to the RUNG off a live-trimmed open count, so the pin was holding a contradiction green. A
# pin follows the sentence it is a pin FOR: when the doctrine is corrected the needle moves
# with it, or the test outlives the thing it was protecting.
PIN_FILL='every slice with no unmet dependency dispatches in one batch sized by the rung the tick prints — `poker: rung=<n>/<ceiling>`, the machine'"'"'s answer to how wide it will carry right now — with `writers` as the ceiling that rung is taken against and the only number the wall enforces'
# RE-POINTED, WRITER-FACING (Step-6 readability R-8). The old needle held a sentence that
# was correct in SKILL.md — where it addresses the DISPATCHER, and where PIN_JOBS_SKILL still
# holds it — and had been pasted verbatim into a block every other bullet of which is
# second-person to the writer. It also named a fix no writer can execute: `pressure_level` is
# a function in a sourced library, not a command on PATH, and tests/run.sh already calls it.
PIN_JOBS='**You do not set your test width.** `tests/run.sh` samples the machine and reads its own width off the pressure rung at suite start, so there is nothing here for you to compute, export, or call — `pressure_level` is a shell function in a sourced library, not a command you can run. Set `BIONIC_TEST_JOBS_CEILING` only when your brief names a ceiling, and never above the one it names.'

# has_pin <file> <string> -> 0 when the file carries the string.
#
# WHITESPACE-NORMALIZED, and that is the only latitude given: the file is folded to one
# line with every run of whitespace collapsed to a single space before the match, so a
# sentence that wraps across two source lines — which every one of these does in at least
# one of its homes — still matches, while a changed word, a changed backtick or a changed
# punctuation mark does not. `tr` + `sed` rather than a regex, so the needle is compared
# literally by `grep -F`.
_flatten() { tr '\n' ' ' < "$1" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g'; }
has_pin() { _flatten "$1" | grep -qF -- "$2"; }

if has_pin "$SKILL_MD" "$PIN_PROBE"; then
  ok "9: SKILL.md Step 0 carries the resources-probe sentence verbatim"
else
  no "9: SKILL.md Step 0 carries the resources-probe sentence verbatim" "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_FILL"; then
  ok "10: SKILL.md carries the 'fill the budget' dispatch rule verbatim"
else
  no "10: SKILL.md carries the 'fill the budget' dispatch rule verbatim" "file: $SKILL_MD"
fi

if has_pin "$SURVIVAL_BLOCK" "$PIN_JOBS"; then
  ok "11: agents-src/blocks/survival.md carries the rung-pointer sentence verbatim (AC-18)"
else
  no "11: agents-src/blocks/survival.md carries the rung-pointer sentence verbatim (AC-18)" \
     "file: $SURVIVAL_BLOCK"
fi

# The render is the delivery mechanism; asserting the block alone would pass on a repo
# whose agents/ was never re-rendered, which is the state a dispatched writer meets.
PINS_JOBS_MISSING=""
for role in auditor critic implementor researcher senior-implementor test-runner; do
  has_pin "${REPO}/agents/${role}.md" "$PIN_JOBS" || PINS_JOBS_MISSING="${PINS_JOBS_MISSING} ${role}"
done
if [ -z "$PINS_JOBS_MISSING" ]; then
  ok "12: all six rendered agents/*.md carry the rung-pointer sentence (render is current, AC-18)"
else
  no "12: all six rendered agents/*.md carry the rung-pointer sentence (render is current, AC-18)" \
     "missing in:${PINS_JOBS_MISSING} — run 'bash agents-src/render.sh'"
fi

# clear_paragraph <file> -> the one paragraph opening with the `/clear` marker, verbatim.
# Paragraph-scoped rather than line-scoped: a difference in how the two channels wrap the
# same words IS a difference, and this pin is for byte identity, not for gist. It ends at a
# blank line or at the render's own `<!-- SURVIVAL-END -->` marker, which agents-src/render.sh
# writes immediately after the last injected line with no blank between them.
clear_paragraph() {
  awk '
    /^\*\*`\/clear` does not kill agents\.\*\*/ { inp = 1 }
    inp && /^[[:space:]]*$/ { exit }
    inp && /^<!--/ { exit }
    inp { print }
  ' "$1" 2>/dev/null
}

CLEAR_BLOCK="$(clear_paragraph "$SURVIVAL_BLOCK")"
CLEAR_RULES="$(clear_paragraph "$AGENT_RULES")"

if [ -n "$CLEAR_BLOCK" ]; then
  ok "13: agents-src/blocks/survival.md carries the '/clear does not kill agents' paragraph"
else
  no "13: agents-src/blocks/survival.md carries the '/clear does not kill agents' paragraph" \
     "file: $SURVIVAL_BLOCK"
fi

# 14: ONE COPY (S7, AC-13) — the second copy that used to live in the rules file is
# retired, not re-homed a third time (r1 §Table 3, AD18: "delete the rules copy. Do not
# port it to the orchestrator role — that would make a fourth"). A bare absence check is
# a vacuous-negative risk (tests/lib/assert.sh's own docblock on `expect_empty`); it is
# paired here with assertion 13's POSITIVE result from the very same `clear_paragraph`
# extractor, on the sibling file, moments above — proof the extractor itself works.
if [ -z "$CLEAR_RULES" ]; then
  ok "14: .claude/rules/agent-discipline.md no longer carries a '/clear' paragraph copy (one copy only)"
else
  no "14: .claude/rules/agent-discipline.md no longer carries a '/clear' paragraph copy (one copy only)" \
     "file: $AGENT_RULES still matches the extractor — a second copy survived the move"
fi

PINS_CLEAR_MISSING=""
for role in auditor critic implementor researcher senior-implementor test-runner; do
  [ "$(clear_paragraph "${REPO}/agents/${role}.md")" = "$CLEAR_BLOCK" ] \
    || PINS_CLEAR_MISSING="${PINS_CLEAR_MISSING} ${role}"
done
if [ -z "$PINS_CLEAR_MISSING" ]; then
  ok "15: all six rendered agents/*.md carry that paragraph byte-identically"
else
  no "15: all six rendered agents/*.md carry that paragraph byte-identically" \
     "differs or missing in:${PINS_CLEAR_MISSING} — run 'bash agents-src/render.sh'"
fi

# 16: CENSUS — no THIRD home exists anywhere in the tree. Assertion 14 proves the one
# named former home is clean; this proves nothing else picked the paragraph up either,
# the same construction-guarded-vs-enforcement-guarded distinction r3 §Part 2 item 18
# draws for AD18's other two copies.
CLEAR_MARKER='`/clear` does not kill agents.'
CLEAR_HOMES_EXPECTED="agents-src/blocks/survival.md agents/auditor.md agents/critic.md agents/implementor.md agents/researcher.md agents/senior-implementor.md agents/test-runner.md"
CLEAR_HOMES_ACTUAL="$(cd "$REPO" && /usr/bin/grep -rl -F -- "$CLEAR_MARKER" \
  agents-src agents .claude payload skills 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
expect_eq "16: the '/clear' marker exists ONLY at its seven expected homes (no third copy anywhere)" \
  "$(printf '%s\n' $CLEAR_HOMES_EXPECTED | sort | tr '\n' ' ' | sed 's/ $//')" "$CLEAR_HOMES_ACTUAL"

# --- Anti-vacuity: the same extractors must report a mutation ---

anchor "$SKILL_MD" 'never re-derived downstream' 1
DOCTORED_SKILL="$TMP/skill-mutated.md"
sed 's/never re-derived downstream/re-derived wherever convenient/' "$SKILL_MD" > "$DOCTORED_SKILL"
if has_pin "$DOCTORED_SKILL" "$PIN_PROBE"; then
  no "17: a doctored SKILL.md fails the probe pin (pin discriminates)" \
     "the mutated copy still matched — the pin is vacuous"
else
  ok "17: a doctored SKILL.md fails the probe pin (pin discriminates)"
fi

anchor "$SURVIVAL_BLOCK" 'only when your brief names a ceiling' 1
DOCTORED_BLOCK="$TMP/survival-mutated.md"
sed 's/only when your brief names a ceiling/whenever you feel the machine is busy/' \
  "$SURVIVAL_BLOCK" > "$DOCTORED_BLOCK"
if has_pin "$DOCTORED_BLOCK" "$PIN_JOBS"; then
  no "18: a doctored survival.md fails the BIONIC_TEST_JOBS pin (pin discriminates)" \
     "the mutated copy still matched — the pin is vacuous"
else
  ok "18: a doctored survival.md fails the BIONIC_TEST_JOBS pin (pin discriminates)"
fi

# 19: mutation target moved to the canonical copy (S7, AC-13) — the rules file no
# longer carries this paragraph at all, so mutating it would anchor on nothing (the
# "anchor MOVED" failure `anchor()`'s own docblock warns against) and prove nothing.
anchor "$SURVIVAL_BLOCK" 'the address that survives' 1
DOCTORED_BLOCK2="$TMP/survival-clear-mutated.md"
sed 's/the address that survives/the address that dies/' "$SURVIVAL_BLOCK" > "$DOCTORED_BLOCK2"
expect_ne "19: a doctored survival.md reads as a different '/clear' paragraph (pin discriminates)" \
  "$CLEAR_BLOCK" "$(clear_paragraph "$DOCTORED_BLOCK2")"

# ── SECTION 3 — SCHED (spec AC-29/AC-30/AC-31/AC-38, `.bionic/docs/plans/wave-bionic-1.4.0-update/`).
#
# WHAT THIS SECTION OWNS. Two instruction-surface sentences in
# `payload/skills/canonical-sdlc/SKILL.md`'s Patrol section that no hook can check, and that
# a machine downstream depends on being read as written:
#
#   (e) "the tick reads pressure to throttle, never to re-derive the budget" — the boundary
#       between lib/resources.sh's CEILING (a pure function of machine facts, written once
#       into the plan header by Step 0) and its live PRESSURE reading. An orchestrator that
#       read the second as licence to rewrite the first would make fan-out width a function
#       of the weather, which is the drift the library exists to remove; the sentence is the
#       only thing standing between the two, because the tick cannot enforce it — the tick
#       does not write plans.
#   (f) the AC-38 QUIET line — "an armed session that has dispatched nothing yet decides
#       QUIET, never REFUSED". The tick implements it, but the SENTENCE is what stops the
#       next reader from re-adding the refusal on the reasoning that an empty roster is
#       suspicious. It was measured suspicious exactly once, on this wave's own tick #1,
#       and it was the reader that was wrong.
#
# BYTE-LEVEL, whitespace-normalized, through §2's own `has_pin` — the same latitude and no
# more: a sentence that wraps differently still matches, a changed word does not.
#
# ANTI-VACUITY, same discriminate-a-doctored-copy pattern §1 and §2 use.
#
# APPENDED, NEVER REWRITTEN: §1 is RELEASE's and §2 is WALLS's, and a slice that edited
# another slice's pins would be a slice deciding what that slice owns.

section "Section 3: the SCHED Patrol-text pins (AC-30, AC-38)"

PIN_THROTTLE='**the tick reads pressure to throttle, never to re-derive the budget** — the ceiling is the plan header'"'"'s `parallel-budget:`, written once by Step 0 from the probe, and no live reading ever raises or lowers it.'
PIN_QUIET='**An armed session that has dispatched nothing yet decides QUIET, never REFUSED** — `poker: QUIET — armed, nothing dispatched yet on this session`, stamp kept — because arming precedes dispatch by design'

if has_pin "$SKILL_MD" "$PIN_THROTTLE"; then
  ok "20: SKILL.md carries the pressure-throttles-never-re-derives sentence verbatim"
else
  no "20: SKILL.md carries the pressure-throttles-never-re-derives sentence verbatim" \
     "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_QUIET"; then
  ok "21: SKILL.md carries the AC-38 QUIET sentence verbatim"
else
  no "21: SKILL.md carries the AC-38 QUIET sentence verbatim" "file: $SKILL_MD"
fi

# The two rungs, the tick's rung line and the fill duty are named in the same section —
# asserted as presence rather than byte-for-byte, because their wording is prose the next
# editor may improve while the two sentences above are contracts. NARROW retired from this
# list at S10 (S8's report: "docs-pins.test.sh:327 still pins the token in SKILL.md and is
# S10's to retire" — NARROW is gone from hooks/session-poker.sh entirely).
PINS_RUNGS_MISSING=""
for token in 'EMERGENCY' 'HOLD' 'rung=<n>/<ceiling>' 'FILL <ids>' 'fill-declined: <reason>' 'Step-3 approval pending'; do
  has_pin "$SKILL_MD" "$token" || PINS_RUNGS_MISSING="${PINS_RUNGS_MISSING} ${token}"
done
if [ -z "$PINS_RUNGS_MISSING" ]; then
  ok "22: SKILL.md's Patrol section names both rungs, the tick's rung line, the FILL line and the decline"
else
  no "22: SKILL.md's Patrol section names both rungs, the tick's rung line, the FILL line and the decline" \
     "missing:${PINS_RUNGS_MISSING}"
fi

# --- Anti-vacuity: the same extractor must report a mutation ---

anchor "$SKILL_MD" 'never to re-derive the budget' 1
DOCTORED_SCHED="$TMP/skill-sched-mutated.md"
sed 's/never to re-derive the budget/and to re-derive the budget/' "$SKILL_MD" > "$DOCTORED_SCHED"
if has_pin "$DOCTORED_SCHED" "$PIN_THROTTLE"; then
  no "23: a doctored SKILL.md fails the throttle pin (pin discriminates)" \
     "the mutated copy still matched — the pin is vacuous"
else
  ok "23: a doctored SKILL.md fails the throttle pin (pin discriminates)"
fi

anchor "$SKILL_MD" 'decides QUIET, never REFUSED' 1
DOCTORED_SCHED2="$TMP/skill-sched-mutated-2.md"
sed 's/decides QUIET, never REFUSED/is REFUSED/' "$SKILL_MD" > "$DOCTORED_SCHED2"
if has_pin "$DOCTORED_SCHED2" "$PIN_QUIET"; then
  no "24: a doctored SKILL.md fails the QUIET pin (pin discriminates)" \
     "the mutated copy still matched — the pin is vacuous"
else
  ok "24: a doctored SKILL.md fails the QUIET pin (pin discriminates)"
fi

section "SECTION 4 — the Patrol tick literal, one string in two files (step-6 review R-8)"
#
# WHAT THIS SECTION OWNS. The armed cron job's prompt begins with the token
# `bionic-patrol session=<session-id[0:8]>`. SKILL.md is where the operator is told to
# write it (§The patrol prompt) and where the resume ritual is told to match on it;
# hooks/patrol-duties-gate.sh REBUILDS it — `TICK_MARK="bionic-patrol session=${SID:0:8}"`
# — and scans the transcript for it to decide whether a tick happened. The two are one
# contract with no shared definition between them.
#
# THE FAILURE THIS CLOSES. The ownership table for "a Patrol tick happened" promised
# "docs-pins: the literal pinned in both files" and `/usr/bin/grep -n bionic-patrol
# tests/docs-pins.test.sh` returned nothing. Fixtures exercise the hook's own copy
# (patrol-duties-gate, hook-adoption) with the literal spelled INSIDE the fixture, so
# rewording the SKILL.md sentence breaks the tick match on real transcripts with every
# suite green — the exact silent-drift class AC-22 exists to prevent.
#
# READ FROM BOTH FILES, not asserted against a constant twice. Each extractor pulls the
# prefix out of its own file and the two are compared; a constant on both sides would
# pass on two files that had drifted together away from what the cron actually carries.
# Assertion 25 additionally pins the extracted value, so an extractor that returned empty
# on both sides could not agree its way to green.

TICK_GATE="${REPO}/hooks/patrol-duties-gate.sh"

# tick_literal_doc <SKILL.md> -> the prefix as documented, placeholder stripped.
# Fails LOUD rather than empty: an unmatched sed leaves the whole line, which no
# comparison below can mistake for agreement.
tick_literal_doc() {
  /usr/bin/grep -m1 '^\*\*The patrol prompt\.\*\*' "$1" 2>/dev/null \
    | sed 's/.*its first token `\([^`]*\)`.*/\1/' \
    | sed 's/<session-id\[0:8\]>$//'
}
# tick_literal_code <patrol-duties-gate.sh> -> the prefix the hook builds.
tick_literal_code() {
  /usr/bin/grep -m1 '^TICK_MARK=' "$1" 2>/dev/null \
    | sed 's/^TICK_MARK="//' \
    | sed 's/\${SID:0:8}"$//'
}

TICK_DOC=$(tick_literal_doc "$SKILL_MD")
TICK_CODE=$(tick_literal_code "$TICK_GATE")

expect_eq "25: SKILL.md's patrol-prompt token is the tick prefix the cron carries" \
  'bionic-patrol session=' "$TICK_DOC"
expect_eq "26: patrol-duties-gate.sh rebuilds the SAME prefix SKILL.md documents" \
  "$TICK_DOC" "$TICK_CODE"

# The resume ritual matches on the same literal to delete a predecessor's clock. If that
# sentence drifts, an operator deletes nothing and two clocks run side by side.
# CAPTURED, THEN MATCHED — never `_flatten | grep -q`. SKILL.md is past the 64 KiB pipe
# buffer, so under this file's `set -o pipefail` an early-exiting `grep -q` SIGPIPEs the
# producer and the pipeline returns 141: a real match reported as a miss, intermittently.
TICK_RESUME_NEEDLE='delete every job whose prompt begins with the patrol marker `bionic-patrol session=`'
TICK_FLAT=$(_flatten "$SKILL_MD")
case "$TICK_FLAT" in
  *"$TICK_RESUME_NEEDLE"*)
    ok "27: SKILL.md's resume ritual names the same marker it tells the prompt to carry" ;;
  *)
    no "27: SKILL.md's resume ritual names the same marker it tells the prompt to carry" \
       "file: $SKILL_MD" ;;
esac

# --- Anti-vacuity: the same extractors must report a mutation, from either side ---

anchor "$SKILL_MD" 'its first token `bionic-patrol session=' 1
DOCTORED_TICK_DOC="$TMP/skill-tick-mutated.md"
sed 's/its first token `bionic-patrol session=/its first token `bionic patrol session=/' \
  "$SKILL_MD" > "$DOCTORED_TICK_DOC"
expect_ne "28: a reworded SKILL.md token breaks the pin (pin discriminates)" \
  "$TICK_CODE" "$(tick_literal_doc "$DOCTORED_TICK_DOC")"

anchor -E "$TICK_GATE" '^TICK_MARK="bionic-patrol session=' 1
DOCTORED_TICK_CODE="$TMP/patrol-duties-gate-mutated.sh"
sed 's/^TICK_MARK="bionic-patrol session=/TICK_MARK="bionic-patrol sid=/' \
  "$TICK_GATE" > "$DOCTORED_TICK_CODE"
expect_ne "29: a renamed hook-side literal breaks the pin (pin discriminates)" \
  "$TICK_DOC" "$(tick_literal_code "$DOCTORED_TICK_CODE")"

#
# SECTION 5 — the session-bound run, and the bind step in the resume ritual (wave-session-bound-run, A4/AC-5/AC-8).
# WHAT THIS SECTION OWNS. Two sentences in `payload/skills/canonical-sdlc/SKILL.md`'s Patrol
# paragraph that no hook can check, and that decide whether a resumed session works its own
# run or its neighbour's:
#
#   (g) THE RULE. "Which run" moved from the PROJECT to the SESSION at bionic 1.4.2: the open
#       run is the plan the session's own engagement marker names, and only an UNBOUND session
#       falls back to the newest plan. The hooks enforce it; the SENTENCE is what stops the
#       next reader from re-deriving the old project-keyed rule from the fallback they
#       happened to observe — which is exactly what an unbound session sees, every time.
#   (h) THE STEP. Engagement binds only a SOLE open run (AC-7), so a session resuming into a
#       root with several is unbound, and `adopt` partitions on the binding (AC-2). Without
#       the bind step the resume ritual reads as complete while leaving the session gated on
#       another run's plan and offered another run's agents — the two symptoms the wave was
#       opened for. No hook can require this: binding is an act the model takes, and the only
#       surface that can ask for it is this paragraph.
#
# BYTE-LEVEL, whitespace-normalized, through §2's own `has_pin` — the same latitude and no
# more. ANTI-VACUITY by the discriminate-a-doctored-copy pattern §1-§4 use.
#
# ASSERTION 32 IS THE ONE WITH TEETH ACROSS FILES: the verb this paragraph tells the operator
# to type is read out of SKILL.md and compared to the verb `hooks/session-poker.sh` puts in
# its own usage block. A rename on either side splits them here rather than in a session that
# types a command the tool does not have.
#
# APPENDED, NEVER REWRITTEN: §1-§4 belong to earlier slices.

section "Section 5: the session-bound run and the resume-ritual bind step"

# THE PARAGRAPH STATES ONE RULE, ONCE (review readability F1, S10b). Before this pin the
# Patrol paragraph carried the PRE-wave rule as a fact — "whether this PROJECT has an OPEN
# run … the open run decides WHAT it enforces" — and then the post-wave correction ~120
# words later in the same paragraph. `payload/scripts/lib/run.sh:313` calls that first
# sentence the defect in the codebase's own words; the doc kept its copy and appended the
# fix after it. The sentence below REPLACED it, so the paragraph no longer teaches the rule
# this wave exists to delete. Pinned as a pair: the new clause present, the old one gone.
PIN_SCOPE_PAIR='whether this SESSION is engaged, and which run this SESSION is bound to. Engagement decides WHETHER a hook acts at all; the bound run decides WHAT it enforces.'
PIN_SCOPE_OLD='whether this PROJECT has an OPEN run'
PIN_BOUND_RUN='**Which run is a property of the SESSION, not of the project** (bionic 1.4.2): the open run is the plan this session is BOUND to, recorded as the `plan=` line of its own engagement marker'
PIN_FALLBACK='Only an UNBOUND session falls back to the newest plan under the docs root'
PIN_BIND_STEP='**The resume ritual binds its run before it adopts anything:** if session-start listed more than one open run — or this session is otherwise unbound in a root that holds several — run `bash <plugin-root>/hooks/session-poker.sh bind <plan>` for the plan this session means, immediately after engaging and before the first dispatch.'

if has_pin "$SKILL_MD" "$PIN_BOUND_RUN"; then
  ok "30: SKILL.md states that the run is a property of the session, verbatim"
else
  no "30: SKILL.md states that the run is a property of the session, verbatim" "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_FALLBACK"; then
  ok "31: …and that ONLY an unbound session takes the newest-plan fallback"
else
  no "31: …and that ONLY an unbound session takes the newest-plan fallback" "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_BIND_STEP"; then
  ok "32: SKILL.md's resume ritual carries the bind step verbatim (A4: exactly one added step)"
else
  no "32: SKILL.md's resume ritual carries the bind step verbatim (A4: exactly one added step)" \
     "file: $SKILL_MD"
fi

# --- 33: the verb the paragraph types is the verb the tool offers ---
#
# READ FROM BOTH FILES, never asserted against a constant twice — §4's rule. The doc side is
# the operand-carrying spelling inside the bind sentence; the code side is the poker's own
# usage line. An extractor that returned empty on both sides could not agree its way to
# green, because assertion 34 pins the extracted value.
POKER_SH="${REPO}/hooks/session-poker.sh"

# bind_verb_doc <SKILL.md> -> `session-poker.sh bind <plan>` as the ritual spells it
bind_verb_doc() {
  _flatten "$1" \
    | sed -n 's/.*run `bash <plugin-root>\/hooks\/\(session-poker\.sh bind <plan>\)` for the plan.*/\1/p'
}
# bind_verb_code <session-poker.sh> -> the same phrase out of the usage block
bind_verb_code() {
  /usr/bin/grep -m1 'session-poker\.sh bind <plan>' "$1" 2>/dev/null \
    | sed -n 's/.*\(session-poker\.sh bind <plan>\).*/\1/p'
}

BIND_DOC=$(bind_verb_doc "$SKILL_MD")
BIND_CODE=$(bind_verb_code "$POKER_SH")

expect_eq "33: SKILL.md tells the operator to type the verb the poker publishes" \
  "$BIND_CODE" "$BIND_DOC"
expect_eq "34: …and the verb both sides name is 'session-poker.sh bind <plan>'" \
  'session-poker.sh bind <plan>' "$BIND_DOC"

# --- Anti-vacuity: the same extractors and pins must report a mutation ---

anchor "$SKILL_MD" 'Only an UNBOUND session falls back' 1
DOCTORED_BOUND="$TMP/skill-bound-run-mutated.md"
sed 's/Only an UNBOUND session falls back/Every session falls back/' "$SKILL_MD" > "$DOCTORED_BOUND"
if has_pin "$DOCTORED_BOUND" "$PIN_FALLBACK"; then
  no "35: a doctored SKILL.md fails the fallback pin (pin discriminates)" \
     "the pin matched a copy that says the opposite"
else
  ok "35: a doctored SKILL.md fails the fallback pin (pin discriminates)"
fi

anchor "$SKILL_MD" 'binds its run before it adopts anything' 1
DOCTORED_BIND="$TMP/skill-bind-step-mutated.md"
sed 's/binds its run before it adopts anything/adopts before it binds anything/' \
  "$SKILL_MD" > "$DOCTORED_BIND"
if has_pin "$DOCTORED_BIND" "$PIN_BIND_STEP"; then
  no "36: a reordered resume ritual fails the bind-step pin (pin discriminates)" \
     "the pin matched a copy that puts adopt first"
else
  ok "36: a reordered resume ritual fails the bind-step pin (pin discriminates)"
fi

anchor "$POKER_SH" 'session-poker.sh bind <plan>' 1
DOCTORED_BIND_VERB="$TMP/session-poker-verb-mutated.sh"
sed 's/session-poker\.sh bind <plan>/session-poker.sh bindrun <plan>/' "$POKER_SH" > "$DOCTORED_BIND_VERB"
expect_ne "37: a renamed poker verb splits from the doc (pin discriminates)" \
  "$BIND_DOC" "$(bind_verb_code "$DOCTORED_BIND_VERB")"

if has_pin "$SKILL_MD" "$PIN_SCOPE_PAIR"; then
  ok "38: SKILL.md's two-facts sentence names the SESSION's bound run, not the project's"
else
  no "38: SKILL.md's two-facts sentence names the SESSION's bound run, not the project's" \
     "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_SCOPE_OLD"; then
  no "39: …and the pre-wave project-scoped clause is gone from the paragraph" \
     "SKILL.md still states the rule this wave deleted: '$PIN_SCOPE_OLD'"
else
  ok "39: …and the pre-wave project-scoped clause is gone from the paragraph"
fi

# Anti-vacuity for 38, same pattern as 35/36: the extractor must report a doctored copy.
anchor "$SKILL_MD" 'which run this SESSION is bound to' 1
DOCTORED_SCOPE="$TMP/skill-scope-mutated.md"
sed 's/which run this SESSION is bound to/whether this PROJECT has an OPEN run/' \
  "$SKILL_MD" > "$DOCTORED_SCOPE"
if has_pin "$DOCTORED_SCOPE" "$PIN_SCOPE_PAIR"; then
  no "40: a doctored SKILL.md fails the scope pin (pin discriminates)" \
     "the pin matched a copy that says the opposite"
else
  ok "40: a doctored SKILL.md fails the scope pin (pin discriminates)"
fi

# --- S10 additions, same section, same shape as PIN_BIND_STEP above ---
#
# PIN_TASKLIST pins the resume-ritual step this wave adds immediately after the bind step:
# a session that resumes into a bound run rebuilds its task list from the plan rather than
# trusting whatever TaskList happens to still hold. PIN_RUNG pins the Patrol prompt's
# replacement for the retired NARROW recommendation (AC-17/AC-19; S8's report: "docs-pins.
# test.sh:327 still pins the token in SKILL.md and is S10's to retire" — Section 3's token
# list above no longer names NARROW, and this is the positive sentence that replaced it).
PIN_TASKLIST='**The resume ritual rebuilds the task list after it binds:** run `TaskList`; if it is empty and the bound plan has `## SDLC State`, recreate one entry per step (and per slice at the current step) from the plan, statuses from the step lines.'
# RE-POINTED at the sentence that separates the rung from the two HOLDS (Step-6 readability
# R-5/R-6). The prompt used to say "Three rungs, in order:" and then list two, and used the
# word `rung` for the advisory pair AND for `pressure_level`'s integer eleven words apart.
# The pin still holds the NARROW/RELAX retirement, which is what it was for.
PIN_RUNG='The rung is the separate thing they are often confused with: `pressure_level`'"'"'s integer, printed on every tick as `poker: rung=<n>/<ceiling>`, and it is the number a fill is sized by. NARROW and RELAX are retired — regulation is the rung'"'"'s, read by every consumer at the moment of use, never a tick'"'"'s advice.'

if has_pin "$SKILL_MD" "$PIN_TASKLIST"; then
  ok "48: SKILL.md's resume ritual rebuilds the task list after it binds, verbatim"
else
  no "48: SKILL.md's resume ritual rebuilds the task list after it binds, verbatim" \
     "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_RUNG"; then
  ok "49: SKILL.md's Patrol prompt names the rung line and retires NARROW/RELAX, verbatim"
else
  no "49: SKILL.md's Patrol prompt names the rung line and retires NARROW/RELAX, verbatim" \
     "file: $SKILL_MD"
fi

anchor "$SKILL_MD" 'recreate one entry per step' 1
DOCTORED_TASKLIST="$TMP/skill-tasklist-mutated.md"
sed 's/recreate one entry per step/recreate one entry per slice only/' "$SKILL_MD" > "$DOCTORED_TASKLIST"
if has_pin "$DOCTORED_TASKLIST" "$PIN_TASKLIST"; then
  no "50: a doctored SKILL.md fails the task-list pin (pin discriminates)" \
     "the pin matched a doctored copy"
else
  ok "50: a doctored SKILL.md fails the task-list pin (pin discriminates)"
fi

anchor "$SKILL_MD" 'NARROW and RELAX are retired' 1
DOCTORED_RUNG="$TMP/skill-rung-mutated.md"
sed 's/NARROW and RELAX are retired/NARROW and RELAX still apply/' "$SKILL_MD" > "$DOCTORED_RUNG"
if has_pin "$DOCTORED_RUNG" "$PIN_RUNG"; then
  no "51: a doctored SKILL.md fails the rung pin (pin discriminates)" \
     "the pin matched a doctored copy"
else
  ok "51: a doctored SKILL.md fails the rung pin (pin discriminates)"
fi

section "Section 6: Step 8's tmp wipe spares session-keyed state"
#
# THE DEFECT THIS PINS (critic C-2, remediated at S10b). Step 8 said `wipe .bionic/tmp/*`,
# unqualified. `.bionic/tmp/` is where EVERY session in the root keeps its engagement
# marker, its roster, its Patrol stamp, its preflight attestation and its sweeper state —
# all keyed by session id. A blanket wipe therefore destroys the live state of every OTHER
# session working that root, which is precisely the two-run scenario this wave exists for,
# and it contradicts the same file's own sentence that "the marker is never removed during
# the session once written". The Step 8 line now names what it spares.
#
# THE FIELD NAME `tmp-wiped:` IS DELIBERATELY UNTOUCHED (§Evidence, step 8 row). It is an
# evidence key the gate parses, not prose; renaming it would be an interface change and is
# not what the finding asked for.
PIN_TMP_SPARE='sparing every session-keyed file — `engaged-*.state`, `roster-*.state`, `patrol-*.state*`, `preflight-*.state`, `sweeper-*.state`'
PIN_TMP_BLANKET='wipe `.bionic/tmp/*`;'

if has_pin "$SKILL_MD" "$PIN_TMP_SPARE"; then
  ok "41: SKILL.md's Step 8 names the session-keyed files its wipe spares"
else
  no "41: SKILL.md's Step 8 names the session-keyed files its wipe spares" "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_TMP_BLANKET"; then
  no "42: …and no longer instructs the blanket wipe that destroyed them" \
     "SKILL.md still says: $PIN_TMP_BLANKET"
else
  ok "42: …and no longer instructs the blanket wipe that destroyed them"
fi

# The evidence key the gate reads is unchanged — the repair is prose, not interface.
if has_pin "$SKILL_MD" 'tmp-wiped:'; then
  ok "43: …while the Step-8 evidence key 'tmp-wiped:' is untouched"
else
  no "43: …while the Step-8 evidence key 'tmp-wiped:' is untouched" \
     "the gate parses this key; the S10b repair must not have renamed it"
fi

# Anti-vacuity, same pattern as 35/36/40.
anchor "$SKILL_MD" 'sparing every session-keyed file' 1
DOCTORED_TMP="$TMP/skill-tmp-wipe-mutated.md"
sed 's/sparing every session-keyed file/taking every file/' "$SKILL_MD" > "$DOCTORED_TMP"
if has_pin "$DOCTORED_TMP" "$PIN_TMP_SPARE"; then
  no "44: a doctored SKILL.md fails the spare-list pin (pin discriminates)" \
     "the pin matched a copy that says the opposite"
else
  ok "44: a doctored SKILL.md fails the spare-list pin (pin discriminates)"
fi

section "Section 7: bind's operand takes the spelling session-start prints"
#
# THE PAIR THIS PINS (S10b phase 2). hooks/session-start.sh prints the open-run listing
# DOCS-root-relative, so an operator copies `plans/<epic>/<wave>.md` out of it. That is the
# one spelling `bind` used to reject, because a relative operand was resolved against the
# PROJECT root only. The verb now tries the docs root when the project-relative spelling is
# not a regular file, and this section is the doc half of that agreement: the paragraph a
# reader learns the verb from must name all three spellings the verb accepts.
PIN_BIND_OPERAND='its operand may be absolute, project-root-relative, or docs-root-relative — the spelling session-start'"'"'s own listing prints'

if has_pin "$SKILL_MD" "$PIN_BIND_OPERAND"; then
  ok "45: SKILL.md names all three spellings bind accepts"
else
  no "45: SKILL.md names all three spellings bind accepts" "file: $SKILL_MD"
fi

# THE CODE HALF, read from the poker rather than asserted against a constant (§4's rule):
# the docs-root fallback must actually be in the verb, not only in the prose. Matched by
# SHAPE (the docs_root("$REPO") interpolation feeding a BIND_DOCS_TRY assignment) rather than
# by the exact operand variable name, so a rename of that operand (as S8 did, BIND_ARG ->
# BIND_ARG_P, for the trailing-slash strip) does not stale this pin the way a literal-string
# grep did.
BIND_DOCS_FALLBACK_RE='BIND_DOCS_TRY="\$\(docs_root "\$REPO"\)/\$[A-Za-z_][A-Za-z_0-9]*"'
if /usr/bin/grep -Eq "$BIND_DOCS_FALLBACK_RE" "$POKER_SH"; then
  ok "46: …and session-poker.sh really does try the docs root for a relative operand"
else
  no "46: …and session-poker.sh really does try the docs root for a relative operand" \
     "file: $POKER_SH"
fi

# Anti-vacuity, same pattern as 35/36/40/44.
anchor "$SKILL_MD" 'its operand may be absolute, project-root-relative, or docs-root-relative' 1
DOCTORED_OPERAND="$TMP/skill-bind-operand-mutated.md"
sed 's/its operand may be absolute, project-root-relative, or docs-root-relative/its operand must be absolute/' \
  "$SKILL_MD" > "$DOCTORED_OPERAND"
if has_pin "$DOCTORED_OPERAND" "$PIN_BIND_OPERAND"; then
  no "47: a doctored SKILL.md fails the operand pin (pin discriminates)" \
     "the pin matched a copy that says the opposite"
else
  ok "47: a doctored SKILL.md fails the operand pin (pin discriminates)"
fi

# Anti-vacuity for 46: a poker with the fallback line deleted must fail the same regex, so
# assertion 46 is proven to discriminate rather than matching everything by accident.
anchor "$POKER_SH" 'BIND_DOCS_TRY=' 1
DOCTORED_POKER_NO_FALLBACK="$TMP/session-poker-no-docs-fallback.sh"
/usr/bin/grep -v 'BIND_DOCS_TRY=' "$POKER_SH" > "$DOCTORED_POKER_NO_FALLBACK"
if /usr/bin/grep -Eq "$BIND_DOCS_FALLBACK_RE" "$DOCTORED_POKER_NO_FALLBACK"; then
  no "52: a poker with the docs-root fallback deleted fails assertion 46's check (pin discriminates)" \
     "the regex matched a copy with the fallback line removed"
else
  ok "52: a poker with the docs-root fallback deleted fails assertion 46's check (pin discriminates)"
fi

section "Section 8: SKILL.md carries its OWN copy of the rung-pointer sentence (AC-18)"
#
# THE GAP THE READBACK NAMED. Assertions 11/12 pin the rendered role files against
# `PIN_JOBS`, but nothing here had ever checked SKILL.md's own restatement of the same
# sentence in its "Fill the budget" paragraph — so a hand-edit to SKILL.md's copy could
# drift from the briefs' copy with no suite ever noticing.
#
# THE ONE REAL DIFFERENCE: SKILL.md's copy is prose inside a running paragraph, never
# bolded, where `agents-src/blocks/survival.md`'s copy leads a bulleted brief and IS bolded
# (`**Each brief…**`). `PIN_JOBS` encodes that bold form, so it is the wrong needle for
# SKILL.md; this pins the same words in the form SKILL.md actually carries them.
PIN_JOBS_SKILL='Each brief in the batch points the writer at the rung: `take your test width from pressure_level at suite start; the ceiling is this header'"'"'s test_jobs`.'

if has_pin "$SKILL_MD" "$PIN_JOBS_SKILL"; then
  ok "53: SKILL.md carries its own copy of the rung-pointer sentence (AC-18)"
else
  no "53: SKILL.md carries its own copy of the rung-pointer sentence (AC-18)" "file: $SKILL_MD"
fi

# Anti-vacuity, same 47-style shape: a doctored SKILL.md must fail the pin above.
anchor "$SKILL_MD" 'Each brief in the batch points the writer at the rung' 1
DOCTORED_SKILL_JOBS="$TMP/skill-jobs-mutated.md"
sed 's/Each brief in the batch points the writer at the rung/Each brief in the batch reads the frozen literal/' \
  "$SKILL_MD" > "$DOCTORED_SKILL_JOBS"
if has_pin "$DOCTORED_SKILL_JOBS" "$PIN_JOBS_SKILL"; then
  no "54: a doctored SKILL.md fails the rung-pointer pin (pin discriminates)" \
     "the pin matched a copy that says the opposite"
else
  ok "54: a doctored SKILL.md fails the rung-pointer pin (pin discriminates)"
fi


section "Section 9: the tick interval, in every place it is written down (D-3)"
#
# THE GAP THIS CLOSES. The design ledger's tick-interval row named "docs-pins holds the
# sentence" as its agreement test, and docs-pins held no such thing: `grep -n '20m'
# tests/docs-pins.test.sh` returned nothing, and either SKILL.md sentence could have been
# reverted to 30m with the whole suite green. AC-19 states the sentences as a deliverable and
# names no pin for them (Step-6 duplication review D-3).
#
# FOUR SITES, ONE DEFAULT. Two SKILL.md sentences carry it as prose — the config knob and the
# cron-job cadence — hooks/session-poker.sh carries it as `POKER_INTERVAL_DEFAULT`, and
# lib/patrol.sh carries it a FOURTH time as `PATROL_INTERVAL_LAST_RESORT=1200`, a deliberate
# commented copy used only when the poker cannot be reached. That copy shipped stale once
# already (S8 fixed a 1800 in it), which is exactly the drift its own comment predicts, so
# the seconds are compared against the poker's own answer rather than asserted twice.
PIN_INTERVAL_KNOB='config knob `poker-interval:` in `.bionic/config.yaml`, default 20m'
PIN_INTERVAL_CRON='fires into a `command not found` every 20 minutes and reports nothing'
PATROL_LIB="${REPO}/payload/scripts/lib/patrol.sh"

if has_pin "$SKILL_MD" "$PIN_INTERVAL_KNOB"; then
  ok "55: SKILL.md names the poker-interval default as 20m, verbatim"
else
  no "55: SKILL.md names the poker-interval default as 20m, verbatim" "file: $SKILL_MD"
fi
if has_pin "$SKILL_MD" "$PIN_INTERVAL_CRON"; then
  ok "56: SKILL.md's cron sentence names the same cadence in minutes, verbatim"
else
  no "56: SKILL.md's cron sentence names the same cadence in minutes, verbatim" "file: $SKILL_MD"
fi

# THE TWO CONSTANTS AGREE, and the poker's own verb is what says so — `interval-default`
# ignores config by contract, so this is the built-in against the last resort and not one
# machine's `.bionic/config.yaml` against another's.
POKER_DEFAULT_SECS="$(bash "$POKER_SH" interval-default 2>/dev/null)"
PATROL_LAST_RESORT="$(sed -n 's/^PATROL_INTERVAL_LAST_RESORT=\([0-9][0-9]*\).*/\1/p' "$PATROL_LIB" | head -1)"
expect_eq "57: lib/patrol.sh's last-resort interval equals the poker's built-in default" \
  "$POKER_DEFAULT_SECS" "$PATROL_LAST_RESORT"
expect_eq "58: …and that default really is 20 minutes, in seconds" "1200" "$POKER_DEFAULT_SECS"

# ANTI-VACUITY, the same doctored-copy shape as 50/51/54: a SKILL.md whose interval was
# reverted to the pre-wave 30m must fail both prose pins.
anchor "$SKILL_MD" 'default 20m' 1
anchor "$SKILL_MD" 'every 20 minutes' 1
DOCTORED_INTERVAL="$TMP/skill-interval-mutated.md"
sed 's/default 20m/default 30m/; s/every 20 minutes/every 30 minutes/' "$SKILL_MD" > "$DOCTORED_INTERVAL"
if has_pin "$DOCTORED_INTERVAL" "$PIN_INTERVAL_KNOB" || has_pin "$DOCTORED_INTERVAL" "$PIN_INTERVAL_CRON"; then
  no "59: a doctored SKILL.md fails both interval pins (they discriminate)" \
     "a pin matched a copy carrying the pre-wave 30m"
else
  ok "59: a doctored SKILL.md fails both interval pins (they discriminate)"
fi

# ---------------------------------------------------------------------------
# SECTION 60-63 — S13: the instrument the brief declares (spec AC-20, AC-21)
# ---------------------------------------------------------------------------
#
# WHAT IT OWNS. `skills/canonical-sdlc/SKILL.md` §Dispatch is where an orchestrator reads
# what a brief must carry. The wall in `hooks/dispatch-preflight.sh` refuses a brief that
# carries neither `Files:` nor `Suites:`, and the writer-side guard refuses a suite outside
# the recorded set — so a §Dispatch section that never mentions either label documents a
# grammar the machine no longer accepts, and every author writes a brief that is refused.
# These pins hold the two labels, the waiver, and the one-regression rule in that section.
#
# THE ROLE FILES ARE NOT PINNED HERE. `agents-src/blocks/survival.md` is the writer-side
# copy and it is GENERATED into agents/*.md — identity by construction, checked by
# `agents-src/render.sh --check`, which section 7 above already calls. A second pin on the
# generated text would be pinning the renderer's arithmetic.
#
# ANTI-VACUITY, the doctored-copy shape sections 50/51/54/59 use: a SKILL.md with the
# instrument sentence removed must fail these pins.
section "SECTION 10 — S13: the instrument the brief declares (spec AC-20, AC-21)"

PIN_S13_FILES='`Files:` on a line of its own names the paths this slice will write'
PIN_S13_DERIVE='the impact command named in `.bionic/config.yaml` turns them into the closed set of suites the agent may run'
PIN_S13_DECLARE='Where no impact command is configured, name the closed set yourself under `Suites:`'
PIN_S13_WAIVER='a brief that runs no suite at all waives with `Suites: none`'
PIN_S13_NEITHER='A brief carrying neither label refuses at dispatch.'
PIN_S13_REGRESSION='a second one refuses unless the plan'"'"'s `## SDLC State` carries a `regression-cause:` line for it'

for _p in FILES DERIVE DECLARE WAIVER NEITHER REGRESSION; do
  eval "_pv=\$PIN_S13_$_p"
  if has_pin "$SKILL_MD" "$_pv"; then
    ok "60: SKILL.md §Dispatch carries the S13 $_p sentence verbatim"
  else
    no "60: SKILL.md §Dispatch carries the S13 $_p sentence verbatim" "file: $SKILL_MD"
  fi
done

anchor "$SKILL_MD" '`Files:` on a line of its own names the paths this slice will write' 1
DOCTORED_S13="$TMP/skill-s13-mutated.md"
sed 's/`Files:` on a line of its own names the paths this slice will write/the brief says what it likes/' \
  "$SKILL_MD" > "$DOCTORED_S13"
if has_pin "$DOCTORED_S13" "$PIN_S13_FILES"; then
  no "61: a doctored SKILL.md fails the S13 FILES pin (it discriminates)" \
     "the pin matched a copy with the sentence removed"
else
  ok "61: a doctored SKILL.md fails the S13 FILES pin (it discriminates)"
fi

# THE WRITER-SIDE COPY EXISTS AND IS THE RENDERER'S INPUT. Not its text — its presence in
# the SOURCE block, so the sentence a dispatched agent reads cannot be edited into the
# generated file and lost at the next render (the failure mode agents-src exists to remove).
SURVIVAL_BLOCK="${REPO}/agents-src/blocks/survival.md"
PIN_S13_SURVIVAL='Your suite budget is on your roster row, and it is a wall.'
if has_pin "$SURVIVAL_BLOCK" "$PIN_S13_SURVIVAL"; then
  ok "62: the writer-side budget rule is in agents-src/blocks/survival.md, the rendered SOURCE"
else
  no "62: the writer-side budget rule is in agents-src/blocks/survival.md, the rendered SOURCE" \
     "file: $SURVIVAL_BLOCK"
fi
# …and it reached every generated role file, which is what the writer actually reads.
S13_ROLES_MISSING=0
for _r in "${REPO}"/agents/*.md; do
  has_pin "$_r" "$PIN_S13_SURVIVAL" || S13_ROLES_MISSING=$((S13_ROLES_MISSING + 1))
done
expect_eq "63: …and every generated role file carries it" "0" "$S13_ROLES_MISSING"
expect_eq "63: …over a non-empty set of role files" "0" \
  "$([ -n "$(ls "${REPO}"/agents/*.md 2>/dev/null)" ] && echo 0 || echo 1)"

# THE SPELLING RULE THAT MAKES THE BUDGET USABLE (review-c C-6). The wall reads the command
# TEXT, so a loop variable is refused by its unexpanded name — and the one place a writer
# reads the budget rule said nothing about it. A fresh agent with no plan read hit exactly
# that on its first attempt (the walk, heading 10b). Pinned in the SOURCE block, and
# reaching every generated role file, on the same footing as the rule it qualifies.
PIN_S13_SPELLING='Spell each suite as a literal path and call it once per suite'
if has_pin "$SURVIVAL_BLOCK" "$PIN_S13_SPELLING"; then
  ok "63b: the spelling rule is in agents-src/blocks/survival.md, the rendered SOURCE"
else
  no "63b: the spelling rule is in agents-src/blocks/survival.md, the rendered SOURCE" \
     "file: $SURVIVAL_BLOCK"
fi
S13_SPELL_MISSING=0
for _r in "${REPO}"/agents/*.md; do
  has_pin "$_r" "$PIN_S13_SPELLING" || S13_SPELL_MISSING=$((S13_SPELL_MISSING + 1))
done
expect_eq "63b: …and every generated role file carries it" "0" "$S13_SPELL_MISSING"

section "Section 11: the plugin renders whole — the skill file is a build output (wave-02 AC-1, AC-6, AC-8)"

# WHAT THIS SECTION OWNS. Until wave-02 S2a, `skills/canonical-sdlc/SKILL.md` was
# hand-written and four of its passages were hand-COPIED into role files under markers
# that said "canonical copy of skills/canonical-sdlc/SKILL.md §…" — a promise, with no
# test between the copies. r3's census found all four, and the irony that one of them IS
# the agreement-test obligation. The repair is not another pairwise diff arm: the skill
# file became the renderer's third unit and the four passages became blocks, so the
# copies are injections and cannot disagree. This section pins BOTH halves of that —
# that `--check` now sees the skill file at all (assertions 64-66, the defect control),
# and that each passage really is one text reaching every surface (67-71).
#
# ANTI-VACUITY. 64 is the positive control 65 and 66 mean nothing without: a clone that
# ALREADY failed --check would make any "the edit turned it red" arm true for free. The
# byte-identity arms (67-71) each assert against a NON-EMPTY extraction, because two
# empty strings are equal and an extractor that found nothing would otherwise pass every
# one of them.
#
# HERMETIC. The clone is a copy of the working tree's render inputs and outputs under
# the same mktemp dir the rest of this file uses; render.sh derives every directory from
# its own location, so the clone renders against its own outputs and the repo is never
# written.

RENDERED_MANIFEST="${REPO}/payload/integrity/rendered.sha256"
BLOCK_DIR="${REPO}/agents-src/blocks"
SKILL_TMPL="${REPO}/agents-src/templates/skills/canonical-sdlc/SKILL.md.tmpl"
OPRULES="${REPO}/skills/canonical-sdlc/operational-rules.md"

expect_true "64a: the skill file has a template (it is a render target, not a hand-written file)" \
  test -f "$SKILL_TMPL"
expect_true "64b: the renderer's unit table names the skill unit" \
  grep -qF 'agents-src/templates/skills/canonical-sdlc|skills/canonical-sdlc' "$RENDER_SH"

# clone_render_tree <dest> — the render inputs and outputs, and nothing else.
clone_render_tree() {
  local dest="$1"
  mkdir -p "$dest/payload/commands" "$dest/payload/.claude-plugin" "$dest/payload/integrity" \
           "$dest/skills/canonical-sdlc" "$dest/agents" || return 1
  cp -R "${REPO}/agents-src" "$dest/agents-src" || return 1
  cp "${REPO}"/agents/*.md "$dest/agents/" || return 1
  cp "${REPO}"/payload/commands/*.md "$dest/payload/commands/" || return 1
  cp "${REPO}/payload/.claude-plugin/plugin.json" "$dest/payload/.claude-plugin/" || return 1
  cp "${REPO}/skills/canonical-sdlc/SKILL.md" "$dest/skills/canonical-sdlc/" || return 1
  [ -f "$RENDERED_MANIFEST" ] && cp "$RENDERED_MANIFEST" "$dest/payload/integrity/"
  return 0
}

CLONE="$TMP/render-clone"
if clone_render_tree "$CLONE"; then
  ok "64: a clone of the render tree is built (the fixture 65 and 66 mutate)"
else
  no "64: a clone of the render tree is built (the fixture 65 and 66 mutate)" "dest: $CLONE"
fi

# THE POSITIVE CONTROL. An unedited clone must be clean, or every "the edit turned it
# red" arm below is true for a reason that has nothing to do with the edit.
if bash "$CLONE/agents-src/render.sh" --check >/dev/null 2>&1; then
  ok "65: the unedited clone passes --check (the control the next two arms need)"
else
  no "65: the unedited clone passes --check (the control the next two arms need)" \
     "run 'bash $CLONE/agents-src/render.sh --check' for the diff"
fi

# THE DEFECT CONTROL FOR AC-1: one hand edit to the rendered skill file.
sed -i.bak 's/^# Canonical SDLC$/# Canonical SDLC (hand-edited)/' \
  "$CLONE/skills/canonical-sdlc/SKILL.md" 2>/dev/null
rm -f "$CLONE/skills/canonical-sdlc/SKILL.md.bak"
CHECK_OUT="$(bash "$CLONE/agents-src/render.sh" --check 2>&1)"
CHECK_RC=$?
expect_ne "66a: one hand edit to skills/canonical-sdlc/SKILL.md turns --check red" "0" "$CHECK_RC"
expect_match "66b: …and the diff names the file it rejected" \
  "*skills/canonical-sdlc/SKILL.md*" "$CHECK_OUT"

# THE SAME FOR THE WIDENED MANIFEST'S OTHER HALF: a command page is a rendered file too,
# and before this slice the manifest answered only for the six role files.
CLONE2="$TMP/render-clone-2"
clone_render_tree "$CLONE2" || true
printf '\nhand-edited\n' >> "$CLONE2/payload/commands/help.md"
CHECK_OUT2="$(bash "$CLONE2/agents-src/render.sh" --check 2>&1)"
expect_ne "67a: one hand edit to a rendered command page turns --check red" "0" "$?"
expect_match "67b: …and the diff names that page" "*commands/help.md*" "$CHECK_OUT2"

# ── The four passages: one text, every surface ──────────────────────────────
#
# marker_span reads the injection markers render.sh writes, so the extraction follows the
# renderer's own contract rather than a second guess at where a passage starts.
marker_span() {  # <file> <MARKER-NAME>
  awk -v m="$2" '
    $0 == "<!-- " m "-BEGIN -->" { inp = 1; next }
    $0 == "<!-- " m "-END -->"   { inp = 0 }
    inp { print }
  ' "$1" 2>/dev/null
}

# same_everywhere <n> <label> <block-file> <marker> <surface...>
same_everywhere() {
  local n="$1" label="$2" blockfile="$3" marker="$4"; shift 4
  local body surface span bad=""
  body="$(cat "$blockfile" 2>/dev/null)"
  if [ -z "$body" ]; then
    no "${n}: ${label}" "the block ${blockfile##*/} is missing or empty — an empty pin proves nothing"
    return
  fi
  for surface in "$@"; do
    span="$(marker_span "$surface" "$marker")"
    [ "$span" = "$body" ] || bad="${bad} ${surface#${REPO}/}"
  done
  if [ -z "$bad" ]; then
    ok "${n}: ${label}"
  else
    no "${n}: ${label}" "differs from ${blockfile##*/} in:${bad} — run 'bash agents-src/render.sh'"
  fi
}

same_everywhere 68 "the auditor mandate is one text in the block, the skill file and agents/auditor.md" \
  "${BLOCK_DIR}/auditor-mandate.md" "AUDITOR-MANDATE" "$SKILL_MD" "${REPO}/agents/auditor.md"

same_everywhere 69 "the critic prompt template is one text in the block, the skill file and agents/critic.md" \
  "${BLOCK_DIR}/critic-template.md" "CRITIC-TEMPLATE" "$SKILL_MD" "${REPO}/agents/critic.md"

same_everywhere 70 "the duplication axis is one text in the block, the skill file and agents/critic.md" \
  "${BLOCK_DIR}/duplication-axis.md" "DUPLICATION-AXIS" "$SKILL_MD" "${REPO}/agents/critic.md"

same_everywhere 71 "the terminal-disposition rule is one text in the block and the skill file" \
  "${BLOCK_DIR}/terminal-disposition.md" "TERMINAL-DISPOSITION" "$SKILL_MD"

same_everywhere 72 "the orchestrator's dispatch body is one text in the block and the skill file" \
  "${BLOCK_DIR}/orchestrator-dispatch.md" "ORCHESTRATOR-DISPATCH" "$SKILL_MD"

# The duplicate that had no renderer at all: two hand-written files carrying one span.
expect_true "73a: operational-rules.md no longer carries its own copy of the rule" \
  test -f "$OPRULES"
expect_absent "73b: …the TERMDISP span is gone from it" "TERMDISP" "$(cat "$OPRULES")"
expect_contains "73c: …and it points at the block instead" \
  "agents-src/blocks/terminal-disposition.md" "$(cat "$OPRULES")"

# ── The manifest covers every rendering (AC-8) ──────────────────────────────
expect_true "74a: payload/integrity/rendered.sha256 exists" test -f "$RENDERED_MANIFEST"
expect_false "74b: payload/integrity/agents.sha256 is gone" \
  test -f "${REPO}/payload/integrity/agents.sha256"
MANIFEST_BODY="$(grep -v '^#' "$RENDERED_MANIFEST" 2>/dev/null | grep -v '^[[:space:]]*$')"
expect_eq "74c: it carries one row per rendered file (six roles, four commands, the skill)" \
  "11" "$(printf '%s\n' "$MANIFEST_BODY" | wc -l | tr -d ' ')"
expect_contains "74d: …including the skill file, plugin-root-relative" \
  "  skills/canonical-sdlc/SKILL.md" "$MANIFEST_BODY"
expect_contains "74e: …and the command pages, plugin-root-relative" \
  "  commands/help.md" "$MANIFEST_BODY"
expect_contains "74f: …and the role files, plugin-root-relative" \
  "  agents/auditor.md" "$MANIFEST_BODY"

# The one runtime consumer reads the file the renderer now writes. Named here because a
# rename that missed it would leave doctor answering `unknown` on every machine.
expect_contains "75: payload/scripts/lib/detect.sh reads integrity/rendered.sha256" \
  'integrity/rendered.sha256' "$(cat "$DETECT_SH")"
expect_absent "75b: …and names the deleted manifest nowhere" \
  'integrity/agents.sha256' "$(cat "$DETECT_SH")"

# ── Section 6: K3 — premise text (AC-K3.1, AC-K3.2) ─────────────────────────
#
# ideas/bug-premise-decisions-surface-at-the-pr.md F1/F2 (D3 keeps F1/F2, cuts F3;
# adrs: is F4, covered by tests/canonical-sdlc-governing-skill.test.sh instead — a
# hook wall, not a doc-text pin). Both ACs are STATIC: docs-pins reads the rendered
# Step-2 Design Interview frame span (SKILL.md, "Open with the frame" paragraph)
# byte-for-byte, the same `has_pin` idiom §1-§5 use.
section "Section 6: K3 — premise text (Context/Problem first, Mechanisms inherited)"

# AC-K3.1: Context and Problem, for a stranger, is the FIRST thing the frame
# ratifies — ahead of the orchestrator's own design intuition and every decision
# below it. Pinned as one substring spanning the frame's opening clause straight
# into the Context-and-Problem sentence, so the pin itself IS an adjacency (hence
# order) check: it can only match a copy where nothing has been inserted, or
# swapped in, between "before any question." and "Its first ratification is
# **Context and Problem".
PIN_K3_FIRST='**Open with the frame**, before any question. Its first ratification is **Context and Problem, for a stranger**'

# AC-K3.2, half 1: the frame carries a "Mechanisms inherited" item, each line
# marked kept or questioned.
PIN_K3_MECH='**Mechanisms inherited**, one line per substrate or mechanism the design builds on, each marked `kept` or `questioned`'

# AC-K3.2, half 2: placement decisions (tier / runtime surface / hardware) are
# named strategic BY RULE, not left to a default.
PIN_K3_STRATEGIC='placing a test cohort in a tier, a job on a runtime surface, or a workload on hardware is **strategic by rule**'

if has_pin "$SKILL_MD" "$PIN_K3_FIRST"; then
  ok "76: SKILL.md's Step-2 frame ratifies Context and Problem, for a stranger, first"
else
  no "76: SKILL.md's Step-2 frame ratifies Context and Problem, for a stranger, first" "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_K3_MECH"; then
  ok "77: …and carries a Mechanisms inherited item, each kept or questioned"
else
  no "77: …and carries a Mechanisms inherited item, each kept or questioned" "file: $SKILL_MD"
fi

if has_pin "$SKILL_MD" "$PIN_K3_STRATEGIC"; then
  ok "78: …and names tier/runtime-surface/hardware placement strategic by rule"
else
  no "78: …and names tier/runtime-surface/hardware placement strategic by rule" "file: $SKILL_MD"
fi

# --- Anti-vacuity: the same pins must discriminate a mutated copy ---

# 79: ORDER REVERSED (AC-K3.1's own fails-when). The doctored copy swaps the
# Context-and-Problem sentence and the Design-intuition sentence in place — the
# literal shape of "the order is reversed" — rather than deleting anything, so a
# pin that merely checked PRESENCE of both phrases would stay green through it.
anchor -E "$SKILL_MD" 'Its first ratification is \*\*Context and Problem, for a stranger\*\*' 1
DOCTORED_K3_ORDER="$TMP/skill-k3-order-reversed.md"
sed -E '
s/(\*\*Open with the frame\*\*, before any question\. )(Its first ratification is \*\*Context and Problem, for a stranger\*\*: the problem and the goal, written as if for a reader who has never opened this repo; this comes before your own design intuition and before every decision in the frame below it — a change not yet explainable to someone who was not there is not yet understood\. )(Then your own \*\*Design intuition\*\*, the shape you expect to be right, stated so the user can push on it; )/\1\3\2/
' "$SKILL_MD" > "$DOCTORED_K3_ORDER"
if has_pin "$DOCTORED_K3_ORDER" "$PIN_K3_FIRST"; then
  no "79: order-reversed SKILL.md fails the first-ratification pin (pin discriminates)" \
     "the mutated copy still matched — the pin does not see the reorder"
else
  ok "79: order-reversed SKILL.md fails the first-ratification pin (pin discriminates)"
fi
# Control: prove the doctored copy really moved Design intuition ahead of
# Context and Problem, rather than merely mangling the text into something that
# happens to fail the pin for an unrelated reason.
expect_contains "79b: …and the doctored copy really does read Design intuition, then Context and Problem" \
  'Then your own **Design intuition**, the shape you expect to be right, stated so the user can push on it; Its first ratification is **Context and Problem' \
  "$(cat "$DOCTORED_K3_ORDER")"

# 80: Mechanisms inherited ABSENT (AC-K3.2's fails-when). The strategic-by-rule
# clause stays untouched in this copy — proof the mutation removed only the
# Mechanisms-inherited item, not the whole paragraph.
anchor "$SKILL_MD" 'Mechanisms inherited' 1
DOCTORED_K3_MECH="$TMP/skill-k3-mechanisms-absent.md"
sed 's/\*\*Mechanisms inherited\*\*, one line per substrate or mechanism the design builds on, each marked `kept` or `questioned` — a `questioned` line becomes a strategic fork; //' \
  "$SKILL_MD" > "$DOCTORED_K3_MECH"
if has_pin "$DOCTORED_K3_MECH" "$PIN_K3_MECH"; then
  no "80: SKILL.md with Mechanisms inherited stripped still passes the mech pin (pin discriminates)" \
     "the mutated copy still matched — the pin does not see the removal"
else
  ok "80: SKILL.md with Mechanisms inherited stripped still passes the mech pin (pin discriminates)"
fi
if has_pin "$DOCTORED_K3_MECH" "$PIN_K3_STRATEGIC"; then
  ok "80b: …and the strategic-by-rule clause survives untouched in the same copy (isolated mutation)"
else
  no "80b: …and the strategic-by-rule clause survives untouched in the same copy (isolated mutation)" \
     "the mutation removed more than the Mechanisms-inherited clause"
fi

# 81: "strategic by rule" ABSENT (AC-K3.2's other half). Mechanisms inherited
# stays untouched here, the mirror-image isolation check of 80b.
anchor "$SKILL_MD" 'strategic by rule' 1
DOCTORED_K3_STRAT="$TMP/skill-k3-strategic-absent.md"
sed "s/is \\*\\*strategic by rule\\*\\* and is never defaulted/is left to the writer's judgment/" \
  "$SKILL_MD" > "$DOCTORED_K3_STRAT"
if has_pin "$DOCTORED_K3_STRAT" "$PIN_K3_STRATEGIC"; then
  no "81: SKILL.md with strategic-by-rule stripped still passes the strategic pin (pin discriminates)" \
     "the mutated copy still matched — the pin does not see the removal"
else
  ok "81: SKILL.md with strategic-by-rule stripped still passes the strategic pin (pin discriminates)"
fi
if has_pin "$DOCTORED_K3_STRAT" "$PIN_K3_MECH"; then
  ok "81b: …and Mechanisms inherited survives untouched in the same copy (isolated mutation)"
else
  no "81b: …and Mechanisms inherited survives untouched in the same copy (isolated mutation)" \
     "the mutation removed more than the strategic-by-rule clause"
fi

finish
