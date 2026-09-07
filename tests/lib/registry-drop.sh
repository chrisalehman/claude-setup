#!/bin/bash
# tests/lib/registry-drop.sh — the registry-drop protocol (epic-22 wave-01 slice 0; REQ-S0/AC-S0.1).
#
# THE QUESTION. `.bionic/docs/ideas/dependent-plugin-registry-drop.md` records an
# observation on Chris's machine: `impeccable@bionic` was installed, its plugin
# cache was still on disk, and its row in the CLI's `installed_plugins.json` was
# gone — so doctor and setup, which read that registry, kept offering the install
# again. Nobody knows which act removes the row. Three suspects are named there
# and none is confirmed.
#
# THE METHOD IS A SNAPSHOT AROUND EVERY SUSPECT, and it is the only method that
# can answer this: a registry row is not observed to vanish, it is observed to be
# ABSENT, and the difference between the two is the action in between. So this
# script installs into a fresh HOME, brings every dependent row to present,
# snapshots the registry, then runs one suspect action at a time and snapshots
# again. The first action after which a dependent row is absent is the cause; if
# no action drops a row, that is a finding too, and the record then says what the
# rig could not exercise rather than declaring the seed wrong.
#
# WHAT COUNTS AS A DEPENDENT ROW. The three plugins bionic's own marketplace
# serves besides bionic itself: `superpowers` and `agent-skills`, which the CLI
# installs automatically because `payload/.claude-plugin/plugin.json` declares
# them as dependencies (they carry `"auto": true`), and `impeccable`, which is
# not declared and is installed on demand by `jit_offer` → `install_plugin_native`
# (no `auto` marker). That difference is deliberate in the fixture: the observed
# drop was of the row WITHOUT the marker, so a protocol that only installed the
# declared two could not have reproduced it.
#
# `document-skills` and `example-skills` are dependent rows of a DIFFERENT
# catalog (`anthropic-agent-skills`); they were present on the machine where the
# drop was seen and they were not the rows that vanished. They are out of this
# protocol's fixture, and that exclusion is a scope limit the record states.
#
# NOT HERMETIC, AND NEVER RUN BY tests/run.sh. It runs the real CLI and reaches
# GitHub. See the header of tests/lib/fresh-home.sh for what is isolated and what
# is deliberately not.
#
# Usage:
#     bash tests/lib/registry-drop.sh [--arm <name>] [--out <dir>] [--keep]
#
#   --arm <name>  suspects           (default) the five suspect actions (a)…(e)
#                 setup-restores     row absent + cache present, then setup --all
#                 marketplace-churn  the catalog stops serving a row, then refresh
#   --out <dir>   copy every snapshot and the rig log into <dir> when done
#   --keep        leave the scratch HOME in place (default: deleted, after --out)
#
# `suspects` is the protocol REQ-S0 names. The other two arms exist because the
# first run of `suspects` found no drop: they are the follow-ups that turn two of
# the resulting fog items into measurements instead of leaving them for a hand-run.
# macOS only as written — the cache-reuse check in `setup-restores` uses BSD
# `stat -f`.
#
# Exit status: 0 when the protocol ran to the end, whatever it found. A non-zero
# rc means the protocol itself broke — never "a row was dropped". The finding is
# the table, not the exit code, for the same reason the CLI's own repair verbs
# all exit 0 (record/epic-21-v1-ladder/fixit-dep-repair-measurement.md §3).

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fresh-home.sh"

OUT_DIR=""
KEEP=""
ARM="suspects"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --keep) KEEP="keep"; shift ;;
    --arm) ARM="${2:-}"; shift 2 ;;
    *) echo "registry-drop.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

DEPENDENTS="superpowers@bionic agent-skills@bionic impeccable@bionic"

# ─── The table, accumulated a row at a time ──────────────────────────────────
#
# One line per action: action | rows before | rows after | first missing row.
# "First missing" is computed from the two SNAPSHOTS, not from anything the
# action printed — an action that reports success while dropping a row is
# precisely the failure mode under investigation.
TABLE=""
FIRST_DROP=""          # the first action that removed a dependent row
FIRST_DROP_ROW=""

