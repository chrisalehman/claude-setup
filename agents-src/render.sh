#!/usr/bin/env bash
# agents-src/render.sh — renders the repo's GENERATED markdown from the templates and shared
# blocks in this directory. Epic-17 W4 S2, spec AC-2; design ledger D1. Generalized to a
# second render unit at W6 S1 (spec AC-6; ratified D-C).
#
# WHY THIS EXISTS. Text that must be word-identical across several files was previously held
# in agreement by pairwise byte-diff arms in the suite — identity by ENFORCEMENT, which is
# green right up until someone edits five of the six. Here there is one copy of each block
# and the finals are generated, so they cannot disagree: identity by CONSTRUCTION.
#
# THREE RENDER UNITS, ONE PIPELINE:
#
#   agents-src/templates/          -> agents/              the six agent role files. Shared
#                                                          duty text: the reporting contract
#                                                          (all six), the implementor core
#                                                          (both implementors), the survival
#                                                          rules (all six).
#   agents-src/templates/commands/ -> payload/commands/    the four shipped slash-command
#                                                          files. Shared text: the
#                                                          presentation contract, one block,
#                                                          in all four (W6 spec AC-6).
#   agents-src/templates/skills/   -> skills/              the governing skill file, whole
#     canonical-sdlc/                 canonical-sdlc/      (wave-02 spec AC-6, DD-2). Shared
#                                                          text: the auditor mandate, the
#                                                          critic prompt template, the
#                                                          duplication axis, the terminal-
#                                                          disposition rule, and the
#                                                          orchestrator's dispatch body.
#
# WHY THE SKILL FILE IS A RENDER TARGET (wave-02 DD-2). Until this unit existed the skill
# file was hand-written, and four of its passages were hand-copied into role files under
# `canonical copy of ...` markers with no agreement test between them: the exact failure
# mode named above, in the one file that defines the method. A copy under a marker is a
# promise; an injection is a fact. The unit's template dir is the LEAF directory
# (templates/skills/canonical-sdlc), not templates/skills, because every unit's template
# glob is one level deep by construction — see the note beside the glob below.
#
# THE SHIPPING BOUNDARY. agents/ and payload/commands/ are product — the plugin installs
# those files. THIS directory is build-time apparatus and never ships;
# tests/plugin-payload.test.sh §G is the wall that keeps it repo-side.
#
#   agents-src/blocks/<name>.md               one shared block, body text only
#   agents-src/templates/<role>.md.tmpl       one role skeleton with directives
#   agents-src/templates/commands/<cmd>.md.tmpl  one command skeleton with directives
#   agents/<role>.md, payload/commands/<cmd>.md  the committed, shipped, generated finals
#
# TEMPLATE DIRECTIVES, each on a line of its own:
#
#   <!-- GENERATED-HEADER -->    expands to the do-not-edit header. Exactly one per
#                                template, and it belongs AFTER the closing frontmatter
#                                fence — Claude Code reads name/model/effort from a role's
#                                fence and `description` from a command's, and a fence has
#                                to start on line 1, so nothing may precede it.
#   <!-- INJECT: <name> -->      expands to blocks/<name>.md wrapped in <!-- NAME-BEGIN -->
#                                / <!-- NAME-END --> markers, the marker name being the
#                                block's own filename upper-cased. Marker and source can
#                                therefore never drift apart.
#
# ONE PLACEHOLDER, substituted INLINE wherever it appears in a template line:
#
#   @@PLUGIN_VERSION@@           the `.version` field of payload/.claude-plugin/plugin.json.
#                                Unlike the two directives above it is not a line of its own:
#                                the SENTENCE belongs to the template (help.md's opening line
#                                reads `bionic @@PLUGIN_VERSION@@ (installed)`) and only the
#                                VALUE comes from here.
#
# WHY THE VERSION IS BAKED AT RENDER TIME (epic-17 W6 S9a, walk finding W-2). help.md used to
# read plugin.json at RUNTIME, from ${CLAUDE_PLUGIN_ROOT}, so that the page and the manifest
# could not disagree. The Step-5 walk measured what that costs a user: run /bionic:help from
# any session whose working directory is not this repo and the read is REFUSED — a permission
# notice one time, a working-directory sandbox error the next — printed above the page, in
# different words each time, with no version line either way. Baking it moves plugin.json
# from a file the shipped page reads into a file THIS PIPELINE reads, which is a source like
# any block or template: `--check` goes red when the committed page and the committed
# plugin.json disagree, in both directions, so plugin.json stays the version's single owner
# and help.md is a rendering of it — the same relationship marketplace.json has with the
# dependency list. A missing or version-less plugin.json is a hard failure, for the same
# reason a missing block is: a page rendered with a hole in it would leave --check green.
#
# Section HEADINGS stay in the templates rather than in the blocks: a block owns doctrine,
# a template owns document structure, and a final is free to place a shared block under
# whatever heading reads right for that file.
#
# WHY THE COMMAND HEADER IS WORDED DIFFERENTLY. The role-file header names this script and
# the suite that guards it. A command file may not: three suites pin every `.sh` token in
# payload/commands/*.md to be an invocation rooted at ${CLAUDE_PLUGIN_ROOT}, because a
# command file naming any other script is naming something the machine cannot run. A build
# instruction in a shipped file is not worth reopening that rule, so the command header
# carries the same warning and the same source pointer with no script filenames in it.
#
# USAGE
#   bash agents-src/render.sh            rewrite every final and the checksum manifest
#                                        (payload/integrity/rendered.sha256, spec AC-4 and
#                                        wave-02 AC-8 — the file /bionic:doctor reads to
#                                        tell a user whether their installed rendered files
#                                        are stock)
#   bash agents-src/render.sh --check    re-render into memory and diff against the
#                                        committed finals AND the committed manifest;
#                                        exit 1 with the diff if any differ. This is the
#                                        whole staleness class in one command, and
#                                        tests/docs-pins.test.sh (section 7) and
#                                        tests/command-relay.test.sh (A5) are where it runs.
#                                        It
#                                        fails identically whether the OUTPUT was
#                                        hand-edited or a SOURCE was edited without a
#                                        re-render, which is the point: both mean the
#                                        committed file is not the render of the committed
#                                        source.
#   bash agents-src/render.sh --archive  the same comparison with the SOURCES taken from
#                                        `git archive HEAD` instead of the working tree.
#                                        Implies --check; there is no write form.
#
# THE ARCHIVE ARM, and why --check alone is not enough. --check reads the sources that are
# ON DISK. A render input that is untracked, gitignored, or simply not staged is on disk,
# so --check renders with it, agrees with the finals that were rendered with it, and goes
# green — while a clone of HEAD, which is what every other machine and every install gets,
# would render something else. --archive closes that gap by unpacking HEAD into a scratch
# directory, rendering from THAT, and diffing against the working tree's committed finals
# and manifest. Red means: the finals this tree carries are not reproducible from what is
# committed, and the diff names the file. The repair is to commit the missing input (or,
# if it was never meant to be a source, to delete it and re-render).
#
# Every directory is derived from this script's own location, never from $PWD, so a copy of
# the tree in a temp directory renders against ITS OWN outputs — that is what lets the suite
# plant staleness into a fixture without touching the repo.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd -P)"

