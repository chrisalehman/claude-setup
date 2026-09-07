#!/bin/bash
# SEAM RESOLUTION CATCH-PROOF — epic-17 wave-02 slice S1 (spec AC-4).
#
# WHAT THE SEAM IS. `tests/lib/resolve-roots.sh` is a sourced helper owning one
# question: where do the scripts under test live. It exports three per-class root
# variables, each env-overridable with a repo default:
#
#     BIONIC_HOOKS_DIR    <repo>/hooks
#     BIONIC_SKILLS_DIR   <repo>/skills
#     BIONIC_SCRIPTS_DIR  <repo>            (root scripts, e.g. wsl-setup.sh)
#
# It is mechanism-agnostic: it points at directories and knows nothing about how
# those directories came to exist (installer tests own that).
#
# WHAT THIS SUITE PROVES. A seam that is never exercised through its override is
# indistinguishable from the hardcoded offset it replaced — both are green in the
# repo checkout, and the redirect only fails the day someone needs it. So this
# suite plants a DOCTORED TREE (real scripts, copied, with a marker sed into
# them) and drives a named check BOTH directions:
#
#   * override set   -> the check observably reads the DOCTORED copy
#   * override unset -> the same check reads the REPO copy
#
# "Observably" means by CONTENT, not by path string: the doctored copies carry a
# marker the repo copies do not, and the repo copies carry a value the doctored
# ones do not. A helper that returned the right-looking path but whose consumers
# still read the repo cannot pass. Each class is proven separately, and one arm
# proves the classes are independent (redirecting hooks must not drag skills
# along), because a helper deriving all three from a single overridden root would
# otherwise slip through.
#
# Location independence gets its own group: the helper is sourced from
# tests/*.test.sh (including the hooks/*.test.sh suites moved under tests/ at
# epic-17 W4 S9), by absolute and by relative reference, from whatever cwd the
# runner happens to be in. It must derive
# <repo> from its OWN path, never the caller's pwd — the naive implementation
# is green from the repo root and wrong from anywhere else.
#
# HERMETIC. Copies files into a mktemp tree, forks bash and grep. No sandbox, no
# network, no hooks, no writes outside $TMP.
#
# Usage: bash tests/seam-resolution.test.sh

set -uo pipefail

# NOT the seam: a catch-proof cannot resolve its subject through its subject. This is
# the one legacy-idiom site outside tests/lib/resolve-roots.sh (spec AC-3, plan A11).
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
SEAM="${REPO}/tests/lib/resolve-roots.sh"
MARKER="SEAM-DOCTORED-MARKER-b7f3"

. "$(dirname "$0")/lib/assert.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------
# The planted doctored tree: real scripts, copied, marker sed in.
# ------------------------------------------------------------------
DOC="$TMP/doctored"
mkdir -p "$DOC/hooks" "$DOC/skills/canonical-sdlc" "$DOC/root"

# hooks class — the real pin-sync subject. The repo copy says
# SUPPORTED_SDLC_VERSION=14; the doctored copy says 99999. Neither value can be
# read from the other file, so the named check's ANSWER names which file it read.
cp "$REPO/hooks/canonical-sdlc-evidence-gate.sh" "$DOC/hooks/canonical-sdlc-evidence-gate.sh"
sed -i.bak 's/^SUPPORTED_SDLC_VERSION=.*/SUPPORTED_SDLC_VERSION=99999/' "$DOC/hooks/canonical-sdlc-evidence-gate.sh"
rm -f "$DOC/hooks/canonical-sdlc-evidence-gate.sh.bak"
printf '# %s\n' "$MARKER" >> "$DOC/hooks/canonical-sdlc-evidence-gate.sh"

# skills class — the real SKILL.md, marker appended.
cp "$REPO/skills/canonical-sdlc/SKILL.md" "$DOC/skills/canonical-sdlc/SKILL.md"
printf '\n<!-- %s -->\n' "$MARKER" >> "$DOC/skills/canonical-sdlc/SKILL.md"

# root-scripts class — a real root script, marker appended. This was
# claude-bootstrap.sh until epic-17 W5 (4/6) deleted the installer; the class
# under test is "scripts at the repo root", not that particular script, so the
# representative moved to the root script that survived. Any root *.sh would
# serve — what the fixture needs is a file the seam can resolve to and a marker
# only the doctored copy carries.
cp "$REPO/wsl-setup.sh" "$DOC/root/wsl-setup.sh"
printf '# %s\n' "$MARKER" >> "$DOC/root/wsl-setup.sh"