rows_line() {  # <label> -> the keys, comma-joined, or "(none)"
  local out; out="$(registry_rows "$1" | tr '\n' ' ')"
  out="$(echo "$out" | sed 's/ *$//; s/ /, /g')"
  [ -n "$out" ] || out="(none)"
  printf '%s' "$out"
}

# CAPTURE, THEN MATCH — never `registry_rows … | grep -q`. A producer piped into
# a `grep -q` that exits on its first hit takes SIGPIPE, and under `pipefail` that
# surfaces as rc 141 on a run that was in fact fine (memory: grep -q SIGPIPE under
# pipefail). The lists here are three lines long, so the cost of holding them in a
# variable is nothing and the failure mode is gone.
missing_dependents() {  # <before-label> <after-label> -> rows present before, absent after
  local before="$1" after="$2" d rb ra
  rb="$(registry_rows "$before")"; ra="$(registry_rows "$after")"
  for d in $DEPENDENTS; do
    case $'\n'"$rb"$'\n' in *$'\n'"$d"$'\n'*) ;; *) continue ;; esac
    case $'\n'"$ra"$'\n' in *$'\n'"$d"$'\n'*) continue ;; esac
    printf '%s\n' "$d"
  done
}

record_action() {  # <action-text> <before-label> <after-label> [note]
  local action="$1" before="$2" after="$3" note="${4:-}" miss first
  miss="$(missing_dependents "$before" "$after")"
  first="${miss%%$'\n'*}"
  [ -n "$first" ] || first="—"
  TABLE="${TABLE}| ${action} | $(rows_line "$before") | $(rows_line "$after") | ${first}${note:+ ${note}} |"$'\n'
  if [ "$first" != "—" ] && [ -z "$FIRST_DROP" ]; then
    FIRST_DROP="$action"; FIRST_DROP_ROW="$first"
  fi
  echo
  echo "### ${action}"
  echo "before (${before}): $(rows_line "$before")"
  echo "after  (${after}):  $(rows_line "$after")"
  echo "diff:"; registry_diff "$before" "$after" | sed 's/^/  /'
  echo "dependent rows missing after this action: ${miss:-none}"
}

