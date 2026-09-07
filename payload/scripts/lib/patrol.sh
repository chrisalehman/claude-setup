#!/bin/bash
# patrol.sh — the Patrol, reconstructed from disk (task T2, plan
# task-dispatch-wall-channel-loss).
#
# WHAT THIS FILE OWNS. One question: what is the Patrol actually doing on this
# machine right now. Nobody can answer it from the authoritative source, because
# there is no authoritative source on disk — the CLI holds its cron table in
# process memory and writes none of it down. So the answer here is RECONSTRUCTED
# from two things that ARE on disk, and every consumer is told so in the same
# breath: `${CLAUDE_CONFIG_DIR}/sessions/<pid>.json`, which names each live
# process with its session id and cwd, and that session's transcript under
# `${CLAUDE_CONFIG_DIR}/projects/<slug>/<sid>.jsonl`, where `CronCreate` and
# `CronDelete` are recorded tool_uses like any other.
#
# THE LIMIT IS PART OF THE ANSWER, not a caveat attached to it. A reconstruction
# is what the transcript IMPLIES; the process may hold something else. A job
# created before the transcript this file can see, one created by a CLI build
# that words its confirmation differently, a delete the platform refused — each
# of those is a live job this file cannot see or a dead one it still counts.
# Every renderer of these lines prints the limit beside them.
#
# THE JOB ID IS NOT IN THE REQUEST. `CronCreate`'s input carries `cron`,
# `prompt` and `recurring` and nothing else; the platform mints the id and
# returns it in the tool_result prose — "Scheduled recurring job b63afd05 (13,43
# * * * *)…" and "Scheduled one-shot task 1037a802 (46 10 18 8 *)…" are the two
# shapes measured on this machine (2026-08-22). So a job is reconstructed by
# JOINING the request to its result on `tool_use_id`, and a request whose result
# is missing from the transcript is a job whose id is unknown — reported as
# such, never guessed, because an id is what a `CronDelete` line is made of.
#
# WHICH JOB IS THE PATROL. Not by its prose: the patrol prompt is composed per
# session by a model, so its wording is not a fact anything may key on. What IS
# fixed is what the prompt has to CONTAIN — skills/canonical-sdlc/SKILL.md
# §Dispatch makes `session-poker.sh tick` the first of its four reads, so a
# recurring job whose prompt runs the poker is a Patrol and one that does not is
# some other timer. That is a structural marker taken from the contract rather
# than a phrase taken from a sample.
#
# READ-ONLY, LIKE ITS ONE CALLER. Nothing here writes, moves or deletes: it
# stats two state files, reads a transcript, and shells out to
# `session-poker.sh interval`, a verb whose whole job is to print a number.
#
# Sourced, never executed.  Depends on detect.sh only for `detect_bounded`,
# and degrades to an unbounded run if that is not present.

PATROL_SCHEMA="patrol-session/v1"
PATROL_JOB_SCHEMA="patrol-job/v1"
PATROL_STAMP_SCHEMA_OUT="patrol-stamp/v1"
PATROL_ROSTER_SCHEMA="patrol-roster/v1"
PATROL_WALL_SCHEMA="patrol-wall/v1"

# The poker's own default, quoted here ONLY as the last resort when the poker
# itself cannot be reached to be asked. Where the script exists it is asked —
# `interval` for the project's configured value and `interval-default` for its
# built-in — because two copies of a constant drift the first time either moves.
PATROL_INTERVAL_LAST_RESORT=1200

# HOW STALE IS STALE (L-DETECT/4.5, improvement, spec AC-22). "The stamp is
# stale past twice the poker interval" is a judgment call three sites in this
# payload each carry as their own inline arithmetic: this file's own
# `patrol_stamp_state` below, `hooks/session-poker.sh` and `hooks/dispatch-
# preflight.sh`. One exported constant is the single owner of the multiplier;
# `patrol_stamp_state` reads it a few lines down, and `session-poker.sh` reads
# it for `adopt`'s liveness window (slice POKER, 1.6). `dispatch-preflight.sh`
# keeps its own inline `* 2` until slice ADOPT switches it; the three are held
# in agreement on the VALUE by tests/patrol-stale.test.sh §4 in the meantime.
export PATROL_STALE_MULTIPLIER=2

