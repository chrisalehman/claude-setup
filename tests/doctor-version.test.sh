#!/bin/bash
# tests/doctor-version.test.sh — doctor.sh's installed-vs-latest version row
# (F5, epic-19 wave-01, spec AC-F5; design ledger
# .bionic/docs/record/epic-19/step2-design-ledger.md, T4 "OK"; grounding
# .bionic/docs/record/epic-19/step1-fixes-grounding.md item 5).
#
# THE CONTRACT UNDER TEST. Doctor's BIONIC NATIVE table carries a `version`
# row, answered per feed kind (payload/scripts/lib/detect.sh:detect_
# marketplace_feed_kind):
#   - git feed: compares the installed plugin.json against the marketplace's
#     CACHED CLONE (known_marketplaces.json's `installLocation`) — current is
#     one quiet ✓ line, lag names the exact repair command and also earns a
#     FIX_LINES_OTHER verdict line (`claude plugin update bionic@bionic`).
#   - directory feed: a remote-latest compare is meaningless there (the CLI
#     already runs that tree) — the row instead reuses the EXISTING registry-
#     sha/reconverge machinery (detect_registry_sha_lag +
#     detect_reconverge_hint), consumed rather than duplicated.
#   - feed kind unknown (no registry, no jq, no bionic entry): an honest
#     `unknown` line, never a guessed verdict.
#
# EXECUTED, NOT SOURCED — same posture as tests/doctor-patrol.test.sh: this
# drives the real payload/scripts/doctor.sh through the seams detect.sh
# already offers every caller (BIONIC_CLAUDE_HOME, BIONIC_PLUGIN_ROOT), with
# fixture `plugins/known_marketplaces.json` / `plugins/installed_plugins.json`
# files under a fixture claude-home rather than any mock of detect.sh itself.
#
# WHY THE DIRECTORY-FEED CASE FORCES ITS OWN PWD. detect_registry_sha_lag()
# compares `installed_plugins.json`'s recorded gitCommitSha against `git
# rev-parse HEAD` **of the caller's own $PWD** (doctor.sh calls it with no
# argument) — so that one case runs doctor from an explicit `(cd "$REPO" &&
# ...)` subshell rather than trusting how this suite itself was invoked.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below (tests/
# assert-helper-race.test.sh): containment is bash `[[ == * ]]` in-process,
# and the one awk extraction below (like doctor-patrol.test.sh's) reads to
# EOF rather than closing early.
#
# Usage: bash tests/doctor-version.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
DOCTOR_SH="${PAYLOAD}/scripts/doctor.sh"

