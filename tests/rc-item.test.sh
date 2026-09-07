#!/bin/bash
# THE RC ITEM — epic-18 wave-03 slice 4/7 (spec §R6, AC-5, AC-6, AC-7).
#
# WHAT THIS SUITE OWNS. The `claude()` shell proxy as a SETUP-MANAGED ITEM: the
# marker-delimited block bionic owns in the user's shell rc, the roster and the
# write/read/delete in payload/scripts/lib/env.sh, the consented step in
# setup.sh that offers it, the row doctor.sh renders for it, and the strip
# remove.sh performs through both of its doors.
#
# WHY A SHELL FUNCTION AND NOT A LINE SOMEONE PASTES. The launch flag has to
# reach the `claude` a person types, and the only place that can happen is
# their shell rc — no settings.json key is equivalent, because the CLI decides
# bypass availability from argv (epic-19 W1, record/epic-19/w1/s1-f2-probe.md).
# A line written there by hand is footprint doctor cannot report
# and remove cannot strip; inside bionic's markers it is an item with an owner —
# offered once with a why, reported present or absent, and taken back out on
# request. That is the whole reason this file exists (Chris 2026-08-23: "It may
# only be made if it is permanently added").
#
# EVERY NEGATIVE HERE HAS A POSITIVE BESIDE IT, ON THE SAME EXTRACTOR AND THE
# SAME FIXTURE (.claude/rules test-authoring rule; memory
# `no-vacuous-tests-at-authoring`). `rc_block_lines` is asserted non-empty after
# a consented setup before it is asserted empty before one; the `type claude`
# readback is asserted to name a shell function after setup before it is
# asserted not to before setup. An extractor that returned the empty string for
# every input would fail the positive arm and take its negative twin with it.
#
# NO awk EQUALITY ON THE MARKER GLYPHS. The markers are box-drawing dashes, and
# an `awk '$0 == marker'` comparison on them is locale-dependent — it has
# silently matched nothing before. Every comparison below is bash's own `[ = ]`
# or a `case` pattern, in-process.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere: containment is bash
# `case`, and the only reads of a file are bash `read` loops.
#
# HERMETIC. Every arm builds its own $HOME under $TMP, plants its own .zshrc,
# and points the payload at it with HOME/ZDOTDIR/SHELL/BIONIC_CLAUDE_HOME. The
# real ~/.zshrc is never read and never written. `claude` is a stub on a
# prepended PATH so no arm asks the live CLI anything.
#
# Usage: bash tests/rc-item.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
ENV_SH="${REPO}/payload/scripts/lib/env.sh"
DETECT_SH="${REPO}/payload/scripts/lib/detect.sh"
SETUP_SH="${REPO}/payload/scripts/setup.sh"
DOCTOR_SH="${REPO}/payload/scripts/doctor.sh"
REMOVE_SH="${REPO}/payload/scripts/remove.sh"

. "$(dirname "$0")/lib/assert.sh"

# expect_not_contains -> expect_absent, pure rename (S1b/A-17 mapping table): same
# `case` glob semantics.
expect_same_bytes() {  # <label> <file-a> <file-b>
  if cmp -s "$2" "$3"; then ok "$1"; else no "$1" "$(diff "$2" "$3" 2>&1 | head -20)"; fi
}
expect_diff_bytes() {  # <label> <file-a> <file-b>
  if cmp -s "$2" "$3"; then no "$1" "the two files are byte-identical and should not be"; else ok "$1"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v zsh >/dev/null 2>&1 || { echo "rc-item.test.sh: zsh is required — the readback arm runs the rc"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "rc-item.test.sh: jq is required"; exit 1; }

# ---------------------------------------------------------------------------
# The literals under test
#
# SPELLED HERE, AND PINNED TO THE PAYLOAD BELOW. The suite has to look for the
# markers to find the block, so it carries them; the pins that follow are what
# make that carriage a pin and not a second source of truth — env.sh's constants
# must equal these, and remove.sh's standalone copies must equal env.sh's.
# ---------------------------------------------------------------------------
RC_START_LIT='# ─── bionic:rc:start ───'
RC_END_LIT='# ─── bionic:rc:end ───'
PROXY_LINE='claude() { command claude --allow-dangerously-skip-permissions "$@"; }'
DOCTOR_ROW_LABEL='claude() shell proxy'

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'STUB'
#!/bin/bash
case "$*" in
  "plugin list --json") echo '[]' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/claude"