# The CLI's config directory, through the same override chain every other
# library here reads, so a fixture machine redirects this one with the knob it
# already uses for the rest.
_patrol_claude_home() {
  printf '%s' "${BIONIC_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
}

# Values ride on `|`-delimited lines read BY KEY, so a value carrying a pipe or
# a newline would forge a field. Same normalisation the roster writer applies to
# a brief, and for the same reason.
# NO `cut`, AND NOT BY ACCIDENT. Doctor's own header states the rule this file
# inherits: a diagnosis that needs coreutils to run dies on the broken machine
# it exists for. Bash does both jobs `cut` was doing here — a substring and a
# prefix strip — so the dependency is spent on `tr`/`sed` alone, which the
# normalisation genuinely needs.
_patrol_clean() {  # <value> [max-chars]
  local v
  v="$(printf '%s' "${1:-}" \
    | tr '\n\r\t|' '    ' \
    | sed -e 's/[[:cntrl:]]/ /g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//')"
  printf '%s' "${v:0:${2:-200}}"
}

_patrol_field() {  # <line> <key>
  local f
  while IFS= read -r f; do
    case "$f" in "${2}="*) printf '%s' "${f#"${2}="}"; return 0 ;; esac
  done <<EOF
$(printf '%s' "${1:-}" | tr '|' '\n')
EOF
  printf ''
}

# THE PROJECT ROOT A SESSION'S STATE FILES LIVE UNDER, resolved from that
# session's cwd through lib/root.sh's `project_root` — the SAME SSoT eleven
# hooks and scripts, doctor, and the Patrol tick's own candidate listing all
# render from (lib/root.sh header, spec §3). This used to be a ninth
# byte-identical copy of the pre-1.4.0 shape `project_root` replaced: git's
# common dir asked FIRST, and a `.bionic` ancestor walked only when no
# repository existed at all. That ordering privileges the git root, so a git
# repo holding a `.bionic` BELOW its root (design-ledger S3, tests/root.test.sh
# §3) had its roster written under the nested `.bionic/tmp` while this
# resolver answered with the git toplevel — the session read as blind
# (FIX-PATROL-ROOT). `project_root` inverts that order: the nearest `.bionic`
# decides, and git is used only to map a linked worktree onto its main
# checkout. LAZILY SOURCED, the way lib/worktree.sh loads its sibling
# git-argv.sh: scripts/lib CAN source across files in the same directory (both
# worktree.sh and doctor.sh already do), so a caller that has not already
# pulled in lib/root.sh pays for it exactly once, here, on first use.
_patrol_self_dir() { dirname "${BASH_SOURCE[0]:-$0}"; }

_patrol_repo_root() {  # <cwd> -> project_root's answer for that cwd
  local d="${1:-}" lib
  [ -n "$d" ] || return 1
  if ! declare -f project_root >/dev/null 2>&1; then
    lib="$( cd "$(_patrol_self_dir)" 2>/dev/null && pwd -P )/root.sh"
    [ -r "$lib" ] || { printf '%s' "$d"; return 0; }
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || { printf '%s' "$d"; return 0; }
    declare -f project_root >/dev/null 2>&1 || { printf '%s' "$d"; return 0; }
  fi
  project_root "$d"
}