# THE TWO ROOTS. Sources — templates, blocks, plugin.json — are read under SRC_ROOT; the
# committed finals a check compares against, and the manifest, live under OUT_ROOT. For
# every ordinary run they are the same directory and nothing here is visible. `--archive`
# is the one mode that separates them: it unpacks `git archive HEAD` into a scratch
# directory and points SRC_ROOT there, leaving OUT_ROOT on the working tree. See THE
# ARCHIVE ARM in the usage block above for why that is a different question from --check.
SRC_ROOT="$REPO_DIR"
OUT_ROOT="$REPO_DIR"

# THE UNIT TABLE: one row per (templates dir -> output dir), both repo-relative. Adding a
# third rendered surface is a row here and nothing else; every loop below is driven from it,
# so a new unit cannot be half-wired — rendered by the write path and invisible to --check.
RENDER_UNITS="
agents-src/templates|agents
agents-src/templates/commands|payload/commands
agents-src/templates/skills/canonical-sdlc|skills/canonical-sdlc
"

ROLES="auditor critic implementor researcher senior-implementor test-runner"

# THE CHECKSUM MANIFEST (epic-17 W4 S5, spec AC-4; widened at wave-02 S2a, spec AC-8).
# /bionic:doctor compares a user's installed rendered files against this file and reports
# one line: stock, or modified locally. It is written HERE, by the same command that writes
# the finals, for one reason — a manifest maintained separately is a manifest that ships
# stale, and a stale manifest accuses a user who edited nothing. The paths inside it are
# PLUGIN-ROOT-relative, which is what they resolve to on the installed machine and, through
# payload/agents -> ../agents and payload/skills/canonical-sdlc -> ../../skills/canonical-sdlc,
# here as well: an output path under payload/ loses that prefix, and one outside payload/ is
# already the name the plugin root carries.
#
# IT COVERS EVERY RENDERING, one row per output of every unit — the six role files, the four
# command files, and the skill file. Widening it past the role files was wave-02 AC-8's own
# acceptance criterion, not a side effect: a manifest that answered for three of eleven
# rendered files would report a doctored command page or a doctored method as stock. Rows
# are emitted in unit-table order and, within a unit, in glob order, so the file a write
# produces and the file a --check recomputes cannot differ by ordering alone.
MANIFEST_REL="payload/integrity/rendered.sha256"
PLUGIN_JSON_REL="payload/.claude-plugin/plugin.json"
VERSION_PLACEHOLDER='@@PLUGIN_VERSION@@'

