#!/bin/bash
# deps.sh — the dependency SSoT (epic-17 wave-03, spec AC-8).
#
# WHAT THIS FILE OWNS. The set of things bionic depends on, and everything that
# is true of a dependency *by declaration*: its class, the route that consumes
# it, where it comes from, what version range it must satisfy, how it is
# installed, and what happens to it when bionic is removed. One row per
# dependency. Nothing else in the repo may author that set — `plugin.json`'s
# `dependencies` array renders the `core` rows and `marketplace.json`'s
# url-sourced entries render the native rows BIONIC'S OWN CATALOG SERVES, both
# pinned by agreement tests that fail on drift. (The second half of that
# sentence narrowed at epic-18 T4: marketplace.json is bionic's catalog, and
# `document-skills`/`example-skills` are native rows another catalog serves —
# an entry for them here would be bionic declaring it serves somebody else's
# plugin. See `dep_marketplace` below.)
#
# WHAT IT DOES NOT OWN. Machine facts. "Is superpowers installed on THIS box"
# is a question about a machine, not about the dependency set; `detect.sh` owns
# every such question and renders the fact lines. The one function here that
# touches a machine, `check_dep`, exists because the probe for a dependency is
# a property of the dependency's mechanism — it returns raw fields and does no
# formatting, and `detect.sh`'s `detect_dep` is its only formatter. There is no
# second implementation of either half.
#
# THE FOUR CLASSES (wave-06 D-B, ratified 2026-08-20; the when-needed roster
# narrowed 2026-08-22 — see the ruling below). `class` answers WHEN bionic
# installs a tool, which is the question the old two-lane split could not
# express — it named the install MECHANISM and let the moment be implied.
#   core        — the two plugin dependencies the CLI's own mechanism resolves.
#                 bionic declares them; the harness installs them. Nothing else
#                 is ever core.
#   basic       — the substrate every machine needs. Asked once at setup, one
#                 consent each, and never removed by bionic: it ensured them, it
#                 does not own them.
#   when-needed — installed with ONE question the first time a route actually
#                 needs the tool. Setup never asks about these rows.
#   extra       — offered once at setup with a line of why, default No.
#
# DETERMINISM OVER LAZY INSTALL (Chris, 2026-08-22, post-incident). Four rows
# that were `when-needed` are `extra` now: `@playwright/cli`, `chrome-devtools`,
# `playwright-chromium` and `motion`. Lazy install put the FIRST install of a
# route's tool inside the run that needed it — a consent prompt and a package
# download in the middle of the work, on a machine whose readiness nobody could
# state beforehand. Offered at setup, the answer is settled before any route
# depends on it, and `/bionic:doctor` can be read as a claim about what will
# work rather than about what has been reached so far.
#
# WHAT `extra` MEANS AFTER THAT RULING. Mechanically, unchanged: offered once at
# setup, one line of why, default No. What it no longer means is "no route wants
# it" — three of its rows name a real route in `consumer`. So the literal `extra`
# in that column is a class-`extra` row's OPTION, not its obligation. The
# traceability pin used to say so (tests/plugin-lib.test.sh Group 3c; deleted
# at 8582861, epic-18 wave-03, and nothing replaced it).
#
# AND THE JIT ARMS STAY (lib/jit.sh). A row being offered at setup is not a row
# being present: the user may decline it, and a machine may lose it later. Every
# route that uses one of the four still calls `jit_check`/`jit_offer` first —
# that offer is the self-heal now rather than the ordinary first install.
#
# `WHEN-NEEDED` IS NOW EMPTY. `impeccable` and `excalidraw-renderer` were the two
# rows this ruling had left there — Chris's list named four rows and neither of
# these — but commit `41110bd` (2026-08-22) promoted both to `extra` as well:
# zero on-demand rows, so the roster below reflects it.
#
# `kind` is the orthogonal question — HOW a row installs — and it is what
# `install_dep` and `check_dep` dispatch on. `native` means the plugin harness
# does it, and `install_dep` REFUSES every native row whatever its class: a
# second installer for a natively-installed plugin is precisely the kludge D1
# rejected. Every non-native row has exactly one installer, the one below —
# the same function for the setup loop and for a just-in-time offer (AC-5).
#
# CLASS AND KIND ARE NOT THE SAME CUT, and impeccable is the row that proves it:
# it is `extra` (offered once at setup, same as document-skills and
# example-skills) and `native` (the harness installs it, from bionic's own
# marketplace, the same mechanism superpowers and agent-skills use at class
# `core`) — three different classes, one kind. That is why the marketplace
# rendering rule is stated over `kind` and the plugin.json dependency rule over
# `class`.
#
# TRACEABILITY. Every row names its `consumer`: the repo-relative path of the
# doctrine file that uses it, or one of exactly two literals — `substrate` for
# the basics no single route owns, `extra` for the optional offers. A row with
# no consumer is a row nobody can justify, and the wave dropped two of them
# (`yq`, `gcloud`) on exactly that test. tests/plugin-lib.test.sh Group 3c
# used to resolve every path; it was deleted at 8582861 (epic-18 wave-03) and
# nothing replaced the check.
#
# CONSENT. `install_dep` and `remove_dep` are the only mutating entry points,
# and neither mutates before an explicit answer on stdin. No assume-yes knob
# exists: "consent per event, never silent, never unattended" is the ratified
# rule, and an env var that switches it off would be the hole in it.
#
# ROOTS ARE OVERRIDABLE. Every path this file reads comes from a variable with
# a live default, so the hermetic suite can point the whole library at a
# fixture tree without a seam that substitutes the value under test.
#
# Sourced, never executed:  . "${CLAUDE_PLUGIN_ROOT}/scripts/lib/deps.sh"

# ─── Roots ───────────────────────────────────────────────────────────────────
# Read at CALL time, not source time: a caller may source once and probe
# several roots (the suite does exactly that).

# THE CLI's CONFIG DIRECTORY is `claude_home` in lib/roots.sh — one definition for the
# whole tree (epic-22 wave-01, N1). This file carried the third of three byte-identical
# copies of that override chain; lib/worktree.sh and lib/patrol.sh carried the other two,
# and no pin held any of them to each other.
_dep_claude_home()      { claude_home; }
_dep_settings_file()    { echo "${BIONIC_SETTINGS_FILE:-$(_dep_claude_home)/settings.json}"; }
_dep_installed_json()   { echo "${BIONIC_INSTALLED_PLUGINS_FILE:-$(_dep_claude_home)/plugins/installed_plugins.json}"; }

# THE PAYLOAD ROOT, one more root this file reads FROM rather than only writes to
# (epic-18 T1), and `plugin_root` in lib/roots.sh is its one definition. This file and
# lib/detect.sh each carried a byte-identical copy of the same three-step resolution — the
# note here used to explain the duplication by saying each file is sourced on its own by
# something, so none may assume a sibling came first. That is still true, and the soft
# source below is what makes it survivable without a second copy (epic-22 wave-01, N1). No
# `dirname`/`basename` in the self-locator either — it has to survive the half-broken
# machine it is most needed on.
_dep_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}
if ! declare -F plugin_root >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_dep_self_dir)" && pwd -P)/roots.sh"
fi

# ccstatusline ships TWO halves (epic-18-w1 handoff §3.1): the `.statusLine`
# command that RENDERS the line, and the layout file that command reads. The
# source is always the payload's own copy; the target defaults to the bare
# path claude-bootstrap.sh always used, `~/.config/ccstatusline/settings.json`
# — overridable for the same reason every other root here is.
_dep_ccstatusline_config_source() { echo "$(plugin_root)/ccstatusline/settings.json"; }
_dep_ccstatusline_config_target() { echo "${BIONIC_CCSTATUSLINE_CONFIG:-$HOME/.config/ccstatusline/settings.json}"; }
_dep_ccstatusline_config_dir() {
  local t; t="$(_dep_ccstatusline_config_target)"
  echo "${t%/*}"
}

# Byte-identical, the same word AC-1 uses and the same tool
# claude-bootstrap.sh's ccstatusline-config step used (`diff -q`) — not `cmp`,
# so a hermetic suite need not add a second comparison binary to its curated
# PATH beside the one every writer path already needs.
_dep_files_match() { [ -f "${1:-}" ] && [ -f "${2:-}" ] && diff -q "$1" "$2" >/dev/null 2>&1; }

# THE LAYOUT MATCH IGNORES THE SCHEMA VERSION (Chris 2026-09-03: "Why the hell
# is ccstatusline not installing?? I just installed it!"). ccstatusline
# migrates its own settings file in place the first time it renders — 2.2.29
# rewrote bionic's version-3 layout as version 4 and changed nothing else — so
# a byte-identical probe flipped to "not installed" the moment the status line
# drew, and every later setup re-copied the shipped file only for ccstatusline
# to migrate it again. Same layout at a different schema version IS installed.
# Falls back to the byte comparison only where jq is missing, which the
# statusline probe already reports as unknown before it gets here.
_dep_ccstatusline_layout_match() {  # <shipped> <installed>
  local a b
  [ -f "${1:-}" ] && [ -f "${2:-}" ] || return 1
  _dep_have jq || { diff -q "$1" "$2" >/dev/null 2>&1; return; }
  a="$(jq -S 'del(.version)' "$1" 2>/dev/null)" || return 1
  b="$(jq -S 'del(.version)' "$2" 2>/dev/null)" || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# The catalogs this machine has registered. Read-only here, and read for exactly
# one question: does an install from a foreign catalog need a `marketplace add`
# in front of it (see `install_plugin_native`).
_dep_known_marketplaces() { echo "${BIONIC_KNOWN_MARKETPLACES_FILE:-$(_dep_claude_home)/plugins/known_marketplaces.json}"; }
# Where the CLI reads loose skills from — the destination of a `github-skill`
# row. Derived from the claude home rather than given its own override, so a
# suite that re-points the home moves this with it and nothing else has to know.
_dep_skills_dir()       { echo "$(_dep_claude_home)/skills"; }
_dep_playwright_cache() {
  if [ -n "${BIONIC_PLAYWRIGHT_CACHE:-}" ]; then echo "$BIONIC_PLAYWRIGHT_CACHE"; return; fi
  case "$(uname -s 2>/dev/null || echo Darwin)" in
    Linux) echo "$HOME/.cache/ms-playwright" ;;
    *)     echo "$HOME/Library/Caches/ms-playwright" ;;
  esac
}

# The excalidraw skill's uv project, which lives INSIDE the plugin now (epic-18 T3, AC-6) —
# so the directory `uv sync` writes its `.venv` into is plugin-root-relative, not
# claude-home-relative. Empty when neither root is set, and that emptiness is deliberate: the
# probe below turns it into `unknown` with a named cause rather than into a confident `no`
# about a project directory nobody could locate. Same rule `_dep_check_pnpm_store` follows.
_dep_excalidraw_refs() {
  if [ -n "${BIONIC_EXCALIDRAW_REFS:-}" ]; then echo "$BIONIC_EXCALIDRAW_REFS"; return; fi
  # Self-locating like every other root here (Chris 2026-08-22: doctor reported
  # "no presence surface" for a directory that was sitting in the plugin).
  local root; root="$(plugin_root)"
  [ -n "$root" ] || { echo ""; return; }
  echo "${root}/skills/excalidraw-diagram/references"
}

# THE VENV'S OWN STABLE PATH (VENV slice, spec AC-17). `_dep_excalidraw_refs`
# above names the SOURCE tree `uv sync --project` reads `pyproject.toml` and
# `uv.lock` from, and that tree is plugin-root-relative — it moves to a new,
# version-numbered directory every time bionic updates. Before AC-17 the venv
# `uv sync` built lived INSIDE that moving tree (`<refs>/.venv`), so an
# in-place plugin upgrade orphaned a perfectly good venv and forced a re-sync
# question on every single update. This path never moves: it is anchored to
# `$HOME` (via the XDG data dir), not to whichever plugin-version directory
# happens to be current, so an upgrade leaves a live renderer behind it.
_dep_excalidraw_venv_dir() {
  echo "${XDG_DATA_HOME:-$HOME/.local/share}/bionic/excalidraw-venv"
}

# The hash of the `uv.lock` this venv was synced against, written BESIDE the
# venv directory — a SIBLING file, never nested inside it. `uv sync` owns
# everything under the venv path and may rebuild it; a marker planted inside
# would not be guaranteed to survive that, so it lives next to it instead.
_dep_excalidraw_lock_hash_file() { echo "$(_dep_excalidraw_venv_dir).lock.sha256"; }

# A minimal sha256, in the same tool-fallback order `detect.sh`'s own
# `_detect_sha256` uses (macOS ships `shasum`, not `sha256sum`) — duplicated
# here rather than sourced, because deps.sh does not otherwise depend on
# detect.sh and one three-line probe is not worth introducing that edge for.
# Empty output, never a nonzero exit read as a hash, when neither tool is on
# PATH: a hash comparison against "" can only ever mismatch, which is the
# same honest "cannot confirm it's current" a probe gives for any other
# unreadable fact, never a false "yes" and never a crash.
_dep_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# ─── The settings values bionic offers ───────────────────────────────────────
#
# THE DEFAULT PERMISSION MODE, OWNED HERE BECAUSE TWO SCRIPTS MUST AGREE ON IT
# (six-axis review D-1). setup.sh offers to write it; remove.sh offers to reset
# it, and that offer is DEFINED as "the one value bionic knows it wrote" — it
# leaves any other value alone, because any other value is somebody else's
# choice. So the two are one decision, and they used to be two bare literals
# with nothing making them agree: a setup that started writing `acceptEdits`
# would have left both suites green while the teardown quietly stopped matching
# and the setting stayed behind on every machine.
#
# It is a plain variable rather than a function because remove.sh's standalone
# door has to be able to fall back to a copy of it — see the shared literals in
# that file. tests/remove.test.sh Group 19 used to arm the agreement between
# them; it was deleted at 8582861 and nothing replaced it.
BIONIC_DEFAULT_PERMISSION_MODE="auto"

# THE ONE SENTENCE ABOUT `.permissions.defaultMode` (epic-17 wave-07 item 1 +
# O-3; rehomed here at epic-18 T13 when profile.sh was deleted). A Remote
# Control session offers its own Manual / Accept edits / Plan only choice and
# that choice wins over whatever this machine's settings file says — so anywhere
# the default mode is shown or asked about has to say so on the same screen, or
# the setting reads as a stronger promise than it is. One literal, beside the
# value it is about, so the sentence and the mode can never drift apart.
BIONIC_PERMISSION_MODE_RC_NOTE='Remote Control sessions override this (Manual / Accept edits / Plan only).'