# The rc every arm starts from: three lines that are not bionic's, and which
# every assertion below requires to come back byte-identical.
plant_rc() {  # <file>
  cat > "$1" <<'RC'
# a line that was here before bionic
export EDITOR=vim
alias ll='ls -la'
RC
}

# THE STALE-BLOCK FIXTURE. bionic's markers around an OLDER payload's proxy
# text, with non-bionic lines above AND below the block. Every install already
# on disk takes this shape the day `rc_default claude-proxy`'s text changes, and
# a user who hand-edits between the markers has it today.
STALE_LINE='claude() { command claude --old-flavour "$@"; }'
plant_stale_rc() {  # <file>
  {
    printf '%s\n' '# a line that was here before bionic'
    printf '%s\n' 'export EDITOR=vim'
    printf '%s\n' "$RC_START_LIT"
    printf '%s\n' "$STALE_LINE"
    printf '%s\n' "$RC_END_LIT"
    printf '%s\n' "alias ll='ls -la'"
    printf '%s\n' 'export PAGER=less'
  } > "$1"
}

# FRESH MEANS FRESH, AND A COUNTER COULD NOT DELIVER IT. Every call site is
# `SB="$(new_sandbox)"`, which runs this function in a COMMAND SUBSTITUTION —
# its own subshell — so a `SANDBOX_N=$((SANDBOX_N + 1))` here incremented a
# variable that died with the subshell and every sandbox in the suite was the
# same directory, re-planted in place. Arms that write and read in immediate
# succession never noticed; an arm that needs two fixtures alive AT ONCE (the
# agreement section below holds three) got one directory wearing three names.
# `mktemp -d` keeps no state to lose (epic-19 W1 S9).
new_sandbox() {  # -> prints a fresh $HOME with a planted .zshrc
  local sb
  sb="$(mktemp -d "$TMP/home-XXXXXX")"
  mkdir -p "$sb/.claude"
  plant_rc "$sb/.zshrc"
  printf '%s' "$sb"
}

new_stale_sandbox() {  # -> a fresh $HOME whose .zshrc already holds a stale block
  local sb
  sb="$(new_sandbox)"
  plant_stale_rc "$sb/.zshrc"
  printf '%s' "$sb"
}

# ---------------------------------------------------------------------------
# Extractors — every assertion below reads through one of these
# ---------------------------------------------------------------------------

# The lines BETWEEN bionic's markers, in order. Not "does the file contain the
# proxy line": a proxy line outside the markers is a line bionic does not own
# and this extractor must not see it.
rc_block_lines() {  # <file>
  local file="$1" line inside=0 out=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$RC_START_LIT" ]; then inside=1; continue; fi
    if [ "$line" = "$RC_END_LIT" ];   then inside=0; continue; fi
    [ "$inside" = "1" ] && out="${out}${line}"$'\n'
  done < "$file"
  printf '%s' "$out"
}

# Every line NOT between bionic's markers, in order, the markers themselves
# excluded. The other half of `rc_block_lines`: what the user's rc held before
# bionic ever touched it, and must still hold afterwards whatever bionic did to
# its own block.
rc_nonblock_lines() {  # <file>
  local file="$1" line inside=0 out=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$RC_START_LIT" ]; then inside=1; continue; fi
    if [ "$line" = "$RC_END_LIT" ];   then inside=0; continue; fi
    [ "$inside" = "0" ] && out="${out}${line}"$'\n'
  done < "$file"
  printf '%s' "$out"
}

# Does the SHELL agree the file is a shell script -- `ok`, or the parser's own
# complaint. An rc that no longer parses is the failure mode that locks a user
# out of their own login shell, and no assertion about bytes or blocks sees it.
zsh_syntax_rc() {  # <file>
  local out
  if out="$(zsh -n "$1" 2>&1)"; then printf 'ok'; else printf '%s' "${out:-nonzero}"; fi
}

