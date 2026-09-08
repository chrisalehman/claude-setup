#!/bin/bash
# tests/render.test.sh — the render pipeline's two check arms (epic-22 wave-01 slice 1,
# REQ-R1: AC-R1.1 and AC-R1.4).
#
# WHAT THIS SUITE OWNS. The ARCHIVE arm of `agents-src/render.sh`, and the tree arm's
# positive control. It does NOT own the passage-identity pins or the hand-edit arm on the
# tree check — those are tests/docs-pins.test.sh sections 7 and 11, which the same wave's
# cherry-pick rewrote, and moving them here would be churn with no reader.
#
# WHY THE ARCHIVE ARM EXISTS AT ALL. `--check` reads the sources ON DISK. A render input
# that is gitignored, untracked or merely unstaged is on disk, so the check renders WITH
# it, agrees with the finals that were rendered with it, and reports green — while a clone
# of HEAD, which is what an install and every other machine gets, would render something
# else. `--check --archive` unpacks `git archive HEAD` into a scratch directory, renders
# from THAT, and diffs against the working tree's finals and manifest. The gap between the
# two answers is the whole defect class.
#
# THE ANTI-VACUITY SHAPE. Every plant below asserts BOTH arms: the tree arm GREEN and the
# archive arm RED on the same fixture. An arm that were merely red for its own reasons
# would pass a "the plant turned it red" assertion for free, and an arm that only
# duplicated --check would fail the "tree arm green" half. The unplanted fixture in
# section 2 is the control that makes both halves mean something.
#
# HERMETIC. Every drive runs against a scratch git repository built under this suite's own
# mktemp root from copies of the repo's render inputs and outputs. The repo is read and
# never written, and no drive touches the developer's git config: every git call carries
# its own identity with `-c`.
#
# Usage: bash tests/render.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="$BIONIC_SCRIPTS_DIR"
RENDER_SH="$REPO/agents-src/render.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/render-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# rt_git <dir> <args...> — git in a fixture, with an identity of its own and the
# developer's hooks, signing and templates out of the way. Stderr is dropped: git's advice
# lines are not this suite's verdict, and the runner is stderr-strict.
rt_git() {
  local dir="$1"; shift
  git -C "$dir" \
      -c user.name="render test" -c user.email="render@test.invalid" \
      -c commit.gpgsign=false -c core.hooksPath=/dev/null \
      "$@" >/dev/null 2>&1
}