# ─── The table ───────────────────────────────────────────────────────────────
#
# FIELDS, in order:
#   name                  the probe identity — what `check_dep`/`dep_field` key on,
#                         and what doctor prints. For a binary that is the command
#                         name (`rg`), for a package-shaped dep the package
#                         (`@playwright/cli`), for an MCP server its server name.
#   class                 core | basic | when-needed | extra — WHEN bionic installs it.
#   consumer              the doctrine route that uses it: a repo-relative path
#                         that resolves, or the literal `substrate` / `extra`.
#                         Repo-relative, not payload-relative, because the
#                         traceability claim is about this repository's doctrine
#                         — which is why a route inside the payload spells its
#                         `payload/` prefix here rather than dropping it. Every
#                         route now ships in the payload: excalidraw-diagram was
#                         the last one outside it and moved in at epic-18 T3.
#   mechanism             the install target. `scheme:target` for the package
#                         managers (brew, brew-cask, npm, uv, pnpm, npx);
#                         `github:owner/repo` for a skill cloned into the CLI's
#                         own skills directory; a bare https git URL for a native
#                         row bionic's marketplace serves, whose renderings need
#                         it verbatim; and `marketplace:<catalog>#<repo>` for a
#                         native row somebody else's catalog serves, which names
#                         the catalog the install id needs and the repo spec
#                         `claude plugin marketplace add` takes (see
#                         `dep_marketplace`).
#   constraint            a semver range, or `any` where no range is declared.
#                         `any` is a real declaration — it says the dependency
#                         is unpinned — not a missing value.
#   kind                  HOW it installs. Names the `_dep_check_*` /
#                         `_dep_install_*` pair that knows how to probe and
#                         install this shape. `native` means the harness does it.
#   removal_behavior      native-uninstall-offer | remove-on-consent | keep-shared
#
# THE ONE FIELD THIS TABLE DOES NOT OWN is the commit `sha` on a native-kind
# marketplace entry. It is deliberately not a seventh column: a sha is a
# SUPPLY-CHAIN pin — "the code installed is the code that was reviewed" — and
# `constraint` above is a VERSION claim — "the installed version satisfies this
# range". Different questions, different lifetimes, different owners: the
# constraint is doctor's to judge on every run, the sha is the manifest's to
# state once and change only by review. So marketplace.json is the sha's author
# by written exception. tests/plugin-lib.test.sh Group 18 used to require EVERY
# url-sourced entry to carry one; that suite was deleted at 8582861 (epic-18
# wave-03) and nothing replaced the requirement. Saying nothing here is what let one
# dependency ship pinned and the other tracking a moving branch head.
#
# PROVENANCE. Native rows: the wave-03 ratified D1 values (agent-skills is
# ^0.6.0 — the ^1.0.0 in today's plugin.json is stale and D3 ratified the
# correction), plus impeccable at wave-06 S3, whose `^4.1.0` was verified
# against the upstream tags rather than assumed: `git ls-remote --tags
# https://github.com/pbakaus/impeccable.git` puts skill-v4.1.1 at the top of the
# skill line, and that commit's `.claude-plugin/plugin.json` declares version
# 4.1.1. Everything else: ported from claude-bootstrap.sh, deleted at W5 and the
# authority on what actually got installed — claude-config.txt supplied the
# roster and the `do_install_*` / `verify_*` pairs the commands. Classes are
# D-B's ratified roster, verbatim.

BIONIC_DEP_TABLE="$(cat <<'TABLE'
superpowers|core|skills/canonical-sdlc/SKILL.md|https://github.com/obra/superpowers.git|^6.3.0|native|native-uninstall-offer
agent-skills|core|skills/canonical-sdlc/SKILL.md|https://github.com/addyosmani/agent-skills.git|^0.6.0|native|native-uninstall-offer
git|basic|substrate|brew:git|any|brew-dep|keep-shared
node|basic|substrate|brew:node|any|brew-dep|keep-shared
pnpm|basic|substrate|brew:pnpm|any|brew-dep|keep-shared
gh|basic|substrate|brew:gh|any|brew-dep|keep-shared
jq|basic|substrate|brew:jq|any|brew-dep|keep-shared
rg|basic|substrate|brew:ripgrep|any|brew-dep|keep-shared
uv|basic|substrate|brew:uv|any|brew-dep|keep-shared
docker|basic|substrate|brew:docker|any|brew-dep|keep-shared
aws|basic|substrate|brew:awscli|any|brew-dep|keep-shared
impeccable|extra|skills/canonical-sdlc/SKILL.md|https://github.com/pbakaus/impeccable.git|^4.1.0|native|native-uninstall-offer
excalidraw-renderer|extra|payload/skills/excalidraw-diagram/SKILL.md|uv:sync|any|uv-project|remove-on-consent
@playwright/cli|extra|skills/browser-verify/SKILL.md|npm:@playwright/cli|any|npm-global|remove-on-consent
chrome-devtools|extra|skills/browser-verify/SKILL.md|npm:chrome-devtools-mcp@latest|any|mcp-server|remove-on-consent
playwright-chromium|extra|payload/skills/excalidraw-diagram/SKILL.md|npx:playwright@latest|any|playwright-browser|remove-on-consent
motion|extra|extra|pnpm:motion|any|pnpm-store|remove-on-consent
ccstatusline|extra|extra|npm:ccstatusline|any|statusline|remove-on-consent
notebooklm|extra|extra|uv:notebooklm-py|any|uv-tool|remove-on-consent
context7|extra|extra|npm:@upstash/context7-mcp@latest|any|mcp-server|remove-on-consent
@pencil.dev/cli|extra|extra|npm:@pencil.dev/cli|any|npm-global|remove-on-consent
humanizer|extra|extra|github:blader/humanizer|any|github-skill|remove-on-consent
document-skills|extra|extra|marketplace:anthropic-agent-skills#anthropics/skills|any|native|native-uninstall-offer
example-skills|extra|extra|marketplace:anthropic-agent-skills#anthropics/skills|any|native|native-uninstall-offer
TABLE
)"

# The nine brew rows are `keep-shared` deliberately, and that is now what the
# `basic` class MEANS rather than a coincidence of their removal policy: bionic
# ENSURED git/node/docker/... on this machine; it does not own them, and pulling
# `git` off a box because bionic is leaving is not a removal anyone asked for.
# The reset charter names shared binaries as the excluded class.
#
# TWO ROWS LEFT AT WAVE-06 S3. `yq` and `gcloud` had no consumer — no skill, no
# rule, no agent file, no test named either — and neither is universal enough to
# justify as substrate. D-B dropped them by name. They are not commented out
# here: a commented row is a row that comes back without a decision.
#
# `excalidraw-renderer` IS THE ROW THAT USED TO BE A README (epic-18 T3, AC-6). The skill's
# render loop needs two things bionic does not ship: a chromium build, which has been the
# `playwright-chromium` row all along, and a synced uv project, which was a "Renderer setup"
# code block the user was expected to find and paste. That made it the one piece of bionic's
# dependency surface with no probe, no consent prompt and no doctor line — invisible until a
# render failed. It is a row now: absent until a render asks, then ONE consented install. Its
# sibling `playwright-chromium` went to `extra` at the 2026-08-22 ruling and this one did not
# — a chromium build is a machine-wide thing worth having ahead of time; a venv inside this
# plugin's own tree is not.
#
# ITS `mechanism` IS `uv:sync` AND ITS TARGET IS NOT A PACKAGE. Every other row's locator
# names a thing to fetch; this one names an operation on a project directory the plugin
# already carries, and the directory comes from `_dep_excalidraw_refs` rather than from the
# table because it is a machine path, not a declaration. The `uv:` scheme is still the honest
# prefix — `uv` is what runs — and `_dep_locator_target` yields `sync`, which is exactly the
# subcommand the argv below uses.
#
# AND ONE LEFT AT EPIC-18 T4, 2026-08-22 (owner ruling, AC-8). `frontend-design`
# was on the retired installer's roster and does not come back: design work in
# this repo routes to `impeccable` alone, which is a properly-attributed superset
# of it and already has its own `when-needed` row above. The evaluation behind
# that is `.claude/rules/agent-discipline.md` ("Design work routes to impeccable
# only", 2026-04-18), and the same file forbids re-installing frontend-design
# without redoing the research. What is new here is only the RECORD: four other
# rows from that roster (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `humanizer`,
# `document-skills`, `example-skills`) turned out to have been dropped by nobody
# — they were simply not ported, and an unrecorded drop is indistinguishable
# from forgetting. This one was decided.
#
# `motion` WAS THE TABLE'S ONE DECLARED EXEMPTION and the 2026-08-22 ruling closed
# it. The row named `skills/canonical-sdlc/SKILL.md` as its consumer while no file
# in this repo mentioned the package — it is pre-warmed into the pnpm store for the
# design route, and nothing wrote that down — so the traceability pin carried a
# named exemption for exactly one row. Group 3c stated the two ways out: "either
# the design route names it or it is an `extra`". It is an `extra` now, so the
# consumer is the literal, the exemption is gone from the suite, and the row claims
# nothing it cannot show.

# ─── Table access ────────────────────────────────────────────────────────────

dep_names() { printf '%s\n' "$BIONIC_DEP_TABLE" | while IFS='|' read -r n _; do [ -n "$n" ] && echo "$n"; done; }

dep_names_class() {  # <core|basic|when-needed|extra>
  local want="${1:-}"
  printf '%s\n' "$BIONIC_DEP_TABLE" | while IFS='|' read -r n class _; do
    [ -n "$n" ] && [ "$class" = "$want" ] && echo "$n"
  done
  return 0
}

dep_names_kind() {  # <native|brew-dep|npm-global|…>
  local want="${1:-}"
  printf '%s\n' "$BIONIC_DEP_TABLE" | while IFS='|' read -r n _ _ _ _ kind _; do
    [ -n "$n" ] && [ "$kind" = "$want" ] && echo "$n"
  done
  return 0
}

# RETIRED — `dep_names_lane` (wave-06 S10, six-axis review A-1). S3 kept the
# pre-wave-06 lane list as a deprecated view because setup.sh and remove.sh still
# walked it; S4 retired setup's call and remove.sh now walks the CLASSES, so
# nothing enumerates by lane any more. The list was never a stored field — it was
# "class core" and "kind != native" under two old names — and keeping it meant a
# second live taxonomy over one table, which is how the teardown came to be
# computed as `kind != native` and silently miss the one native row outside core.
# tests/plugin-lib.test.sh Group 3b used to pin the removal and state the set
# that replaced it; it was deleted at 8582861 (epic-18 wave-03) and nothing
# replaced the pin. The lane FIELD stays: see `dep_field` below.

dep_row() {  # <name> — the whole row, verbatim. Non-zero if there is no such row.
  local want="${1:-}" line
  while IFS= read -r line; do
    case "$line" in "${want}|"*) echo "$line"; return 0 ;; esac
  done <<< "$BIONIC_DEP_TABLE"
  return 1
}

dep_field() {  # <name> <field>
  local name="${1:-}" field="${2:-}" row
  local f_name f_class f_consumer f_mech f_con f_kind f_rem
  row="$(dep_row "$name")" || { echo "deps.sh: no such dependency: ${name}" >&2; return 1; }
  IFS='|' read -r f_name f_class f_consumer f_mech f_con f_kind f_rem <<< "$row"
  case "$field" in
    name)                printf '%s\n' "$f_name" ;;
    class)               printf '%s\n' "$f_class" ;;
    consumer)            printf '%s\n' "$f_consumer" ;;
    mechanism|source_url)          printf '%s\n' "$f_mech" ;;
    constraint)          printf '%s\n' "$f_con" ;;
    kind|install_fn_or_check)      printf '%s\n' "$f_kind" ;;
    removal_behavior)    printf '%s\n' "$f_rem" ;;
    # DEPRECATED and derived — never a stored column. detect.sh's fact line is
    # its one caller and renders it verbatim; the LIST that used to compute the
    # same rule is retired (see above), so this is now the only place the old
    # taxonomy is spoken at all.
    lane)
      if [ "$f_class" = "core" ]; then printf '3a\n'
      elif [ "$f_kind" != "native" ]; then printf '3b\n'
      else printf 'none\n'; fi ;;
    *) echo "deps.sh: no such field: ${field}" >&2; return 1 ;;
  esac
}

# ─── Which catalog installs a native row ─────────────────────────────────────
#
# THE CATALOG USED TO BE A CONSTANT, and it could be: every native row came from
# bionic's own marketplace, so `install_plugin_native` composed `<name>@bionic`
# and the teardown asked the registry about that id. epic-18 T4 carries two rows
# the CLI installs from `anthropic-agent-skills` (the `anthropics/skills` repo),
# and a constant would have installed them under an id that does not resolve and
# then read the user's own copies as somebody else's.
#
# So the catalog is a property of the ROW, spelled in the mechanism. `kind` stays
# `native` for all of them, deliberately: kind names HOW a row installs — the
# CLI's own plugin install, which `install_dep` must refuse for every one of them
# — and that has not changed. What changed is which catalog answers.
#
# NON-ZERO FOR A ROW NO CATALOG SERVES, rather than a default. Every non-native
# row would otherwise read as "bionic's", and the manifest-agreement pin is
# stated over this function's answer: a brew row silently claiming a catalog is
# how marketplace.json would come to be rendered from rows it cannot serve.
dep_marketplace() {  # <name> -> the catalog the CLI installs this row from
  local name="${1:-}" mech target
  [ "$(dep_field "$name" kind 2>/dev/null)" = "native" ] || return 1
  mech="$(dep_field "$name" mechanism)" || return 1
  case "$mech" in
    marketplace:*) target="${mech#marketplace:}"; printf '%s\n' "${target%%#*}" ;;
    *)             printf '%s\n' "${BIONIC_DEP_MARKETPLACE:-bionic}" ;;
  esac
}

# The repo spec `claude plugin marketplace add` takes, for a row whose catalog is
# not bionic's own. Non-zero for bionic's rows, and that non-zero IS the answer:
# bionic's marketplace is registered by the time any of this runs (the user added
# it to install bionic), so there is nothing to add and no command to print.
dep_marketplace_source() {  # <name>
  local name="${1:-}" mech target
  mech="$(dep_field "$name" mechanism 2>/dev/null)" || return 1
  case "$mech" in
    marketplace:*)
      target="${mech#marketplace:}"
      case "$target" in *#*) printf '%s\n' "${target#*#}" ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# The rows a given catalog serves. bionic's own answer is what marketplace.json
# is rendered from and what tests/plugin-lib.test.sh Group 18 used to pin in
# both directions; that suite was deleted at 8582861 (epic-18 wave-03) and
# nothing replaced the pin.
dep_names_marketplace() {  # <catalog>
  local want="${1:-}" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$(dep_marketplace "$n" 2>/dev/null)" = "$want" ] && echo "$n"
  done <<< "$(dep_names_kind native)"
  return 0
}