# Every path either root decides, in one place, so that moving a root moves all of them.
# Called once now (so nothing below is unset under `set -u`) and again after the argument
# parse, which is the only thing that can move SRC_ROOT.
derive_roots() {
  SRC_DIR="$SRC_ROOT/agents-src"
  BLOCK_DIR="$SRC_DIR/blocks"
  PLUGIN_JSON="$SRC_ROOT/$PLUGIN_JSON_REL"
  MANIFEST="$OUT_ROOT/$MANIFEST_REL"
}
derive_roots

die() { echo "render.sh: $1" >&2; exit 1; }

# The plugin version, read once and cached. Read LAZILY — only a template that actually
# carries the placeholder needs it — so a render unit that has nothing to do with the plugin
# manifest does not acquire a dependency on it, and the error, when there is one, names the
# template that asked.
#
# `jq` when it is here, a field read when it is not: this script runs from the suite on
# machines where jq is a bionic dependency rather than a given, and a renderer that silently
# skipped the substitution on such a machine would commit a page with the placeholder still
# in it. Both paths return the same bytes for a manifest of this shape, and an empty result
# from either is a failure, never a default.
PLUGIN_VERSION=""
plugin_version() {
  [ -n "$PLUGIN_VERSION" ] && { printf '%s' "$PLUGIN_VERSION"; return 0; }
  [ -f "$PLUGIN_JSON" ] || { echo "render.sh: $PLUGIN_JSON_REL does not exist, and a template needs the plugin version from it" >&2; return 1; }
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)"
  else
    v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" 2>/dev/null | head -1)"
  fi
  [ -n "$v" ] || { echo "render.sh: $PLUGIN_JSON_REL declares no non-empty .version" >&2; return 1; }
  PLUGIN_VERSION="$v"
  printf '%s' "$PLUGIN_VERSION"
}

# Digest one file. shasum is present on macOS and on any box with perl; sha256sum is the
# GNU spelling. Nothing else is tried: a manifest written by an unknown tool would be a
# manifest doctor cannot reproduce.
sha256_of() {  # <file>
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1")" || return 1
  else
    return 1
  fi
  echo "${out%% *}"
}

