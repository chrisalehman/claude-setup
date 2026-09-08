#!/bin/bash
# payload/scripts/lib/refuse.sh — THE REFUSAL OBJECT AND ITS ONE RENDERER
# (epic-22 wave-01 slice 11, REQ-E1, AC-E1.2/E1.3/E1.5; ADR-002 "a refusal is an
# object rendered once, not a string each hook formats").
#
# WHAT IT OWNS. A refusal is `{verb, fact, fix, detail}` and this file is the only
# place that turns one into bytes:
#
#   refuse <mode> <verb> <fact> <fix> <detail>
#         builds the object, validates it, emits it on the channels the table
#         below says the mode has, and EXITS the calling hook with the status that
#         mode needs. It does not return.
#   refuse_channel <mode> <field> -> one cell of the channel table, on stdout;
#         exit 1 and silent for an unknown mode or field.
#   refuse_modes -> the modes usable as a refusal channel, one per line.
#
# THE USER SEES EXACTLY ONE LINE:
#
#     bionic: <verb> refused — <fact> (<fix>)
#
# and the model reads `detail` as well, over whichever channel the E1 measurement
# proved carries it. `BIONIC_WALL_VERBOSE=1` puts `detail` on the user stream too.
#
# THE ONE CLASS `detail` DOES NOT HANDLE (Step-6 critic, issue 4): a raw byte >= 0x80
# that is not valid UTF-8 passes through unescaped — `_refuse_json_escape` below
# escapes the control bytes, not this one — and both readers of the JSON substitute
# U+FFFD for it rather than failing, so the wire holds and the byte reaches the model
# altered. Lossy, never fail-open, and unhandled on purpose until a wall is measured
# putting non-UTF-8 bytes in `detail`.
#
# WHY IT EXISTS (surfaces map §B.3). 21 hook files carry 62 distinct refusal texts
# across four emission modes. `hooks/stop-guard.sh`'s `deny()` frame is 12 fixed
# lines before its reasons and reaches 18 rendered; `hooks/background-suite-guard.sh`'s
# run-arm heredoc is the twelve red lines Chris named. Every one of them is the model's
# instruction and the user's interruption printed to one stream, because the hook had
# nowhere else to put either half. This file is that other place.
#
# ── THE CHANNEL TABLE IS DATA, AND ITS SOURCE IS A MEASUREMENT ────────────────
#
# `BIONIC_REFUSE_TABLE` below is not a summary of how Claude Code is believed to
# behave. Every cell in it was measured on CLI 2.1.263 by slice 10 and is quoted from
# `record/wave-01-plugin-only/e1-measurement.md`; the `source` column names the row.
# Cells the measurement could not establish carry the literal value `unverified`,
# never a guess. Slice 12's attended run (§D-2 of the same file, findings F-D2-1..3)
# drove the three BLOCKING modes live and filled their `user_interactive` cells; the
# two non-blocking modes were never driven interactively and still say `unverified`,
# which is a gap named rather than a guess written.
#
# Ten fields, `|`-separated, one row per mode. No cell may contain a `|`.
#
#   1  mode              the key callers pass to `refuse`
#   2  mechanism         what the hook actually does on the wire
#   3  refusal           `yes` iff this mode may carry a refusal at all
#   4  blocks            does the tool call / stop actually not happen
#   5  user_headless     what `claude -p`'s terminal shows — measured
#   6  user_interactive  what a live session's terminal shows — measured for the
#                        three blocking modes (§D-2), `unverified` for the other two
#   7  model             what reaches the model's context — measured
#   8  model_only        `yes` iff `detail` reaches the model and not the user
#   9  detail_to_user    does THIS renderer also put `detail` on the user stream
#   10 source            the measurement row every cell above is quoted from
#
# FIELD 9 IS THE ONE SWITCH SLICE 12 OWNED, AND IT IS NOW `no` EVERYWHERE. It is why
# the table is data rather than a `case`. On `deny` and `block` the split is real:
# `detail` rides the JSON reason, the user line rides stderr, and the user stream is
# one line. On `exit2` there is one wire for both — the CLI wraps the hook's stderr
# into the model's tool_result and, §D-2 finding F-D2-3 showed, paints that same
# stderr to the user in red, whole, under the refused tool's own header. So there is
# no split to spend: whatever `exit2` gives the model it gives the reader. Ruling
# D-1 ("a refusal is a sentence with a pointer", Chris 2026-09-07) spends that one
# wire on the line alone — `exit2` ships with `detail_to_user=no`, the reader is
# interrupted by one sentence, and `detail` lives in the hook's own log and behind
# `BIONIC_WALL_VERBOSE=1`. The cost is design D4's degradation taken deliberately:
# on `exit2` the model reads the line and no more, so a migrated wall's `detail`
# must be worth reading where it does land. tests/refuse.test.sh §2 asserts that
# shape literally rather than reading it back out of this table, which is why the
# flip made it go red and be edited on purpose.
#
# WHY exit2 IS STILL SUPPORTED. Nine of the real walls and all 21 loader walls use
# it, and four hook events in the roster (SubagentStop, PostToolUse, SessionStart,
# UserPromptSubmit) have no JSON refusal channel at all. A mode the tree needs is
# not made safer by leaving it out of the one renderer.
#
# THE MODE IS AN ARGUMENT AND NEVER AN ENVIRONMENT VARIABLE. `BIONIC_WALL_VERBOSE`
# is an env knob because it can only ADD output; the mode decides whether the wall
# blocks at all (`exit 2` versus `exit 0` with JSON), so an env spelling of it would
# be a bypass an agent turn could set on itself — the reason `loader_fail_closed`
# has no override either. A hook whose event is fixed assigns the mode to a local
# once and passes it at every site.
#
# `refuse` EXITS, IT DOES NOT RETURN. A wall that formats its refusal and then falls
# through to `exit 0` waves the action past itself, and that is the fail-DANGEROUS
# direction (.claude/rules/hook-authoring.md). Owning the exit here means a call site
# cannot forget it.
#
# A MALFORMED REFUSAL IS A PROGRAMMING ERROR AND STILL BLOCKS. A seven-word `fix`,
# a two-line `fact`, an unknown mode: each is refused loudly, through this file's own
# format under the verb `refuse-call`, with exit 2. Loud rather than truncated,
# because a silently shortened `fix` is a wrong instruction rather than a missing
# one; exit 2 rather than exit 1, because the wall the caller was building must
# still hold while its text is being fixed.
#
# BASH 3.2. No associative arrays, no `${var^^}`, no `mapfile`. The JSON is escaped
# by parameter expansion, not by `jq`: `jq` is a dependency this machine can lose
# (the loader block runs it with stderr closed for exactly that reason), and a wall
# that cannot format its refusal must not therefore fail open.
#
# SOURCED, NEVER EXECUTED. The only top-level command is the soft source of
# width.sh below, which defines functions and prints nothing.
#
# [WALL: tests/refuse.test.sh]
# [WALL: tests/cross-gate-agreement.test.sh]