# THE ID THE CLI KNOWS BIONIC BY, and the one place it is composed (bionic
# 1.4.4 fixit phase 4, review-b B-7). `<name>@<catalog>` is the key `claude
# plugin list` prints and the argument an install command takes. Three files
# needed it and each spelled the same expansion — this one, doctor.sh's
# `BIONIC_PLUGIN_ID` and setup.sh's `SETUP_PLUGIN_ID` — and the derivation is the
# one thing no suite could see, because nothing in the tree re-pointed the
# catalog: any one of the three could have been edited back to the literal
# `bionic@bionic` and every assertion still passed on its rendered default. A
# machine that re-points the catalog has to move all three together, so they are
# one function now, and doctor-reads §6f renders the report under a re-pointed
# catalog so a copy that stopped moving goes red.
#
# THE ENVIRONMENT WINS OUTRIGHT. `BIONIC_PLUGIN_ID` names the whole id, so a
# machine that sets it is not asked about a catalog at all; `BIONIC_DEP_MARKETPLACE`
# names only the catalog half. Both read with `:-`, so an empty value falls back
# the same way an unset one does.
dep_plugin_id() {  # -> the <name>@<catalog> id this machine knows bionic by
  echo "${BIONIC_PLUGIN_ID:-bionic@${BIONIC_DEP_MARKETPLACE:-bionic}}"
}

# THE REPAIR ROUTE FOR A MISSING CORE DEPENDENCY, and the one place it is
# spelled (bionic 1.4.4 fixit, design "Option 1", Chris 2026-09-05).
#
# WHOSE REPAIR IT IS. A `core` row is not installed by anything in this file:
# the CLI installs superpowers and agent-skills alongside bionic itself, because
# `payload/.claude-plugin/plugin.json` declares them as bionic's dependencies and
# the registry records them with `"auto": true`. D1 already rules that setup
# never installs a native row, so `→ /bionic:setup` on such a row names a command
# that plans nothing for it — the reader runs it, is told "nothing left to do",
# and the ✗ is still there. The party that owns this repair is the CLI, and the
# four surfaces that render the route (doctor's THIRD PARTY table, doctor's
# headline absence line, setup's own absent arm, and setup's load-failure arm —
# the Fix line under the CLI's own error) all defer to it from here.
#
# WHY THE RE-RUN AND NOT `claude plugin install <dep>@bionic`. Measured, CLI
# 2.1.261, record/epic-21-v1-ladder/fixit-dep-repair-measurement.md: re-running
# bionic's own install re-resolves EVERY declared dependency at once and
# re-registers the restored one as bionic's (`"auto": true`), leaving the
# registry byte-shaped like a clean install — which is what /bionic:remove's
# teardown reads. Installing the dependency directly also repairs the machine but
# registers it as a user-owned plugin, and `claude plugin update` does not repair
# at all ("already at the latest version", nothing written).
#
# THE ID IS DERIVED, NEVER SPELLED, and it is `dep_plugin_id` above that derives
# it — for this route, for doctor's `BIONIC_PLUGIN_ID` and for setup's
# `SETUP_PLUGIN_ID` alike. This function used to expand the same fallback pair
# inline and claim it matched setup's "character for character"; it matched
# semantically and not textually (review-a A-3), which is the kind of claim that
# stops being true without anything looking edited. One owner, so there is
# nothing left to compare.
dep_core_repair_route() {  # -> the command that re-resolves bionic's declared dependencies
  echo "claude plugin install $(dep_plugin_id)"
}

# Reports any row whose field count is not exactly 7. Silence means the table
# is well-formed; the suite asserts on the silence.
dep_table_field_count_report() {
  local line n
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="$(printf '%s' "$line" | tr -cd '|' | wc -c | tr -d ' ')"
    [ "$n" = "6" ] || echo "${line} (has $((n + 1)) fields, want 7)"
  done <<< "$BIONIC_DEP_TABLE"
  return 0
}

# ─── Version comparison ──────────────────────────────────────────────────────
#
# Enough semver to judge the ranges the table actually declares. Deliberately
# NOT a general semver implementation: a range shape this does not recognise
# returns `unknown` rather than guessing, which keeps an unparsed constraint
# visible in doctor's output instead of silently reading as satisfied.

_dep_semver_cmp() {  # <a> <b> -> echoes -1 | 0 | 1  (prerelease tags ignored)
  local a="${1%%-*}" b="${2%%-*}" i av bv
  local -a A B
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  for i in 0 1 2; do
    av="${A[i]:-0}"; bv="${B[i]:-0}"
    av="${av//[!0-9]/}"; bv="${bv//[!0-9]/}"
    av="${av:-0}"; bv="${bv:-0}"
    if [ "$av" -lt "$bv" ]; then echo -1; return 0; fi
    if [ "$av" -gt "$bv" ]; then echo 1; return 0; fi
  done
  echo 0
}

_dep_is_semver() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([-+].*)?$ ]]; }

dep_constraint_verdict() {  # <constraint> <version> -> ok | violation | unknown
  local c="${1:-}" v="${2:-}" base cmp upper
  # `any` is decided first, and deliberately: it declares that no range is
  # pinned, so it cannot be violated by any version — including one this
  # machine could not read. Making an unreadable version outrank it would
  # have doctor flag an unpinned dependency that is in fact fine.
  [ "$c" = "any" ] && { echo ok; return 0; }
  { [ -z "$v" ] || [ "$v" = "unknown" ]; } && { echo unknown; return 0; }
  _dep_is_semver "$v" || { echo unknown; return 0; }

  case "$c" in
    '^'*)
      base="${c#^}"; _dep_is_semver "$base" || { echo unknown; return 0; }
      [ "$(_dep_semver_cmp "$v" "$base")" = "-1" ] && { echo violation; return 0; }
      # npm's caret: the leftmost NON-ZERO component is what stays fixed, so
      # ^0.6.0 admits 0.6.x only. agent-skills is a 0.x dep — this branch is
      # its everyday case, not a corner.
      # One `local` per line on purpose: a later assignment in a chained
      # `local a=.. b=$a` does NOT see the earlier one.
      local maj min rest
      maj="${base%%.*}"; rest="${base#*.}"; min="${rest%%.*}"
      if [ "${maj//[!0-9]/}" = "0" ]; then upper="0.$((${min//[!0-9]/} + 1)).0"
      else upper="$((${maj//[!0-9]/} + 1)).0.0"; fi
      [ "$(_dep_semver_cmp "$v" "$upper")" = "-1" ] && echo ok || echo violation
      ;;
    '~'*)
      base="${c#\~}"; _dep_is_semver "$base" || { echo unknown; return 0; }
      [ "$(_dep_semver_cmp "$v" "$base")" = "-1" ] && { echo violation; return 0; }
      local tmaj tmin trest
      tmaj="${base%%.*}"; trest="${base#*.}"; tmin="${trest%%.*}"
      upper="${tmaj}.$((${tmin//[!0-9]/} + 1)).0"
      [ "$(_dep_semver_cmp "$v" "$upper")" = "-1" ] && echo ok || echo violation
      ;;
    '>='*)
      base="${c#>=}"; _dep_is_semver "$base" || { echo unknown; return 0; }
      cmp="$(_dep_semver_cmp "$v" "$base")"
      [ "$cmp" = "-1" ] && echo violation || echo ok
      ;;
    *)
      if _dep_is_semver "$c"; then
        [ "$(_dep_semver_cmp "$v" "$c")" = "0" ] && echo ok || echo violation
      else
        echo unknown
      fi
      ;;
  esac
  return 0
}

# ─── Locator helpers ─────────────────────────────────────────────────────────

_dep_locator_target() {  # brew:ripgrep -> ripgrep ; https://... -> unchanged
  local loc="${1:-}"
  case "$loc" in
    http://*|https://*) printf '%s\n' "$loc" ;;
    *:*)                printf '%s\n' "${loc#*:}" ;;
    *)                  printf '%s\n' "$loc" ;;
  esac
}

# THE PACKAGE WITHOUT ITS PIN. An npm locator target is a package name that may
# carry `@version`, and the two are not interchangeable: `npm install -g` takes
# the pinned form, while anything that has to be EXECUTED — the status line's
# recorded command — takes the bare name. Writing the pinned form where an
# executable was meant is a defect the reviewers caught latent rather than live
# (review-a C-3): the locator is unpinned today, so `ccstatusline@2.2.29` only
# reaches settings.json the moment someone adopts the pin the docblock below
# holds in reserve, and the failure then is a status line that silently renders
# nothing. A leading `@` is a SCOPE, not a version, so it survives: the split is
# on the first `@` after the first character.
_dep_pkg_unversioned() {  # ccstatusline@2.2.29 -> ccstatusline ; @scope/x@1 -> @scope/x
  local pkg="${1:-}" lead="" rest="${1:-}"
  case "$pkg" in @*) lead="@"; rest="${pkg#@}" ;; esac
  printf '%s%s\n' "$lead" "${rest%%@*}"
}

# ─── The name-list removal loop, once ────────────────────────────────────────
#
# ONE SPLIT, ONE GLOB GUARD, ONE LOOP (epic-21 1.4.4 T7, review-d D-2). Four
# call sites — setup's two legacy items, remove's two twins — fed the same
# comma-separated, PAYLOAD-DERIVED name list through this exact shape: split on
# comma into positional parameters, guard `[ -f ]`, `rm -f`, count. Two of the
# four wrapped the split in `set -f`; two did not, and an unquoted
# `set -- $names` is a pathname expansion the instant a file in the CALLER's
# $PWD happens to match one of the names — demonstrated: a payload shipping a
# hook literally named `n*.sh` beside the machine owner's own file, with a
# decoy in $PWD matching that glob, deleted the owner's file and left the
# payload's own leftover in place, the exact inversion both detectors this
# feeds exist to prevent. The guard now lives once, here, so all four call
# sites are consistent by construction instead of by four authors remembering.
_dep_rm_named_files() {  # <dir> <comma-separated-names> -> echoes the count actually removed
  local dir="${1:-}" names="${2:-}" name removed=0 ifs_save noglob_was_on=no
  ifs_save="$IFS"
  # review-e E-3: restore to the CALLER's prior state, not unconditionally to
  # off. Every call site today reads this back through a command substitution,
  # so an unconditional `set +f` has never been observable — but this is now a
  # public library function any future caller can invoke directly, and the
  # instant one does without a subshell between it and its own `set -f`, an
  # unconditional restore would turn its globbing back on behind its back.
  case $- in *f*) noglob_was_on=yes ;; esac
  set -f
  IFS=','
  # shellcheck disable=SC2086  # the split IS the point, on a list this script's own library built
  set -- $names
  IFS="$ifs_save"
  [ "$noglob_was_on" = yes ] || set +f
  for name in "$@"; do
    [ -n "$name" ] || continue
    [ -f "${dir}/${name}" ] || continue
    rm -f "${dir}/${name}" 2>/dev/null && removed=$((removed + 1))
  done
  echo "$removed"
}

_dep_have() { command -v "${1:-}" >/dev/null 2>&1; }

# First semver-looking token in a `--version` line. Tools disagree about
# everything else in that line ("ripgrep 15.2.0", "jq-1.7.1", "v22.3.0"), so
# the token is what we take and nothing around it.
_dep_version_from_probe() {  # <argv...>
  local out
  out="$("$@" 2>/dev/null | head -3)" || true
  [ -n "$out" ] || { echo unknown; return 0; }
  local tok
  tok="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  echo "${tok:-unknown}"
}