# How many times a whole line equals <literal>. The idempotence arm reads this.
count_lines_equal() {  # <file> <literal>
  local file="$1" want="$2" line n=0
  [ -f "$file" ] || { printf '0'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$want" ] && n=$((n + 1))
  done < "$file"
  printf '%s' "$n"
}

# A single-quoted shell constant's contents, read out of a script. Pure bash —
# the values are box-drawing glyphs and this must not go through awk or sed.
const_from() {  # <file> <name>
  local file="$1" name="$2" line v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${name}='"*)
        v="${line#${name}=\'}"; v="${v%\'}"
        printf '%s' "$v"; return 0 ;;
    esac
  done < "$file"
  return 1
}

# The one line of a report that names the proxy row.
report_row() {  # <report text> <label>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *"$2"*) printf '%s' "$line"; return 0 ;; esac
  done <<< "$1"
  return 0
}

# What the SHELL says the name resolves to, from that HOME's own rc. This is the
# arm no file assertion can stand in for: a block written into a file the shell
# never reads is a block that changed nothing.
type_claude() {  # <sandbox>
  HOME="$1" ZDOTDIR="$1" SHELL=/bin/zsh PATH="$TMP/bin:$PATH" \
    zsh -ic 'type claude' 2>&1
}

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

setup_run() {  # <sandbox> <answer>
  local sb="$1" answer="$2"
  printf '%s\n' "$answer" | HOME="$sb" ZDOTDIR="$sb" SHELL=/bin/zsh \
    PATH="$TMP/bin:$PATH" BIONIC_CLAUDE_HOME="$sb/.claude" \
    bash "$SETUP_SH" --only claude-proxy 2>&1
}

doctor_run() {  # <sandbox>
  HOME="$1" ZDOTDIR="$1" SHELL=/bin/zsh \
    PATH="$TMP/bin:$PATH" BIONIC_CLAUDE_HOME="$1/.claude" \
    BIONIC_DOCTOR_PROBE_SECONDS=2 \
    bash "$DOCTOR_SH" </dev/null 2>&1
}

remove_run() {  # <sandbox> <answer> [script]
  local sb="$1" answer="$2" script="${3:-$REMOVE_SH}"
  printf '%s\n' "$answer" | HOME="$sb" ZDOTDIR="$sb" SHELL=/bin/zsh \
    PATH="$TMP/bin:$PATH" BIONIC_CLAUDE_HOME="$sb/.claude" \
    bash "$script" --only claude-proxy 2>&1
}

# One env.sh call in a fresh bash, against a fixture HOME.
env_run() {  # <sandbox> <shell-path> -- <function> [args...]
  local sb="$1" shell_path="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  HOME="$sb" SHELL="$shell_path" PATH="$TMP/bin:$PATH" \
    BIONIC_CLAUDE_HOME="$sb/.claude" \
    bash -c '
      set -uo pipefail
      . "$1" || exit 90
      shift
      "$@"
    ' _ "$ENV_SH" "$@"
}

# The same, for a snippet that has to READ a variable env.sh defines rather than
# call a function it defines.
env_eval() {  # <sandbox> <shell-path> <snippet>
  HOME="$1" SHELL="$2" PATH="$TMP/bin:$PATH" BIONIC_CLAUDE_HOME="$1/.claude" \
    bash -c '
      set -uo pipefail
      . "$1" || exit 90
      eval "$2"
    ' _ "$ENV_SH" "$3"
}

section "env.sh: the roster, the literals and the default"

SB_A="$(new_sandbox)"
expect_eq "env.sh RC_ITEMS names the proxy" \
  "claude-proxy" "$(env_eval "$SB_A" /bin/zsh 'printf "%s" "$RC_ITEMS"' 2>/dev/null)"

ENV_RC_START="$(const_from "$ENV_SH" RC_START)" || ENV_RC_START=""
ENV_RC_END="$(const_from "$ENV_SH" RC_END)"     || ENV_RC_END=""
expect_nonempty "env.sh carries an RC_START constant" "$ENV_RC_START"
expect_nonempty "env.sh carries an RC_END constant"   "$ENV_RC_END"
expect_eq "env.sh RC_START is the spec's literal" "$RC_START_LIT" "$ENV_RC_START"
expect_eq "env.sh RC_END is the spec's literal"   "$RC_END_LIT"   "$ENV_RC_END"

expect_eq "rc_default claude-proxy is the proxy function, exactly" \
  "$PROXY_LINE" "$(env_run "$SB_A" /bin/zsh -- rc_default claude-proxy)"
expect_empty "rc_default refuses a name that is not bionic's" \
  "$(env_run "$SB_A" /bin/zsh -- rc_default not-an-item 2>/dev/null)"

section "env.sh: rc_file picks the rc the shell reads"

SB_B="$(new_sandbox)"
expect_eq "rc_file under zsh is that HOME's .zshrc" \
  "${SB_B}/.zshrc" "$(env_run "$SB_B" /bin/zsh -- rc_file)"
expect_eq "rc_file under bash is that HOME's .bashrc" \
  "${SB_B}/.bashrc" "$(env_run "$SB_B" /bin/bash -- rc_file)"
RC_FISH_OUT="$(env_run "$SB_B" /usr/local/bin/fish -- rc_file 2>&1)"; RC_FISH_RC=$?
expect_ne "rc_file refuses a shell bionic writes no rc for" "0" "$RC_FISH_RC"
expect_contains "rc_file says which shell it declined" "fish" "$RC_FISH_OUT"

section "setup: consent yes writes the block, and the shell reads it"

SB_YES="$(new_sandbox)"
cp "$SB_YES/.zshrc" "$TMP/yes-before.zshrc"

# NEGATIVE AND POSITIVE ON THE SAME EXTRACTOR AND THE SAME FIXTURE. The block is
# read before and after one consented run; the "empty" assertion is only
# meaningful because the "non-empty" one below it passes on the same file.
BLOCK_BEFORE="$(rc_block_lines "$SB_YES/.zshrc")"
TYPE_BEFORE="$(type_claude "$SB_YES")"

SETUP_OUT="$(setup_run "$SB_YES" y)"
BLOCK_AFTER="$(rc_block_lines "$SB_YES/.zshrc")"
TYPE_AFTER="$(type_claude "$SB_YES")"

expect_nonempty "after a consented setup the marker block holds a line" "$BLOCK_AFTER"
expect_eq "the block holds exactly the proxy function" "$PROXY_LINE" "$BLOCK_AFTER"
expect_empty  "before setup the same file has no marker block" "$BLOCK_BEFORE"

expect_contains "after setup the shell reports claude as a function" "shell function" "$TYPE_AFTER"
expect_absent "before setup the same shell reports no function" "shell function" "$TYPE_BEFORE"

expect_contains "setup states the why before it asks" "bypass" "$SETUP_OUT"

# The rest of the rc is untouched: everything that is not the block is the
# planted file, byte for byte.
{
  printf '%s\n' "$RC_START_LIT"
  printf '%s\n' "$PROXY_LINE"
  printf '%s\n' "$RC_END_LIT"
} > "$TMP/expected-block"
cat "$TMP/yes-before.zshrc" "$TMP/expected-block" > "$TMP/yes-expected.zshrc"
expect_same_bytes "the rc is the planted file plus the block, byte for byte" \
  "$TMP/yes-expected.zshrc" "$SB_YES/.zshrc"

section "setup: a second run changes nothing"

cp "$SB_YES/.zshrc" "$TMP/idem-before.zshrc"
setup_run "$SB_YES" y >/dev/null 2>&1
expect_same_bytes "a second consented run leaves the rc byte-identical" \
  "$TMP/idem-before.zshrc" "$SB_YES/.zshrc"
expect_eq "exactly one start marker after two runs" "1" \
  "$(count_lines_equal "$SB_YES/.zshrc" "$RC_START_LIT")"
expect_eq "exactly one proxy line after two runs" "1" \
  "$(count_lines_equal "$SB_YES/.zshrc" "$PROXY_LINE")"

section "setup: consent no writes nothing"

SB_NO="$(new_sandbox)"
cp "$SB_NO/.zshrc" "$TMP/no-before.zshrc"
NO_OUT="$(setup_run "$SB_NO" n)"
expect_same_bytes "a declined setup leaves the rc byte-identical" \
  "$TMP/no-before.zshrc" "$SB_NO/.zshrc"
expect_empty "a declined setup leaves no marker block" "$(rc_block_lines "$SB_NO/.zshrc")"
# The positive twin for the two assertions above, on the same fixture and the
# same extractors: a yes on this very file does change it.
setup_run "$SB_NO" y >/dev/null 2>&1
expect_diff_bytes "a consented setup on the same fixture does change the rc" \
  "$TMP/no-before.zshrc" "$SB_NO/.zshrc"
expect_nonempty "a consented setup on the same fixture does write a block" \
  "$(rc_block_lines "$SB_NO/.zshrc")"

section "doctor: one row, absent before and present after"

SB_DOC="$(new_sandbox)"
ROW_ABSENT="$(report_row "$(doctor_run "$SB_DOC")" "$DOCTOR_ROW_LABEL")"
setup_run "$SB_DOC" y >/dev/null 2>&1
ROW_PRESENT="$(report_row "$(doctor_run "$SB_DOC")" "$DOCTOR_ROW_LABEL")"

expect_nonempty "doctor renders a proxy row when the block is present" "$ROW_PRESENT"
expect_nonempty "doctor renders a proxy row when the block is absent"  "$ROW_ABSENT"
expect_ne "the two rows differ" "$ROW_ABSENT" "$ROW_PRESENT"
expect_contains "the absent row routes the reader to setup" "/bionic:setup" "$ROW_ABSENT"
expect_absent "the present row does not route to setup" "/bionic:setup" "$ROW_PRESENT"

section "detect: the presence fact"

SB_DET="$(new_sandbox)"
detect_run() {  # <sandbox>
  HOME="$1" SHELL=/bin/zsh PATH="$TMP/bin:$PATH" BIONIC_CLAUDE_HOME="$1/.claude" \
    bash -c '. "$1" && detect_rc_claude_proxy' _ "$DETECT_SH" 2>&1
}
DET_ABSENT="$(detect_run "$SB_DET")"
setup_run "$SB_DET" y >/dev/null 2>&1
DET_PRESENT="$(detect_run "$SB_DET")"
expect_eq "detect_rc_claude_proxy reports present after setup" \
  "env:rc-claude-proxy present=yes" "$DET_PRESENT"
expect_eq "detect_rc_claude_proxy reports absent before setup" \
  "env:rc-claude-proxy present=no" "$DET_ABSENT"

section "the two doors answer the same question the same way"

# WHAT THIS SECTION OWNS. "Is bionic's `claude()` proxy in place" is asked by
# two doors — setup decides whether to offer the item (`rc_get`), doctor decides
# what to print (`detect_rc_claude_proxy`) — and one concept answered two ways is
# a concept that can disagree. The two arms above drive both predicates already,
# but only on the states where they cannot differ: a file with no block, and a
# file whose block holds exactly the current line.
#
# THE THIRD FIXTURE IS THE ONLY ONE THAT SEPARATES THEM: bionic's markers around
# an OLDER payload's proxy text, which is the state every install already on disk
# entered the day `rc_default`'s line changed (epic-19 W1 slice 4/1 changed it).
# A marker-only predicate calls that machine done; a line-comparing predicate
# calls it pending. Whoever is wrong, they must not be wrong differently — this
# is the agreement pin the Step-6 DUPLICATION review found missing.

# Setup's own predicate, as setup consumes it (setup.sh:1194 `rc_get … && continue`).
setup_says() {  # <sandbox> -> in-place | pending
  if env_run "$1" /bin/zsh -- rc_get claude-proxy >/dev/null 2>&1
  then printf 'in-place'; else printf 'pending'; fi
}
# Doctor's, as doctor consumes it (doctor.sh: `[ "$RC_PROXY_STATE" = "yes" ]`).
doctor_says() {  # <sandbox> -> in-place | pending
  case "$(detect_run "$1")" in
    *present=yes) printf 'in-place' ;;
    *)            printf 'pending' ;;
  esac
}