# width.sh, THE SOFT SOURCE — the idiom lib/run.sh uses for lib/roots.sh and
# lib/detect.sh for lib/deps.sh. The 100-column budget and the column counter that
# knows `—` is one column wide already have an owner; a second count of the same
# thing here is the duplication epic-19 W1 S9 removed.
_refuse_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}
if ! declare -F bionic_cols >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_refuse_self_dir)" && pwd -P)/width.sh"
fi

# THE FIX BUDGET. Six words is REQ-E1/AC-E1.3's number. Forty columns is the same
# criterion's other half: AC-E1.3's regex is `\(.{1,40}\)$`, so a `fix` wider than
# that is a line the acceptance criterion rejects however few words it has. Both are
# enforced here so the library cannot emit a line its own criterion refuses.
BIONIC_REFUSE_FIX_WORDS=6
BIONIC_REFUSE_FIX_COLS=40

# THE CHANNEL TABLE. Every cell quoted from record/wave-01-plugin-only/e1-measurement.md.
BIONIC_REFUSE_TABLE='exit2|exit 2 with the text on stderr|yes|yes|none|the whole stderr painted in red as the error result of the refused tool call, about 12 lines then "+N lines", for every non-Bash tool; a Bash call collapses to "Ran N shell commands" at the default view until ctrl+o|the full stderr text, wrapped in a synthetic is_error tool_result prefixed "PreToolUse:<tool> hook error"|no|no|e1-measurement.md channel table, mode 1 + D-2
deny|PreToolUse JSON hookSpecificOutput.permissionDecision=deny with permissionDecisionReason, exit 0|yes|yes|none|nothing raw at the default view: "Ran 1 shell command" collapsed, then whatever the model says next; on a non-Bash tool the reason lands in the same is_error tool_result slot and is expected to paint as exit2 does — inferred, not measured|permissionDecisionReason verbatim, unwrapped, as a synthetic is_error tool_result|yes|no|e1-measurement.md channel table, mode 2 + D-2
systemmessage|top-level JSON systemMessage, exit 0|no|no|none|unverified|nothing in the conversation: a stream-json system/informational event and no more|no|n-a|e1-measurement.md channel table, mode 3
block|JSON decision=block with reason on stdout, exit 0|yes|yes|none|nothing raw, and on PreToolUse the command RAN anyway ("Ran 2 shell commands", then its output) — not a reliable interactive block, so PreToolUse block is off the table|reason verbatim: an is_error tool_result on PreToolUse, a synthetic user turn "Stop hook feedback" on Stop|yes|no|e1-measurement.md channel table, mode 4 + D-2
additionalcontext|PreToolUse JSON hookSpecificOutput.additionalContext, exit 0|no|no|none|unverified|nothing: zero occurrences anywhere in the stream-json transcript|no|n-a|e1-measurement.md channel table, mode 5'