# THE VERSION AN `npx <pkg>@latest` ROW IS ACTUALLY RUNNING. An npx row pins
# nothing: the recorded command names `@latest`, so the version in play is
# whatever npm resolved into its `_npx` cache the last time the command ran.
# That cache IS a version surface — each entry is an ordinary node_modules tree
# with the package's own package.json in it — and the certified doctor table asks
# for a literal version wherever one exists rather than a dash where one could be
# read.
#
# A READ, NEVER A FETCH. Doctor calls this, and doctor is read-only and offline
# by contract, so this looks only at what is already on disk. A machine that has
# never run the command has no cache entry and gets `unknown` — which is the
# honest answer, not a failure: the row's presence is decided elsewhere, and this
# function only ever decorates it.
#
# NEWEST ENTRY WINS. npx keys its cache by a hash of the install request, so a
# package upgraded over time leaves several trees behind. The most recently
# modified one is the one the last run used.
dep_npx_version() {  # <package-name> -> the cached version, or `unknown`
  local pkg="${1:-}" root newest="" pj ver
  [ -n "$pkg" ] || { echo unknown; return 0; }
  # `@latest` and friends are part of the install request, never of the path.
  case "$pkg" in
    @*/*) pkg="${pkg%@*}" ;;   # a scoped name keeps its leading @
    *@*)  pkg="${pkg%@*}" ;;
  esac
  root="${BIONIC_NPX_CACHE:-$HOME/.npm/_npx}"
  [ -d "$root" ] || { echo unknown; return 0; }
  for pj in "$root"/*/node_modules/"$pkg"/package.json; do
    [ -f "$pj" ] || continue
    if [ -z "$newest" ] || [ "$pj" -nt "$newest" ]; then newest="$pj"; fi
  done
  [ -n "$newest" ] || { echo unknown; return 0; }
  if _dep_have jq; then
    ver="$(jq -r '.version // ""' "$newest" 2>/dev/null)"
  else
    ver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$newest" 2>/dev/null \
           | head -1 | grep -oE '"[^"]+"$' | tr -d '"')"
  fi
  echo "${ver:-unknown}"
}

# ─── Per-mechanism probes ────────────────────────────────────────────────────
#
# Each prints `<present>|<version>` where present is yes | no | unknown.
# `unknown` is used only where the mechanism genuinely has no presence surface
# — reporting `no` there would be a confident wrong answer, and doctor would
# nag about a dependency that is in fact fine.
#
# THE PROBE CONTRACT (epic-18 AC-9). A probe answers "is this dependency in
# the state setup leaves it in", not "is it registered". Those two questions
# only coincide where setup's own act of installing IS the registration
# (native, mcp-server below) — everywhere else, checking a registry as a
# stand-in for the state is a wrong-answer waiting to happen: the registry can
# say yes while the route that actually needs the dependency gets nothing.
# Audited against this at T5, one line per kind:
#   native              registration IS the installed state (a plugin's key in
#                        installed_plugins.json is not a proxy for anything
#                        else) — fine.
#   brew-dep/brew-cask   the binary on PATH is the state itself, not a lookup
#                        in some brew ledger — fine.
#   npm-global           `npm list -g` reads npm's own record of what its
#                        install left behind; for a global package that record
#                        IS the state, there is no second question to ask —
#                        fine.
#   mcp-server           registration via `claude mcp add` is genuinely the
#                        entire state a route consumes; no other installed
#                        surface exists to probe instead — fine.
#   pnpm-store           no presence surface exists at all (see
#                        _dep_check_pnpm_store below); `unknown` is the honest
#                        answer, never a registration stand-in — fine.
#   playwright-browser   a filesystem marker left by the actual install, not a
#                        network --dry-run check — fine.
#   statusline           being fixed in flight — see the note at
#                        _dep_check_statusline below (epic-18 T1, parallel).
#   uv-tool (notebooklm) being fixed in flight — see the note at
#                        _dep_check_uv_tool below (epic-18 T2, parallel).

_dep_check_native() {  # native kind: the harness's own install registry
  local name="$1" file ver
  file="$(_dep_installed_json)"
  _dep_have jq || { echo "unknown|unknown"; return 0; }
  [ -f "$file" ] || { echo "no|unknown"; return 0; }
  # Marketplace-agnostic on purpose: S3 re-points both deps at bionic's own
  # marketplace, which rewrites the right-hand side of the `name@marketplace`
  # key. Matching on the name half survives that.
  ver="$(jq -r --arg n "$name" '
      [ (.plugins // {}) | to_entries[]
        | select((.key | split("@")[0]) == $n)
        | .value[0].version // "unknown" ] | first // "absent"' "$file" 2>/dev/null)"
  case "$ver" in
    absent|null|"") echo "no|unknown" ;;
    *)              echo "yes|${ver}" ;;
  esac
}

_dep_check_brew_dep() {  # presence is the binary on PATH, exactly as bootstrap checks it
  local name="$1"
  if _dep_have "$name"; then echo "yes|$(_dep_version_from_probe "$name" --version)"; else echo "no|unknown"; fi
}
_dep_check_brew_cask() { _dep_check_brew_dep "$@"; }

# uv-tool's default probe is the brew-dep one — CLI on PATH — and that is
# right for the mechanism in general. notebooklm is the one row with a second
# half: `notebooklm skill install` (ported from claude-bootstrap.sh
# 1542-1550) writes ~/.claude/skills/notebooklm/SKILL.md, and the CLI being on
# PATH says nothing about whether that step ever ran — the ccstatusline bug
# this wave exists to fix, one row over (handoff §3.1 vs §3.2, AC-5). A new
# `kind` for one row would be the second-installer-shaped kludge the ownership
# table exists to prevent, so the name check lives here instead, the same way
# `_dep_install_statusline` is a whole dedicated function for its one row.
# (T5's probe audit deferred this row to T2's landing — satisfied here.)
_dep_check_uv_tool() {
  local name="$1" raw present version
  raw="$(_dep_check_brew_dep "$name")"
  present="${raw%%|*}"; version="${raw##*|}"
  if [ "$name" = "notebooklm" ] && [ "$present" = "yes" ]; then
    [ -f "$(_dep_claude_home)/skills/notebooklm/SKILL.md" ] || present=no
  fi
  printf '%s|%s\n' "$present" "$version"
}

_dep_check_npm_global() {  # the PACKAGE is the probe target, not a binary name
  local name="$1" pkg out
  pkg="$(_dep_locator_target "$(dep_field "$name" source_url)")"
  _dep_have npm || { echo "unknown|unknown"; return 0; }
  out="$(npm list -g --depth=0 "$pkg" 2>/dev/null)" || { echo "no|unknown"; return 0; }
  local ver
  ver="$(printf '%s\n' "$out" | grep -oE "@[0-9]+\.[0-9]+\.[0-9]+" | tail -1)"
  ver="${ver#@}"
  echo "yes|${ver:-unknown}"
}

_dep_check_mcp_server() {
  local name="$1"
  _dep_have claude || { echo "unknown|unknown"; return 0; }
  if claude mcp get "$name" >/dev/null 2>&1; then echo "yes|unknown"; else echo "no|unknown"; fi
}

# THE STORE HAS A SURFACE AFTER ALL (Chris 2026-08-22: "Why didn't the previous
# one install motion?" — it had; the probe just could not see it, so setup
# re-offered it forever). pnpm's store keeps an index.db naming every cached
# `<name>@<version>`; a package is present when its name is in that index, and
# the newest recorded version rides along. `unknown` only when pnpm itself, or
# the store, cannot be found — that is a cause doctor can name, not a shrug.
_dep_check_pnpm_store() {
  local name="$1" store idx ver
  _dep_have pnpm || { echo "unknown|unknown"; return 0; }
  store="${BIONIC_PNPM_STORE:-$(pnpm store path 2>/dev/null)}"
  idx="${store}/index.db"
  [ -n "$store" ] && [ -f "$idx" ] || { echo "unknown|unknown"; return 0; }
  ver="$(/usr/bin/strings "$idx" 2>/dev/null | /usr/bin/grep -o "${name}@[0-9][0-9A-Za-z.+-]*" \
         | sed "s/^${name}@//" | sort -V | tail -1)"
  if [ -n "$ver" ]; then echo "yes|${ver}"; else echo "no|unknown"; fi
}

# A filesystem probe rather than bootstrap's `--dry-run` walk: doctor is
# read-only and must not shell out to the network. Same caveat bootstrap's own
# comment makes about its glob — this proves SOME completed chromium build
# exists, not that a given project's pinned build does.
_dep_check_playwright_browser() {
  local cache marker
  cache="$(_dep_playwright_cache)"
  [ -d "$cache" ] || { echo "no|unknown"; return 0; }
  for marker in "$cache"/chromium-*/INSTALLATION_COMPLETE; do
    [ -f "$marker" ] || continue
    local dir="${marker%/INSTALLATION_COMPLETE}"
    echo "yes|${dir##*chromium-}"
    return 0
  done
  echo "no|unknown"
}

# THE VENV IS THE STATE `uv sync` LEAVES BEHIND, so the venv is what this asks about. Not
# whether `uv` is on PATH — that is the `uv` row's question, and answering this row with it
# would report a renderer as ready on a machine that has never synced the project.
#
# THE VENV LIVES AT THE STABLE PATH NOW, NOT `<refs>/.venv` (VENV slice, AC-17). `refs` still
# names the SOURCE tree — where `pyproject.toml` and `uv.lock` are read from — but the venv
# itself is checked at `_dep_excalidraw_venv_dir`, which does not move when the plugin
# updates. `refs` is still needed here for exactly one thing: reading the SHIPPED `uv.lock`
# this venv should currently match.
#
# The version reported is the renderer's own driver, not the venv's interpreter — see the
# note at the read below. The constraint is `any`, so nothing is judged on it; it is there so
# the report says something true rather than `unknown` about a directory it can plainly read.
#
# `unknown` when the project directory cannot be located at all (neither plugin-root name is
# set), with the cause doctor renders beside it. A `no` there would be a confident answer
# about a path nobody resolved.
#
# STALE IS ITS OWN STATE, NOT `no` (AC-17: "a venv stale against uv.lock is re-synced, not
# re-offered"). A venv that exists but was built against a DIFFERENT `uv.lock` than the one
# now shipped is not the same fact as a venv that was never built — collapsing the two into
# one `no` would tell setup to ask the "not installed, install now?" question over a machine
# that plainly has a working renderer sitting on it, one lockfile update behind. The
# comparison is skippable-safe: no hash file (an upgrade from before this slice, or a tool
# lookup failure) or no shipped lock to compare against both fall through to `yes` rather than
# manufacturing a mismatch neither side can actually support.
_dep_check_uv_project() {
  local refs venv ver shipped_lock hash_file current_hash stored_hash
  refs="$(_dep_excalidraw_refs)"
  [ -n "$refs" ] || { echo "unknown|unknown"; return 0; }
  venv="$(_dep_excalidraw_venv_dir)"
  [ -x "${venv}/bin/python" ] || { echo "no|unknown"; return 0; }
  # The version that means something here is the renderer's driver — the
  # playwright the sync pinned — not the venv's interpreter (Chris 2026-08-22:
  # the row read "records no version" while a real one sat in the venv).
  ver="$(cat "${venv}"/lib/python*/site-packages/playwright-*.dist-info/METADATA 2>/dev/null \
         | /usr/bin/grep -m1 '^Version:' | sed 's/^Version:[[:space:]]*//' | tr -d '[:space:]')"
  ver="${ver:-unknown}"

  shipped_lock="${refs}/uv.lock"
  hash_file="$(_dep_excalidraw_lock_hash_file)"
  if [ -f "$shipped_lock" ] && [ -f "$hash_file" ]; then
    current_hash="$(_dep_sha256 "$shipped_lock")"
    stored_hash="$(cat "$hash_file" 2>/dev/null)"
    if [ -n "$current_hash" ] && [ "$current_hash" != "$stored_hash" ]; then
      echo "stale|${ver}"
      return 0
    fi
  fi
  echo "yes|${ver}"
}

# TWO HALVES, ONE ANSWER (epic-18 T1, AC-2). `present=yes` used to mean only
# "the command is set" — the probe-contract violation that let a machine
# report healthy while ccstatusline rendered its own stock default (handoff
# §3.1). Now it means both: the command AND the layout file the command
# reads. The second field carries WHICH half is missing when it is not
# `yes`, so doctor's degradation line can name it rather than repeat the
# A skill is present when the file that MAKES it a skill is readable, not when a
# directory of its name exists. An interrupted clone leaves the directory and
# nothing in it, and reporting that as installed is the half-installed shape this
# task's sibling rows exist to stop reporting (AC-9's rule: a probe answers "is
# this in the state setup leaves it in", never "is there something by this name").
# No version: a cloned skill carries no version anywhere the probe could read.
_dep_check_github_skill() {
  local name="$1"
  if [ -f "$(_dep_skills_dir)/${name}/SKILL.md" ]; then echo "yes|unknown"; else echo "no|unknown"; fi
}

# THREE HALVES, ONE ANSWER (epic-18 T1 AC-2; epic-21 1.4.4 T5). `present=yes`
# used to mean only "the command is set" — the probe-contract violation that let
# a machine report healthy while ccstatusline rendered its own stock default
# (handoff §3.1) — and then "the command AND the layout file the command reads".
# It now means all three: an executable that IS installed, a recorded command
# that will exec it without a network round trip, and the layout it renders
# from. The second field carries WHICH parts are missing when the answer is not
# `yes`, plus-joined, so a caller that wants to name the gap can.
#
# WHY THE npx FORM IS AN ABSENCE, NOT A PRESENCE (review-a C-1, review-b F-1).
# The old glob accepted `npx ccstatusline@latest` as proof the dependency was
# there, which is the string this release exists to remove: doctor's ENVIRONMENT
# table flagged it and sent the reader to `/bionic:setup`, setup asked this
# function, was told the row was fine, and reported "nothing left to do" with the
# ✗ still on the screen. That is the field defect of
# `bug-doctor-setup-ownership.md` verbatim, one release later, and every machine
# that ran setup before 1.4.4 is in exactly that state. Rejecting the npx form
# here is what puts a real item behind the hint: the row goes pending on those
# machines, `--all` offers the repair, and the existing install arm rewrites the
# command. The glob needs the trailing space, so a command merely CONTAINING
# "npx" is not caught.
#
# AND "RECORDED" IS NOT "INSTALLED" (review-a C-4). The command being set says
# nothing about whether `npm install -g ccstatusline` ever succeeded — the
# interim hand patch in the bug report applied the settings.json edit alone, and
# a failed or offline install leaves the same shape. Doctor rendered `✓
# ccstatusline … command set, layout file in place` over a machine with a blank
# status line. The binary is probed exactly the way every other npm row's is, so
# "installed" means one thing across the roster. An UNREADABLE answer (no npm on
# the machine) is not a missing one: reporting the row absent there would send
# the reader to a repair that cannot run, since the installer needs the same npm.
_dep_check_statusline() {
  local name="${1:-ccstatusline}" settings cmd bin missing=""
  local cmd_ok=no cfg_ok=no bin_ok=yes
  settings="$(_dep_settings_file)"
  _dep_have jq || { echo "unknown|unknown"; return 0; }
  if [ -f "$settings" ]; then
    cmd="$(jq -r '.statusLine?.command? // "" | tostring' "$settings" 2>/dev/null)"
    case "$cmd" in
      "npx "*)        cmd_ok=no ;;
      *ccstatusline*) cmd_ok=yes ;;
    esac
  fi
  _dep_ccstatusline_layout_match "$(_dep_ccstatusline_config_source)" "$(_dep_ccstatusline_config_target)" \
    && cfg_ok=yes
  bin="$(_dep_check_npm_global "$name")"
  [ "${bin%%|*}" = "no" ] && bin_ok=no

  [ "$bin_ok" = "yes" ] || missing="binary"
  [ "$cmd_ok" = "yes" ] || missing="${missing:+${missing}+}command"
  [ "$cfg_ok" = "yes" ] || missing="${missing:+${missing}+}config"
  if [ -z "$missing" ]; then echo "yes|ok"; else echo "no|${missing}-missing"; fi
}

# ─── check_dep ───────────────────────────────────────────────────────────────

check_dep() {  # <name> -> present=<yes|no|unknown>|version=<v|unknown>|verdict=<ok|violation|unknown>
  local name="${1:-}" mech constraint raw present version verdict
  mech="$(dep_field "$name" install_fn_or_check)" || return 1
  constraint="$(dep_field "$name" constraint)"

  case "$mech" in
    native)             raw="$(_dep_check_native "$name")" ;;
    brew-dep)           raw="$(_dep_check_brew_dep "$name")" ;;
    brew-cask)          raw="$(_dep_check_brew_cask "$name")" ;;
    npm-global)         raw="$(_dep_check_npm_global "$name")" ;;
    uv-tool)            raw="$(_dep_check_uv_tool "$name")" ;;
    pnpm-store)         raw="$(_dep_check_pnpm_store "$name")" ;;
    mcp-server)         raw="$(_dep_check_mcp_server "$name")" ;;
    playwright-browser) raw="$(_dep_check_playwright_browser "$name")" ;;
    uv-project)         raw="$(_dep_check_uv_project "$name")" ;;
    github-skill)       raw="$(_dep_check_github_skill "$name")" ;;
    statusline)         raw="$(_dep_check_statusline "$name")" ;;
    *)                  raw="unknown|unknown" ;;
  esac

  present="${raw%%|*}"; version="${raw##*|}"

  # A constraint verdict is a judgement about an installed version. With
  # nothing installed there is nothing to judge — that is `unknown`, not `ok`.
  if [ "$present" != "yes" ]; then
    verdict=unknown
  else
    verdict="$(dep_constraint_verdict "$constraint" "$version")"
  fi
  echo "present=${present}|version=${version}|verdict=${verdict}"
}

# ─── Display indentation ─────────────────────────────────────────────────────
#
# THE CALLER OWNS THE DEPTH (six-axis review R-2). The prose this file prints
# lands inside somebody else's block — setup's numbered steps, which sit three
# spaces in, or remove's items, which sit two — and the indent used to be a bare
# literal here, so the seam between two files was visible on the user's screen:
# setup's own sentence three spaces in, the install prose beneath it two, down
# the whole step. The caller sets `BIONIC_DEP_INDENT` once; every line this file
# prints reads it. Two spaces is the default because that is what remove.sh and
# a route's just-in-time offer already use.
_dep_indent() { printf '%s' "${BIONIC_DEP_INDENT:-  }"; }

