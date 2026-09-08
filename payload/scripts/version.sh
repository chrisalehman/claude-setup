#!/bin/bash
# version.sh — the one-line answer to "what am I running" (epic-22 wave-01 slice 14,
# spec AC-E2.1). `/bionic:version` runs this and shows its output verbatim.
#
# WHAT THIS FILE OWNS. Nothing factual, the same posture doctor.sh states for itself:
# every field on the line is read out of detect.sh, never re-derived here. This script
# composes four already-owned facts into one line and nothing more —
#
#   bionic <version> (installed) · <sha or feed> · <install path> · <this checkout |
#   OTHER checkout | unregistered>
#
# — where:
#   <version>      plugin.json's `.version`, via `detect_plugin_integrity` — the same
#                  reader doctor.sh's header uses, so the two can never disagree.
#   <sha or feed>  the installed commit, 8 hex characters, when the registry can be
#                  compared against a real git tree; the feed kind ("directory"/"git")
#                  otherwise. Same match/lag/not-in-repo branching doctor.sh's header
#                  uses for PAYLOAD_SHA (detect_registry_sha_lag +
#                  detect_marketplace_feed_kind), composed fresh here rather than reread
#                  from doctor's own variables — this script never sources doctor.sh, a
#                  script sourcing another SCRIPT (not a library) is not this codebase's
#                  shape.
#   <install path> the marketplace's own source path when one is registered (the
#                  directory a directory-feed install actually runs), else the resolved
#                  plugin-install path.
#   <this checkout | OTHER checkout | unregistered>
#                  `detect_checkout_verdict` — the ONE site for this comparison,
#                  doctor.sh's own "plugin source:" row calls the same function, so this
#                  line and that row can never disagree either.
#
# EXIT 0, ALWAYS — for the same reason doctor.sh gives: this is a diagnosis (what is
# installed), never a mutation, and a diagnosis is not a failure.
#
# Executed, never sourced:  bash ${CLAUDE_PLUGIN_ROOT}/scripts/version.sh

set -uo pipefail

# No `dirname` here for the same reason detect.sh and doctor.sh give: a script that
# needs coreutils to locate itself dies on the exact broken machine it exists to report
# on.
_version_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}
VERSION_LIB="$(cd "$(_version_self_dir)" && pwd -P)/lib"

if [ ! -f "${VERSION_LIB}/detect.sh" ]; then
  echo "version.sh: cannot find ${VERSION_LIB}/detect.sh — the payload looks incomplete." >&2
  echo "            reinstall with: claude plugin install bionic@bionic" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "${VERSION_LIB}/detect.sh"

# THIS CHECKOUT'S OWN ROOT — the same three-levels-up climb doctor.sh's DOCTOR_REPO_ROOT
# uses (lib -> scripts -> payload -> repo root), resolved from THIS SCRIPT's own
# location and never from BIONIC_PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT: the "which tree is
# asking" question is about where this file physically lives, and an env override that
# redirected it would make the comparison answer a question nobody asked.
VERSION_REPO_ROOT="$(cd "${VERSION_LIB}/../../.." && pwd -P)"

# ─── The version ─────────────────────────────────────────────────────────────
PLUGIN_FACT="$(detect_plugin_integrity)"
PLUGIN_VERSION="${PLUGIN_FACT#plugin: version=}"; PLUGIN_VERSION="${PLUGIN_VERSION%% *}"

# ─── The commit or the feed ──────────────────────────────────────────────────
FEED_KIND="$(detect_marketplace_feed_kind)"

_version_is_repo() { ( cd "${1:-/nonexistent}" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); }

# THE TREE THE REGISTRY NAMES, NOT THIS PROCESS'S CWD — same reasoning as doctor.sh's
# DOCTOR_INSTALL_PATH: `detect_registry_sha_lag` compares against a directory, and the
# only directory that comparison means anything against is the one the CLI actually
# installed to, never wherever this script happened to be invoked from.
VERSION_INSTALL_PATH="$(detect_plugin_install_path bionic 2>/dev/null)" || VERSION_INSTALL_PATH=""
if [ -z "$VERSION_INSTALL_PATH" ] || ! _version_is_repo "$VERSION_INSTALL_PATH"; then
  _version_root_alt="$(plugin_root)"
  if _version_is_repo "$_version_root_alt"; then VERSION_INSTALL_PATH="$_version_root_alt"; fi
  [ -n "$VERSION_INSTALL_PATH" ] || VERSION_INSTALL_PATH="$_version_root_alt"
fi

REG_SHA_FACT="$(detect_registry_sha_lag "$VERSION_INSTALL_PATH")"
REG_SHA_STATE="${REG_SHA_FACT#*state=}"; REG_SHA_STATE="${REG_SHA_STATE%% *}"
REG_SHA_REG="${REG_SHA_FACT#*registry=}"; REG_SHA_REG="${REG_SHA_REG%% *}"
REG_SHA_REPO="${REG_SHA_FACT#*repo=}";    REG_SHA_REPO="${REG_SHA_REPO%% *}"

_version_sha8() { printf '%.8s' "${1:-}"; }
case "$REG_SHA_STATE" in
  match)       SHA_OR_FEED="$(_version_sha8 "$REG_SHA_REG")" ;;
  lag)
    if [ "$FEED_KIND" = "directory" ]; then
      SHA_OR_FEED="$(_version_sha8 "$REG_SHA_REPO")"
    else
      SHA_OR_FEED="$(_version_sha8 "$REG_SHA_REG")"
    fi ;;
  not-in-repo) SHA_OR_FEED="$(_version_sha8 "$REG_SHA_REG")" ;;
  *)           SHA_OR_FEED="$FEED_KIND" ;;
esac
[ -n "$SHA_OR_FEED" ] || SHA_OR_FEED="$FEED_KIND"

# ─── The install path ────────────────────────────────────────────────────────
#
# THE MARKETPLACE'S OWN PATH WINS WHEN THERE IS ONE — it names the directory a
# directory-feed install actually runs from, which is the more useful answer on
# exactly the machines where install path and marketplace path could differ.
MP_SOURCE_PATH="$(detect_marketplace_source_path)"; MP_SOURCE_STATE=$?
if [ "$MP_SOURCE_STATE" -eq 0 ] && [ -n "$MP_SOURCE_PATH" ]; then
  INSTALL_PATH_FIELD="$MP_SOURCE_PATH"
else
  INSTALL_PATH_FIELD="${VERSION_INSTALL_PATH:-unknown}"
fi

# ─── The checkout verdict ────────────────────────────────────────────────────
CHECKOUT_VERDICT="$(detect_checkout_verdict "$VERSION_REPO_ROOT")"

printf 'bionic %s (installed) · %s · %s · %s\n' \
  "$PLUGIN_VERSION" "$SHA_OR_FEED" "$INSTALL_PATH_FIELD" "$CHECKOUT_VERDICT"
exit 0