banner() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# ─── arm `suspects` — the five suspect actions of the seed ───────────────────
arm_suspects() {
banner "0. fresh HOME, marketplace add, install bionic"
fh_init || { echo "registry-drop.sh: rig init failed"; exit 1; }
echo "scratch root : $FH_ROOT"
echo "HOME         : $HOME"
echo "CLAUDE_CONFIG_DIR: $CLAUDE_CONFIG_DIR"
echo "clone        : $FH_CLONE @ $FH_SRC_SHA"
echo "CLI          : $FH_CLAUDE_BIN — $("$FH_CLAUDE_BIN" --version 2>&1 | head -1)"

snapshot_registry 00-empty >/dev/null
echo; echo "--- claude plugin marketplace add \$clone ---"
fh_marketplace_add; echo "rc=$?"
echo; echo "--- claude plugin install bionic@bionic --scope user --yes ---"
fh_install_bionic; echo "rc=$?"
snapshot_registry 01-install >/dev/null
echo "rows after install: $(rows_line 01-install)"

banner "1. bring the dependent rows to present"
# WHICH VERB, MEASURED RATHER THAN CHOSEN. `setup --all` does not install a
# native row at all — `install_dep` refuses every one of them (deps.sh) and only
# `install_plugin_native` reaches the CLI — so the product's own path to a present
# `impeccable` row is the CLI install below, exactly as jit.sh composes it. The
# other two arrive with bionic itself, as the install line above reports.
echo "--- claude plugin install impeccable@bionic --scope user --yes ---"
fh_install_plugin impeccable; echo "rc=$?"
snapshot_registry 02-deps-present >/dev/null
echo "rows with every dependent present: $(rows_line 02-deps-present)"
echo
echo "impeccable's entry (no \"auto\" marker — a user-owned install, unlike the two declared deps):"
registry_entry 02-deps-present "impeccable@bionic"
echo "plugin cache on disk:"
ls -1 "$CLAUDE_CONFIG_DIR/plugins/cache/bionic" 2>/dev/null | sed 's/^/  /'
for p in bionic superpowers agent-skills impeccable; do
  echo "  cache/bionic/$p: $(ls -1 "$CLAUDE_CONFIG_DIR/plugins/cache/bionic/$p" 2>/dev/null | tr '\n' ' ')"
done

# ─── (a) plugin update, no version change ────────────────────────────────────
banner "2. suspect (a): claude plugin update bionic@bionic"
fh_update_bionic; echo "rc=$?"
snapshot_registry 03-after-update >/dev/null
record_action "(a) claude plugin update bionic@bionic" 02-deps-present 03-after-update

# ─── (b) version bump in the marketplace source, then update ─────────────────
banner "3. suspect (b): bump payload/.claude-plugin/plugin.json in the clone, commit, update"
# THE BUMP IS THE HALF THE PRIOR MEASUREMENT COULD NOT RUN. epic-21's
# fixit-dep-repair-measurement.md §4 records `plugin update` as a no-op because
# the installed version already matched the marketplace's, and marks the
# advancing case `unverified` because bumping the version meant writing to this
# repo. The clone makes that write free.
OLD_VER="$(jq -r .version "$FH_CLONE/payload/.claude-plugin/plugin.json")"
NEW_VER="${OLD_VER%.*}.$(( ${OLD_VER##*.} + 1 ))"
echo "version bump in the marketplace source: ${OLD_VER} -> ${NEW_VER}"
jq --arg v "$NEW_VER" '.version = $v' "$FH_CLONE/payload/.claude-plugin/plugin.json" > "$FH_ROOT/pj.json" \
  && mv "$FH_ROOT/pj.json" "$FH_CLONE/payload/.claude-plugin/plugin.json"
git -C "$FH_CLONE" -c user.email=rig@local -c user.name=rig commit -qam "bump to ${NEW_VER}" \
  && echo "committed in the clone: $(git -C "$FH_CLONE" rev-parse --short HEAD)"
echo "--- claude plugin update bionic@bionic --scope user --yes ---"
fh_update_bionic; echo "rc=$?"
snapshot_registry 04-after-bump-update >/dev/null
echo "bionic's entry after the bump:"; registry_entry 04-after-bump-update "bionic@bionic"
echo "cache dirs after the bump:"
for p in bionic superpowers agent-skills impeccable; do
  echo "  cache/bionic/$p: $(ls -1 "$CLAUDE_CONFIG_DIR/plugins/cache/bionic/$p" 2>/dev/null | tr '\n' ' ')"
done
record_action "(b) version bump + claude plugin update" 03-after-update 04-after-bump-update

# ─── (c) setup --all, all-yes ────────────────────────────────────────────────
banner "4. suspect (c): payload setup.sh --all, all-yes"
fh_setup_all | tail -40; echo "rc=${PIPESTATUS[0]}"
snapshot_registry 05-after-setup >/dev/null
record_action "(c) setup.sh --all (all-yes)" 04-after-bump-update 05-after-setup

# ─── (d) remove --all, all-yes, then reinstall ───────────────────────────────
banner "5. suspect (d): payload remove.sh --all, all-yes"
fh_remove_all | tail -40; echo "rc=${PIPESTATUS[0]}"
snapshot_registry 06-after-remove >/dev/null
record_action "(d) remove.sh --all (all-yes)" 05-after-setup 06-after-remove "[consented teardown]"

banner "6. reinstall, to carry the protocol past the teardown"
fh_marketplace_add; echo "rc=$?"
fh_install_bionic; echo "rc=$?"
fh_install_plugin impeccable; echo "rc=$?"
snapshot_registry 07-reinstalled >/dev/null
echo "rows after reinstall: $(rows_line 07-reinstalled)"

# ─── (e) a plain session start ───────────────────────────────────────────────
banner "7. suspect (e): a plain session start"
# THE FRESH HOME HAS NO CREDENTIALS and none may be copied into it, so the three
# probes below are ordered cheapest-first and the last one is the only one that
# needs an authenticated session. Whatever it does — refuse, prompt, or answer —
# the registry is snapshotted after it and the record says which of the three
# actually exercised a session start.
echo "--- claude plugin list ---"; fh_claude plugin list; echo "rc=$?"
snapshot_registry 08-after-plugin-list >/dev/null
echo "--- claude --version ---"; fh_claude --version; echo "rc=$?"
snapshot_registry 09-after-version >/dev/null
echo "--- claude -p 'reply ok' --max-turns 1 ---"
fh_claude -p 'reply ok' --max-turns 1; PRC=$?; echo "rc=$PRC"
snapshot_registry 10-after-headless >/dev/null
record_action "(e1) claude plugin list" 07-reinstalled 08-after-plugin-list
record_action "(e2) claude --version" 08-after-plugin-list 09-after-version
record_action "(e3) claude -p (headless session, rc=$PRC)" 09-after-version 10-after-headless

# ─── The table ───────────────────────────────────────────────────────────────
banner "TABLE — action -> rows present before -> rows present after -> first missing row"
echo
echo "| action | rows present before | rows present after | first missing dependent row |"
echo "|---|---|---|---|"
printf '%s' "$TABLE"
echo
if [ -n "$FIRST_DROP" ]; then
  echo "FIRST DROPPING ACTION: ${FIRST_DROP} — first missing row: ${FIRST_DROP_ROW}"
else
  echo "FIRST DROPPING ACTION: none — no action in this protocol removed a dependent row."
fi
echo
echo "snapshots: $FH_SNAPDIR"
echo "rig log  : $FH_LOG"
echo "stubbed package-manager calls: $(wc -l < "$FH_CALLS" | tr -d ' ') (see $FH_CALLS)"
}