# ─── Consent ─────────────────────────────────────────────────────────────────

_dep_consent() {  # <prompt> -> 0 yes, 1 an explicit no, 2 EOF (nobody there to ask)
  local prompt="$1" answer=""
  # THE ANSWER IS ALREADY GIVEN. `setup --all` and `remove --all` print every
  # item their run would ask about — this one among them — and take a single
  # explicit `y` over that printed page before either sets its flag. Asking
  # again here would be asking a person to answer the same question twice.
  #
  # AND THE VALUE HERE IS ALWAYS THE SCRIPT'S OWN (epic-17 W7 S11, six-axis review
  # axis 4). An earlier version of this comment claimed neither name was settable
  # from outside those two scripts. That was FALSE, and it was the whole defect:
  # this function reads BOTH names, setup.sh zeroed only `SETUP_ALL` and remove.sh
  # only `RM_ALL`, so an exported `RM_ALL=1` answered every question in setup and
  # an exported `SETUP_ALL=1` answered every deps.sh-routed row in remove — with
  # the standard input closed and no page ever printed. What makes the claim true
  # now is not this comment: each script zeroes BOTH names before anything can ask
  # anything, so whatever the environment carries is overwritten by the script that
  # owns the question, and the only writer of a 1 is that script's own `--all` `y`.
  # The behavioural wall used to be one arm per suite (setup.test.sh /
  # remove.test.sh, both names exported, nothing on stdin, the machine
  # byte-identical afterwards) — a name grep cannot see this class. Both
  # suites are gone (remove.test.sh deleted at 8582861); no test currently
  # exercises this arm, so the claim above is presently unverified prose, not
  # a proven wall.
  if [ "${SETUP_ALL:-0}" = "1" ] || [ "${RM_ALL:-0}" = "1" ]; then return 0; fi
  printf '%s [y/N] ' "$prompt"
  IFS= read -r answer || { echo ""; return 2; }
  echo ""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# THE OTHER HALF OF A "NO" (AC-12). `_dep_consent` returning non-zero used to
# mean one thing — an explicit no — so every caller printed the same
# "declined —" sentence whether a person typed n or a non-interactive first
# pass hit EOF on the very first question. "declined" is a recorded choice;
# EOF means nobody was there to make one. This is the one sentence for that
# second case, so the transcript says so instead of putting a "no" in an
# absent user's mouth.
_dep_not_asked() {  # <name> — <name> stays absent, not asked
  printf '%snot asked — %s stays absent.\n' "$(_dep_indent)" "$1"
}

# The removal-side counterpart: a row left in place because nobody was there
# to answer, not because they said no. Same rule, opposite tail — every
# `_dep_consent` caller in this file (installers AND removers) gets to tell
# the two apart, not just `install_dep`.
_dep_not_asked_left() {  # <name> — <name> left in place, not asked
  printf '%snot asked — %s left in place.\n' "$(_dep_indent)" "$1"
}

# ─── Install ─────────────────────────────────────────────────────────────────
#
# One mutating entry point. The setup loop calls it once per row it installs; a
# route that hits an absent dependency calls it for that one row (AC-5). There
# is no third path and no silent path.

# The argv a mechanism would run. Printed to the user BEFORE the question and
# executed AFTER it, from the same source — the plan the user consented to is
# by construction the command that runs.
_dep_install_argv() {  # <name> — one token per line
  local name="$1" mech target
  mech="$(dep_field "$name" install_fn_or_check)" || return 1
  target="$(_dep_locator_target "$(dep_field "$name" source_url)")"
  case "$mech" in
    brew-dep)           printf '%s\n' brew install "$target" --quiet ;;
    brew-cask)          printf '%s\n' brew install --cask "$target" --quiet ;;
    npm-global)         printf '%s\n' npm install -g "$target" --silent ;;
    uv-tool)            printf '%s\n' uv tool install "$target" --quiet ;;
    pnpm-store)         printf '%s\n' pnpm store add "${target}@latest" ;;
    mcp-server)         printf '%s\n' claude mcp add "$name" -s user -- npx -y "$target" ;;
    playwright-browser) printf '%s\n' npx --yes "$target" install chromium ;;
    # `--project <dir>` rather than a `cd`: install_dep execs an argv, it does not run a
    # shell line, so the directory has to be an argument. An unresolvable project directory
    # yields no argv at all, which install_dep reports as "no install mechanism" instead of
    # syncing whatever the current directory happens to be.
    uv-project)
      local refs; refs="$(_dep_excalidraw_refs)"
      [ -n "$refs" ] || return 1
      printf '%s\n' uv "$target" --project "$refs" ;;
    # ONE COMMAND, AND THAT IS THE POINT. The retired installer cloned to /tmp,
    # copied the tree into place and stripped `.git`; a single clone into the
    # destination keeps this row on the same print-the-plan / consent / run-that
    # -exact-plan path every other mechanism uses, and makes jit.sh's one-line
    # fix a command the user can paste. The `.git` left behind costs nothing:
    # the teardown removes the whole directory either way.
    github-skill)       printf '%s\n' git clone --depth 1 "https://github.com/${target}.git" "$(_dep_skills_dir)/${name}" ;;
    statusline)         return 1 ;;  # not an argv — see _dep_install_statusline
    *)                  return 1 ;;
  esac
}