# rt_fixture <dir> — a scratch tree carrying the render inputs and outputs, committed to a
# git repository of its own so that `git archive HEAD` has something to say. Returns
# non-zero if any step fails, so a section can report a broken fixture rather than assert
# against one.
rt_fixture() {
  local dir="$1"
  mkdir -p "$dir/agents" "$dir/payload/commands" "$dir/payload/.claude-plugin" \
           "$dir/payload/integrity" "$dir/skills/canonical-sdlc" || return 1
  cp -R "$REPO/agents-src" "$dir/agents-src" || return 1
  cp "$REPO"/agents/*.md "$dir/agents/" || return 1
  cp "$REPO"/payload/commands/*.md "$dir/payload/commands/" || return 1
  cp "$REPO/payload/.claude-plugin/plugin.json" "$dir/payload/.claude-plugin/" || return 1
  cp "$REPO/skills/canonical-sdlc/SKILL.md" "$dir/skills/canonical-sdlc/" || return 1
  cp "$REPO/payload/integrity/rendered.sha256" "$dir/payload/integrity/" || return 1
  rt_git "$dir" init || return 1
  rt_git "$dir" add -A || return 1
  rt_git "$dir" commit -m "fixture" || return 1
  return 0
}

# rt_check <dir> <args...> — drive the fixture's own render.sh, leaving RT_OUT (stdout and
# stderr together, which is where the diff and the verdict respectively land) and RT_RC.
RT_OUT=""; RT_RC=0
rt_check() {
  local dir="$1"; shift
  RT_OUT="$(bash "$dir/agents-src/render.sh" "$@" 2>&1)"
  RT_RC=$?
}

# ─────────────────────────────────────────────────────────────────────────────
section "Section 1: the tree arm on this repo (AC-R1.1)"

rt_check "$REPO" --check
expect_status "1a: bash agents-src/render.sh --check exits 0 on the committed tree" 0 "$RT_RC"
expect_match "1b: …and says every final and the manifest match a fresh render" \
  "*every rendered final matches a fresh render*" "$RT_OUT"

# The archive arm on this repo is NOT asserted here. It answers a question about what is
# COMMITTED, and a writer's tree legitimately carries an uncommitted render input mid-slice;
# pinning it against the live checkout would make this suite a function of the developer's
# staging area. Sections 2-6 drive it against fixtures whose commit state the suite owns.

# ─────────────────────────────────────────────────────────────────────────────
section "Section 2: the archive arm's control — an honestly committed tree is green"

FIX_OK="$TMPROOT/control"
if rt_fixture "$FIX_OK"; then
  ok "2a: a scratch git repository of the render tree is built (the control the plants need)"
else
  no "2a: a scratch git repository of the render tree is built (the control the plants need)" \
     "dest: $FIX_OK"
fi

rt_check "$FIX_OK" --check
expect_status "2b: the unplanted fixture's TREE arm is green" 0 "$RT_RC"

rt_check "$FIX_OK" --check --archive
expect_status "2c: the unplanted fixture's ARCHIVE arm is green" 0 "$RT_RC"
expect_match "2d: …and it says so in the archive arm's own words" \
  "*matches a render of git archive HEAD*" "$RT_OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 3: a gitignored render input — the tree arm cannot see it, the archive arm can (AC-R1.4)"

# THE PLANT. A block file that is on disk and OUT of HEAD, injected by a template that IS
# in HEAD, with the finals rendered and committed. This is the exact shape the arm exists
# for: everything a reader of the repository can see agrees with everything else, and the
# text in the shipped file comes from a file no clone receives.
FIX_IGN="$TMPROOT/gitignored"
RT_IGN_READY=no
if rt_fixture "$FIX_IGN"; then
  printf 'agents-src/blocks/planted.md\n' > "$FIX_IGN/.gitignore"
  printf 'PLANTED BLOCK BODY — reaches the final, never reaches HEAD.\n' \
    > "$FIX_IGN/agents-src/blocks/planted.md"
  printf '\n<!-- INJECT: planted -->\n' \
    >> "$FIX_IGN/agents-src/templates/skills/canonical-sdlc/SKILL.md.tmpl"
  if bash "$FIX_IGN/agents-src/render.sh" >/dev/null 2>&1 \
     && rt_git "$FIX_IGN" add -A && rt_git "$FIX_IGN" commit -m "plant"; then
    RT_IGN_READY=yes
  fi
fi
expect_eq "3a: the gitignored-input fixture is built and its finals are committed" "yes" "$RT_IGN_READY"

expect_true "3b: …the planted block is really absent from HEAD" \
  bash -c "! git -C '$FIX_IGN' cat-file -e HEAD:agents-src/blocks/planted.md 2>/dev/null"
expect_true "3c: …and its text really did reach the committed final" \
  grep -qF 'PLANTED BLOCK BODY' "$FIX_IGN/skills/canonical-sdlc/SKILL.md"

rt_check "$FIX_IGN" --check
expect_status "3d: the TREE arm is GREEN — it reads the on-disk block, so it sees nothing wrong" \
  0 "$RT_RC"

rt_check "$FIX_IGN" --check --archive
expect_ne "3e: the ARCHIVE arm is RED on the same tree" "0" "$RT_RC"
expect_match "3f: …and it names the render input HEAD is missing" "*planted*" "$RT_OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 4: a source edit left out of the commit — the arm DIFFS, it does not only detect missing files"

# A different failure mode of the same class, and the one that proves the arm compares
# BYTES rather than merely surviving the render: the block is tracked and present in HEAD,
# its edit is not, and the finals rendered from that edit are committed. The archive render
# therefore succeeds and produces DIFFERENT text.
FIX_DIFF="$TMPROOT/unstaged"
RT_DIFF_READY=no
if rt_fixture "$FIX_DIFF"; then
  printf '\nUNCOMMITTED SOURCE SENTENCE.\n' >> "$FIX_DIFF/agents-src/blocks/survival.md"
  if bash "$FIX_DIFF/agents-src/render.sh" >/dev/null 2>&1 \
     && rt_git "$FIX_DIFF" add agents payload skills \
     && rt_git "$FIX_DIFF" commit -m "finals only"; then
    RT_DIFF_READY=yes
  fi
fi
expect_eq "4a: the unstaged-source fixture is built (finals committed, the block edit is not)" \
  "yes" "$RT_DIFF_READY"

rt_check "$FIX_DIFF" --check
expect_status "4b: the TREE arm is GREEN — on-disk source and on-disk finals agree" 0 "$RT_RC"

rt_check "$FIX_DIFF" --check --archive
expect_ne "4c: the ARCHIVE arm is RED" "0" "$RT_RC"
expect_match "4d: …and it names a rendered final that HEAD does not reproduce" \
  "*agents/auditor.md*" "$RT_OUT"
expect_match "4e: …and prints the difference as a diff, not only a verdict" \
  "*UNCOMMITTED SOURCE SENTENCE*" "$RT_OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 5: the manifest half, and that --archive never writes"

FIX_MAN="$TMPROOT/manifest"
RT_MAN_READY=no
rt_fixture "$FIX_MAN" && RT_MAN_READY=yes
expect_eq "5a: the manifest fixture is built" "yes" "$RT_MAN_READY"

# One doctored digest in the working tree's manifest. The finals are untouched, so only the
# manifest half of the comparison can catch it.
RT_ZEROS="0000000000000000000000000000000000000000000000000000000000000000"
sed -i.bak "5s/^[0-9a-f]\{64\}/$RT_ZEROS/" \
  "$FIX_MAN/payload/integrity/rendered.sha256" 2>/dev/null
rm -f "$FIX_MAN/payload/integrity/rendered.sha256.bak"
expect_true "5b: the doctored digest really is in the fixture's manifest" \
  grep -qF "$RT_ZEROS" "$FIX_MAN/payload/integrity/rendered.sha256"

rt_check "$FIX_MAN" --check --archive
expect_ne "5c: a doctored manifest digest turns the archive arm red" "0" "$RT_RC"
expect_match "5d: …and it names the manifest" "*payload/integrity/rendered.sha256*" "$RT_OUT"

# --archive IMPLIES --check and has no write form: a run of it must leave the doctored
# manifest exactly as doctored. A mode that quietly rewrote the tree from a render of HEAD
# would discard whatever the tree was carrying — the opposite of a reproducibility check.
expect_true "5e: --archive wrote nothing — the doctored row is still doctored" \
  grep -qF "$RT_ZEROS" "$FIX_MAN/payload/integrity/rendered.sha256"

# The bare form takes the same path: it implies --check, and writes nothing either.
rt_check "$FIX_MAN" --archive
expect_ne "5f: the bare --archive form is a check too (red on the same doctored manifest)" \
  "0" "$RT_RC"
expect_true "5g: …and it wrote nothing either" \
  grep -qF "$RT_ZEROS" "$FIX_MAN/payload/integrity/rendered.sha256"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 6: the arm refuses rather than passes when it cannot do its job"

# A directory with no git repository cannot answer the archive question. Reporting green
# there would be the worst outcome available: a check that silently means nothing.
FIX_NOGIT="$TMPROOT/nogit"
mkdir -p "$FIX_NOGIT"
cp -R "$FIX_OK/agents-src" "$FIX_NOGIT/agents-src" 2>/dev/null
cp -R "$FIX_OK/agents" "$FIX_NOGIT/agents" 2>/dev/null
cp -R "$FIX_OK/payload" "$FIX_NOGIT/payload" 2>/dev/null
cp -R "$FIX_OK/skills" "$FIX_NOGIT/skills" 2>/dev/null
# GIT_CEILING_DIRECTORIES stops the rev-parse from climbing out of the fixture and finding
# some enclosing repository — without it this arm would depend on where TMPDIR happens to be.
RT_OUT="$(GIT_CEILING_DIRECTORIES="$TMPROOT" bash "$FIX_NOGIT/agents-src/render.sh" --check --archive 2>&1)"
RT_RC=$?
expect_ne "6a: --archive outside a git work tree refuses" "0" "$RT_RC"
expect_match "6b: …and says what it needed" "*git work tree*" "$RT_OUT"

expect_true "6c: the renderer documents the arm in its own usage block" \
  grep -qF 'THE ARCHIVE ARM' "$RENDER_SH"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 7: a stray template under the role unit never becomes a phantom role file (A15, S10, AC-R4.3)"

# THE DEFECT THIS GUARDS AGAINST. `agents-src/templates` (the role unit) is a flat
# `*.md.tmpl` glob with no membership check of its own — RENDER_UNITS names the
# directory, never the files inside it. A template dropped there whose basename names no
# role in $ROLES would render exactly like a real role template: a phantom output file
# nothing else in the tree references, silently added to the manifest by a bare write run.
FIX_A15="$TMPROOT/a15-stray"
RT_A15_READY=no
if rt_fixture "$FIX_A15"; then
  # A WELL-FORMED TEMPLATE, not garbage — the defect is a role-shaped file that simply
  # names no role in $ROLES (e.g. an orchestrator template dropped in the role unit by
  # mistake), never a template render_one would reject on its own merits. Built from a
  # real role template's own frontmatter shape so it clears render_one's GENERATED-HEADER
  # and frontmatter requirements exactly as a real stray would.
  {
    printf -- '---\nname: not-a-role\ndescription: fixture only, plugin ships no such role.\nmodel: opus\neffort: high\n---\n\n'
    printf -- '<!-- GENERATED-HEADER -->\n\n## Role\n\nSTRAY TEMPLATE BODY — this file names no role in $ROLES.\n'
  } > "$FIX_A15/agents-src/templates/not-a-role.md.tmpl"
  RT_A15_READY=yes
fi
expect_eq "7a: the stray-template fixture is built" "yes" "$RT_A15_READY"

rt_check "$FIX_A15" --check
expect_status "7b: --check on a tree carrying an un-rendered stray template stays green" \
  0 "$RT_RC"

bash "$FIX_A15/agents-src/render.sh" >/dev/null 2>&1
expect_true "7c: a write run creates no phantom output file for the stray template" \
  bash -c "[ ! -e '$FIX_A15/agents/not-a-role.md' ]"
expect_false "7d: …and the phantom path never enters the manifest" \
  grep -qF 'not-a-role.md' "$FIX_A15/payload/integrity/rendered.sha256"

# THE PAIRED POSITIVE: a template that DOES name a role still renders, so 7c/7d are the
# guard discriminating on membership, not merely on being new.
FIX_A15R="$TMPROOT/a15-real-role"
RT_A15R_READY=no
if rt_fixture "$FIX_A15R"; then
  cp "$FIX_A15R/agents-src/templates/auditor.md.tmpl" \
     "$FIX_A15R/agents-src/templates/auditor.md.tmpl.orig" 2>/dev/null
  RT_A15R_READY=yes
fi
expect_eq "7e: the real-role control fixture is built" "yes" "$RT_A15R_READY"
bash "$FIX_A15R/agents-src/render.sh" >/dev/null 2>&1
expect_true "7f: …a template naming a real role still renders (7c-7d discriminate on membership)" \
  test -f "$FIX_A15R/agents/auditor.md"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 8: render.sh itself is a render input the archive arm compares (A-18)"

# THE GAP THIS CLOSES (A-18; s01-render-pipeline's A-S01-1). Every OTHER source under
# --archive is read from the `git archive HEAD` copy, but the loop that reads them runs
# as THIS invocation of render.sh, on disk — so an uncommitted edit to the renderer
# itself was exercised by the archive arm, never compared by it, until now.
FIX_SELF="$TMPROOT/self-edit"
RT_SELF_READY=no
if rt_fixture "$FIX_SELF"; then
  printf '\n# UNCOMMITTED RENDERER EDIT — never reached HEAD\n' \
    >> "$FIX_SELF/agents-src/render.sh"
  RT_SELF_READY=yes
fi
expect_eq "8a: the self-edited-renderer fixture is built" "yes" "$RT_SELF_READY"

rt_check "$FIX_SELF" --check
expect_status "8b: the TREE arm is GREEN — the edit touches no rendered final or manifest" \
  0 "$RT_RC"

rt_check "$FIX_SELF" --check --archive
expect_ne "8c: the ARCHIVE arm is RED — this run of render.sh is not what HEAD carries" \
  "0" "$RT_RC"
expect_match "8d: …and it names render.sh itself" "*agents-src/render.sh*" "$RT_OUT"

# THE CONTROL: an unedited fixture's archive arm (Section 2) stays green with the digest
# arm wired in — 8c is the digest arm firing, not a false positive on every fixture.
rt_check "$FIX_OK" --check --archive
expect_status "8e: …while an honestly-committed renderer keeps the archive arm green" \
  0 "$RT_RC"

# ─────────────────────────────────────────────────────────────────────────────
section "Section 9: browser-verify's frontmatter description is valid YAML (A19, AC-R4.3)"

# THE DEFECT (A19). A `description:` scalar with an unquoted `: ` sequence deep inside its
# own value ("picking the input rung by surface: ref-based commands…") is ambiguous YAML —
# a bare colon-space inside a plain scalar opens a second mapping a strict parser is
# entitled to reject. The fix wraps the whole value in double quotes.
#
# NO PyYAML on this machine — `python3 -c 'import yaml'` fails here — so this is the
# "strict awk" alternative the brief allows: an unquoted top-level scalar containing its
# own `: ` is flagged; a quoted scalar is valid as long as its closing quote is present.
rt_yaml_frontmatter_ok() {  # <file> -> exit 0 (valid) or 1 (first violation), on stdout
  awk '
    /^---[ \t]*$/ { d++; next }
    d==1 {
      if ($0 !~ /^[A-Za-z_][A-Za-z0-9_-]*:[ \t]*/) next
      line=$0
      sub(/^[A-Za-z0-9_-]+:[ \t]*/, "", line)
      val=line
      if (val ~ /^"/) { if (val !~ /"[ \t]*$/) { print "UNTERMINATED: " $0; bad=1 } }
      else if (val ~ /^\x27/) { if (val !~ /\x27[ \t]*$/) { print "UNTERMINATED: " $0; bad=1 } }
      else if (val ~ /: /) { print "UNQUOTED COLON: " $0; bad=1 }
    }
    d>=2 { exit }
    END { exit bad }
  ' "$1"
}

BV_SKILL="$REPO/skills/browser-verify/SKILL.md"
expect_true "9a: browser-verify/SKILL.md exists" test -f "$BV_SKILL"

rt_yaml_frontmatter_ok "$BV_SKILL" >/dev/null
expect_status "9b: its frontmatter's description parses as a valid scalar (quoted, A19)" \
  0 "$?"

# THE PAIRED NEGATIVE: the pre-A19 shape (same text, unquoted) really does fail the same
# check, so 9b is not vacuous.
BV_BROKEN="$TMPROOT/browser-verify-broken.md"
sed 's/^description: "\(.*\)"$/description: \1/' "$BV_SKILL" > "$BV_BROKEN"
expect_true "9c: …the un-A19'd text really did lose its quoting in the fixture" \
  bash -c "! grep -q '^description: \"' '$BV_BROKEN'"
rt_yaml_frontmatter_ok "$BV_BROKEN" >/dev/null
expect_ne "9d: …and reverting the quoting on the same text really does fail it (9b discriminates)" \
  "0" "$?"

finish