SB_AG_ABSENT="$(new_sandbox)"
SB_AG_CURRENT="$(new_sandbox)"; setup_run "$SB_AG_CURRENT" y >/dev/null 2>&1
SB_AG_STALE="$(new_stale_sandbox)"

# The extractors are proved to discriminate before the third fixture is asked
# anything: each one answers both words, on the two fixtures where the answer is
# not in dispute. A predicate stuck on one value would fail here and take the
# stale arm's meaning with it.
expect_eq "setup's predicate says pending on an rc with no block" \
  "pending" "$(setup_says "$SB_AG_ABSENT")"
expect_eq "setup's predicate says in-place after a consented setup" \
  "in-place" "$(setup_says "$SB_AG_CURRENT")"
expect_eq "doctor's predicate says pending on an rc with no block" \
  "pending" "$(doctor_says "$SB_AG_ABSENT")"
expect_eq "doctor's predicate says in-place after a consented setup" \
  "in-place" "$(doctor_says "$SB_AG_CURRENT")"

expect_eq "the two predicates agree on an rc with no block" \
  "$(setup_says "$SB_AG_ABSENT")" "$(doctor_says "$SB_AG_ABSENT")"
expect_eq "the two predicates agree after a consented setup" \
  "$(setup_says "$SB_AG_CURRENT")" "$(doctor_says "$SB_AG_CURRENT")"