# ─── Writing through a symlink ───────────────────────────────────────────────
#
# WHAT A DOTFILES USER GETS OTHERWISE (critic delta 2 N1). A `~/.zshrc` or a
# `~/.claude/settings.json` symlinked into a dotfiles repo is a regular way to
# manage those files. Every writer in this payload stages a `<file>.bionic.tmp`
# and `mv`s it into place, and `mv` REPLACES the link with a regular file: the
# rewrite lands in a fresh inode at the link's path, the dotfiles copy keeps the
# content bionic just reported removing, `git status` in that repo shows nothing,
# and the next `stow` puts the whole footprint back. The user is told the
# footprint is gone while it is sitting in the file they actually manage. So the
# writers resolve the path to the FINAL target of its symlink chain and publish
# onto THAT: the link survives, still points where it did, and the file it names
# is the one that changed.
#
# NO `realpath`, and no `readlink -f`. `realpath` is not on a bare macOS, and
# BSD `readlink` has no `-f`. The loop below is the portable spelling: one hop at
# a time, relative targets resolved against the LINK's own directory (that is
# what the kernel does), with a hop cap so a symlink loop terminates instead of
# spinning. Bash 3.2 — no `${var@…}`, no arrays, no `readarray`.
#
# HONEST DEGRADATION, the same contract `stat` already has here. If `readlink` is
# not on the machine the loop breaks on the first hop and the caller writes to the
# path as given, which is the behaviour every writer had before this existed — a
# degradation, never a refusal. The standalone door runs on the box with the bare
# /bin and must still write.
#
# THE ABSENT CASE IS NOT NEUTRAL (critic delta 3 F5). Absent `readlink`, the write
# lands on the link's path as given, which replaces a symlink with a regular
# file — the pre-S15 behaviour. `readlink` lives beside `stat` on both platforms
# this payload targets, so the risk is negligible; it is recorded here because the
# consequence, not just the mechanism, is what a reader of this comment needs.
#
# TWO OTHER FILES CARRY A BYTE-IDENTICAL COPY under the same name — hooks.sh
# and remove.sh. Each is sourced on its own by something (the suites load the
# libraries directly; remove.sh's standalone door runs where scripts/lib/ no
# longer exists), so neither may assume this file came first, and a `. deps.sh`
# inside a library also breaks every mutation arm that runs a doctored COPY of it
# from a scratch directory. setup.sh sources this file at load and uses this
# definition. tests/remove.test.sh used to pin all three against each other,
# the same wall the settings writer's two copies stood behind; that suite was
# deleted at 8582861 and nothing replaced either wall.
bionic_link_target() {  # <path> — the final target of a symlink chain, else <path>
  local p="${1:-}" link dir n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    link="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$link" ] || break
    case "$link" in
      /*) p="$link" ;;
      *)  dir="${p%/*}"; [ "$dir" = "$p" ] && dir="."; p="${dir}/${link}" ;;
    esac
    n=$((n + 1))
  done
  printf '%s\n' "$p"
}

# THE ONE SETTINGS WRITER IN THIS FILE. Both statusline arms — recording the
# line on install and clearing it on removal — are jq rewrites of the same
# ~/.claude/settings.json, so they are one function rather than two copies of
# six lines. They were two copies once, and the drift that cost is exactly this:
# the mode repair that landed in the payload's other writers never reached
# either of them, and no test noticed. tests/remove.test.sh used to pin this
# body's shape alongside the other three and wall the payload against a fifth
# writer appearing beside them; that suite was deleted at 8582861 and nothing
# replaced the wall.
#
# THE FILE'S MODE SURVIVES THE REWRITE. `mv` replaces the inode, so without the
# capture-and-reapply below a settings.json the user deliberately kept at 0600 —
# it routinely holds an `env` block with tokens — would come back at whatever the
# umask says, as a side effect of recording a statusline. `stat` is spelled both
# ways because BSD and GNU take different flags and neither accepts the other's;
# an absent `stat` leaves `mode` empty and the rewrite still lands, which is the
# same honest degradation this file already practises for `jq`.
#
# AND IT IS THE TARGET'S MODE, NOT THE LINK'S (S14, closing the class the S13
# critic delta left standing here). A `~/.claude/settings.json` symlinked into a
# dotfiles repo is the commonest way people manage it, and a bare `stat` on a
# symlink reports the LINK's own mode — 755 — never the file's. Capturing that
# and handing it to `chmod` publishes the rewrite as `rwxr-xr-x`: WIDER than the
# file being replaced, which is the one outcome this capture exists to prevent.
# `-L` is what makes the capture mean the file; both flavours take it.
#
# THE ORDER IS THE FIX. `umask 077` and the `chmod` both come BEFORE the `mv`, so
# the rename publishes an already-correct inode. Repairing the mode afterwards —
# the obvious spelling — leaves the tmp holding the tokens at 0644 under a
# predictable name, and makes the widening PERMANENT if the process dies in the
# window between the two. Do not move either below the rename. The guard is
# spelled `-z … ||` rather than `-n … &&` because this is a single `&&` chain: on
# a machine with no `stat` the `-n` spelling would break the chain and skip the
# rename entirely, turning honest degradation into a silent refusal to write.
# hooks.sh's `hooks_strip_legacy_channel` carries the same shape for the same
# reasons.
#
# THE STALE TMP IS REMOVED, NOT TRUNCATED. `>` on an existing file keeps that
# file's mode, so a tmp left behind by an earlier interrupted run would carry
# ITS width through the write, exposed until the chmod line below catches up —
# the one hole S13's own header comment ("nothing ever exists at a mode wider
# than the file it is replacing") did not cover for this writer.
_dep_settings_write_jq() {  # <settings-file> <jq-program> [jq-arg...]
  local settings="${1:-}" program="${2:-}"
  shift 2 || return 1
  local tmp mode
  settings="$(bionic_link_target "$settings")"
  tmp="${settings}.bionic.tmp"
  mode="$(stat -L -f '%Lp' "$settings" 2>/dev/null || stat -L -c '%a' "$settings" 2>/dev/null)"
  [ -e "$settings" ] || mode=""
  rm -f "$tmp"
  if (umask 077; jq "$@" "$program" "$settings" > "$tmp") \
     && { [ -z "$mode" ] || chmod "$mode" "$tmp"; } \
     && mv "$tmp" "$settings"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# ─── The retired permission block, and stripping it back out ─────────────────
#
# BIONIC NO LONGER SHIPS AN ALLOW-LIST (epic-18 T13). It used to render a
# managed block of `permissions.allow` rules into the user's settings.json, so
# that its own scripts and hooks ran without a prompt. That is deleted: a
# permission MODE is the user's answer to "how much do I want to be asked", and
# a product that quietly exempts itself from the manual mode they chose has
# overridden the choice rather than honoured it. Setup still offers to set the
# mode; it no longer carves itself out of it.
#
# WHAT REMAINS IS CLEANUP, AND ONLY CLEANUP. Machines set up before this change
# carry the block, and nothing in the product would ever mention it again — a
# silent leftover granting permissions its owner can no longer see named. So
# both doors offer to strip it once, consented: /bionic:setup on the upgrade
# path and /bionic:remove on the teardown path. Neither writes it back.
#
# THE SENTINELS ARE THE OLD SPELLING, VERBATIM, and must stay that way: they are
# what is already in the files being cleaned. remove.sh's standalone door
# carries its own copy of both literals and of the program below, because it
# runs where scripts/lib/ is already gone. No test pins the copies against
# these originals or drives both doors over a shared fixture since
# tests/remove.test.sh was deleted at 8582861.
BIONIC_PERMISSION_BLOCK_BEGIN_PREFIX='Bash(: bionic-profile-begin version='
BIONIC_PERMISSION_BLOCK_END='Bash(: bionic-profile-end)'

# Removes the marker block, inclusive, and collapses the containers the old
# apply created. The collapse is what makes a machine that had no `permissions`
# key at all come back the way it started: apply created `.permissions.allow`,
# so the strip must unmake it. (The one case this cannot distinguish is a file
# that already carried an EMPTY allow array before bionic ever ran; such a file
# comes back semantically identical with the empty container removed.) Rules
# OUTSIDE the block are the machine's own and are never touched.
BIONIC_PERMISSION_BLOCK_STRIP_JQ='
  if (.permissions | type) != "object" then .
  elif (.permissions.allow | type) != "array" then .
  else
    .permissions.allow as $a
    | ($a | map(type == "string" and startswith("'"${BIONIC_PERMISSION_BLOCK_BEGIN_PREFIX}"'")) | index(true)) as $b
    | ($a | map(. == "'"${BIONIC_PERMISSION_BLOCK_END}"'") | index(true)) as $e
    | if $b == null or $e == null or $e < $b then .
      else .permissions.allow = ($a[0:$b] + $a[$e+1:]) end
  end
  | if (.permissions | type) == "object"
       and (.permissions.allow | type) == "array"
       and (.permissions.allow | length) == 0
    then del(.permissions.allow) else . end
  | if (.permissions | type) == "object" and (.permissions | length) == 0
    then del(.permissions) else . end
'

# True when this machine still carries a block. Read TEXTUALLY, so it survives a
# machine with no `jq` — the state where an unremovable leftover matters most.
# The strip itself refuses without jq, and says so; it never guesses.
bionic_has_permission_block() {  # [settings-file]
  local settings="${1:-$(_dep_settings_file)}"
  [ -f "$settings" ] || return 1
  grep -qF "$BIONIC_PERMISSION_BLOCK_BEGIN_PREFIX" "$settings" 2>/dev/null
}

# No consent gate here, by design — the same reasoning the old strip carried:
# this only ever removes what bionic itself put there, and the CALLER owns the
# conversation with the user. A strip on a machine that never applied one is a
# genuine no-op rather than a rewrite that happens to produce the same JSON, so
# it returns before touching the file.
bionic_strip_permission_block() {  # [settings-file]
  local settings="${1:-$(_dep_settings_file)}"
  bionic_has_permission_block "$settings" || return 0
  _dep_have jq || return 1
  _dep_settings_write_jq "$settings" "$BIONIC_PERMISSION_BLOCK_STRIP_JQ"
}

# ccstatusline is a REAL package install now, not only a settings.json edit
# (epic-21, bug-ccstatusline-npx-per-render.md). Claude Code runs the recorded
# `.statusLine.command` on EVERY render, and the command used to be `npx
# ccstatusline@latest` — a registry lookup to resolve `latest` before the
# first byte of the status line could print, measured stalling 73s per render
# on a network with TLS interception (the bug report's table). The fix
# installs the binary once, the same `npm install -g` mechanism the
# `npm-global` kind runs (see `_dep_install_argv`'s `npm-global` case), and
# records the bare command name so every later render just execs it — nothing
# left to resolve. Ported from claude-bootstrap.sh's do_set_statusline, which
# this now goes beyond: that installer never ran `npm install` either, and
# relied on `npx` to fetch on demand — the exact behavior being removed.
#
# UNPINNED, BY MEASUREMENT (the bug report leaves this call to the writer).
# `npm:ccstatusline@2.2.29` would guard against the shipped layout's schema
# drifting out from under a newer ccstatusline release. It is not needed:
# `_dep_ccstatusline_layout_match` (above) already strips `.version` before
# comparing, added 2026-09-03 for exactly this — ccstatusline 2.2.29 rewrote
# bionic's layout from schema version 3 to 4 in place and changed nothing else
# — so the one schema bump on record was already absorbed without a pin.
# Pinning would freeze ccstatusline's own upstream bugfixes for no schema
# benefit this repo can see today, so the locator stays `any`/unpinned.
#
# BOTH HALVES (epic-18 T1, AC-1) STILL STAND. Recording the command alone
# leaves ccstatusline rendering its own stock default — handoff §3.1's
# incident — because the LAYOUT (colors, field order) lives in a second file
# this function also copies: the payload's own
# ${CLAUDE_PLUGIN_ROOT}/ccstatusline/settings.json, published to
# ~/.config/ccstatusline/settings.json exactly as claude-bootstrap.sh's
# ccstatusline-config step did. Skipped when already byte-identical, ported
# from that same step's `diff -q` short-circuit.
#
# THE WRITE IS A MERGE, AND THE COMMAND IS NOT THE LOCATOR (1.4.4 T5, review-a
# C-3 / review-b N-1). Two facts about the one jq assignment below:
#   • `.statusLine` is an object the USER may already own. Replacing it whole
#     threw away every sibling key beside `command` — ccstatusline's own
#     `padding`, anything a future Claude Code release adds — on a file bionic is
#     a guest in. Merging into what is there writes the two keys this function
#     is responsible for and leaves the rest alone.
#   • The command has to be EXECUTABLE. It used to be the locator target
#     verbatim, so the pin the docblock above holds in reserve would have
#     recorded `ccstatusline@2.2.29` — a string no shell can run — and the status
#     line would have gone blank with nothing on screen to say why. The install
#     still takes the pinned form; only the recorded command is stripped.
_dep_install_statusline() {
  local settings pkg cmd source target
  settings="$(_dep_settings_file)"
  pkg="$(_dep_locator_target "$(dep_field ccstatusline source_url)")"
  cmd="$(_dep_pkg_unversioned "$pkg")"
  _dep_have jq  || { echo "$(_dep_indent)jq is not installed — cannot edit ${settings}" >&2; return 1; }
  _dep_have npm || { echo "$(_dep_indent)npm is not installed — cannot install ${pkg}" >&2; return 1; }
  npm install -g "$pkg" --silent || { echo "$(_dep_indent)npm install -g ${pkg} failed" >&2; return 1; }
  # Deliberately NOT under `umask 077`: the defect being fixed is widening a mode
  # the USER chose, and a file that does not exist yet carries no such choice.
  # bionic creating settings.json at 0600 where the CLI would have made it 0644
  # is a different decision, and not this fold's to make.
  [ -f "$settings" ] || echo '{}' > "$settings"
  _dep_settings_write_jq "$settings" \
    '.statusLine = ((.statusLine // {}) + {"type": "command", "command": $c})' \
    --arg c "$cmd" || return 1

  source="$(_dep_ccstatusline_config_source)"
  target="$(_dep_ccstatusline_config_target)"
  if [ ! -f "$source" ]; then
    echo "$(_dep_indent)shipped ccstatusline layout missing at ${source} — the statusline command is set but its config was not copied." >&2
    return 1
  fi
  _dep_ccstatusline_layout_match "$source" "$target" && return 0
  mkdir -p "$(_dep_ccstatusline_config_dir)" && cp "$source" "$target"
}

install_dep() {  # <name>
  local name="${1:-}" kind plan line
  local -a argv=()
  kind="$(dep_field "$name" kind)" || return 1

  # KIND, not class. Every native row is the harness's — the two core plugins
  # and the when-needed one alike — and a class-keyed guard would hand
  # impeccable to a mechanism that has no argv for it.
  if [ "$kind" = "native" ]; then
    echo "deps.sh: ${name} is installed by the plugin harness; there is no second installer." >&2
    return 1
  fi

  if [ "$(dep_field "$name" install_fn_or_check)" = "statusline" ]; then
    # BOTH HALVES, SURFACED BEFORE THE ONE QUESTION (AC-1: "never silently
    # overwritten"). This is a single-item row like every other — one
    # `_dep_consent` call below covers the whole plan — so a config file
    # already there that DIFFERS from the shipped layout is named in the
    # plan sentence itself rather than discovered only after a yes.
    local cfg_source cfg_target cfg_note=""
    cfg_source="$(_dep_ccstatusline_config_source)"
    cfg_target="$(_dep_ccstatusline_config_target)"
    if [ -f "$cfg_target" ] && ! _dep_ccstatusline_layout_match "$cfg_source" "$cfg_target"; then
      cfg_note=" (a config file already there differs from the shipped layout and would be overwritten)"
    fi
    # THE PLAN NAMES WHAT THE WRITE WILL WRITE. Two different strings under a pin —
    # the package installed, and the bare command recorded — so the sentence a user
    # consents to reads them separately rather than printing the locator twice.
    local sl_pkg; sl_pkg="$(_dep_locator_target "$(dep_field "$name" source_url)")"
    plan="npm install -g ${sl_pkg}, record '$(_dep_pkg_unversioned "$sl_pkg")' as the statusline in $(_dep_settings_file), and copy ${cfg_source} to ${cfg_target}${cfg_note}"
  else
    while IFS= read -r line; do argv+=("$line"); done < <(_dep_install_argv "$name") || true
    [ "${#argv[@]}" -gt 0 ] || { echo "deps.sh: no install mechanism for ${name}" >&2; return 1; }
    # Joined with a literal space whatever IFS the caller left behind — a
    # read-loop's IFS= once printed the humanizer clone as one run-together word
    # (Chris 2026-08-22).
    plan="$(printf '%s ' "${argv[@]}")"; plan="${plan% }"
    # AC-5: notebooklm's second half, named in the plan the user consents to
    # rather than run silently behind it (see _dep_check_uv_tool above).
    [ "$name" = "notebooklm" ] && plan="${plan} && notebooklm skill install"
  fi

  # Under --all the page already named this item and the user already said yes;
  # the plan line is for the per-item pass where the question is live.
  [ "${SETUP_ALL:-0}" = "1" ] || [ "${RM_ALL:-0}" = "1" ] || \
    echo "$(_dep_indent)${name} — not installed; bionic would run: ${plan}"
  _dep_consent "$(_dep_indent)Install ${name} now?"
  case $? in
    0) ;;
    2) _dep_not_asked "$name"; return 2 ;;
    *) echo "$(_dep_indent)declined — ${name} stays absent."; return 1 ;;
  esac

  # THE SUCCESS LINE (AC-11 — O-1). Every other item kind confirms what it did
  # ("added.", "applied.", "set."); a `tool:*` row used to run its mechanism and
  # say nothing at all, so a consented install and a silently-absent tool read
  # identically until the next `/bionic:doctor`. `install_dep`'s return value IS
  # the mechanism's own exit code — this only speaks on the zero.
  # THE MECHANISM'S OWN CHATTER IS NOT THE REPORT (Chris 2026-08-22: "Step 4 is
  # very difficult to read"). Download bars and package lists go to the log
  # file; the user sees one line per item. stderr stays, so a failure still
  # shows its reason.
  local quiet_log="${BIONIC_INSTALL_LOG:-${TMPDIR:-/tmp}/bionic-install.log}"
  # VENV slice, AC-17: `uv sync` is told where to put the venv by an
  # environment variable, not by the directory it is pointed `--project` at —
  # so it has to be EXPORTED here, into this shell, before the argv runs
  # (a `_dep_install_argv` line cannot export into its caller; it runs in a
  # process-substitution subshell). Scoped to the one mechanism this applies
  # to, so no other row's install picks up an env var that means nothing to it.
  [ "$(dep_field "$name" install_fn_or_check)" = "uv-project" ] && \
    export UV_PROJECT_ENVIRONMENT="$(_dep_excalidraw_venv_dir)"
  if [ "${#argv[@]}" -gt 0 ]; then
    if "${argv[@]}" >>"$quiet_log" 2>&1; then
      if [ "$name" = "notebooklm" ]; then
        notebooklm skill install >>"$quiet_log" 2>&1 || {
          echo "$(_dep_indent)installed, but 'notebooklm skill install' failed." >&2
          return 1
        }
      fi
      if [ "$(dep_field "$name" install_fn_or_check)" = "uv-project" ]; then
        # THE HASH THE NEXT PROBE COMPARES AGAINST (AC-17). Written beside the
        # venv, never inside it — see `_dep_excalidraw_lock_hash_file`. A sync
        # that ran without a readable `uv.lock` or a working hash tool leaves
        # no hash file behind, which `_dep_check_uv_project` already treats as
        # "cannot judge staleness" rather than as a false positive.
        local _xr_refs _xr_hash
        _xr_refs="$(_dep_excalidraw_refs)"
        if [ -n "$_xr_refs" ] && [ -f "${_xr_refs}/uv.lock" ]; then
          _xr_hash="$(_dep_sha256 "${_xr_refs}/uv.lock")"
          if [ -n "$_xr_hash" ]; then
            mkdir -p "$(dirname "$(_dep_excalidraw_lock_hash_file)")" 2>/dev/null
            printf '%s\n' "$_xr_hash" > "$(_dep_excalidraw_lock_hash_file)"
          fi
        fi
      fi
      [ "${SETUP_ALL:-0}" = "1" ] || echo "$(_dep_indent)installed."
      return 0
    fi
  else
    _dep_install_statusline && { [ "${SETUP_ALL:-0}" = "1" ] || echo "$(_dep_indent)installed."; return 0; }
  fi
  return 1
}

# ─── The OTHER installer, and why there are exactly two ──────────────────────
#
# `install_dep` refuses every native row above, and that refusal is right: there
# is no argv bionic could run to install a plugin, because installing a plugin
# is the CLI's own act. What the refusal did NOT do is give anybody a way to ASK
# for one. Setup's first step grew its own copy of the question, and when a
# when-needed row turned out to be native too (`impeccable`, the design route's
# dependency) the just-in-time offer had nothing to call and printed a command
# for the user to paste instead — an offer with no answer, for the one class of
# tool the ratified policy says to install at the moment of need (D-B, AC-11).
#
# So this is that missing entry point, and it is deliberately a SIBLING of
# install_dep rather than a branch inside it. The two differ in every part that
# matters — who executes the install, what the plan sentence is, and whether the
# result is usable in the session that asked — and folding them together would
# be the second-installer kludge the ownership table exists to prevent. What
# they share is the only thing that must not fork: the consent gate, which is
# `_dep_consent` here exactly as it is there.
#
# CONSENT, THEN THE CLI, THEN THE ONE THING THE USER HAS TO KNOW. The plan is
# printed before the question and run after it, from the same string. The `--yes`
# is not a consent bypass: it suppresses the CLI's own second prompt about a
# decision this function has already had with the user, and without it a
# consented install would sit waiting on a question nobody can see.
#
# THE CAVEAT IS THE POINT OF THE THIRD LINE. A plugin the CLI installs mid-run
# is not loaded into the session that asked for it until the plugins are re-read.
# Saying so is the one line that changes what the user does next, which is
# exactly the bar the voice contract sets for a caveat.
#
# Callers: setup.sh's first step (bionic itself) and jit.sh's `jit_offer` for a
# native `when-needed` row. Both reach the CLI through this function and nowhere
# else.
# Is this catalog registered on this machine? Read from the CLI's own list, not
# guessed from a re-add's error text: `claude plugin marketplace add` on an
# already-registered catalog exits NON-ZERO with "already" in the message, and a
# routine that reads success out of that string is a routine that reads success
# out of any message containing it. jq missing, or the file missing, both mean
# "cannot tell" — non-zero, so the add is attempted; an add that turns out to be
# unnecessary is a no-op, while a skipped add that was necessary is an install
# that cannot resolve.
_dep_marketplace_known() {  # <catalog>
  local catalog="${1:-}" file
  [ -n "$catalog" ] || return 1
  _dep_have jq || return 1
  file="$(_dep_known_marketplaces)"
  [ -f "$file" ] || return 1
  [ "$(jq -r --arg n "$catalog" 'has($n)' "$file" 2>/dev/null)" = "true" ]
}


# ─── The row the registry lost, and the cache that outlived it ───────────────
#
# WHY THIS IS NOT A SECOND INSTALLER (plan A-15; slice-0 ruling §8, the open
# question it left the orchestrator). D1 rules that a natively-installed plugin
# has exactly one installer — the CLI — and `install_dep` refuses every native
# row on that ground. Nothing below installs anything. No network is touched, no
# archive is unpacked, and not one file belonging to the plugin is created,
# moved or rewritten: the plugin's own files are already on this machine, in the
# directory the CLI itself unpacked them into, and the only thing missing is the
# line of bookkeeping that says so. Putting that line back repairs the CLI's
# RECORD; it is not a second way to obtain the code, which is what D1 is about.
# The cost of pretending otherwise was measured rather than argued: `setup --all`
# over a machine in exactly this state re-downloaded a plugin whose bytes on disk
# were already correct (record/wave-01-plugin-only/s00-registry-drop.md §4,
# `CACHE VERDICT: CHANGED`).

# WHERE THE CLI UNPACKS A PLUGIN: one level per catalog, one per plugin, one per
# build. Rooted in the claude home like every other path in this file and given
# no override of its own, so a suite that moves the home moves this with it and
# nothing has to be told twice.
_dep_plugin_cache_dir() {  # <name> -> the cache directory for this row
  local name="${1:-}" marketplace
  [ -n "$name" ] || return 1
  marketplace="$(dep_marketplace "$name" 2>/dev/null)" || return 1
  [ -n "$marketplace" ] || return 1
  printf '%s/plugins/cache/%s/%s\n' "$(_dep_claude_home)" "$marketplace" "$name"
}

# THE BASENAME IS THE VERSION, AND THAT IS THE RULE FOR PICKING ONE. Every row
# this machine's registry carries records a `version` equal to the basename of
# its `installPath` — `4.1.1` where the catalog pins a version, `41bbe19d1a1a`
# where it pins a commit — so a directory name is not a guess at the version, it
# is where the CLI keeps it. A cache holds SEVERAL builds more often than not:
# an update leaves the build it replaced, and `claude plugin install bionic@bionic`
# materialises a bare-sha directory for every sha-pinned plugin in the catalog
# without registering any of them (measured directly — the sha directory appears
# on a machine whose row stays absent across that command; see the probe in this
# slice's report). Newest-first alone therefore picks the CLI's leftover over the
# build the machine was actually running, which is how the first cut of this
# function restored a row naming a directory that had not existed ten seconds
# earlier.
#
# SO SELF-CONSISTENCY DECIDES, AND RECENCY ONLY BREAKS THE TIE. A build whose
# directory name equals the version its own `plugin.json` declares is a build
# installed under that version — the shape a version-pinned install leaves, and
# the shape the lost row named. A catalog that pins commits ships no such
# agreement (the two anthropic packs carry no `plugin.json` in the cache at all),
# and there the newest is both the only available answer and the right one: it is
# what the registry records for those rows today.
#
# `ls -1t` and not `stat`: the ordering is the same on BSD and GNU and costs one
# process rather than one per entry.
dep_cached_build() {  # <name> -> the cached build a restore should name
  local name="${1:-}" dir entry newest="" manifest declared
  dir="$(_dep_plugin_cache_dir "$name")" || return 1
  [ -d "$dir" ] || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -d "${dir}/${entry}" ] || continue
    [ -n "$newest" ] || newest="${dir}/${entry}"
    manifest="${dir}/${entry}/.claude-plugin/plugin.json"
    [ -f "$manifest" ] || continue
    _dep_have jq || continue
    declared="$(jq -r '.version // empty' "$manifest" 2>/dev/null)"
    if [ -n "$declared" ] && [ "$declared" = "$entry" ]; then
      printf '%s/%s\n' "$dir" "$entry"
      return 0
    fi
  done <<< "$(ls -1t "$dir" 2>/dev/null)"
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
  return 0
}

# THE STATE THE FIELD REPORT DESCRIBES, as one question rather than two facts
# about one name: this catalog's row is not in the registry, and the plugin's
# files are still where the CLI put them. The cache is what tells it apart from
# never-installed — a machine that never had the plugin has no directory there —
# and that distinction is the whole reason a probe reading the registry alone
# cannot see this state and offers a fresh install instead.
#
# `absent` AND NOT `other`. `_dep_native_registry_state` answers about the row's
# OWN catalog: a name registered under somebody else's catalog is present, is
# loading, and is nobody's row to restore. A registry that cannot be read at all
# answers `unknown`, and an unknown is never treated as a missing row.
dep_registry_row_restorable() {  # <name>
  local name="${1:-}"
  [ -n "$name" ] || return 1
  [ "$(dep_field "$name" kind 2>/dev/null)" = "native" ] || return 1
  [ "$(_dep_native_registry_state "$name")" = "absent" ] || return 1
  dep_cached_build "$name" >/dev/null 2>&1
}

# THE COMMIT THE CATALOG PINS, read out of the clone the CLI keeps for that
# catalog rather than out of this repo's own manifest — the row may belong to
# somebody else's catalog (`document-skills` does), and this file must not
# assume bionic's. `known_marketplaces.json` names the clone: `installLocation`
# is the checkout itself for a directory-source feed and a cached clone for a
# git one. A catalog that is not registered, a clone with no manifest, or an
# entry that pins no commit all answer with nothing — and nothing is the right
# answer, because `gitCommitSha` is a field this machine's registry already
# carries as null on rows whose source pins no commit. Nothing is invented to
# fill it.
dep_marketplace_sha() {  # <name> -> the pinned commit, or nothing
  local name="${1:-}" marketplace file loc manifest
  [ -n "$name" ] || return 1
  _dep_have jq || return 1
  marketplace="$(dep_marketplace "$name" 2>/dev/null)" || return 1
  file="$(_dep_known_marketplaces)"
  [ -f "$file" ] || return 1
  loc="$(jq -r --arg n "$marketplace" '.[$n].installLocation // empty' "$file" 2>/dev/null)"
  [ -n "$loc" ] || return 1
  manifest="${loc}/.claude-plugin/marketplace.json"
  [ -f "$manifest" ] || return 1
  jq -r --arg n "$name" \
    '(.plugins // []) | map(select(.name == $n)) | (.[0].source.sha // empty)' \
    "$manifest" 2>/dev/null | head -1
}

# THE REPAIR ITSELF. One consented act, the same shape every other mutating
# entry point in this file has: the plan is printed before the question and run
# after it, and the plan names both halves of what is true, because the reason
# to say yes to this rather than to an install is precisely that nothing is
# fetched.
#
# TWO STORES, NOT ONE. `installed_plugins.json` decides what LOADS, and
# `settings.json`'s `enabledPlugins` decides whether a loaded plugin is switched
# on. They disagree freely — run 4 of the ruling deleted the row and found the
# flag still `true` — so a restore that wrote only the row would be correct on
# that machine and would leave a differently-broken one registered and switched
# off. The flag is written only when it is not already true, so an ordinary
# machine's settings file is not rewritten to say what it already says.
#
# `_dep_settings_write_jq` WRITES BOTH, despite its name: it is this file's one
# atomic jq-through-a-temp-file writer, mode preserved and the original left
# untouched on any failure, and a second copy of it for the registry would be
# the duplication the ownership table exists to prevent.
restore_plugin_row() {  # <name>
  local name="${1:-}" marketplace id build version sha reg settings now
  [ -n "$name" ] || { echo "deps.sh: restore_plugin_row needs a plugin name" >&2; return 1; }
  _dep_have jq || {
    echo "$(_dep_indent)jq is not on PATH, so bionic cannot read or write the list of installed plugins."
    return 1
  }
  marketplace="$(dep_marketplace "$name" 2>/dev/null)" || marketplace=""
  [ -n "$marketplace" ] || marketplace="${BIONIC_DEP_MARKETPLACE:-bionic}"
  id="${name}@${marketplace}"
  build="$(dep_cached_build "$name")" || {
    echo "$(_dep_indent)${name}: no files are left in the plugin cache, so there is no record to restore."
    return 1
  }
  version="${build##*/}"

  if [ "${SETUP_ALL:-0}" != "1" ]; then
    echo "$(_dep_indent)${name} — the plugin's files are still on disk at ${build}, and only its entry in the list of installed plugins is missing; bionic would write that entry back and download nothing."
  fi
  _dep_consent "$(_dep_indent)Restore ${name}'s entry now?"
  case $? in
    0) ;;
    2) _dep_not_asked "$name"; return 2 ;;
    *) echo "$(_dep_indent)declined — ${name} stays unregistered."; return 1 ;;
  esac

  reg="$(_dep_installed_json)"
  mkdir -p "${reg%/*}" 2>/dev/null || true
  [ -f "$reg" ] || printf '%s\n' '{"version":2,"plugins":{}}' > "$reg"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  sha="$(dep_marketplace_sha "$name" 2>/dev/null)" || sha=""

  # THE SHAPE IS THIS MACHINE'S OWN (ruling §3): `"version": 2`, and each key
  # holding an ARRAY of entries rather than an object. Written with the fields a
  # real install writes, and `gitCommitSha` omitted rather than nulled when the
  # catalog pins no commit.
  if ! _dep_settings_write_jq "$reg" \
      '.plugins = ((.plugins // {}) | .[$k] = [ {"scope":"user","installPath":$p,"version":$v,"installedAt":$t,"lastUpdated":$t} + (if $s == "" then {} else {"gitCommitSha":$s} end) ])' \
      --arg k "$id" --arg p "$build" --arg v "$version" --arg t "$now" --arg s "$sha"; then
    echo "$(_dep_indent)${name}: the entry could not be written to ${reg}."
    return 1
  fi

  settings="$(_dep_settings_file)"
  [ -f "$settings" ] || echo '{}' > "$settings"
  if [ "$(jq -r --arg k "$id" '.enabledPlugins[$k] // empty' "$settings" 2>/dev/null)" != "true" ]; then
    if ! _dep_settings_write_jq "$settings" \
        '.enabledPlugins = ((.enabledPlugins // {}) | .[$k] = true)' --arg k "$id"; then
      echo "$(_dep_indent)${name}: the entry was restored, but it could not be switched on in ${settings}."
      return 1
    fi
  fi

  echo "$(_dep_indent)${name} ${version} — entry restored from the plugin cache; nothing was downloaded."
  [ "${SETUP_ALL:-0}" = "1" ] || echo "$(_dep_indent)Takes effect after /reload-plugins or a new session."
  SETUP_PLUGIN_CHANGED=yes
  return 0
}
install_plugin_native() {  # <name>
  local name="${1:-}" marketplace id source add_first=no
  [ -n "$name" ] || { echo "deps.sh: install_plugin_native needs a plugin name" >&2; return 1; }
  # THE CHEAPER TRUE ANSWER FIRST, AND BEFORE THE CLI GUARD BELOW. A machine
  # whose only fault is a lost registry row does not need an install and does not
  # need the CLI to be on PATH to have the row put back — asking for a binary
  # this branch will not run would refuse a repair on a machine that can take it.
  # Every caller reaches the right act by asking for the same thing: setup's
  # extras step, a just-in-time offer and step 1 alike say "make this plugin
  # usable", and which act that is, is a fact about the machine rather than about
  # the caller. See the ownership note above `_dep_plugin_cache_dir` for why this
  # is a repair of the CLI's record and not the second installer D1 forbids.
  if dep_registry_row_restorable "$name"; then
    restore_plugin_row "$name"
    return $?
  fi
  # THE ONE EXTERNAL THIS FILE USED TO CALL UNGUARDED (critic F-5). `jq`, `npm`
  # and `brew` all pass through `_dep_have` first; these two did not, so a machine
  # without the CLI got `deps.sh: line 664: claude: command not found` — a library
  # filename and a line number on a user's terminal, which is the exact class of
  # display this wave exists to remove and the one class no source lint can see,
  # because bash writes the string at runtime. Guarded BEFORE the plan is printed:
  # an offer whose yes cannot be honoured is a worse thing to show than no offer.
  _dep_have claude || {
    echo "$(_dep_indent)the Claude Code CLI is not on PATH — bionic cannot install a plugin without it."
    return 1
  }
  # The row's own catalog, with the constant as the fallback for the one caller
  # that has no row at all: setup's first step installs `bionic` itself.
  marketplace="$(dep_marketplace "$name" 2>/dev/null)" || marketplace=""
  [ -n "$marketplace" ] || marketplace="${BIONIC_DEP_MARKETPLACE:-bionic}"
  id="${name}@${marketplace}"

  # A CATALOG THE CLI HAS NEVER HEARD OF CANNOT RESOLVE AN INSTALL FROM IT, so
  # the registration is part of this plan rather than a prerequisite the user is
  # left to discover from an error. It is printed in the same sentence and
  # covered by the same single question: one decision — "put this plugin on my
  # machine" — never two.
  source="$(dep_marketplace_source "$name" 2>/dev/null)" || source=""
  if [ -n "$source" ] && ! _dep_marketplace_known "$marketplace"; then add_first=yes; fi

  if [ "${SETUP_ALL:-0}" != "1" ]; then
    if [ "$add_first" = "yes" ]; then
      echo "$(_dep_indent)${name} — not installed; bionic would run: claude plugin marketplace add ${source} && claude plugin install ${id} --scope user --yes"
    else
      echo "$(_dep_indent)${name} — not installed; bionic would run: claude plugin install ${id} --scope user --yes"
    fi
  fi
  _dep_consent "$(_dep_indent)Install ${name} now?"
  case $? in
    0) ;;
    2) _dep_not_asked "$name"; return 2 ;;
    *) echo "$(_dep_indent)declined — ${name} stays absent."; return 1 ;;
  esac

  # The add's own exit status is NOT the verdict. It fails on an
  # already-registered catalog — which is the case `_dep_marketplace_known` could
  # not read on a machine without jq — and the install below is the honest test
  # of whether the catalog is usable. The CLI's own stderr has already reached
  # the transcript either way, so nothing is swallowed silently.
  local quiet_log="${BIONIC_INSTALL_LOG:-${TMPDIR:-/tmp}/bionic-install.log}"
  if [ "$add_first" = "yes" ]; then
    claude plugin marketplace add "$source" >>"$quiet_log" 2>&1 || true
  fi

  if claude plugin install "$id" --scope user --yes >>"$quiet_log" 2>&1; then
    [ "${SETUP_ALL:-0}" = "1" ] || echo "$(_dep_indent)Takes effect after /reload-plugins or a new session."
    SETUP_PLUGIN_CHANGED=yes
    return 0
  fi
  return 1
}