# refuse_channel <mode> <field> -> the cell on stdout; exit 1, silent, for an
# unknown mode or field. The caller holds both names already, so a diagnostic here
# would be noise on a path that has one legitimate use: asking whether a mode exists.
refuse_channel() {
  local mode="${1:-}" field="${2:-}" idx="" cell=""
  case "$field" in
    mode) idx=1 ;;
    mechanism) idx=2 ;;
    refusal) idx=3 ;;
    blocks) idx=4 ;;
    user_headless) idx=5 ;;
    user_interactive) idx=6 ;;
    model) idx=7 ;;
    model_only) idx=8 ;;
    detail_to_user) idx=9 ;;
    source) idx=10 ;;
    *) return 1 ;;
  esac
  # awk, not `grep | cut`: awk reads its whole input, so there is no early-exit
  # SIGPIPE against the producer under `pipefail` (.claude/rules, the `grep -q`
  # class), and `-F'|'` needs no quoting dance for a field separator that is also
  # a shell metacharacter.
  cell="$(printf '%s\n' "$BIONIC_REFUSE_TABLE" \
    | awk -F'|' -v m="$mode" -v i="$idx" '$1==m { print $i; f=1 } END { exit !f }')" || return 1
  printf '%s' "$cell"
}

# refuse_modes -> the modes that may carry a refusal, one per line, table order.
refuse_modes() {
  printf '%s\n' "$BIONIC_REFUSE_TABLE" | awk -F'|' '$3=="yes" { print $1 }'
}

# _refuse_words <string> -> its word count. `set -f` because a `fix` naming a path
# or a glob must be counted, not expanded; the subshell keeps the option local.
_refuse_words() {
  ( set -f; set -- ${1:-}; printf '%s' "$#" )
}

# _refuse_json_escape <string> -> the string as a JSON string body (no quotes).
# Backslash FIRST, or every escape this function adds is escaped again.
#
# EVERY CODE POINT BELOW U+0020, not just the five with a short spelling (Step-6
# review F-1). JSON forbids all of them unescaped, and `detail` is not a field this
# library controls: farm-out-reminder.sh interpolates the model's own Bash command
# text into it, scrubbed for secrets and truncated but never filtered for control
# bytes. One raw 0x01 makes the whole `deny` verdict unparseable, and `deny` exits 0
# — so the wall would report success while telling the CLI nothing, which is the
# fail-OPEN direction. The five keep their short forms because a reader of a hook log
# should see `\n` rather than `\u000a`; the rest go to `\u00XX`.
#
# STILL PARAMETER EXPANSION, NEVER `jq` — the header's reason stands, and the sweep
# adds no external process either: `printf -v` is a builtin and every test below is a
# glob. NO `[[:cntrl:]]` FAST PATH GUARDING THE LOOP: the class is locale-defined and
# a locale in which it stopped matching would put us back to emitting invalid JSON,
# silently. 28 substring globs on the REFUSAL path is not a cost worth that risk.
# NUL needs no arm: bash cannot hold one in a variable.
_refuse_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  local _c _e _i
  for _i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v _c "\\$(printf '%03o' "$_i")"
    case "$s" in *"$_c"*) ;; *) continue ;; esac
    printf -v _e '\\u%04x' "$_i"
    s="${s//$_c/$_e}"
  done
  printf '%s' "$s"
}

# _refuse_selfrefuse <fact> <fix> — the library refusing its own caller, in the
# library's own format, fail-closed. The fact is held inside the line budget by
# width.sh's truncator so that a malformed call carrying a long path still produces
# a line that satisfies the format contract it is complaining about.
_refuse_selfrefuse() {
  local fact="${1:-}" fix="${2:-}"
  # 30 columns for `bionic: refuse-call refused — ` and 3 for ` (` + `)`.
  fact="$(bionic_trunc "$fact" $((BIONIC_LINE_WIDTH - 33 - $(bionic_cols "$fix"))))"
  printf 'bionic: refuse-call refused — %s (%s)\n' "$fact" "$fix" >&2
  exit 2
}