expect_eq "the two predicates agree on a STALE block — the state that separates them" \
  "$(setup_says "$SB_AG_STALE")" "$(doctor_says "$SB_AG_STALE")"

# The fixture is the stale one it claims to be, read through the same extractor
# the rebuild section uses — otherwise the agreement above could be agreement
# about a file that holds no block at all.
expect_eq "the stale fixture holds an older payload's line inside the markers" \
  "$STALE_LINE" "$(rc_block_lines "$SB_AG_STALE/.zshrc")"

# STALE IS ITS OWN ANSWER, not a second spelling of absent. Markers with a
# foreign line is a machine that consented and now carries a line bionic no
# longer writes; markers absent is a machine that was never asked or said no.
# Doctor routes the first to a rewrite and leaves the second alone, so the fact
# function has to tell them apart.
expect_eq "detect reports a stale block as stale" \
  "env:rc-claude-proxy present=stale" "$(detect_run "$SB_AG_STALE")"
expect_eq "detect still reports no block at all as absent" \
  "env:rc-claude-proxy present=no" "$(detect_run "$SB_AG_ABSENT")"

ROW_STALE="$(report_row "$(doctor_run "$SB_AG_STALE")" "$DOCTOR_ROW_LABEL")"
expect_nonempty "doctor renders a proxy row on a stale block" "$ROW_STALE"
expect_contains "the stale row says stale"                     "stale"         "$ROW_STALE"
expect_contains "the stale row routes the reader to setup"     "/bionic:setup" "$ROW_STALE"
expect_ne "the stale row is not the healthy row" "$ROW_PRESENT" "$ROW_STALE"