# ─── arm `setup-restores` — the OTHER half of the user's report ──────────────
#
# The seed quotes Chris: "Why do I have to keep installing the underlying
# packages like impeccable? … it seems that I have to keep reinstalling those,
# through `bionic:setup --all`." The `suspects` arm answers the first half — what
# takes the row away. This arm answers the second: with the row ALREADY absent
# and the plugin cache still on disk, what does `setup --all` do about it, and
# does it reach the network to do it?
#
# That is exactly the behaviour AC-S0.3 specifies ("setup restores the row
# without re-downloading"), so this arm is the before-picture the fix is measured
# against. The download question is answered by comparing the cache directory's
# mtime across the setup run: a reused cache keeps its timestamp, a re-fetch does
# not.
arm_setup_restores() {
  banner "arm: setup-restores — impeccable absent, cache present, then setup --all"
  fh_init || { echo "registry-drop.sh: rig init failed"; exit 1; }
  echo "scratch root : $FH_ROOT"; echo "HOME: $HOME"; echo "clone: $FH_CLONE @ $FH_SRC_SHA"

  fh_marketplace_add; echo "rc=$?"
  fh_install_bionic;  echo "rc=$?"
  fh_install_plugin impeccable; echo "rc=$?"
  snapshot_registry a1-all-present >/dev/null
  echo "rows: $(rows_line a1-all-present)"

  local cache="$CLAUDE_CONFIG_DIR/plugins/cache/bionic/impeccable" before_mtime after_mtime
  before_mtime="$(find "$cache" -maxdepth 1 -mindepth 1 -exec stat -f '%m %N' {} \; 2>/dev/null | sort)"
  echo "impeccable cache before: ${before_mtime:-(none)}"

  # THE ROW ONLY. The uninstall verb would take the cache with it, and a cache
  # that is gone cannot answer "was it reused". The observed state on Chris's
  # machine was precisely row-absent-cache-present, so that is the state built
  # here: the registry entry is deleted and nothing else is touched.
  banner "delete impeccable's ROW from the registry, leave its cache on disk"
  local reg; reg="$(fh_registry_file)"
  jq 'del(.plugins["impeccable@bionic"])' "$reg" > "$FH_ROOT/reg.json" && mv "$FH_ROOT/reg.json" "$reg"
  snapshot_registry a2-row-deleted >/dev/null
  echo "rows: $(rows_line a2-row-deleted)"
  echo "cache still on disk: $(ls -1 "$cache" 2>/dev/null | tr '\n' ' ')"

  banner "setup.sh --all (all-yes) against the row-absent machine"
  fh_setup_all | tail -60; echo "rc=${PIPESTATUS[0]}"
  snapshot_registry a3-after-setup >/dev/null
  after_mtime="$(find "$cache" -maxdepth 1 -mindepth 1 -exec stat -f '%m %N' {} \; 2>/dev/null | sort)"

  echo
  echo "| action | rows present before | rows present after | impeccable row restored? |"
  echo "|---|---|---|---|"
  local restored="no"
  case $'\n'"$(registry_rows a3-after-setup)"$'\n' in *$'\n'impeccable@bionic$'\n'*) restored="yes" ;; esac
  echo "| setup.sh --all with impeccable's row absent | $(rows_line a2-row-deleted) | $(rows_line a3-after-setup) | ${restored} |"
  echo
  echo "impeccable cache after : ${after_mtime:-(none)}"

  # THE VERDICT ASKS ABOUT THE BUILDS THAT WERE THERE, not about the listing.
  #
  # Comparing the two listings whole was the first cut, and it answered the wrong
  # question. `setup --all` opens by asking the CLI to install bionic, and that
  # command MATERIALISES a bare-sha directory for every sha-pinned plugin in the
  # catalog while registering none of them — measured on its own, with impeccable's
  # row absent before and still absent after (slice 9's report, the sha-directory
  # probe). A new directory therefore appears on every run of this arm no matter
  # what bionic does about the row, and a whole-listing comparison reported that as
  # "re-downloaded" and could never have flipped.
  #
  # What AC-S0.3 is about is whether the plugin bionic already had was fetched
  # again, so the question is asked of the builds that were on disk BEFORE: is each
  # one still there, and does it still carry the mtime it had. A directory that
  # merely appeared is reported on its own line, attributed, and is not the verdict.
  local reused="yes" line ts path now
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ts="${line%% *}"; path="${line#* }"
    now="$(stat -f '%m' "$path" 2>/dev/null)" || now=""
    if [ "$now" != "$ts" ]; then
      reused="no"
      echo "REWRITTEN: ${path} (${ts} -> ${now:-gone})"
    fi
  done <<< "$before_mtime"

  local added=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line#* }"
    case $'\n'"$before_mtime"$'\n' in
      *" ${path}"$'\n'*) ;;
      *) added="${added}${added:+, }${path##*/}" ;;
    esac
  done <<< "$after_mtime"
  [ -n "$added" ] && echo "ADDED (not by the restore): ${added} — the CLI writes a bare-sha directory for every sha-pinned plugin in the catalog when it is asked to install bionic, and registers none of them"

  echo "RESTORED ROW POINTS AT: $(jq -r '.plugins["impeccable@bionic"][0].installPath // "<no row>"' "$reg" 2>/dev/null)"
  if [ "$reused" = "yes" ]; then
    echo "CACHE VERDICT: unchanged — every build that was on disk before this run is still there, byte-for-byte untouched."
  else
    echo "CACHE VERDICT: CHANGED — a build that was already on disk was rewritten, i.e. re-downloaded."
  fi
  echo "network-capable calls the stubs intercepted: $(wc -l < "$FH_CALLS" | tr -d ' ')"
}