# Every live CLI process, from the session files it keeps. `kind`/`status` are
# deliberately not read: a session file describes a process, and whether that
# process still exists is a question only the kernel answers — `kill -0` is a
# builtin, so this survives a machine with no `ps` on PATH.
patrol_live_sessions() {  # -> session=<sid>|pid=<pid>|cwd=<path>, one per line
  local dir f pid sid cwd
  dir="$(_patrol_claude_home)/sessions"
  [ -d "$dir" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
    sid="$(jq -r '.sessionId // empty' "$f" 2>/dev/null)"
    cwd="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
    [ -n "$pid" ] && [ -n "$sid" ] || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    printf 'session=%s|pid=%s|cwd=%s\n' \
      "$(_patrol_clean "$sid" 80)" "$pid" "$(_patrol_clean "$cwd" 300)"
  done
}

# ─── SESSION-KEYED STATE UNDER .bionic/tmp ───────────────────────────────────
#
# ONE DEFINITION OF WHICH FILES BELONG TO A SESSION, read by both parties that
# need it: hooks/session-poker.sh's `sweep`, which deletes them once their owner
# is gone, and scripts/lib/checks.sh's dead-session detector, which is how doctor
# names the sweep as the repair. Written once here because the two must agree —
# a class added on the detector's side but not the verb's would put a row on
# doctor's page whose named cure clears nothing, which is the exact defect shape
# the check table exists to end.
#
# THE CLASSES, each `<class>-<session id>.state` under `<root>/.bionic/tmp`:
#
#   roster     hooks/dispatch-preflight.sh   the dispatch ledger
#   preflight  hooks/preflight-probe.sh      the budget attestation
#   engaged    scripts/lib/binding.sh        the engagement marker
#   sweeper    hooks/session-sweeper.sh      the ack ledger
#   patrol     hooks/session-poker.sh        the Patrol stamp, plus its `.armed` sibling
#
# THE FILES THAT ARE NOT SESSION-KEYED ARE UNREACHABLE THROUGH THESE FUNCTIONS,
# and that is a property of the shape rather than a list anyone maintains:
# `context-spend.state`, `farm-out.state` and `stop-check.state` carry no session
# id in their names, so no id derived here can address one. A non-session file
# added later is safe on arrival for the same reason.
PATROL_STATE_CLASSES="roster preflight engaged sweeper patrol"
PATROL_STATE_ARMED_SUFFIX=".armed"

# EVERY SESSION ID WITH STATE HERE, each once, in class-then-name order. Symlinks
# COUNT (a `-L` test beside `-e`, so a dangling one counts too): a link planted at
# one of these paths is a thing the reader has to see in order to refuse it out
# loud, and a walk that skipped it would report a session as clean while an aimed
# path sat in the directory.
patrol_state_session_ids() {  # <root> -> one session id per line
  local d="${1:-}/.bionic/tmp" c f base sid seen=""
  [ -d "$d" ] || return 0
  for c in $PATROL_STATE_CLASSES; do
    for f in "$d/$c"-*.state "$d/$c"-*.state"$PATROL_STATE_ARMED_SUFFIX"; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      base="${f##*/}"
      sid="${base#"$c"-}"
      sid="${sid%"$PATROL_STATE_ARMED_SUFFIX"}"
      sid="${sid%.state}"
      [ -n "$sid" ] || continue
      case "$sid" in *"/"*|.|..) continue ;; esac
      case " $seen " in *" $sid "*) continue ;; esac
      seen="$seen $sid"
      printf '%s\n' "$sid"
    done
  done
}

# ONE SESSION'S FILES, BY EXACT PATH AND NEVER BY GLOB. The ids come off the
# filenames above, so building each candidate path back by concatenation means a
# strange id can only ever address the file it was read from — there is no
# pattern here for it to widen.
patrol_session_state_files() {  # <root> <session id> -> one path per line
  local d="${1:-}/.bionic/tmp" sid="${2:-}" c f
  [ -n "$sid" ] || return 0
  for c in $PATROL_STATE_CLASSES; do
    for f in "$d/$c-$sid.state" "$d/$c-$sid.state$PATROL_STATE_ARMED_SUFFIX"; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      printf '%s\n' "$f"
    done
  done
}

# The live set as bare ids. CWD IS DELIBERATELY NOT CONSULTED: a session live in
# another project still owns its files here — it may have been started in this
# root and `cd`-ed away — and the pid is the only fact that decides whether
# anyone can still act on what it left.
patrol_live_session_ids() {  # -> one live session id per line
  local l
  patrol_live_sessions 2>/dev/null | while IFS= read -r l; do
    case "$l" in
      session=*) l="${l#session=}"; printf '%s\n' "${l%%|*}" ;;
    esac
  done
}