# ------------------------------------------------------------------
# The probe: a stand-in consumer suite. Sources the seam exactly the way a real
# suite will, then runs ONE named check that reads a file THROUGH the seam var.
# Args: <seam-reference> <check-name>. The seam reference is passed as given
# (absolute or relative) so a relative source resolves against the probe's cwd,
# which is what a suite run from an arbitrary directory actually does.
# ------------------------------------------------------------------
cat > "$TMP/probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$1" || { echo "PROBE-SOURCE-FAILED"; exit 3; }
case "$2" in
  var-hooks)    printf '%s\n' "${BIONIC_HOOKS_DIR:-UNSET}" ;;
  var-skills)   printf '%s\n' "${BIONIC_SKILLS_DIR:-UNSET}" ;;
  var-scripts)  printf '%s\n' "${BIONIC_SCRIPTS_DIR:-UNSET}" ;;
  # The named check, verbatim in the shape S2 gives the pin-sync rows: read the
  # evidence gate's version constant through BIONIC_HOOKS_DIR.
  read-hooks)   grep -o 'SUPPORTED_SDLC_VERSION=[0-9]*' "${BIONIC_HOOKS_DIR}/canonical-sdlc-evidence-gate.sh" | head -1 ;;
  # Marker reads: did the consumer land in the doctored copy or the repo copy?
  mark-hooks)   grep -c 'SEAM-DOCTORED-MARKER-b7f3' "${BIONIC_HOOKS_DIR}/canonical-sdlc-evidence-gate.sh" ;;
  mark-skills)  grep -c 'SEAM-DOCTORED-MARKER-b7f3' "${BIONIC_SKILLS_DIR}/canonical-sdlc/SKILL.md" ;;
  mark-scripts) grep -c 'SEAM-DOCTORED-MARKER-b7f3' "${BIONIC_SCRIPTS_DIR}/wsl-setup.sh" ;;
  *) echo "PROBE-UNKNOWN-CHECK"; exit 4 ;;
esac
PROBE

# probe <cwd> <seam-ref> <check> — env overrides come from the caller's own env.
probe() { ( cd "$1" && bash "$TMP/probe.sh" "$2" "$3" 2>&1 ); }

section "Group 1: repo defaults with no override set"

expect_eq "BIONIC_HOOKS_DIR defaults to <repo>/hooks" \
  "$REPO/hooks" "$(probe "$REPO" "$SEAM" var-hooks)"
expect_eq "BIONIC_SKILLS_DIR defaults to <repo>/skills" \
  "$REPO/skills" "$(probe "$REPO" "$SEAM" var-skills)"
expect_eq "BIONIC_SCRIPTS_DIR defaults to <repo>" \
  "$REPO" "$(probe "$REPO" "$SEAM" var-scripts)"

section "Group 2: location independence (repo derives from the helper, not the caller)"

expect_eq "absolute source from cwd=/ resolves <repo>/hooks" \
  "$REPO/hooks" "$(probe "/" "$SEAM" var-hooks)"
expect_eq "absolute source from cwd=<repo>/hooks resolves <repo>/hooks" \
  "$REPO/hooks" "$(probe "$REPO/hooks" "$SEAM" var-hooks)"
expect_eq "absolute source from cwd=\$TMP resolves <repo>/hooks" \
  "$REPO/hooks" "$(probe "$TMP" "$SEAM" var-hooks)"
expect_eq "relative source from cwd=<repo> resolves <repo>/hooks" \
  "$REPO/hooks" "$(probe "$REPO" "tests/lib/resolve-roots.sh" var-hooks)"
expect_eq "relative source from cwd=<repo>/tests resolves <repo>/hooks" \
  "$REPO/hooks" "$(probe "$REPO/tests" "lib/resolve-roots.sh" var-hooks)"
expect_eq "relative source from cwd=<repo>/hooks resolves <repo>/skills" \
  "$REPO/skills" "$(probe "$REPO/hooks" "../tests/lib/resolve-roots.sh" var-skills)"
# cwd was <repo>/lib until the W5 Step-6 review retired lib/platform.sh and left
# that directory empty (and so untracked, and so absent from a fresh clone). What
# the arm needs is only a directory ONE level below the repo, so the seam is
# reached by the same `../tests/lib/...` spelling; skills/ is that, and unlike
# lib/ it is a directory the payload itself ships.
expect_eq "relative source from cwd=<repo>/skills resolves <repo>" \
  "$REPO" "$(probe "$REPO/skills" "../tests/lib/resolve-roots.sh" var-scripts)"

section "Group 3: override set -> the named check reads the DOCTORED copy"

_v="$(BIONIC_HOOKS_DIR="$DOC/hooks" probe "$REPO" "$SEAM" read-hooks)"
expect_eq "hooks override: named check reads the doctored constant" \
  "SUPPORTED_SDLC_VERSION=99999" "$_v"
expect_absent "hooks override: named check does NOT read the repo constant" \
  "SUPPORTED_SDLC_VERSION=14" "$_v"
expect_eq "hooks override: doctored marker is present in what was read" \
  "1" "$(BIONIC_HOOKS_DIR="$DOC/hooks" probe "$REPO" "$SEAM" mark-hooks)"
