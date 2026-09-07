#!/bin/bash
# VERSION COMPARE — L-DETECT/4.2 (spec AC-19).
#
# WHAT THIS SUITE OWNS. `payload/scripts/lib/detect.sh`'s `version_compare`, a
# semver-shaped three-int ordering primitive, and the one caller it feeds:
# `detect_plugin_latest`'s installed-vs-marketplace compare, which used to be
# STRING inequality (`[ "$installed" = "$latest" ]` → current, else lag
# unconditionally) — so an installed build NEWER than the marketplace's cached
# clone read as "behind" it. `detect_plugin_latest` now reports a third state,
# `ahead`, for exactly that case.
#
# NOT `detect_registry_sha_lag`. That function compares git commit SHAs for a
# directory-source feed and has no version field to order — it keeps its
# existing states (match/lag/not-in-repo/unknown) unchanged. Only the git-feed,
# marketplace-clone compare in `detect_plugin_latest` gains `ahead`.
#
# WHAT THIS SUITE DOES NOT OWN. How doctor.sh RENDERS an `ahead` row — that is
# a later slice in this wave (the DOCTOR slice); this suite only pins the
# library-level state, not doctor's presentation of it.
#
# HERMETIC, DIRECT-SOURCED (same posture as tests/detect-probes.test.sh):
# no network, no live ~/.claude. `version_compare` is a pure function, called
# through a `bash -c '. "$1"; shift; "$@"'` subshell so it never pollutes this
# suite's own environment. `detect_plugin_latest` is driven against fixture
# BIONIC_PLUGIN_ROOT / BIONIC_KNOWN_MARKETPLACES_FILE trees, never the real
# machine's.
#
# Usage: bash tests/version-compare.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
DETECT_SH="${REPO}/payload/scripts/lib/detect.sh"

command -v jq >/dev/null 2>&1 || { echo "version-compare.test.sh: jq is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sourced() {  # <fn> [args...] — run one detect.sh function in a clean subshell
  bash -c '. "$1"; shift; "$@"' _ "$DETECT_SH" "$@" 2>/dev/null
}

section "Section 1: version_compare — semver ordering, not string inequality"

if bash -n "$DETECT_SH" >/dev/null 2>&1; then ok "0: detect.sh passes bash -n"; else no "0: detect.sh passes bash -n"; fi

expect_eq "1: 1.4.0 vs 1.3.2 -> ahead"    "ahead"   "$(sourced version_compare 1.4.0 1.3.2)"
expect_eq "2: 1.3.2 vs 1.3.2 -> current"  "current" "$(sourced version_compare 1.3.2 1.3.2)"
expect_eq "3: 1.3.1 vs 1.3.2 -> lag"      "lag"     "$(sourced version_compare 1.3.1 1.3.2)"
expect_eq "4: 1.10.0 vs 1.9.0 -> ahead (numeric, not lexical)" \
  "ahead" "$(sourced version_compare 1.10.0 1.9.0)"
expect_eq "5: 1.9.0 vs 1.10.0 -> lag (the reverse of 4)" \
  "lag" "$(sourced version_compare 1.9.0 1.10.0)"
expect_eq "6: a prerelease suffix compares by its release numbers" \
  "lag" "$(sourced version_compare 9.9.9-rc.1 10.0.0)"

section "Section 2: detect_plugin_latest gains a real ahead state"

# A fixture PAYLOAD whose own plugin.json is NEWER than the marketplace clone's,
# which is the exact defect this slice closes: pre-fix, string inequality alone
# ("9.9.9" != "1.0.0") reported this machine as state=lag — a build newer than
# the marketplace copy told it was "behind".
make_payload() {  # <version> -> payload root on stdout
  local v="$1" dir
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/.claude-plugin" "$dir/hooks"
  jq -nc --arg v "$v" '{name:"bionic", version:$v}' > "$dir/.claude-plugin/plugin.json"
  printf '%s' "$dir"
}

make_marketplace() {  # <version> -> claude-home dir on stdout
  local v="$1" home clone
  home="$(mktemp -d -p "$TMP")"
  clone="$(mktemp -d -p "$TMP")"
  mkdir -p "$home/plugins" "$clone/.claude-plugin" "$clone/payload/.claude-plugin"
  # The clone's OWN marketplace.json, naming bionic's plugin source as the
  # plain relative path this repo's own manifest uses — same shape
  # tests/doctor-version.test.sh's make_git_marketplace_clone builds.
  jq -nc '{plugins:[{name:"bionic", source:"./payload"}]}' \
    > "$clone/.claude-plugin/marketplace.json"
  jq -nc --arg v "$v" '{name:"bionic", version:$v}' > "$clone/payload/.claude-plugin/plugin.json"
  jq -nc --arg loc "$clone" \
    '{bionic:{source:{"source":"github","repo":"example/bionic"}, installLocation:$loc}}' \
    > "$home/plugins/known_marketplaces.json"
  printf '%s' "$home"
}

run_detect_plugin_latest() {  # <installed-version> <marketplace-version>
  local payload home
  payload="$(make_payload "$1")"
  home="$(make_marketplace "$2")"
  BIONIC_PLUGIN_ROOT="$payload" BIONIC_CLAUDE_HOME="$home" sourced detect_plugin_latest
}

FACT_AHEAD="$(run_detect_plugin_latest 1.4.0 1.3.2)"
case "$FACT_AHEAD" in
  "plugin:latest state=ahead installed=1.4.0 latest=1.3.2 cause=-") ok "7: installed 1.4.0 vs marketplace 1.3.2 -> ahead" ;;
  *) no "7: installed 1.4.0 vs marketplace 1.3.2 -> ahead" "$FACT_AHEAD" ;;
esac

FACT_CURRENT="$(run_detect_plugin_latest 1.3.2 1.3.2)"
case "$FACT_CURRENT" in
  "plugin:latest state=current installed=1.3.2 latest=1.3.2 cause=-") ok "8: equal versions -> current" ;;
  *) no "8: equal versions -> current" "$FACT_CURRENT" ;;
esac

FACT_LAG="$(run_detect_plugin_latest 1.3.1 1.3.2)"
case "$FACT_LAG" in
  "plugin:latest state=lag installed=1.3.1 latest=1.3.2 cause=-") ok "9: installed behind the marketplace -> lag, unchanged" ;;
  *) no "9: installed behind the marketplace -> lag, unchanged" "$FACT_LAG" ;;
esac

finish