section "remove: the block goes, every other line stays"

SB_RM="$(new_sandbox)"
cp "$SB_RM/.zshrc" "$TMP/rm-before.zshrc"
setup_run "$SB_RM" y >/dev/null 2>&1
expect_nonempty "the block is there to remove" "$(rc_block_lines "$SB_RM/.zshrc")"
RM_OUT="$(remove_run "$SB_RM" y)"
expect_empty "after remove the block is gone" "$(rc_block_lines "$SB_RM/.zshrc")"
expect_eq "after remove no start marker survives" "0" \
  "$(count_lines_equal "$SB_RM/.zshrc" "$RC_START_LIT")"
expect_eq "after remove no end marker survives" "0" \
  "$(count_lines_equal "$SB_RM/.zshrc" "$RC_END_LIT")"
expect_same_bytes "after remove the rc is byte-identical to the planted file" \
  "$TMP/rm-before.zshrc" "$SB_RM/.zshrc"
expect_contains "remove names the file it changed" "${SB_RM}/.zshrc" "$RM_OUT"

section "remove: the standalone door does the same"

# The script alone, with no scripts/lib beside it — the curl-fetched shape.
mkdir -p "$TMP/standalone"
cp "$REMOVE_SH" "$TMP/standalone/remove.sh"

SB_SA="$(new_sandbox)"
cp "$SB_SA/.zshrc" "$TMP/sa-before.zshrc"
setup_run "$SB_SA" y >/dev/null 2>&1
expect_nonempty "the standalone arm has a block to remove" "$(rc_block_lines "$SB_SA/.zshrc")"
SA_OUT="$(remove_run "$SB_SA" y "$TMP/standalone/remove.sh")"
expect_empty "the standalone door strips the block too" "$(rc_block_lines "$SB_SA/.zshrc")"
expect_same_bytes "the standalone door leaves the rest of the rc byte-identical" \
  "$TMP/sa-before.zshrc" "$SB_SA/.zshrc"