expect_eq "skills override: marker is present in what was read" \
  "1" "$(BIONIC_SKILLS_DIR="$DOC/skills" probe "$REPO" "$SEAM" mark-skills)"
expect_eq "scripts override: marker is present in what was read" \
  "1" "$(BIONIC_SCRIPTS_DIR="$DOC/root" probe "$REPO" "$SEAM" mark-scripts)"
expect_eq "override survives a foreign cwd (cwd=/, hooks redirected)" \
  "SUPPORTED_SDLC_VERSION=99999" "$(BIONIC_HOOKS_DIR="$DOC/hooks" probe "/" "$SEAM" read-hooks)"

section "Group 4: override unset -> the same check reads the REPO copy"

_v="$(probe "$REPO" "$SEAM" read-hooks)"
expect_eq "no override: named check reads the repo constant" \
  "SUPPORTED_SDLC_VERSION=14" "$_v"
expect_eq "no override: hooks read carries no doctored marker" \
  "0" "$(probe "$REPO" "$SEAM" mark-hooks)"
expect_eq "no override: skills read carries no doctored marker" \
  "0" "$(probe "$REPO" "$SEAM" mark-skills)"
expect_eq "no override: scripts read carries no doctored marker" \
  "0" "$(probe "$REPO" "$SEAM" mark-scripts)"

section "Group 5: the three classes are independent"

expect_eq "hooks override does not drag skills along" \
  "0" "$(BIONIC_HOOKS_DIR="$DOC/hooks" probe "$REPO" "$SEAM" mark-skills)"
expect_eq "hooks override does not drag root scripts along" \
  "0" "$(BIONIC_HOOKS_DIR="$DOC/hooks" probe "$REPO" "$SEAM" mark-scripts)"
expect_eq "skills override does not drag hooks along" \
  "0" "$(BIONIC_SKILLS_DIR="$DOC/skills" probe "$REPO" "$SEAM" mark-hooks)"
expect_eq "scripts override does not drag hooks along" \
  "0" "$(BIONIC_SCRIPTS_DIR="$DOC/root" probe "$REPO" "$SEAM" mark-hooks)"
# All three redirected at once — each class must land in its own doctored dir.
probe3() { BIONIC_HOOKS_DIR="$DOC/hooks" BIONIC_SKILLS_DIR="$DOC/skills" BIONIC_SCRIPTS_DIR="$DOC/root" \
             probe "$REPO" "$SEAM" "$1"; }
expect_eq "all three overrides together each bind to their own class" \
  "1 1 1" "$(probe3 mark-hooks) $(probe3 mark-skills) $(probe3 mark-scripts)"

section "Group 6: no suite resolves privately (spec AC-3, enumerated)"
# The seam is only a seam while it is the ONLY answer. A suite added later with a
# hardcoded offset opts out silently: it sources nothing, reds nothing, and goes
# blind the day an overridden root goes live (W5 cold install).
UNSEAMED=""
LEGACY_IDIOM=""
# hooks/*.test.sh moved under tests/ at epic-17 W4 S9 (spec AC-9); hooks/ now
# holds only the hook scripts themselves, so that glob element is retired
# rather than kept as a permanently-vacuous no-op. `lib/*.test.sh` went the same
# way at the W5 Step-6 review, and for the same reason: lib/platform.sh and its
# suite retired together, `lib/` is empty, and `[ -f ] || continue` would have
# hidden the dead element forever rather than reporting it.
for f in "$REPO"/tests/*.test.sh; do
  [ -f "$f" ] || continue
  case "$f" in */seam-resolution.test.sh) continue ;; esac   # documented exemption, :46
  /usr/bin/grep -q 'resolve-roots\.sh' "$f" || UNSEAMED="$UNSEAMED ${f#$REPO/}"
  # The complementary negative: sourcing the seam does not by itself prove a
  # suite stopped computing its OWN offset alongside it (a partial conversion —
  # the more likely drift shape than a total opt-out, given S2 converted 29
  # sites). Neither pre-seam idiom may appear anywhere in this glob; the two
  # documented exemptions (tests/lib/resolve-roots.sh itself, which the glob
  # never reaches, and this suite's own REPO line at :48, which uses `pwd -P`
  # rather than the legacy `pwd`) are excluded from the match by construction,
  # not by a case-arm here.
  if /usr/bin/grep -qF '$(cd "$(dirname "$0")" && pwd)' "$f" || \
     /usr/bin/grep -qF '$(cd "$(dirname "$0")/.." && pwd)' "$f"; then
    LEGACY_IDIOM="$LEGACY_IDIOM ${f#$REPO/}"
  fi
done
expect_eq "every suite sources the path-resolution seam" "" "$UNSEAMED"
expect_eq "no suite keeps a private legacy offset alongside the seam" "" "$LEGACY_IDIOM"

finish