# refuse <mode> <verb> <fact> <fix> <detail> — the whole interface. Exits.
refuse() {
  if [ "$#" -ne 5 ]; then
    _refuse_selfrefuse "refuse takes 5 arguments and got $#" "pass mode verb fact fix detail"
  fi
  local mode="$1" verb="$2" fact="$3" fix="$4" detail="$5"

  # (a) THE MODE must be a refusal channel. `systemmessage` and `additionalcontext`
  # are in the table because the measurement covered them and a later reader needs
  # to see WHY they are not options; neither was shown reaching the model, so
  # routing a refusal over one would drop it in silence.
  if [ "$(refuse_channel "$mode" refusal 2>/dev/null || echo no)" != "yes" ]; then
    _refuse_selfrefuse "\"$mode\" is not a refusal channel" "use exit2, deny or block"
  fi

  # (b) THE VERB is the regex's `[a-z-]+` and nothing else.
  case "$verb" in
    ""|*[!a-z-]*) _refuse_selfrefuse "verb \"$verb\" is not lower-case letters and hyphens" "rename the verb" ;;
  esac

  # (c) ONE LINE means one line. A newline in `fact` or `fix` would emit two.
  case "$fact" in
    "") _refuse_selfrefuse "the fact field is empty" "name the fact refused" ;;
    *"
"*) _refuse_selfrefuse "the fact field carries a newline" "make the fact one line" ;;
  esac
  case "$fix" in
    "") _refuse_selfrefuse "the fix field is empty" "name one repairing command" ;;
    *"
"*) _refuse_selfrefuse "the fix field carries a newline" "make the fix one line" ;;
  esac

  # (d) THE FIX BUDGET, both halves, loud and never truncated.
  local fix_words fix_cols
  fix_words="$(_refuse_words "$fix")"
  if [ "$fix_words" -gt "$BIONIC_REFUSE_FIX_WORDS" ]; then
    _refuse_selfrefuse "the fix field has $fix_words words, max $BIONIC_REFUSE_FIX_WORDS" "shorten the fix"
  fi
  fix_cols="$(bionic_cols "$fix")"
  if [ "$fix_cols" -gt "$BIONIC_REFUSE_FIX_COLS" ]; then
    _refuse_selfrefuse "the fix field is $fix_cols columns, max $BIONIC_REFUSE_FIX_COLS" "shorten the fix"
  fi

  # (e) THE LINE BUDGET. width.sh's 100, counted in columns, because the em dash is
  # three bytes and one column and a byte count would pass a line that wraps.
  local line="bionic: $verb refused — $fact ($fix)"
  local line_cols
  line_cols="$(bionic_cols "$line")"
  if [ "$line_cols" -gt "$BIONIC_LINE_WIDTH" ]; then
    _refuse_selfrefuse "the user line is $line_cols columns, max $BIONIC_LINE_WIDTH" "shorten the fact"
  fi

  # (f) THE TWO PRODUCTS. `user_out` is what the user stream carries; `model_out` is
  # what the model reads. They differ by `detail` and by nothing else.
  local user_out="$line" model_out="$line"
  if [ -n "$detail" ]; then
    model_out="$line

$detail"
    if [ "${BIONIC_WALL_VERBOSE:-}" = "1" ] || [ "$(refuse_channel "$mode" detail_to_user)" = "yes" ]; then
      user_out="$model_out"
    fi
  fi

  # (g) THE WIRE. One case, three modes, and the exit status is part of each.
  case "$mode" in
    exit2)
      # ONE STREAM FOR BOTH. stderr is what the CLI hands the model on exit 2, and
      # it is what an interactive terminal may paint; `detail_to_user` above already
      # decided whether `detail` is on it.
      printf '%s\n' "$user_out" >&2
      exit 2
      ;;
    deny)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
        "$(_refuse_json_escape "$model_out")"
      printf '%s\n' "$user_out" >&2
      exit 0
      ;;
    block)
      printf '{"decision":"block","reason":"%s"}\n' "$(_refuse_json_escape "$model_out")"
      printf '%s\n' "$user_out" >&2
      exit 0
      ;;
  esac

  # UNREACHABLE while (a) and (g) agree on the mode list, and fail-closed if they
  # ever stop agreeing: a mode the table calls a refusal channel and this case does
  # not emit would otherwise fall out of `refuse` with status 0 and wave the action
  # through.
  _refuse_selfrefuse "\"$mode\" is a refusal channel with no emitter" "add the emitter to refuse.sh"
}