# plugin_rel <repo-relative-output-path> -> the path the same file answers to from the
# installed plugin root. `payload/` IS that root, so an output inside it loses the prefix;
# an output outside it (agents/, skills/) is reached from the root by a symlink of the same
# name, so its repo-relative path is already the answer.
plugin_rel() {
  case "$1" in
    payload/*) printf '%s' "${1#payload/}" ;;
    *)         printf '%s' "$1" ;;
  esac
}

# The manifest bytes for the finals just rendered, on stdout. Takes the staging directory
# and the newline-separated list of repo-relative output paths the render loop produced, in
# the order it produced them.
manifest_of_rendered() {  # <staging-dir> <rel-paths, newline separated>
  local dir="$1" rels="$2" rel digest
  echo "# GENERATED — sha256 of every rendered plugin file, plugin-root-relative."
  echo "# Written by agents-src/render.sh alongside the finals themselves; regenerate with"
  echo "# \`bash agents-src/render.sh\`. /bionic:doctor reads it to report whether an installed"
  echo "# machine's rendered files are stock or locally modified."
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    digest="$(sha256_of "$dir/$rel")" || return 1
    printf '%s  %s\n' "$digest" "$(plugin_rel "$rel")"
  done <<EOF
$rels
EOF
}

# generated_header <template-path-relative-to-the-repo>
#
# The header is chosen by WHERE the template lives, because that is what decides where its
# output ships and therefore which rules the output has to satisfy. See "WHY THE COMMAND
# HEADER IS WORDED DIFFERENTLY" above.
generated_header() {
  case "$1" in
    agents-src/templates/commands/*)
      cat <<EOF
<!-- GENERATED FILE — DO NOT EDIT.
     Rendered from $1 and the shared blocks in
     agents-src/blocks/. Edit those, then re-render; the render check goes red whenever
     this file and its sources disagree. -->
EOF
      ;;
    *)
      cat <<EOF
<!-- GENERATED FILE — DO NOT EDIT.
     Rendered by agents-src/render.sh from $1 and the shared
     blocks in agents-src/blocks/. Edit those, then re-run \`bash agents-src/render.sh\`.
     tests/docs-pins.test.sh goes red whenever this file and its sources disagree. -->
EOF
      ;;
  esac
}

# render_one <template-path> <template-path-relative-to-the-repo> → rendered bytes on
# stdout; nonzero (and a reason on stderr) if the template is missing, names a block that
# does not exist, or carries no header directive. A missing block must be loud: a silent
# skip would emit a final with a hole in it and --check would stay green, because output and
# source would still agree.
render_one() {
  local tmpl="$1" tmpl_rel="$2"
  [ -f "$tmpl" ] || { echo "render.sh: no template at $tmpl" >&2; return 1; }

  local line name upper block version saw_header=0
  local role role_tmpl role_model role_effort role_what
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "<!-- GENERATED-HEADER -->")
        generated_header "$tmpl_rel"
        saw_header=$((saw_header + 1))
        ;;
      "<!-- AGENT-ROSTER -->")
        # THE ROSTER IS READ, NEVER TRANSCRIBED. help.md names six roles and the
        # model and effort each one runs at, and those are values that change —
        # a role gets raised to opus, an effort drops to low — in the role
        # sources, where the change is the point. A hand-written table in the
        # help page would be a seventh copy of six facts, and the copy that is
        # wrong is always the one nobody re-read. So the row is generated from
        # the same frontmatter the role file itself is rendered from, and a
        # model change reaches the help page by re-rendering and by nothing else.
        #
        # THE TEMPLATES, NOT THE FINALS, and the ordering is why: this same run
        # is rewriting agents/*.md, and a directive that read the finals would
        # report whatever the PREVIOUS render left there. The template is the
        # source both readings share.
        for role in $ROLES; do
          role_tmpl="$SRC_DIR/templates/$role.md.tmpl"
          [ -f "$role_tmpl" ] || { echo "render.sh: AGENT-ROSTER wants $role_tmpl" >&2; return 1; }
          role_model="$(awk -F': *' '/^model:/ { print $2; exit }' "$role_tmpl")"
          role_effort="$(awk -F': *' '/^effort:/ { print $2; exit }' "$role_tmpl")"
          # The first sentence of the description, which is the half that says
          # what the role is FOR; the rest tells canonical-sdlc when to dispatch
          # it, which is not a thing a user of this page acts on.
          role_what="$(awk -F': *' '/^description:/ { sub(/^description: */, ""); print; exit }' "$role_tmpl" \
                       | awk -F'\\. ' '{ print $1 }')"
          [ -n "$role_model" ] && [ -n "$role_effort" ] && [ -n "$role_what" ] || {
            echo "render.sh: $role.md.tmpl is missing model, effort or description" >&2; return 1; }
          printf '| `%s` | %s · %s | %s |\n' "$role" "$role_model" "$role_effort" "$role_what"
        done
        ;;
      "<!-- INJECT: "*" -->")
        name="${line#<!-- INJECT: }"; name="${name% -->}"
        block="$BLOCK_DIR/$name.md"
        [ -f "$block" ] || { echo "render.sh: $tmpl_rel injects '$name' but $block does not exist" >&2; return 1; }
        upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
        printf '<!-- %s-BEGIN -->\n' "$upper"
        # Command substitution strips trailing newlines; the printf puts exactly one back,
        # so a block source with or without a trailing blank line renders the same bytes.
        printf '%s\n' "$(cat "$block")"
        printf '<!-- %s-END -->\n' "$upper"
        ;;
      *)
        # Bash's own replacement rather than sed: a version string is arbitrary text, and
        # `&` or `|` in it would be a sed metacharacter waiting for a release to trip over.
        if [ "${line#*$VERSION_PLACEHOLDER}" != "$line" ]; then
          version="$(plugin_version)" || return 1
          line="${line//$VERSION_PLACEHOLDER/$version}"
        fi
        printf '%s\n' "$line"
        ;;
    esac
  done < "$tmpl"

  case "$saw_header" in
    1) ;;
    0) echo "render.sh: $tmpl_rel has no <!-- GENERATED-HEADER --> directive" >&2; return 1 ;;
    *) echo "render.sh: $tmpl_rel has $saw_header GENERATED-HEADER directives (want exactly 1)" >&2; return 1 ;;
  esac
  return 0
}