# ─── arm `marketplace-churn` — a catalog that stops serving a row ────────────
#
# THE ONE SUSPECT A CLONE CANNOT REACH BY ACCIDENT. On Chris's machine the bionic
# marketplace is a `directory` source pointing at the LIVE checkout
# (`known_marketplaces.json` → `{"source":"directory","path":".../personal/bionic"}`),
# and that checkout changes branch constantly. So the catalog's own content is
# not a constant there the way it is in a scratch clone: a branch whose
# `marketplace.json` predates the impeccable entry (added 2026-08-20, 095fe14)
# makes the catalog stop serving a row that is installed from it.
#
# This arm builds that state deliberately — remove the entry from the clone's
# marketplace.json, commit, refresh — and asks whether the CLI prunes the row of
# a plugin its catalog no longer offers. A yes here is suspect 1 of the seed
# confirmed in the only shape the rig can reach it.
arm_marketplace_churn() {
  banner "arm: marketplace-churn — the catalog stops serving impeccable"
  fh_init || { echo "registry-drop.sh: rig init failed"; exit 1; }
  echo "scratch root : $FH_ROOT"; echo "HOME: $HOME"; echo "clone: $FH_CLONE @ $FH_SRC_SHA"

  fh_marketplace_add; echo "rc=$?"
  fh_install_bionic;  echo "rc=$?"
  fh_install_plugin impeccable; echo "rc=$?"
  snapshot_registry b1-all-present >/dev/null
  echo "rows: $(rows_line b1-all-present)"

  banner "drop impeccable from the clone's marketplace.json, commit"
  jq 'del(.plugins[] | select(.name == "impeccable"))' "$FH_CLONE/.claude-plugin/marketplace.json" \
    > "$FH_ROOT/mp.json" && mv "$FH_ROOT/mp.json" "$FH_CLONE/.claude-plugin/marketplace.json"
  echo "catalog now serves: $(jq -r '[.plugins[].name] | join(", ")' "$FH_CLONE/.claude-plugin/marketplace.json")"
  git -C "$FH_CLONE" -c user.email=rig@local -c user.name=rig commit -qam "catalog drops impeccable" \
    && echo "committed in the clone: $(git -C "$FH_CLONE" rev-parse --short HEAD)"

  banner "claude plugin marketplace update bionic"
  fh_claude plugin marketplace update bionic; echo "rc=$?"
  snapshot_registry b2-after-marketplace-update >/dev/null
  record_action "(f) catalog drops impeccable + marketplace update" b1-all-present b2-after-marketplace-update

  banner "claude plugin update bionic@bionic (with the catalog short one row)"
  fh_update_bionic; echo "rc=$?"
  snapshot_registry b3-after-plugin-update >/dev/null
  record_action "(g) catalog short one row + plugin update bionic" b2-after-marketplace-update b3-after-plugin-update

  banner "claude plugin list (a read of a registry the catalog disagrees with)"
  fh_claude plugin list; echo "rc=$?"
  snapshot_registry b4-after-list >/dev/null
  record_action "(h) catalog short one row + plugin list" b3-after-plugin-update b4-after-list

  echo
  echo "| action | rows present before | rows present after | first missing dependent row |"
  echo "|---|---|---|---|"
  printf '%s' "$TABLE"
  echo
  if [ -n "$FIRST_DROP" ]; then
    echo "FIRST DROPPING ACTION: ${FIRST_DROP} — first missing row: ${FIRST_DROP_ROW}"
  else
    echo "FIRST DROPPING ACTION: none — a catalog that stops serving a row does not prune it."
  fi
}