# THE PIN. The standalone door cannot source env.sh, so it carries copies; a
# copy that drifts is a block setup writes and remove cannot find.
RM_RC_START_COPY="$(const_from "$REMOVE_SH" RM_RC_START)" || RM_RC_START_COPY=""
RM_RC_END_COPY="$(const_from "$REMOVE_SH" RM_RC_END)"     || RM_RC_END_COPY=""
expect_nonempty "remove.sh carries an RM_RC_START copy" "$RM_RC_START_COPY"
expect_nonempty "remove.sh carries an RM_RC_END copy"   "$RM_RC_END_COPY"
expect_eq "RM_RC_START is byte-equal to env.sh's RC_START" "$ENV_RC_START" "$RM_RC_START_COPY"
expect_eq "RM_RC_END is byte-equal to env.sh's RC_END"     "$ENV_RC_END"   "$RM_RC_END_COPY"

section "env.sh: rc_get sees the line only inside the markers"

SB_G="$(new_sandbox)"
setup_run "$SB_G" y >/dev/null 2>&1
env_run "$SB_G" /bin/zsh -- rc_get claude-proxy >/dev/null 2>&1
expect_eq "rc_get is 0 when the block holds the line" "0" "$?"

# The same file with the same proxy line OUTSIDE the markers: a line bionic does
# not own, which rc_get must not claim.
SB_H="$(new_sandbox)"
printf '%s\n' "$PROXY_LINE" >> "$SB_H/.zshrc"
env_run "$SB_H" /bin/zsh -- rc_get claude-proxy >/dev/null 2>&1
expect_ne "rc_get is non-zero for the same line outside the markers" "0" "$?"

section "a stale in-block line: the block is rebuilt, never filtered"

# WHAT THIS SECTION OWNS. What setup and remove do to a marker block that holds
# something other than the current `rc_default` line. Everything above this
# point runs on a block that is either empty or exactly that line, so nothing
# above it can see a rebuild go wrong (epic-18 wave-03 critic F1/F2).

# THE SYNTAX EXTRACTOR IS PROVED TO DISCRIMINATE BEFORE ANYTHING IS ASKED OF IT:
# it calls the planted fixture well-formed and a deliberately broken file
# broken, through the same function.
printf '%s\n' 'if [ 1 = 1 ]' > "$TMP/broken.zshrc"

SB_ST1="$(new_stale_sandbox)"
cp "$SB_ST1/.zshrc" "$TMP/stale-before.zshrc"
expect_eq "zsh -n calls the planted stale rc well-formed" \
  "ok" "$(zsh_syntax_rc "$TMP/stale-before.zshrc")"
expect_ne "zsh -n calls a deliberately broken rc broken" \
  "ok" "$(zsh_syntax_rc "$TMP/broken.zshrc")"