# ─── Remove ──────────────────────────────────────────────────────────────────

# THE COUNTERPART TO `install_plugin_native`, and it exists because the installer
# shipped without one (six-axis review A-2). Same shape, same rule, opposite
# direction: the plan is printed before the question and run after it, from the
# same string, and `--yes` suppresses the CLI's second prompt about a decision
# this function has already had with the user — never the first one.
#
# NO PRESENCE CHECK HERE. The caller establishes presence (remove.sh asks
# `check_dep` before it walks a row), exactly as it does for every other kind:
# a function that re-probed would be a second opinion about a fact the table
# already owns.
remove_plugin_native() {  # <name>
  local name="${1:-}" marketplace id
  [ -n "$name" ] || { echo "deps.sh: remove_plugin_native needs a plugin name" >&2; return 1; }
  # Same guard, same reason as install_plugin_native (critic F-5), and it matters
  # more here: remove.sh's standalone door exists for a machine where bionic's
  # world is partly gone, which is exactly where the CLI may already be missing.
  _dep_have claude || {
    echo "$(_dep_indent)the Claude Code CLI is not on PATH — bionic cannot uninstall a plugin without it."
    return 1
  }
  # The row's catalog, for the reason the installer takes it from there: an id
  # composed against a constant is an id the CLI cannot resolve for the two rows
  # another catalog serves.
  marketplace="$(dep_marketplace "$name" 2>/dev/null)" || marketplace=""
  [ -n "$marketplace" ] || marketplace="${BIONIC_DEP_MARKETPLACE:-bionic}"
  id="${name}@${marketplace}"

  echo "$(_dep_indent)${name}: bionic would run: claude plugin uninstall ${id} --yes"
  _dep_consent "$(_dep_indent)Remove ${name} now?"
  case $? in
    0) ;;
    2) _dep_not_asked_left "$name"; return 2 ;;
    *) echo "$(_dep_indent)declined — ${name} left in place."; return 1 ;;
  esac

  claude plugin uninstall "$id" --yes || return 1
  return 0
}