MODE="write"
ARCHIVE="no"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)   MODE="check" ;;
    # --archive implies --check. There is no write form of it on purpose: writing the
    # working tree's finals from a render of HEAD would silently discard whatever source
    # edit the tree is carrying, which is the opposite of what an operator running a
    # reproducibility check wants.
    --archive) MODE="check"; ARCHIVE="yes" ;;
    -h|--help)
      # The leading comment block, verbatim, with its `# ` stripped — no line-number range to
      # fall out of step with the comment it is meant to print.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) die "unknown argument '$1' (want --check, --archive, or no argument to write)" ;;
  esac
  shift
done

# THE ARCHIVE ROOT. `git archive HEAD` is the bytes a stranger gets from a clone: tracked
# files at HEAD and nothing else. Unpacking it and rendering FROM it, while still diffing
# AGAINST the working tree's finals and manifest, is what turns "these finals match their
# sources" into "these finals are reproducible from what is committed". The gap between the
# two answers is exactly a render input that is not in HEAD — untracked, gitignored, or
# merely unstaged — and the tree arm cannot see it, because it reads that input too.
ARCH=""
if [ "$ARCHIVE" = yes ]; then
  command -v git >/dev/null 2>&1 || die "--archive needs git on PATH"
  git -C "$REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1 \
    || die "--archive needs a git work tree with a commit at HEAD ($REPO_DIR)"
  ARCH="$(mktemp -d)" || die "cannot create a temp directory for the archive"
  # No pipe: `git archive | tar -x` under `set -o pipefail` reports the LAST command, and a
  # tar that succeeds on a truncated stream would hide an archive failure. Two steps, two
  # exit codes, each checked.
  git -C "$REPO_DIR" archive --format=tar -o "$ARCH/HEAD.tar" HEAD \
    || { rm -rf "$ARCH"; die "git archive HEAD failed in $REPO_DIR"; }
  tar -xf "$ARCH/HEAD.tar" -C "$ARCH" \
    || { rm -rf "$ARCH"; die "cannot unpack the archive of HEAD into $ARCH"; }
  rm -f "$ARCH/HEAD.tar"
  SRC_ROOT="$ARCH"
  derive_roots