STALE_BLOCK_BEFORE="$(rc_block_lines "$SB_ST1/.zshrc")"
STALE_OUTSIDE_BEFORE="$(rc_nonblock_lines "$SB_ST1/.zshrc")"
env_run "$SB_ST1" /bin/zsh -- rc_get claude-proxy >/dev/null 2>&1
STALE_GET_BEFORE=$?

setup_run "$SB_ST1" y >/dev/null 2>&1
env_run "$SB_ST1" /bin/zsh -- rc_get claude-proxy >/dev/null 2>&1
STALE_GET_AFTER=$?

expect_eq "a consented setup over a stale block leaves the rc well-formed" \
  "ok" "$(zsh_syntax_rc "$SB_ST1/.zshrc")"
expect_nonempty "the stale fixture had a block before setup" "$STALE_BLOCK_BEFORE"
expect_eq "after setup the block holds exactly the proxy function" \
  "$PROXY_LINE" "$(rc_block_lines "$SB_ST1/.zshrc")"
expect_eq "after setup the proxy line appears exactly once" "1" \
  "$(count_lines_equal "$SB_ST1/.zshrc" "$PROXY_LINE")"
expect_eq "after setup the stale line is gone" "0" \
  "$(count_lines_equal "$SB_ST1/.zshrc" "$STALE_LINE")"
expect_eq "the stale line was in the fixture to go" "1" \
  "$(count_lines_equal "$TMP/stale-before.zshrc" "$STALE_LINE")"
expect_eq "rc_get sees the line setup wrote over the stale block" "0" "$STALE_GET_AFTER"
expect_ne "rc_get did not read the stale line as bionic's" "0" "$STALE_GET_BEFORE"
expect_nonempty "the stale fixture has lines outside the block" "$STALE_OUTSIDE_BEFORE"
expect_eq "setup leaves every line outside the block untouched" \
  "$STALE_OUTSIDE_BEFORE" "$(rc_nonblock_lines "$SB_ST1/.zshrc")"

# What the file must be once bionic's block is out of it: the four non-bionic
# lines, in the order they were planted, and nothing else.
{
  printf '%s\n' '# a line that was here before bionic'
  printf '%s\n' 'export EDITOR=vim'
  printf '%s\n' "alias ll='ls -la'"
  printf '%s\n' 'export PAGER=less'
} > "$TMP/stale-after-remove.zshrc"

SB_ST2="$(new_stale_sandbox)"
cp "$SB_ST2/.zshrc" "$TMP/stale2-before.zshrc"
STALE_BLOCK_BEFORE_RM="$(rc_block_lines "$SB_ST2/.zshrc")"
remove_run "$SB_ST2" y >/dev/null 2>&1

expect_nonempty "the stale block was there for remove to strip" "$STALE_BLOCK_BEFORE_RM"
expect_empty "after remove the stale block is gone" "$(rc_block_lines "$SB_ST2/.zshrc")"
expect_eq "after remove no start marker survives a stale block" "0" \
  "$(count_lines_equal "$SB_ST2/.zshrc" "$RC_START_LIT")"
expect_eq "after remove no end marker survives a stale block" "0" \
  "$(count_lines_equal "$SB_ST2/.zshrc" "$RC_END_LIT")"
expect_eq "the end marker was in the fixture to go" "1" \
  "$(count_lines_equal "$TMP/stale2-before.zshrc" "$RC_END_LIT")"
expect_same_bytes "remove leaves a stale rc as its non-bionic lines, byte for byte" \
  "$TMP/stale-after-remove.zshrc" "$SB_ST2/.zshrc"
expect_eq "remove over a stale block leaves the rc well-formed" \
  "ok" "$(zsh_syntax_rc "$SB_ST2/.zshrc")"

# The standalone door has no env.sh to call, so it strips the block with its own
# copy of the walk; on this fixture the two doors must land on the same bytes.
SB_ST3="$(new_stale_sandbox)"
remove_run "$SB_ST3" y "$TMP/standalone/remove.sh" >/dev/null 2>&1
expect_same_bytes "the standalone door strips a stale block to the same bytes" \
  "$TMP/stale-after-remove.zshrc" "$SB_ST3/.zshrc"

finish