case "$ARM" in
  suspects)          arm_suspects ;;
  setup-restores)    arm_setup_restores ;;
  marketplace-churn) arm_marketplace_churn ;;
  *) echo "registry-drop.sh: unknown arm '$ARM' (suspects | setup-restores | marketplace-churn)" >&2; exit 2 ;;
esac

# EVERY SNAPSHOT, IN FULL, INTO THE RUN'S OWN OUTPUT. The scratch HOME is deleted
# when this script ends, so a snapshot that lived only there would be an evidence
# artifact with the lifetime of a temp directory (memory: evidence artifacts are
# not ephemera). Printed here, they land in whatever log the run was redirected
# to, and the record quotes them from it.
banner "SNAPSHOTS, verbatim"
for f in "$FH_SNAPDIR"/*.json; do
  echo; echo "--- $(basename "$f") ---"
  cat "$f"
done

if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR"
  cp "$FH_SNAPDIR"/*.json "$OUT_DIR"/ 2>/dev/null
  cp "$FH_LOG" "$OUT_DIR"/rig.log 2>/dev/null
  cp "$FH_CALLS" "$OUT_DIR"/calls.log 2>/dev/null
  echo "copied snapshots and logs to: $OUT_DIR"
fi

fh_cleanup "$KEEP"
exit 0