# WHOSE COPY IS THIS? (critic F-4.) `_dep_check_native` matches on the NAME half
# across catalogs, deliberately — S3 re-points bionic's own marketplace and that
# match is what survives it — so "present" says nothing about who installed what
# is present. The teardown needs the other question, and only the teardown does:
# a `<name>@bionic` key is a plugin bionic's own route installed and nothing else
# will ever remove; a `<name>@somebody-else` key is the user's own, and removing
# it would be a mutation nobody asked for under an id that does not exist.
#
# Three states rather than a yes/no, because "not ours" and "not there at all"
# are different sentences to a reader and only one of them is about a catalog:
#
#   ours     `<name>@<bionic's marketplace>` is a key in the registry
#   other    the name is there, under somebody else's catalog
#   absent   no key of that name at all
#   unknown  the registry could not be read (no jq)
#
# "OURS" IS THE ROW'S CATALOG, NOT A CONSTANT (epic-18 T4). `document-skills` is
# a plugin bionic's own extras step installs, from `anthropic-agent-skills`.
# Asked about `document-skills@bionic` it would answer `other` — somebody else's
# copy — and the teardown would leave behind a plugin bionic put there, which is
# the same defect one catalog over from the one this function was written for.
_dep_native_registry_state() {  # <name> -> ours|other|absent|unknown
  local name="${1:-}" id file out marketplace
  [ -n "$name" ] || { echo unknown; return 0; }
  marketplace="$(dep_marketplace "$name" 2>/dev/null)" || marketplace=""
  [ -n "$marketplace" ] || marketplace="${BIONIC_DEP_MARKETPLACE:-bionic}"
  id="${name}@${marketplace}"
  _dep_have jq || { echo unknown; return 0; }
  file="$(_dep_installed_json)"
  [ -f "$file" ] || { echo absent; return 0; }
  out="$(jq -r --arg n "$name" --arg k "$id" '
      (.plugins // {}) as $p
      | if ($p | has($k)) then "ours"
        elif ([ $p | keys[] | select((split("@")[0]) == $n) ] | length) > 0 then "other"
        else "absent" end' "$file" 2>/dev/null)" || out=""
  case "$out" in ours|other|absent) echo "$out" ;; *) echo unknown ;; esac
}

_dep_remove_argv() {  # <name> — one token per line
  local name="$1" mech target
  mech="$(dep_field "$name" install_fn_or_check)"
  target="$(_dep_locator_target "$(dep_field "$name" source_url)")"
  case "$mech" in
    npm-global) printf '%s\n' npm uninstall -g "$target" ;;
    uv-tool)    printf '%s\n' uv tool uninstall "$target" ;;
    mcp-server) printf '%s\n' claude mcp remove "$name" -s user ;;
    # The whole directory the install created, and nothing above it. Named in
    # the plan the user consents to, exactly as `playwright-browser`'s cache
    # removal is — a recursive delete the user cannot see the path of is not a
    # consented delete.
    github-skill) printf '%s\n' rm -rf "$(_dep_skills_dir)/${name}" ;;
    *)          return 1 ;;
  esac
}

# THE ONE ENTRY POINT FOR "what happens to this dependency", and its answer is
# an exit code with three meanings, not two:
#
#   0  this row's policy was carried out — removed, or kept with the user told why
#   2  left in place by policy, nothing asked and nothing declined (critic F-4:
#      a same-named plugin from a catalog bionic never installed from)
#   1  not done — declined, or a mechanism that failed or could not be read
#
# The caller counts 0 and 2 as settled and 1 as outstanding; remove.sh's summary
# is built on that split.
# ─── What a teardown asks, which is not what a report asks ───────────────────
#
# A REPORT asks "is this row in the state setup leaves it in". A TEARDOWN asks
# "is there anything of bionic's here to take off". For nearly every row those
# are the same question and this function answers both with the same probe.
#
# THEY CAME APART ON THE STATUS LINE (1.4.4 T5, t5-report.md R-1). The moment
# `_dep_check_statusline` stopped calling `npx ccstatusline@latest` healthy, the
# pre-1.4.4 machine started reporting the row absent — while still carrying the
# command bionic wrote into settings.json, the layout bionic copied into
# ~/.config/ccstatusline, and possibly the package bionic installed. Asked the
# HEALTH question, `/bionic:remove` called that machine "already clean" and
# walked away from all three, on precisely the machines this release exists for.
# A teardown keyed on health is a teardown that stops working the instant a
# probe gets stricter, which is backwards.
_dep_statusline_leftovers() {  # <name> -> 0 when this machine carries statusline state bionic wrote
  local name="${1:-ccstatusline}" settings cmd
  settings="$(_dep_settings_file)"
  if [ -f "$settings" ] && _dep_have jq; then
    cmd="$(jq -r '.statusLine?.command? // "" | tostring' "$settings" 2>/dev/null)"
    # THE NAME, NOT THE KEY. A `.statusLine` pointing at the user's own renderer
    # is not bionic's to remove and must survive a teardown; every string bionic
    # has ever written there names ccstatusline, the npx form included.
    case "$cmd" in *ccstatusline*) return 0 ;; esac
  fi
  [ -d "$(_dep_ccstatusline_config_dir)" ] && return 0
  case "$(_dep_check_npm_global "$name")" in "yes|"*) return 0 ;; esac
  return 1
}

dep_teardown_state() {  # <name> -> yes | no | unknown
  local name="${1:-}" raw
  if [ "$(dep_field "$name" install_fn_or_check)" = "statusline" ]; then
    if _dep_statusline_leftovers "$name"; then echo "yes"; else echo "no"; fi
    return 0
  fi
  raw="$(check_dep "$name")" || return 1
  raw="${raw#present=}"
  echo "${raw%%|*}"
}

remove_dep() {  # <name>
  local name="${1:-}" behavior plan line rc
  local -a argv=()
  behavior="$(dep_field "$name" removal_behavior)" || return 1

  case "$behavior" in
    keep-shared)
      # R-1: `keep-shared` is this table's word for the policy, not the user's.
      # What reaches the terminal is what was decided and why.
      echo "$(_dep_indent)${name}: kept — shared with other tools, bionic never removes it."
      return 0
      ;;
    native-uninstall-offer)
      # TWO NATIVE BEHAVIOURS, NOT ONE (six-axis review A-2). Both kinds of row
      # are plugins the CLI installed, and that is where the resemblance ends.
      #
      #   a row bionic DECLARES (class core, in plugin.json's dependencies):
      #     removing bionic removes it — the uninstall and prune at the end of
      #     the teardown are what take it, and asking here would be a second
      #     question about one decision.
      #
      #   a row bionic does NOT declare (impeccable at class when-needed, and
      #   the two anthropic-agent-skills packs at class extra):
      #     `install_plugin_native` can put it on a machine mid-session from a
      #     route's offer, and A-3.1 rules that the marketplace entry declares no
      #     dependency. Nothing else will ever remove it. This branch used to
      #     tell that user their plugin uninstall would take it, which was false
      #     by construction and left the plugin behind after a full, all-yes
      #     teardown.
      if [ "$(dep_field "$name" class)" = "core" ]; then
        echo "$(_dep_indent)${name}: bionic declares this plugin, so removing bionic removes it too."
        return 0
      fi
      # AND THE ID HAS TO BE THE ONE THE REGISTRY HOLDS (critic F-4). The presence
      # probe two functions up matches the bare name across catalogs, so a user's
      # own `impeccable` from another catalog read as present and was offered for
      # removal under `impeccable@bionic` — an id that does not exist. The CLI
      # answered "not installed", the non-zero landed in the skipped bucket, and a
      # user who said yes was reported as having skipped it.
      #
      # There is no question to ask about somebody else's copy, so none is asked:
      # exit 2 says "left in place by policy, nothing was declined", which is the
      # bucket the caller counts as clean rather than as a refusal.
      case "$(_dep_native_registry_state "$name")" in
        ours)
          remove_plugin_native "$name"; return $? ;;
        other)
          echo "$(_dep_indent)${name}: installed from another catalog — bionic did not install it and leaves it alone."
          return 2 ;;
        absent)
          echo "$(_dep_indent)${name}: bionic did not install this plugin, so there is nothing here to remove."
          return 2 ;;
        *)
          echo "$(_dep_indent)${name}: the list of installed plugins could not be read, so ${name} is left in place."
          return 1 ;;
      esac
      ;;
  esac

  case "$(dep_field "$name" install_fn_or_check)" in
    playwright-browser)
      plan="rm -rf $(_dep_playwright_cache)"
      ;;
    # THE VENV AND ITS HASH FILE, AND NOTHING ELSE. The skill's own files ship inside
    # the plugin, so they leave when the plugin does; what a teardown has to account
    # for here is the stable-path venv `uv sync` built (VENV slice, AC-17 — it is no
    # longer inside the plugin's own tree, so no plugin uninstall knows about it
    # either) and the lock-hash file written beside it.
    uv-project)
      plan="rm -rf $(_dep_excalidraw_venv_dir) $(_dep_excalidraw_lock_hash_file)"
      ;;
    pnpm-store)
      echo "$(_dep_indent)${name}: lives in the shared pnpm store — removing it would evict a cache other projects hard-link from; leaving it."
      return 0
      ;;
    statusline)
      # Fix step 3 (bug-ccstatusline-npx-per-render.md): the install arm now
      # runs a real `npm install -g`, so the removal plan says so too — a
      # settings.json clear alone would leave the global package on disk.
      # review-e E-2: this is the sentence printed at the moment of consent,
      # on BOTH the `--all` and `--only tool:ccstatusline` doors — `--only`
      # never shows the page bullet `_rm_item_verb` builds, so this is the
      # only place that door's user reads what the clear will do. It has to
      # say the same conditional thing that bullet does (review-d D-1):
      # `.statusLine` is cleared only if it still names ccstatusline.
      plan="npm uninstall -g $(_dep_locator_target "$(dep_field "$name" source_url)"), clear .statusLine from $(_dep_settings_file) only if it still names ccstatusline, and remove $(_dep_ccstatusline_config_dir)"
      ;;
    *)
      while IFS= read -r line; do argv+=("$line"); done < <(_dep_remove_argv "$name") || true
      [ "${#argv[@]}" -gt 0 ] || { echo "deps.sh: no removal mechanism for ${name}" >&2; return 1; }
      plan="${argv[*]}"
      # AC-5: notebooklm's skill dir, named in the plan alongside the uv-tool
      # uninstall — one consent covers both halves, same as the install arm.
      [ "$name" = "notebooklm" ] && plan="${plan} && rm -rf $(_dep_claude_home)/skills/notebooklm"
      ;;
  esac

  echo "$(_dep_indent)${name}: bionic would run: ${plan}"
  _dep_consent "$(_dep_indent)Remove ${name} now?"
  case $? in
    0) ;;
    2) _dep_not_asked_left "$name"; return 2 ;;
    *) echo "$(_dep_indent)declined — ${name} left in place."; return 1 ;;
  esac

  if [ "${#argv[@]}" -gt 0 ]; then
    "${argv[@]}"
    rc=$?
    [ "$name" = "notebooklm" ] && rm -rf "$(_dep_claude_home)/skills/notebooklm"
    return "$rc"
  else
    case "$(dep_field "$name" install_fn_or_check)" in
      playwright-browser) rm -rf "$(_dep_playwright_cache)" ;;
      uv-project)
        rm -rf "$(_dep_excalidraw_venv_dir)" "$(_dep_excalidraw_lock_hash_file)"
        ;;
      statusline)
        # BOTH HALVES (AC-3). The settings-clear used to `return 0` the
        # instant settings.json was absent, which skipped the config purge
        # below it entirely whenever the two halves came apart — exactly the
        # shape a machine with the config directory but no `.statusLine` key
        # is in. The two removals are independent now: an absent settings
        # file is nothing to clear, not a reason to stop.
        local settings dir pkg
        # THE GLOBAL PACKAGE, THIRD (epic-21 Fix step 3). Best-effort: npm
        # missing or the uninstall failing is not a reason to abandon the two
        # removals below it — a package that never installed cleanly is not
        # made worse by a settings.json this still clears.
        pkg="$(_dep_locator_target "$(dep_field "$name" source_url)")"
        _dep_have npm && npm uninstall -g "$pkg" >/dev/null 2>&1
        # THE NAME, NOT THE UNION (review-d D-1). `dep_teardown_state` asks
        # whether ANY of three facts is true — the command names ccstatusline,
        # OR the config directory exists, OR the package is installed —
        # because the directory and the package are bionic's to remove even
        # once the command has moved on. That union is licence to run this
        # whole arm; it is not licence for what THIS clear does. A `.statusLine`
        # pointing at the user's own renderer is not bionic's, and must survive
        # this teardown even when it is reached because of the OTHER two
        # facts — so the delete is conditional on the one fact that makes it
        # bionic's, exactly like `_dep_statusline_leftovers`'s own command arm.
        settings="$(_dep_settings_file)"
        if [ -f "$settings" ]; then
          _dep_have jq || return 1
          _dep_settings_write_jq "$settings" \
            'if ((.statusLine?.command? // "") | tostring | test("ccstatusline")) then del(.statusLine) else . end' \
            || return 1
        fi
        # THE SAME NEVER-LIST remove.sh's `_rm_purge_dir` enforces, its own
        # copy rather than a call across files — this library must stay
        # sourceable with no remove.sh in the process (tests/plugin-lib.test.sh
        # used to drive remove_dep directly to prove that; it was deleted at
        # 8582861, epic-18 wave-03, and nothing replaced the drive), the same
        # reason `bionic_link_target` is duplicated rather than shared.
        dir="$(_dep_ccstatusline_config_dir)"
        case "$dir" in
          */.bionic|*/.bionic/*|""|/|"$HOME") ;;
          *) rm -rf "$dir" ;;
        esac
        ;;
    esac
  fi
}