fi

[ -d "$BLOCK_DIR" ] || die "no blocks directory at $BLOCK_DIR"
for unit in $RENDER_UNITS; do
  [ -d "$SRC_ROOT/${unit%%|*}" ] || die "no templates directory at $SRC_ROOT/${unit%%|*}"
  [ -d "$OUT_ROOT/${unit##*|}" ] || die "no output directory at $OUT_ROOT/${unit##*|}"
done

WORK="$(mktemp -d)" || die "cannot create a temp directory"
trap 'rm -rf "$WORK" ${ARCH:+"$ARCH"}' EXIT

RC=0
STALE=""
# Every repo-relative output path the loop rendered, in order — the manifest's row order and
# the only list of what a --check has staged.
RENDERED_RELS=""

# RENDER.SH ITSELF IS A RENDER INPUT, AND THE ARCHIVE ARM DOES NOT COMPARE IT (A-18,
# s01-render-pipeline A-S01-1). Every OTHER source below is read from $SRC_ROOT, which
# --archive points at the `git archive HEAD` copy — but the loop that reads them runs as
# THIS invocation of the script, on disk, possibly mid-edit. So an uncommitted change to
# render.sh itself is exercised by the archive arm rather than compared by it, exactly the
# gap the archive arm exists to close for every other input. One digest closes it: the
# running script against its own committed copy, checked only under --archive (a plain
# --check has no archived copy to compare against, and a write run has no comparison to
# make at all).
if [ "$ARCHIVE" = yes ]; then
  SELF_REL="agents-src/render.sh"
  if [ ! -f "$ARCH/$SELF_REL" ]; then
    echo "render.sh: $SELF_REL is missing from git archive HEAD (uncommitted new script?)" >&2
    STALE="$STALE $SELF_REL"; RC=1
  elif ! cmp -s "$SELF_DIR/render.sh" "$ARCH/$SELF_REL"; then
    echo "── $SELF_REL differs from its committed copy at HEAD ──" >&2
    echo "  this run of render.sh is not the render.sh that HEAD carries, so this archive" >&2
    echo "  check exercised an uncommitted renderer instead of comparing against it." >&2
    STALE="$STALE $SELF_REL"; RC=1
  fi
fi