# THE ANSWER BOTH READERS ACTUALLY WANT: which sessions left state here that
# nobody can act on any more. Extra ids may be named as live by the caller, and
# the one caller that does is the session running the verb — it is live by
# construction, and saying so by hand is what keeps a claude-home this process
# cannot read (an unreadable sessions directory, a missing jq) from letting a
# session sweep its own state out from under itself.
patrol_dead_sessions() {  # <root> [<also-live id>...] -> one session id per line
  local root="${1:-}" live sid; shift 2>/dev/null || :
  live="$(patrol_live_session_ids)"
  for sid in "$@"; do
    [ -n "$sid" ] && live="${live}${live:+
}${sid}"
  done
  # Newline-delimited containment, so a dead session whose id is a PREFIX of a
  # live one is not mistaken for it.
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    case "
$live
" in
      *"
$sid
"*) continue ;;
    esac
    printf '%s\n' "$sid"
  done <<EOF
$(patrol_state_session_ids "$root")
EOF
}

# The transcript file for a session id. Scanned rather than derived from a
# slugged cwd, the same way hooks/dispatch-preflight.sh's liveness probe scans:
# the slug rule belongs to the CLI and a copy of it here would be a second
# definition of where the CLI keeps its own files.
patrol_transcript() {  # <sid> -> path, or empty
  local sid="${1:-}" d
  [ -n "$sid" ] || return 1
  for d in "$(_patrol_claude_home)"/projects/*/; do
    [ -f "${d}${sid}.jsonl" ] && { printf '%s' "${d}${sid}.jsonl"; return 0; }
  done
  return 1
}

# ONE STREAMING PASS over the transcript, emitting four record kinds for the awk
# join below. Streaming and not `jq -s`: a long session's transcript is tens of
# megabytes and slurping it costs the memory of the whole file to answer a
# question about a dozen lines of it.
#
# MAIN THREAD ONLY, BY THE POKER'S OWN TWO RULES. A subagent's turns are written
# to `<sid>/subagents/*.jsonl` on this machine, but `isSidechain` is the field
# that SAYS so, and filtering on the fact rather than on the layout keeps this
# correct if the layout moves. The second rule — an entry carrying an explicit
# agent-id key is somebody's agent turn, not this thread's — is
# hooks/session-poker.sh's `count_main_thread_dispatches`, adopted here verbatim
# so the two readers partition the transcript identically; it is matched over the
# whole serialized entry rather than over top-level keys because that is where the
# poker's line regex matches it, and on this machine's transcripts every such key
# is NESTED (12 entries, 0 top-level). Two readers with different partitions are
# two answers, which is the defect this shape exists to prevent
# (tests/cross-gate-agreement.test.sh §Q).
_patrol_scan_jq='
  select(type == "object")
  | select(.isSidechain != true)
  | select((tostring | test("\"agent_?[Ii][dD]\"[ \t]*:[ \t]*\"[^\"]")) | not)
  | select((.message.content? | type) == "array")
  | . as $entry
  | $entry.message.content[]
  | if (.type == "tool_use" and .name == "CronCreate") then
      ["C", .id,
       ((.input.cron // "") | tostring),
       (if (.input.recurring // false) then "yes" else "no" end),
       (if ((.input.prompt // "") | test("session-poker\\.sh[[:space:]]+tick")) then "patrol" else "other" end),
       ((.input.prompt // "") | gsub("[\n\r\t|]"; " ") | .[0:160])]
    elif (.type == "tool_use" and .name == "CronDelete") then
      ["D", ((.input.id // "") | tostring)]
    elif (.type == "tool_use" and .name == "Agent") then
      # THE TIMESTAMP RIDES ALONG: the ENTRY own `timestamp` field, the same one
      # hooks/session-poker.sh window-scopes count_main_thread_dispatches against, read off
      # $entry rather than off this content item (a tool_use block carries none of its own).
      ["A", .id, ($entry.timestamp // "")]
    elif (.type == "tool_result") then
      ((if (.content | type) == "string" then .content
        elif (.content | type) == "array" then ([.content[]? | select(.type == "text") | .text] | join(" "))
        else "" end) | gsub("[\n\r\t|]"; " ")) as $full
      | ["R", (.tool_use_id // ""),
         (if ($full | test("PreToolUse:Agent hook error:")) then "1" else "0" end),
         ($full | .[0:200]), ($entry.timestamp // "")]
    else empty end
  | @tsv
'

# THE JOIN, AND THE SUBTRACTION. A `CronCreate` is joined to its result to learn
# the id the platform minted; ids named by a `CronDelete` are removed. What is
# left is the job table as the transcript implies it. Creation order is
# preserved, which is what lets the duplicate verdict keep the NEWEST job and
# name the older ones for deletion.
#
# REFUSED DISPATCHES ARE COUNTED HERE TOO, off the same `R` records the job
# join already reads — no second pass over the transcript. This is a
# DELIBERATE second copy of hooks/session-poker.sh's own
# `count_refused_dispatches`, not a shared helper: that script answers for the
# live tick from a bare transcript scan, this one answers for doctor's
# reconstruction inside a jq/awk join that already has the `R` record in hand,
# and a sourced library the installer misses would make either copy a silently
# inert consumer (the same reasoning hooks/session-poker.sh's own header gives
# for its `parse_seconds` duplicate).
#
# THE MARKER IS NOT THE RULE — THE JOIN IS. `PreToolUse:Agent hook error:` is
# what the CLI writes into a refused dispatch's tool_result, but it is ordinary
# text everywhere else: the plan that specifies this behaviour, the reports that
# review it and every brief that quotes it all carry the literal, and reading a
# file with one in it puts it in a tool_result of that read. So a refusal is
# credited only when the tool_result carrying it JOINS BY tool_use_id to an
# `Agent` tool_use — the refused dispatch's own result — which is the rule
# hooks/session-poker.sh now applies too, on the same fixture
# (tests/cross-gate-agreement.test.sh §Q). The test is taken on the UNTRUNCATED
# content: a real refusal carries the marker at offset 482 (the CLI prefixes the
# hook's own stderr with the tool name and the hook's path), so the 200-character
# cut the job join reads by belongs after the test, never before it.
#
# THE WINDOW APPLIES HERE TOO. `agents` and `refused` used to be counted over the
# transcript's WHOLE LIFE, while hooks/session-poker.sh's own counters scope to the
# roster's own window (`roster_window()`, exposed as its `window` verb) — and since a
# `.bionic/tmp` wipe re-opens the roster at zero, a session running a second wave read its
# first wave's dispatches against a roster that only began at the wipe, and doctor printed
# `N launches unrostered` for a wall that had rostered everything asked of it since. The
# two readers are now the SAME RULE: `since` (passed in by patrol_window(), or empty for
# "the whole transcript" — exactly the fallback hooks/session-poker.sh takes when a roster
# cannot be dated at all) gates BOTH the `A` records that build `isagent`/`agents` and the
# `R` records that credit a refusal, each on its own entry's timestamp. An agent dispatched
# before the window never enters `isagent`, and a refusal recorded before the window is
# never credited, matching a wall that is only being asked about from the window forward.
#
# AN ENTRY WITH NO TIMESTAMP IS IN, the same answer hooks/session-poker.sh's own
# in_window() gives a line whose `timestamp` field it cannot find: a reader that dropped
# undatable entries would silently shrink every count on a transcript shape neither reader
# has seen, which is the wrong direction for a wall.
_patrol_join_awk='
  BEGIN { FS = "\t"; n = 0; agents = 0; refused = 0 }
  function in_window(ts,   d) {
    if (since == "") return 1
    if (ts == "") return 1
    d = substr(ts, 1, 19)
    return (d >= substr(since, 1, 19))
  }
  $1 == "C" { ord[++n] = $2; cron[$2] = $3; rec[$2] = $4; kind[$2] = $5; head[$2] = $6 }
  $1 == "D" { del[$2] = 1 }
  $1 == "R" { res[$2] = $4; if ($3 == "1" && ($2 in isagent) && in_window($5)) refused++ }
  $1 == "A" { if (in_window($3)) { agents++; isagent[$2] = 1 } }
  END {
    for (i = 1; i <= n; i++) {
      tid = ord[i]
      id = ""
      nf = split(res[tid], w, " ")
      for (j = 1; j < nf; j++) {
        if (w[j] == "job" || w[j] == "task") { id = w[j+1]; break }
      }
      # A trailing punctuation mark on the id would make it a different string
      # from the one CronDelete was given.
      gsub(/[^0-9A-Za-z_-]/, "", id)
      if (id != "" && (id in del)) continue
      printf "JOB\t%s\t%s\t%s\t%s\t%s\n", (id == "" ? "?" : id), cron[tid], rec[tid], kind[tid], head[tid]
    }
    printf "AGENTS\t%d\n", agents
    printf "REFUSED\t%d\n", refused
  }
'

_patrol_scan() {  # <transcript> [<since ISO>] -> JOB/AGENTS/REFUSED records
  local t="${1:-}" since="${2:-}" secs
  [ -f "$t" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  secs="${BIONIC_DOCTOR_PROBE_SECONDS:-15}"
  if command -v detect_bounded >/dev/null 2>&1; then
    detect_bounded "$secs" jq -r "$_patrol_scan_jq" "$t" 2>/dev/null | awk -v since="$since" "$_patrol_join_awk"
  else
    jq -r "$_patrol_scan_jq" "$t" 2>/dev/null | awk -v since="$since" "$_patrol_join_awk"
  fi
}

# The interval, from its owner. `interval` is the project's configured value and
# REFUSES on a malformed one; `interval-default` is the poker's own built-in and
# is what a refusal falls back to — the same two-step
# hooks/dispatch-preflight.sh's arming wall takes, so doctor measures staleness
# against the number the wall would refuse against.
patrol_interval() {  # <repo-root> -> "<seconds> <configured|default|last-resort>"
  local repo="${1:-}" poker secs
  poker="$(_detect_plugin_root 2>/dev/null)/hooks/session-poker.sh"
  if [ -f "$poker" ]; then
    secs=$( cd "$repo" 2>/dev/null && bash "$poker" interval 2>/dev/null )
    case "$secs" in ''|*[!0-9]*) secs="" ;; esac
    if [ -n "$secs" ] && [ "$secs" -gt 0 ]; then printf '%s configured' "$secs"; return 0; fi
    secs=$( bash "$poker" interval-default 2>/dev/null )
    case "$secs" in ''|*[!0-9]*) secs="" ;; esac
    if [ -n "$secs" ] && [ "$secs" -gt 0 ]; then printf '%s default' "$secs"; return 0; fi
  fi
  printf '%s last-resort' "$PATROL_INTERVAL_LAST_RESORT"
}

# THE WINDOW, from its owner. "Since when does THIS roster's own record of this session
# begin" is hooks/session-poker.sh's own question — its `window` verb answers it with the
# roster file's own creation time, or the Patrol stamp beside it when the roster itself
# cannot be dated (`roster_window()`). This shells out to that verb rather than
# re-deriving `file_birth`/`epoch_iso`/`roster_window` here, the same call
# `patrol_interval()` above already makes for the interval and for the identical reason: a
# copy grown in a lib/ file that cannot source hooks/ would be a second, silently
# driftable answer to one question. tests/cross-gate-agreement.test.sh §Q.3 compares the
# two COUNTING functions this window feeds (hooks/session-poker.sh's
# count_main_thread_dispatches/count_refused_dispatches against this file's own
# _patrol_scan) on one shared fixture, the same way §Q already does for the refusal-join
# rule.
#
# EVERY FAILURE IS AN EMPTY STRING, never a refusal: an unreachable poker, an unresolvable
# root or a filesystem that keeps no creation time all mean "no window", and the counters
# fall back to the whole transcript — the answer doctor gave before this existed.
patrol_window() {  # <repo-root> <sid> -> ISO instant on stdout, empty for "the whole transcript"
  local repo="${1:-}" sid="${2:-}" poker w
  [ -n "$repo" ] && [ -n "$sid" ] || { printf ''; return 0; }
  poker="$(_detect_plugin_root 2>/dev/null)/hooks/session-poker.sh"
  [ -f "$poker" ] || { printf ''; return 0; }
  w=$( cd "$repo" 2>/dev/null && CLAUDE_CODE_SESSION_ID="$sid" bash "$poker" window 2>/dev/null )
  case "$w" in
    ''|*[!0-9TZ:.-]*) printf '' ;;
    *) printf '%s' "$w" ;;
  esac
}

_patrol_mtime() {  # <file>
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# THE STAMP SAYS FIRINGS ARE LANDING, and nothing else. It cannot see the cron
# table, so a job deleted a moment ago still stamps fresh for up to one stale
# window — which is why the job table above and this line are two facts printed
# side by side rather than one verdict merged out of both.
patrol_stamp_state() {  # <repo-root> <sid> -> state=…|age=…|limit=…|interval=…|source=…|path=…
  local repo="${1:-}" sid="${2:-}" f iv secs src mt age limit state
  f="${repo}/.bionic/tmp/patrol-${sid}.state"
  iv="$(patrol_interval "$repo")"; secs="${iv%% *}"; src="${iv##* }"
  limit=$(( secs * PATROL_STALE_MULTIPLIER ))
  if [ -L "$f" ] || [ ! -f "$f" ]; then
    state="never-armed"; age=""
  else
    mt="$(_patrol_mtime "$f")"
    case "$mt" in
      ''|*[!0-9]*) state="unknown"; age="" ;;
      *)
        age=$(( $(date -u +%s 2>/dev/null || echo 0) - mt ))
        [ "$age" -lt 0 ] && age=0
        if [ "$age" -gt "$limit" ]; then state="not-firing"; else state="firing"; fi ;;
    esac
  fi
  printf 'state=%s|age=%s|limit=%s|interval=%s|source=%s|path=%s' \
    "$state" "$age" "$limit" "$secs" "$src" "$f"
}

# THE ROSTER, COUNTED THE WAY IT IS WRITTEN. The file is append-only and a row
# is appended per status transition — `intended` at the wall, then `confirmed`,
# then `identified` — so the number of DISPATCHES the wall saw is the number of
# `status=intended` rows, and counting rows outright would multiply every
# dispatch by however far it got. A dispatch is CLOSED when hooks/landing-gate.sh
# has journalled a `landing-swept/v1` marker for its name SAYING `state=MET`;
# anything else — no marker, or a marker carrying any other verdict — is open.
#
# `state=` IS LOAD-BEARING, and this reader used to ignore it (Step-6 security
# review, out-of-axis note 2). hooks/session-start.sh's `open_rows` and the
# poker's `adopt_fold` have always required MET; this function and the poker's
# `youngest_suite_writer` took ANY marker, so four readers of one schema held
# two rules. S17's `adopt_copy_marker` then became a second WRITER that copies a
# predecessor's verdict — UNMET included — verbatim onto a successor's roster,
# which is how a non-MET marker reaches a roster this function reads. Reporting
# an UNMET contract as closed is reporting a wave as finished.
patrol_roster_state() {  # <repo-root> <sid> -> rows=…|open=…|closed=…|names=…|path=…
  local repo="${1:-}" sid="${2:-}" f rows names closed open swept nm
  f="${repo}/.bionic/tmp/roster-${sid}.state"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    printf 'rows=0|open=0|closed=0|present=no|path=%s' "$f"
    return 0
  fi
  rows=$(grep -c '^roster-state/v1|status=intended|' "$f" 2>/dev/null || true)
  case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
  names="$(grep '^roster-state/v1|status=intended|' "$f" 2>/dev/null \
           | tr '|' '\n' | sed -n 's/^name=//p' | sort -u)"
  # CAPTURED, THEN MATCHED — never `grep <file> | grep -q`. Under `pipefail` a
  # `-q` consumer closes the pipe on its first hit and the producer dies of
  # SIGPIPE with status 141, which a caller reads as a failed search rather than
  # a successful one.
  # MATCHED BY FIELD EQUALITY, never by substring: `state=` is last in the
  # originator's printf today, and a field appended after it must not silently
  # turn every marker in the fleet into a non-closing one.
  swept="$(grep '^landing-swept/v1|' "$f" 2>/dev/null \
           | awk -F'|' '{ for (i = 1; i <= NF; i++) if ($i == "state=MET") { print; break } }' \
           || true)"
  closed=0; open=0
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    case "$swept" in
      *"|name=${nm}|"*) closed=$((closed + 1)) ;;
      *)                open=$((open + 1)) ;;
    esac
  done <<EOF
$names
EOF
  printf 'rows=%s|open=%s|closed=%s|present=yes|path=%s' "$rows" "$open" "$closed" "$f"
}

# EVERY LINE THE PATROL REPORT IS MADE OF, for every live session on this
# machine. Emitted as keyed records rather than prose so the renderer decides
# what a reader sees and this file decides nothing about presentation.
patrol_report() {  # -> patrol-session/v1 … patrol-job/v1 … patrol-stamp/v1 … patrol-roster/v1 … patrol-wall/v1
  local sess sid pid cwd repo here_repo tr scan since agents refused cause blind
  local id cron rec kind phead rline dispatches tag a b c d e

  here_repo="$(_patrol_repo_root "$PWD")"

  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    sid="$(_patrol_field "$sess" session)"
    pid="$(_patrol_field "$sess" pid)"
    cwd="$(_patrol_field "$sess" cwd)"
    repo="$(_patrol_repo_root "$cwd")"

    tr="$(patrol_transcript "$sid")" || tr=""
    cause=""
    if [ -z "$tr" ]; then cause="no transcript under projects/"
    elif ! command -v jq >/dev/null 2>&1; then cause="jq is not on PATH"
    fi

    printf '%s|session=%s|pid=%s|cwd=%s|repo=%s|here=%s|cause=%s\n' \
      "$PATROL_SCHEMA" "$sid" "$pid" "$cwd" "$repo" \
      "$( [ "$repo" = "$here_repo" ] && echo yes || echo no )" "$cause"

    agents=""; refused=""
    if [ -n "$tr" ] && [ -z "$cause" ]; then
      since="$(patrol_window "$repo" "$sid")"
      scan="$(_patrol_scan "$tr" "$since")"
      while IFS=$'\t' read -r tag a b c d e; do
        case "$tag" in
          JOB)
            id="$a"; cron="$b"; rec="$c"; kind="$d"; phead="$e"
            printf '%s|session=%s|id=%s|cron=%s|recurring=%s|kind=%s|prompt=%s\n' \
              "$PATROL_JOB_SCHEMA" "$sid" "$id" "$(_patrol_clean "$cron" 40)" \
              "$rec" "$kind" "$(_patrol_clean "$phead" 160)" ;;
          AGENTS) agents="$a" ;;
          REFUSED) refused="$a" ;;
        esac
      done <<EOF
$scan
EOF
    fi
    case "$refused" in ''|*[!0-9]*) refused=0 ;; esac

    printf '%s|session=%s|%s\n' "$PATROL_STAMP_SCHEMA_OUT" "$sid" "$(patrol_stamp_state "$repo" "$sid")"

    rline="$(patrol_roster_state "$repo" "$sid")"
    printf '%s|session=%s|%s\n' "$PATROL_ROSTER_SCHEMA" "$sid" "$rline"

    dispatches="$(_patrol_field "$rline" rows)"
    case "$agents" in ''|*[!0-9]*) agents="" ;; esac
    if [ -z "$agents" ]; then
      printf '%s|session=%s|dispatched=|rostered=%s|blind=|refused=%s|cause=%s\n' \
        "$PATROL_WALL_SCHEMA" "$sid" "$dispatches" "$refused" "${cause:-the transcript could not be read}"
    else
      # NET OF REFUSALS. A dispatch the wall REFUSED still shows up as an
      # `Agent`/`Task` tool_use in $agents (the attempt happened), but it exits
      # before dispatch-preflight.sh's roster append and so is never in
      # $dispatches either — a refusal is the wall doing its job, not a gap in
      # it, and crediting it here is what keeps a session full of healthy
      # refusals from reading as a wall that never saw them.
      blind=$(( agents - dispatches - refused ))
      [ "$blind" -lt 0 ] && blind=0
      printf '%s|session=%s|dispatched=%s|rostered=%s|blind=%s|refused=%s|cause=\n' \
        "$PATROL_WALL_SCHEMA" "$sid" "$agents" "$dispatches" "$blind" "$refused"
    fi
  done <<EOF
$(patrol_live_sessions)
EOF
}