command -v jq >/dev/null 2>&1 || { echo "doctor-version.test.sh: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "doctor-version.test.sh: git is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_true "payload/scripts/doctor.sh exists" test -f "$DOCTOR_SH"

REAL_VERSION="$(jq -r '.version // empty' "${PAYLOAD}/.claude-plugin/plugin.json")"
expect_true "the real payload plugin.json carries a version" test -n "$REAL_VERSION"

# ---------- fixture builders ----------

# A claude-home carrying only the two registry files detect.sh's marketplace
# facts read (`_detect_known_marketplaces_file` / `_detect_installed_plugins_file`'s
# defaults, both under `<claude-home>/plugins/`).
make_registry_home() {  # -> claude-home dir on stdout
  local dir
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/plugins"
  printf '%s' "$dir"
}

write_known_marketplaces() {  # <claude-home> <source-json> <installLocation>
  jq -nc --argjson src "$2" --arg loc "$3" \
    '{bionic:{source:$src, installLocation:$loc, lastUpdated:"2026-08-27T00:00:00Z"}}' \
    > "$1/plugins/known_marketplaces.json"
}

write_empty_known_marketplaces() {  # <claude-home> — no bionic entry at all
  printf '{}' > "$1/plugins/known_marketplaces.json"
}

write_installed_plugins_sha() {  # <claude-home> <installPath> <gitCommitSha>
  jq -nc --arg path "$2" --arg sha "$3" \
    '{plugins:{"bionic@bionic":[{installPath:$path, gitCommitSha:$sha}]}}' \
    > "$1/plugins/installed_plugins.json"
}

# A git-feed marketplace's cached clone: `.claude-plugin/marketplace.json`
# naming bionic's plugin source (bionic ships this as the plain relative path
# "./payload" — .claude-plugin/marketplace.json in this very repo does the
# same), plus the plugin.json that source resolves to.
make_git_marketplace_clone() {  # <version> -> clone dir on stdout
  local version="$1" dir
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/.claude-plugin" "$dir/payload/.claude-plugin"
  jq -nc '{plugins:[{name:"bionic", source:"./payload"}]}' \
    > "$dir/.claude-plugin/marketplace.json"
  jq -nc --arg v "$version" '{name:"bionic", version:$v}' \
    > "$dir/payload/.claude-plugin/plugin.json"
  printf '%s' "$dir"
}

# ---------- driving doctor ----------

# A LONG PATH SEGMENT, used by the fixture rc below and by Section 5's clone.
LONGSEG="$(printf 'segment-%.0s' $(seq 1 8))"

# THE SHELL RC IS A FIXTURE, NOT THE MACHINE'S (added at S9 with Section 5).
# doctor's ENVIRONMENT section names the rc it read, and until this existed the
# suite read the real `$HOME/.zshrc` — so that row's width, and whether it said
# the proxy was on, depended on whose machine ran the suite. It is now bionic's
# own block at a deliberately long path: deterministic, and long enough that the
# row it renders needs the column budget to survive.
FIXTURE_RC="${TMP}/${LONGSEG}/${LONGSEG}/dot.zshrc"
mkdir -p "$(dirname "$FIXTURE_RC")"
{
  echo '# ─── bionic:rc:start ───'
  echo 'claude() { command claude --allow-dangerously-skip-permissions "$@"; }'
  echo '# ─── bionic:rc:end ───'
} > "$FIXTURE_RC"

# `(cd "$REPO" && ...)` UNCONDITIONALLY, not only for the directory-feed case:
# it costs nothing for the git-feed/unknown cases and removes any dependence
# on how this suite itself was invoked, matching REPO's `git rev-parse HEAD`
# to what a run through tests/run.sh (which itself `cd`s to $REPO) would see.

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

run_doctor() {  # <claude-home> [shell-rc]
  ( cd "$REPO" && HOME="$TMP" PATH="$BIN" BIONIC_SHELL_RC="${2:-$FIXTURE_RC}" \
      BIONIC_CLAUDE_HOME="$1" BIONIC_PLUGIN_ROOT="$PAYLOAD" BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

run_doctor_no_claude() {  # <claude-home> — the same page with the CLI off PATH
  ( cd "$REPO" && HOME="$TMP" PATH="$BIN_NO_CLAUDE" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$1" BIONIC_PLUGIN_ROOT="$PAYLOAD" BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

# The version row alone — the one line in BIONIC NATIVE beginning with one of
# the three status glyphs followed by "version". Read to EOF (no `grep -q`
# early close, per assert-helper-race.test.sh).
#
# `[^ ]+`, NOT `.`. The status glyph is three bytes and one column, and awk's `.`
# matches a CHARACTER only under a UTF-8 locale. Under `LC_ALL=C` — the locale
# scripts/lib/width.sh exists for — `/^  . version /` matched nothing, this
# helper returned the empty string, and thirteen cases below failed as "no match
# … in: ''" against a doctor that was printing the row correctly. Same defect
# and same repair as tests/doctor-walls.test.sh's `walls_rows`.
version_row() {  # <full-output>
  printf '%s\n' "$1" | awk '/^  [^ ]+ version /'
}

section "Section 1: git feed, installed == marketplace latest"

CLONE1="$(make_git_marketplace_clone "$REAL_VERSION")"
HOME1="$(make_registry_home)"
write_known_marketplaces "$HOME1" '{"source":"github","repo":"example/bionic"}' "$CLONE1"

OUT1="$(run_doctor "$HOME1")"
ROW1="$(version_row "$OUT1")"

expect_match "1: the row is a quiet checkmark" "*✓ version*${REAL_VERSION}*up to date*" "$ROW1"
expect_no_match "2: no update command rides the row when current" "*claude plugin update*" "$ROW1"
expect_no_match "3: no update-command verdict line prints when current" \
  "*claude plugin update bionic@bionic*" "$OUT1"

section "Section 2: git feed, installed lags the marketplace"

CLONE2="$(make_git_marketplace_clone "9.9.9")"
HOME2="$(make_registry_home)"
write_known_marketplaces "$HOME2" '{"source":"github","repo":"example/bionic"}' "$CLONE2"

OUT2="$(run_doctor "$HOME2")"
ROW2="$(version_row "$OUT2")"

expect_match "4: the row names installed and the exact update command" \
  "*✗ version*${REAL_VERSION}*9.9.9 available*claude plugin update bionic@bionic*" "$ROW2"
expect_match "5: the verdict area carries a matching fix line" \
  "*bionic ${REAL_VERSION} installed, 9.9.9 available*claude plugin update bionic@bionic*" "$OUT2"

section "Section 3: directory feed — reconverge integration, not a remote compare"

HOME3="$(make_registry_home)"
write_known_marketplaces "$HOME3" '{"source":"directory","path":"'"$REPO"'"}' "$REPO"
REPO_HEAD="$(git -C "$REPO" rev-parse HEAD)"
write_installed_plugins_sha "$HOME3" "$REPO" "$REPO_HEAD"

OUT3="$(run_doctor "$HOME3")"
ROW3="$(version_row "$OUT3")"

expect_match "6: a directory feed at the registered sha reads as a match, not a compare" \
  "*✓ version*${REAL_VERSION}*tree matches the registered cache*" "$ROW3"
expect_no_match "7: no marketplace-latest language leaks into the directory-feed row" \
  "*available*claude plugin update*" "$ROW3"

section "Section 4: feed kind cannot be determined — honest unknown, never a guess"

HOME4="$(make_registry_home)"
write_empty_known_marketplaces "$HOME4"

OUT4="$(run_doctor "$HOME4")"
ROW4="$(version_row "$OUT4")"

expect_match "8: the degraded case reads unknown with a stated cause" \
  "*– version*unknown —*" "$ROW4"
expect_no_match "9: a degraded feed kind never claims current or lag" \
  "*up to date*" "$ROW4"
expect_no_match "10: a degraded feed kind never prints an update command" \
  "*claude plugin update*" "$ROW4"

section "Section 5: every line doctor prints fits the column budget"

# WHY THIS SECTION IS IN THIS SUITE. doctor.sh's format rules have always stated
# the budget — nothing printed may exceed 100 columns, because a wrapped line is
# one row turned into two — and nothing has enforced it since
# tests/doctor.test.sh was deleted at 8582861 (epic-18 wave-03). The row F5 added
# is what found the gap: on the wave's own T3 capture it measured 104 columns,
# because `unknown — ${LATEST_CAUSE}` interpolates free text nobody bounded.
# Slice 4/3 had built exactly this wall for setup.sh (tests/command-relay.test.sh
# Group B) one slice earlier. This is that wall, on the other script, driving the
# four feed-kind arms above plus the worst case below.
#
# THE RULER IS THE PRODUCT'S OWN (`bionic_cols`, payload/scripts/lib/width.sh) —
# the same function doctor truncates with, because a wall measured in bytes
# while the script budgets in columns is a wall with a gap in it. That ruler is
# pinned directly, positives and negatives, in command-relay.test.sh Group B0.
# shellcheck source=/dev/null
. "${PAYLOAD}/scripts/lib/width.sh"

# ONE EXEMPTION, NAMED AND NEVER SILENT. The half-uninstalled teardown line is a
# raw URL inside a pipefail wrapper that a person has to PASTE — 132 columns, and
# eliding it would hand them a command that fails instead of a line that wraps.
# doctor.sh says so where it prints it. So the rule this suite walls is "every
# line fits except that one", and the arms below prove the exemption is load-
# bearing rather than a hole: on a fixture that prints it, at least one
# over-budget line must exist and every over-budget line must BE it.
REMOVE_CMD_LINE='*curl -fsSL *remove.sh | bash'"'"

over_budget_lines() {  # <text> -> every line wider than the budget
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(bionic_cols "$line")" -gt "$BIONIC_LINE_WIDTH" ] && printf '%s\n' "$line"
  done <<< "$1"
  return 0
}

expect_all_lines_fit() {  # <label> <text>
  local label="$1" over line bad=""
  over="$(over_budget_lines "$2")"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2254  # RHS is a glob on purpose
    case "$line" in $REMOVE_CMD_LINE) continue ;; esac
    bad="$line"; break
  done <<< "$over"
  if [ -z "$bad" ]; then ok "$label"
  else no "$label" "$(bionic_cols "$bad") columns (budget ${BIONIC_LINE_WIDTH}): ${bad}"; fi
}

# THE WORST CASE THE REVIEW NAMED, built rather than argued: a git feed whose
# marketplace clone has no plugin.json, so `detect_plugin_latest`'s cause is
# `no plugin.json at <installLocation>/payload/.claude-plugin/plugin.json` —
# an absolute path inside a sentence inside a row that already spends 25 columns
# on its prefix. The clone lives under a deliberately long directory so the
# untruncated row would run past 280 columns.
CLONE5="${TMP}/${LONGSEG}/${LONGSEG}/clone"
mkdir -p "$CLONE5/.claude-plugin"
jq -nc '{plugins:[{name:"bionic", source:"./payload"}]}' \
  > "$CLONE5/.claude-plugin/marketplace.json"
HOME5="$(make_registry_home)"
write_known_marketplaces "$HOME5" '{"source":"github","repo":"example/bionic"}' "$CLONE5"

OUT5="$(run_doctor "$HOME5")"
ROW5="$(version_row "$OUT5")"

# The positive the wall means nothing without: this fixture really does reach
# the unbounded arm, and really does carry the long path into the row.
expect_match "12: the missing-manifest fixture reaches the unknown arm" \
  "*version*unknown — no plugin.json at *" "$ROW5"
# The long clone path is no longer READABLE in the row — that is the point:
# it was elided to fit. The elision itself is the assertion.
expect_match "13: and the long clone path was elided rather than printed whole" \
  "*…" "$ROW5"

expect_all_lines_fit "14: git feed, current — every line fits the budget"          "$OUT1"
expect_all_lines_fit "15: git feed, lagging — every line fits the budget"          "$OUT2"
expect_all_lines_fit "16: directory feed — every line fits the budget"             "$OUT3"
expect_all_lines_fit "17: unknown feed kind — every line fits the budget"          "$OUT4"
expect_all_lines_fit "18: git feed, missing manifest, long path — every line fits" "$OUT5"

# THE EXEMPTION IS LOAD-BEARING, and this is the arm that says so. These
# fixtures have no bionic entry in installed_plugins.json, so doctor calls the
# machine half-uninstalled and prints the teardown command — over the budget, on
# purpose, and the only thing above it. Delete the exemption and 14/15/17 go
# red; delete the reason for it and this arm does.
# A HALF-UNINSTALLED MACHINE: no bionic entry in the registry (registered=no)
# and a legacy footprint in the rc (`detect_env_todo_tools`), which is the
# disjunction detect_half_uninstalled asks for. Only that machine prints the
# teardown command.
HALF_RC="${TMP}/${LONGSEG}/half.zshrc"
{
  echo '# ─── bionic:rc:start ───'
  echo 'claude() { command claude --allow-dangerously-skip-permissions "$@"; }'
  echo '# ─── bionic:rc:end ───'
  echo 'export CLAUDE_CODE_ENABLE_TODO_TOOLS=1'
} > "$HALF_RC"
HOME6="$(make_registry_home)"
write_empty_known_marketplaces "$HOME6"
OUT6="$(run_doctor "$HOME6" "$HALF_RC")"
OVER6="$(over_budget_lines "$OUT6")"

expect_match "20: the half-uninstalled fixture prints the teardown command" \
  "*curl -fsSL *remove.sh | bash*" "$OUT6"
# COUNTED, not pattern-matched against the whole blob: "every over-budget line
# is that command" is only asserted if the number of them is asserted too — a
# glob with a leading `*` would happily skip past a second offending line.
OVER6_N="$(printf '%s\n' "$OVER6" | awk 'NF { n++ } END { print n + 0 }')"
expect_eq "21: exactly one line on that machine is over the budget" "1" "$OVER6_N"
expect_match "22: and it is that paste-verbatim command" \
  "$REMOVE_CMD_LINE" "$OVER6"
expect_all_lines_fit "23: half-uninstalled — every other line still fits" "$OUT6"

# The rc row is the other line the walk found over the budget (101 columns on a
# short $HOME). The fixture rc path is far longer than that, so this proves the
# row is elided rather than merely short.
RC_ROW="$(printf '%s\n' "$OUT1" | awk '/claude\(\) shell proxy/')"
expect_match "24: the proxy row's rc path was elided to fit" "*…*" "$RC_ROW"
# AND THE HALF THAT SURVIVED IS THE HALF THAT MATTERS. Truncation takes the end
# of a string; a row that elided its own closing sentence would state a fact and
# withhold what to do about it. The path gives way, the sentence does not.
expect_match "25: and the sentence after the path survived the cut whole" \
  "* — new shells pick it up" "$RC_ROW"

section "Section 6: a version that is not version-shaped is not printed"

# WHAT THIS SECTION OWNS. `latest` is the one field on the version row that
# comes out of a file bionic does not write — the marketplace clone's
# plugin.json — and it is printed verbatim into the row, the FIX section, and
# from there into a relayed block a person pastes from. detect.sh's fact line is
# `key=value` separated by spaces and every reader splits on that, so a version
# carrying a space or a newline fabricates a second fact line without anyone
# intending harm. Same trust domain as the install, so this is grammar
# hardening, not a threat model (Step-6 security review, §S).
#
# THE POSITIVE IS SECTION 2, on this same fixture builder: a well-formed 9.9.9
# reaches the row and the fix line whole. This section is its twin — the same
# builder, a crafted value, and nothing of it on the page.

# A NEWLINE AND NO SPACES, which is what makes this fixture discriminate. The
# fact line's readers cut a field at the first space (`${LATEST_LATEST%% *}`),
# so a value carrying spaces is merely mangled — bad enough, it still fabricates
# "9.9.9 available" out of a manifest that says no such thing, and assertions 26
# and 28 catch that. A space-free value survives that cut intact and carries its
# own LINE onto a page whose every other line is a fact bionic vouched for.
CRAFTED='9.9.9
✗dep-sudo-fabricated-by-a-crafted-version'
CLONE7="$(make_git_marketplace_clone "$CRAFTED")"
HOME7="$(make_registry_home)"
write_known_marketplaces "$HOME7" '{"source":"github","repo":"example/bionic"}' "$CLONE7"

OUT7="$(run_doctor "$HOME7")"
ROW7="$(version_row "$OUT7")"

# The cause is asserted by its opening, not whole: this row is subject to the
# same column budget as every other, and the sentence is long enough to be
# elided on a narrow prefix. What must be there is that it says unknown and
# says why.
expect_match "26: a malformed version reads unknown with a stated cause" \
  "*version*unknown — the marketplace's plugin.json version is not*" "$ROW7"
expect_no_match "27: the line the value tried to fabricate never reaches the page" \
  "*✗dep-sudo-fabricated*" "$OUT7"
expect_no_match "28: and it never becomes a fix line" \
  "*claude plugin update bionic@bionic*" "$OUT7"
expect_all_lines_fit "29: the malformed-version page still fits the budget" "$OUT7"

# A version-SHAPED token is still accepted — the guard rejects by shape, not by
# novelty, and a prerelease tag must keep working.
CLONE8="$(make_git_marketplace_clone "9.9.9-rc.1")"
HOME8="$(make_registry_home)"
write_known_marketplaces "$HOME8" '{"source":"github","repo":"example/bionic"}' "$CLONE8"
ROW8="$(version_row "$(run_doctor "$HOME8")")"
expect_match "30: a dotted/dashed prerelease version is still reported" \
  "*9.9.9-rc.1 available*" "$ROW8"

section "Section 8: feed kind is keyed on the installed plugin's own marketplace name (AC-18, L-DETECT/4.1)"

# THE DEFECT. detect_marketplace_feed_kind used to key known_marketplaces.json
# on the LITERAL string "bionic" — so a machine that registered bionic's feed
# under any other marketplace name (a fork, e.g. `bionic@my-fork`) found no
# entry at all and read `unknown` forever, even though the registry has every
# fact needed to answer correctly. The fix reads the marketplace name FROM
# installed_plugins.json's own `bionic@<name>` key rather than assuming it.
#
# A DIRECTORY-SOURCE FIXTURE UNDER THE NAME "my-fork", never "bionic" anywhere
# in either registry file. Before the fix this reads `unknown` (no `.bionic`
# key in known_marketplaces.json); after, it reads as a directory feed and the
# version row shows the same reconverge integration as Section 3's `bionic`-
# named fixture.
HOME9="$(make_registry_home)"
jq -nc --argjson src '{"source":"directory","path":"'"$REPO"'"}' --arg loc "$REPO" \
  '{"my-fork":{source:$src, installLocation:$loc, lastUpdated:"2026-08-27T00:00:00Z"}}' \
  > "$HOME9/plugins/known_marketplaces.json"
jq -nc --arg path "$REPO" --arg sha "$REPO_HEAD" \
  '{plugins:{"bionic@my-fork":[{installPath:$path, gitCommitSha:$sha}]}}' \
  > "$HOME9/plugins/installed_plugins.json"

OUT9="$(run_doctor "$HOME9")"
ROW9="$(version_row "$OUT9")"

expect_match "32: a bionic@my-fork registry still reads as a directory feed, not unknown" \
  "*✓ version*${REAL_VERSION}*tree matches the registered cache*" "$ROW9"
expect_no_match "33: no marketplace-latest language leaks in for the fork's feed" \
  "*available*claude plugin update*" "$ROW9"

section "Section 9: the version row reads the registry installPath, never the cwd (AC-20)"

# THE DEFECT (handoff 4.3). doctor called `detect_registry_sha_lag` with NO
# argument, and that function defaults its repo directory to `$PWD` — so the
# commit in doctor's own header, and the whole directory-feed version row, were
# facts about WHEREVER THE USER HAPPENED TO BE STANDING rather than about the
# plugin tree the CLI is running. Run from an unrelated repository, doctor
# compared the registry's recorded sha against that repository's HEAD and
# reported `not-in-repo` about a build it had never been asked about.
#
# THE FIX IS THE REGISTRY'S OWN ANSWER. `installPath` is where the CLI recorded
# the install; that directory is what the sha is compared against, and the cwd
# is not consulted at all. The proof is a differential: the SAME registry, read
# from two different working directories, must produce the same row.

UNRELATED="${TMP}/unrelated-repo"
mkdir -p "$UNRELATED"
( cd "$UNRELATED" && git init -q . && git -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "an unrelated history" ) >/dev/null 2>&1

# A directory feed whose installPath is THIS repo, exactly as Section 3 built it.
HOME10="$(make_registry_home)"
write_known_marketplaces "$HOME10" '{"source":"directory","path":"'"$REPO"'"}' "$REPO"
write_installed_plugins_sha "$HOME10" "$REPO" "$REPO_HEAD"

# The same run, from the unrelated repository. `run_doctor` cd's to $REPO, so
# this case spells its own cd — that is the variable under test.
OUT10="$( cd "$UNRELATED" && HOME="$TMP" BIONIC_SHELL_RC="$FIXTURE_RC" \
    BIONIC_CLAUDE_HOME="$HOME10" BIONIC_PLUGIN_ROOT="$PAYLOAD" BIONIC_DOCTOR_PROBE_SECONDS=3 \
    bash "$DOCTOR_SH" < /dev/null 2>&1 )"
ROW10="$(version_row "$OUT10")"

expect_match "34: from an unrelated cwd the row still reads the plugin tree" \
  "*✓ version*${REAL_VERSION}*tree matches the registered cache*" "$ROW10"
expect_no_match "35: the unrelated repository's history never reaches the row" \
  "*registered build not in this tree*" "$ROW10"

# And the header's commit is the plugin tree's, not the unrelated repo's.
REPO_HEAD8="$(printf '%.8s' "$REPO_HEAD")"
UNREL_HEAD8="$( cd "$UNRELATED" && git rev-parse HEAD 2>/dev/null | cut -c1-8 )"
expect_match "36: the header names the plugin tree's commit" "*@ ${REPO_HEAD8}*" "$OUT10"

# THE CANDIDATE THAT IS A REPOSITORY IS THE ONE ASKED. On a directory feed the
# CLI records the CACHE as installPath and then reads the source tree instead, so
# a registry answer with no git history behind it must fall through to the plugin
# root rather than settle for `unknown` — measured on this machine, where the
# registry's installPath is the 1.3.2 cache directory. The fallback is still a
# registry-derived path and still never the cwd, which is what §9 is about.
NOREPO="${TMP}/registry-names-a-non-repo"
mkdir -p "$NOREPO"
HOME12="$(make_registry_home)"
write_known_marketplaces "$HOME12" '{"source":"directory","path":"'"$REPO"'"}' "$REPO"
write_installed_plugins_sha "$HOME12" "$NOREPO" "$REPO_HEAD"

OUT12="$( cd "$UNRELATED" && HOME="$TMP" BIONIC_SHELL_RC="$FIXTURE_RC" \
    BIONIC_CLAUDE_HOME="$HOME12" BIONIC_PLUGIN_ROOT="$PAYLOAD" BIONIC_DOCTOR_PROBE_SECONDS=3 \
    bash "$DOCTOR_SH" < /dev/null 2>&1 )"
ROW12="$(version_row "$OUT12")"

expect_match "37b: a registry path with no history falls through to the plugin root" \
  "*✓ version*${REAL_VERSION}*tree matches the registered cache*" "$ROW12"
expect_no_match "37c: and still never reaches the cwd's history" \
  "*registered build not in this tree*" "$ROW12"
if [ -n "$UNREL_HEAD8" ]; then
  expect_no_match "37: the header never names the cwd's commit" "*@ ${UNREL_HEAD8}*" "$OUT10"
else
  no "37: the unrelated fixture repo has no HEAD to compare against"
fi

section "Section 10: a git feed whose installed build is AHEAD of the marketplace (AC-19)"

# `version_compare` (L-DETECT/4.2) gave detect_plugin_latest a real `ahead`
# state; before it, a string inequality lumped ahead in with lag and doctor
# printed "N available" plus an update command for a machine that was NEWER
# than the copy it would have been updated to. The row must now say so, and
# must not name a repair for a state that has none.
CLONE11="$(make_git_marketplace_clone "0.0.1")"
HOME11="$(make_registry_home)"
write_known_marketplaces "$HOME11" '{"source":"github","repo":"example/bionic"}' "$CLONE11"

OUT11="$(run_doctor "$HOME11")"
ROW11="$(version_row "$OUT11")"

expect_match "38: an ahead install is stated as newer than the marketplace copy" \
  "*version*${REAL_VERSION}*newer than the marketplace copy*" "$ROW11"
expect_match "39: and says there is nothing to do" "*no action*" "$ROW11"
expect_no_match "40: no update command rides an ahead row" \
  "*claude plugin update*" "$ROW11"
expect_no_match "41: an ahead install raises no verdict line" \
  "*claude plugin update bionic@bionic*" "$OUT11"
expect_no_match "42: an ahead install is not marked broken" "*✗ version*" "$ROW11"


section "Section 12: the claude CLI absent, and present, on one fixture (AC-7)"

# THE PAIR IS THE POINT, AND IT IS THE STATE THAT USED TO BREAK THIS SUITE.
# `claude` is the one program on the fixture's PATH whose presence changes what
# this page says: the four `mcp-server` rows are checked with `claude mcp get`,
# so with the CLI gone they turn from a plain absence into an UNKNOWN with a
# cause, and one of the fix lines that renders from that cause measured 105
# columns. Before the tool directory above, which half a run got was whatever
# the runner's PATH happened to hold. Now the fixture says, and both halves are
# asserted here — the absent render, and the present one that proves the absent
# assertion is not matching everything.
OUT_NOCLI="$(run_doctor_no_claude "$HOME1")"
OUT_WITHCLI="$(run_doctor "$HOME1")"

expect_match "43: with the CLI off PATH, an MCP row names that as the cause"   "*chrome-devtools*the claude CLI is not on PATH*" "$OUT_NOCLI"
expect_no_match "44: …and with the CLI present that cause is nowhere on the page"   "*the claude CLI is not on PATH*" "$OUT_WITHCLI"
expect_match "45: …which answers the same row from the CLI instead (the pair is not vacuous)"   "*chrome-devtools*not installed*" "$OUT_WITHCLI"
expect_all_lines_fit "46: the CLI-absent page still fits the budget" "$OUT_NOCLI"

section "Section 13: the rendered-file integrity manifest doctor reads (wave-02 AC-8)"

# WHAT CHANGED AND WHY IT NEEDS A TEST AT ALL. detect_agent_integrity() has shipped since
# epic-17 W4 and, until now, NO suite exercised it: the manifest it reads was written by
# agents-src/render.sh and named by exactly one other file, and a rename of either would
# have been silent. Wave-02 S2a renames it (integrity/agents.sha256 ->
# integrity/rendered.sha256) and widens it from the six role files to every rendered
# plugin file, so the fact function's contract — stock / modified / unknown, with the
# modified files NAMED — is pinned here where doctor's own rows live.
#
# DRIVEN THROUGH THE SEAM detect.sh ALREADY OFFERS. BIONIC_PLUGIN_ROOT points the fact
# function at a fixture root built from the repo's own rendered files, so this asserts
# against the SHIPPED manifest rather than a hand-typed one. Sourced in a child /bin/bash
# so the fixture root never leaks into the rest of this suite.

DETECT_LIB="${PAYLOAD}/scripts/lib/detect.sh"
RENDERED_MANIFEST="${PAYLOAD}/integrity/rendered.sha256"

expect_true "47: the payload ships payload/integrity/rendered.sha256" test -f "$RENDERED_MANIFEST"
expect_false "48: …and no longer ships the old integrity/agents.sha256" \
  test -f "${PAYLOAD}/integrity/agents.sha256"

# make_plugin_root -> a plugin root laid out the way an INSTALLED payload is: the manifest
# beside agents/, commands/ and skills/, each at the plugin-root-relative path the manifest
# names (the repo reaches those through payload/agents and payload/skills/* symlinks).
make_plugin_root() {
  local dir; dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/integrity" "$dir/agents" "$dir/commands" "$dir/skills/canonical-sdlc"
  cp "$RENDERED_MANIFEST" "$dir/integrity/" || return 1
  cp "${REPO}"/agents/*.md "$dir/agents/" || return 1
  cp "${REPO}"/payload/commands/*.md "$dir/commands/" || return 1
  cp "${REPO}/skills/canonical-sdlc/SKILL.md" "$dir/skills/canonical-sdlc/" || return 1
  printf '%s' "$dir"
}

# integrity_line <plugin-root> -> detect_agent_integrity's one line
integrity_line() {
  BIONIC_PLUGIN_ROOT="$1" /bin/bash -c '. "$0"; detect_agent_integrity' "$DETECT_LIB" 2>/dev/null
}

PROOT_STOCK="$(make_plugin_root)"
LINE_STOCK="$(integrity_line "$PROOT_STOCK")"
expect_match "49: an untouched install reads as stock" "*state=stock*" "$LINE_STOCK"
expect_match "50: …over all eleven rendered files, not just the six roles" "*total=11*" "$LINE_STOCK"
expect_match "51: …with nothing named as modified" "*modified=0 names=-*" "$LINE_STOCK"

# THE DEFECT CONTROL. `stock` above is worth nothing unless the same reader turns on a
# real edit — and the role files are the case the line was written for.
PROOT_ROLE="$(make_plugin_root)"
printf '\nlocally added line\n' >> "$PROOT_ROLE/agents/critic.md"
LINE_ROLE="$(integrity_line "$PROOT_ROLE")"
expect_match "52: one doctored ROLE file reads as modified" "*state=modified*" "$LINE_ROLE"
expect_match "53: …and is named" "*names=critic.md*" "$LINE_ROLE"

# THE WIDENING ITSELF: before this slice a doctored skill file or command page was
# invisible to this line, because the manifest had no row for either.
PROOT_SKILL="$(make_plugin_root)"
printf '\nlocally added line\n' >> "$PROOT_SKILL/skills/canonical-sdlc/SKILL.md"
LINE_SKILL="$(integrity_line "$PROOT_SKILL")"
expect_match "54: a doctored SKILL.md reads as modified" "*state=modified*" "$LINE_SKILL"
expect_match "55: …and is named" "*names=SKILL.md*" "$LINE_SKILL"

PROOT_CMD="$(make_plugin_root)"
printf '\nlocally added line\n' >> "$PROOT_CMD/commands/help.md"
LINE_CMD="$(integrity_line "$PROOT_CMD")"
expect_match "56: a doctored command page reads as modified" "*state=modified*" "$LINE_CMD"
expect_match "57: …and is named" "*names=help.md*" "$LINE_CMD"

# THE THIRD VALUE. A payload with no manifest answers `unknown` with the cause naming the
# path it looked for — which is how a rename that missed detect.sh would show itself.
PROOT_NONE="$(make_plugin_root)"
rm -f "$PROOT_NONE/integrity/rendered.sha256"
LINE_NONE="$(integrity_line "$PROOT_NONE")"
expect_match "58: a payload with no manifest answers unknown" "*state=unknown*" "$LINE_NONE"
expect_match "59: …naming integrity/rendered.sha256 as what it looked for" \
  "*integrity/rendered.sha256*" "$LINE_NONE"

finish