for unit in $RENDER_UNITS; do
  tmpl_dir="${unit%%|*}"
  out_dir="${unit##*|}"
  mkdir -p "$WORK/$out_dir" || { echo "render.sh: cannot stage $out_dir" >&2; RC=1; continue; }

  # maxdepth 1 by construction: the role unit's directory HOLDS the command unit's and the
  # skill unit's, and a recursive glob would render those twice, into the wrong place the
  # second time. A unit whose templates sit deeper names the deeper directory in the table.
  for tmpl in "$SRC_ROOT/$tmpl_dir"/*.md.tmpl; do
    [ -f "$tmpl" ] || continue
    base="$(basename "$tmpl")"; base="${base%.md.tmpl}"

    # A15 GUARD (S10): the role unit's directory is a flat *.md.tmpl glob with no
    # membership check of its own, so a stray template dropped there — one that
    # names no role in $ROLES — would render as a phantom role file nothing else
    # in the tree references. Skip it rather than write it; --check then stays
    # honest about what the committed roster actually is.
    if [ "$tmpl_dir" = "agents-src/templates" ]; then
      case " $ROLES " in
        *" $base "*) ;;
        *) continue ;;
      esac
    fi

    rel="$out_dir/$base.md"

    if ! render_one "$tmpl" "$tmpl_dir/$base.md.tmpl" > "$WORK/$rel"; then
      RC=1
      continue
    fi
    RENDERED_RELS="${RENDERED_RELS}${rel}
"

    if [ "$MODE" = check ]; then
      if [ ! -f "$OUT_ROOT/$rel" ]; then
        echo "render.sh: $rel does not exist (the template renders, nothing committed)" >&2
        STALE="$STALE $rel"; RC=1
      elif ! diff -u "$OUT_ROOT/$rel" "$WORK/$rel" > "$WORK/$out_dir/$base.diff" 2>&1; then
        echo "── $rel differs from a fresh render ──"
        sed -e "s|$WORK/|<rendered>/|" -e "s|$OUT_ROOT/||" "$WORK/$out_dir/$base.diff"
        STALE="$STALE $rel"; RC=1
      fi
    else
      cp "$WORK/$rel" "$OUT_ROOT/$rel" || { echo "render.sh: cannot write $rel" >&2; RC=1; }
    fi
  done
done

# The manifest, from the bytes just rendered. Skipped entirely when a render failed: a
# manifest of a partial render is worse than none, because doctor would then report a
# healthy machine as modified.
MANIFEST_STALE=no
if [ "$RC" = 0 ]; then
  if ! manifest_of_rendered "$WORK" "$RENDERED_RELS" > "$WORK/rendered.sha256"; then
    echo "render.sh: cannot compute checksums (no shasum or sha256sum on PATH)" >&2
    RC=1
  elif [ "$MODE" = check ]; then
    if [ ! -f "$MANIFEST" ]; then
      echo "render.sh: $MANIFEST_REL does not exist (the finals render, no manifest is committed)" >&2
      MANIFEST_STALE=yes; RC=1
    elif ! diff -u "$MANIFEST" "$WORK/rendered.sha256" > "$WORK/manifest.diff" 2>&1; then
      echo "── $MANIFEST_REL differs from a fresh render ──"
      sed -e "s|$WORK/|<rendered>/|" -e "s|$MANIFEST|$MANIFEST_REL|" "$WORK/manifest.diff"
      MANIFEST_STALE=yes; RC=1
    fi
  else
    # `mkdir -p` rather than a precondition: unlike agents/, the manifest's directory is an
    # output location, and a copy of the tree that has never been rendered has no reason to
    # carry one already (tests/docs-pins.test.sh renders into exactly such a copy).
    if mkdir -p "${MANIFEST%/*}" 2>/dev/null && cp "$WORK/rendered.sha256" "$MANIFEST"; then
      :
    else
      echo "render.sh: cannot write $MANIFEST_REL" >&2
      RC=1
    fi
  fi
fi

if [ "$MODE" = check ]; then
  if [ "$RC" = 0 ]; then
    if [ "$ARCHIVE" = yes ]; then
      echo "render.sh --check --archive: every rendered final matches a render of git archive HEAD, and so does the manifest"
    else
      echo "render.sh --check: every rendered final matches a fresh render, and so does the manifest"
    fi
  else
    [ "$MANIFEST_STALE" = yes ] && STALE="$STALE $MANIFEST_REL"
    if [ "$ARCHIVE" = yes ]; then
      echo "render.sh --check --archive: NOT REPRODUCIBLE FROM HEAD —${STALE:- (render failure)}" >&2
      echo "  the file in this tree is not what a render of \`git archive HEAD\` produces, so a" >&2
      echo "  clone would not reproduce it. Some render input is missing from HEAD — untracked," >&2
      echo "  gitignored, or unstaged — or a final was committed without its source." >&2
      echo "  Repair: commit every render input (git status --porcelain agents-src), then" >&2
      echo "  bash agents-src/render.sh and commit the finals with them." >&2
    else
      echo "render.sh --check: STALE —${STALE:- (render failure)}" >&2
      echo "  the committed file is not the render of the committed source. Either a final was" >&2
      echo "  edited directly, a block/template was edited without re-rendering, or the manifest" >&2
      echo "  was not refreshed with the finals." >&2
      echo "  Repair: bash agents-src/render.sh — then commit the finals with the sources." >&2
    fi
  fi
else
  [ "$RC" = 0 ] && echo "render.sh: rendered every final and refreshed $MANIFEST_REL"
fi

exit "$RC"
