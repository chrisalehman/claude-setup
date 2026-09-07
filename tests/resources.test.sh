#!/bin/bash
# tests/resources.test.sh — payload/scripts/lib/resources.sh and the attestation v2 it feeds.
#
# WHAT THIS SUITE PINS (spec AC-24, AC-25, AC-30 thresholds; wave 1.4.0 slice L-RESOURCES).
# The parallel budget stopped being a number a human guessed and became a function of the
# machine. Three questions, three functions, one file:
#
#   resources_probe                        what this machine IS
#   resources_budget <cores> <mem> <disk>   how wide a wave may run on a machine like that
#   resources_pressure <cores>              whether it is under strain RIGHT NOW
#
# WHY MEMORY IS THE HARD TERM AND COMPUTE THE SOFT ONE (user 2026-09-02, "1 amended").
# The measured failure is a kernel SIGKILL: seven concurrent suites on an 8 GB machine
# drove free memory to ~188 MB and the kernel killed a suite mid-run (tests/run.sh:63-68).
# Over-subscribing cores costs wall time; over-subscribing memory destroys work. So the
# memory term is measured and binding, and the compute term carries `measured: pending`
# until AC-32's live run at the wave head replaces CORES_PER_SUITE with a number.
#
# THE BUDGET IS DERIVED ONCE AND READ, NEVER RE-DERIVED (design-ledger S6). `resources_budget`
# is a pure function of its three arguments — it consults nothing live — so the same machine
# facts always answer the same budget, whatever the machine is doing at the time. Pressure is
# the separate, live question, and it can only HOLD or NARROW; it never moves the ceiling.
#
# HERMETIC. The budget and pressure arms take every reading as an argument or through the
# BIONIC_PROBE_FREE_MB / BIONIC_PROBE_LOAD_1M overrides, so the assertions do not depend on
# what this machine happens to be doing. Exactly one arm reads the real machine — §C, which
# asserts SHAPE and plausibility, never specific numbers. The attestation arms run the probe
# script inside a throwaway sandbox repo with HOME and CLAUDE_CONFIG_DIR redirected.
#
# FIXTURE FIDELITY (declared, per .claude memory fixtures-can-pin-away-the-test):
#   * The four budget fixtures are the plan's, and the fourth (18c / 128 GB / 1700 GB) is
#     THIS machine, measured 2026-09-02: `sysctl -n hw.ncpu` = 18, `hw.memsize` =
#     137438953472 (128 GiB), `df -Pg .` Available = 1710 GB, `sysctl -n vm.loadavg` =
#     { 4.34 2.63 2.18 }, `uname -s` = Darwin. Its expected budget is the hand-derived
#     budget this wave is running under (plan frontmatter `parallel-budget:`), so the
#     library reproducing it is what retires the hand derivation.
#   * The pressure readings are INJECTED, chosen to sit either side of the constants. The
#     emergency figure is anchored on the measured ~188 MB kill.
#   * The v1 attestation fixture is a real record shape: the field set hooks/preflight-probe.sh
#     wrote before this slice, which tests/preflight-probe.test.sh already drives.
#   * session ids are SHAPE-ONLY well-formed uuids, the same convention
#     tests/preflight-probe.test.sh uses.
#
# Usage: bash tests/resources.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$REPO_ROOT/payload/scripts/lib/resources.sh"
PROBE="${BIONIC_HOOKS_DIR}/preflight-probe.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/resources-test.XXXXXX")"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"; }
trap cleanup EXIT

# expect_match here was an ERE matcher spelled under the framework's glob name, with
# arguments reversed (`<label> <actual> <ERE>`) — the A-17 hazard. Every call site below
# is renamed to expect_regex with the order corrected (label, ERE, actual), never a bare
# delete: a bare delete binds the calls to the framework's whole-value GLOB matcher with
# the arguments still in the wrong position, and nothing goes red.

# The library must load before anything else can be asked of it.
if [ ! -r "$LIB" ]; then
  echo "FAIL: payload/scripts/lib/resources.sh is not readable at $LIB"
  echo; echo "resources.test.sh: 0 passed, 1 failed, 1 total"
  exit 1
fi
# shellcheck disable=SC1090
. "$LIB"

# field <line> <key> — reads a `key=value` out of a space-separated one-line record BY KEY,
# never by position (the A6 rule the attestation schema already lives under).
field() {
  printf '%s\n' "$1" | tr ' ' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

# ════════════════════════════════════════════════════════════ §A — the constants block

section "A — constants carry their datum (AC-24: 'every constant carries its datum and date')"

expect_eq   "MEM_RESERVE_GB"    "2"    "${MEM_RESERVE_GB:-unset}"
expect_eq   "MEM_PER_SUITE_GB"  "1.2"  "${MEM_PER_SUITE_GB:-unset}"
expect_eq   "CORES_PER_SUITE"   "1.61" "${CORES_PER_SUITE:-unset}"
expect_eq   "DISK_PER_TREE_GB"  "0.5"  "${DISK_PER_TREE_GB:-unset}"
expect_eq   "WRITERS_EXTRA"     "4"    "${WRITERS_EXTRA:-unset}"
expect_eq   "TEST_JOBS_MIN"     "4"    "${TEST_JOBS_MIN:-unset}"
expect_eq   "TEST_JOBS_MAX"     "24"   "${TEST_JOBS_MAX:-unset}"
expect_eq   "WORKTREES_MIN"     "2"    "${WORKTREES_MIN:-unset}"
expect_eq   "WORKTREES_MAX"     "32"   "${WORKTREES_MAX:-unset}"
expect_eq   "WRITERS_MIN"       "2"    "${WRITERS_MIN:-unset}"
expect_eq   "WRITERS_MAX"       "32"   "${WRITERS_MAX:-unset}"
expect_eq   "HOLD_FREE_MB"      "1024" "${HOLD_FREE_MB:-unset}"
expect_eq   "HOLD_LOAD_FACTOR"  "1.5"  "${HOLD_LOAD_FACTOR:-unset}"
expect_eq   "EMERGENCY_FREE_MB" "256"  "${EMERGENCY_FREE_MB:-unset}"

# The datum is the point of the constant. A number with no provenance is the thing this
# slice exists to remove, so every assignment above must carry a trailing comment.
for _c in MEM_RESERVE_GB MEM_PER_SUITE_GB CORES_PER_SUITE DISK_PER_TREE_GB WRITERS_EXTRA \
          TEST_JOBS_MIN TEST_JOBS_MAX WORKTREES_MIN WORKTREES_MAX WRITERS_MIN WRITERS_MAX \
          HOLD_FREE_MB HOLD_LOAD_FACTOR EMERGENCY_FREE_MB; do
  if grep -Eq "^${_c}=[^ ]+[[:space:]]+#[[:space:]]*\S" "$LIB"; then
    ok "$_c assignment carries a datum comment"
  else
    no "$_c assignment carries a datum comment"
  fi
done

# AC-32 replaced AC-24's 'measured: pending' line at the wave head with the measurement
# and its provenance: date, job count, the sha it was taken at, and the record path.
expect_true "CORES_PER_SUITE carries its AC-32 measurement (date, jobs, sha, record)" \
  grep -q 'measured 2026-09-03 at BIONIC_TEST_JOBS=18' "$LIB"
expect_true "CORES_PER_SUITE names the full-suite record it was measured from" \
  grep -q 'record/wave-1.4.0/step5-full-suite-report.md' "$LIB"
# The 8 GB kernel-SIGKILL measurement is the memory term's whole justification.
expect_true "MEM_PER_SUITE_GB cites the tests/run.sh:81-87 kill datum" \
  grep -q 'tests/run.sh:81-87' "$LIB"

# ════════════════════════════════════════════════════════════ §B — resources_budget

section "B — resources_budget: memory hard, compute soft, disk for trees (AC-24)"

# fixture-fidelity: the plan's four fixtures, verbatim.
#   suites    = max(1, min(floor((mem_gb − 2) / 1.2), floor(cores / CORES_PER_SUITE)))
#   test_jobs = clamp(cores, 4, 24)
#   worktrees = clamp(floor(disk_free_gb / 0.5), 2, 32)
#   writers   = clamp(suites + 4, 2, 32)

B1="$(resources_budget 8 8 100)"
expect_eq "8c/8GB/100GB → suites 4 (compute binds: floor(8/1.61)=4 < floor(6/1.2)=5)" "4" "$(field "$B1" suites)"
expect_eq "8c/8GB/100GB → writers 8"                             "8" "$(field "$B1" writers)"
expect_eq "8c/8GB/100GB → test_jobs 8"                           "8" "$(field "$B1" test_jobs)"
expect_eq "8c/8GB/100GB → worktrees 32 (disk term clamped)"      "32" "$(field "$B1" worktrees)"

B2="$(resources_budget 32 128 1000)"
expect_eq "32c/128GB/1000GB → suites 19 (compute binds: floor(32/1.61))" "19" "$(field "$B2" suites)"
expect_eq "32c/128GB/1000GB → writers 23 (19 + 4)"       "23" "$(field "$B2" writers)"
expect_eq "32c/128GB/1000GB → test_jobs 24 (clamped)"    "24" "$(field "$B2" test_jobs)"

B3="$(resources_budget 2 4 10)"
expect_eq "2c/4GB/10GB → suites 1 (floor never falls below one)" "1"  "$(field "$B3" suites)"
expect_eq "2c/4GB/10GB → writers 5"                             "5"  "$(field "$B3" writers)"
expect_eq "2c/4GB/10GB → test_jobs 4 (clamped up)"              "4"  "$(field "$B3" test_jobs)"
expect_eq "2c/4GB/10GB → worktrees 20 (disk binds)"             "20" "$(field "$B3" worktrees)"

# fixture-fidelity: THIS machine, probed 2026-09-02; CORES_PER_SUITE measured on it 2026-09-03
# (AC-32). Its answer is narrower than the hand-derived budget the wave ran under (suites 18,
# writers 22) — the measurement moved the compute term from `cores` to floor(18/1.61) = 11.
B4="$(resources_budget 18 128 1700)"
expect_eq "18c/128GB/1700GB (this machine) → suites 11 (floor(18/1.61))" "11" "$(field "$B4" suites)"
expect_eq "18c/128GB/1700GB (this machine) → writers 15"   "15" "$(field "$B4" writers)"
expect_eq "18c/128GB/1700GB (this machine) → worktrees 32" "32" "$(field "$B4" worktrees)"
expect_eq "18c/128GB/1700GB (this machine) → test_jobs 18" "18" "$(field "$B4" test_jobs)"

expect_regex "output is one key=value line, four keys, plan order" '^writers=[0-9]+ suites=[0-9]+ worktrees=[0-9]+ test_jobs=[0-9]+$'\
  "$B4"

# A pure function of its arguments: it must not consult the live machine at all, so a
# machine under load answers exactly what an idle one does (design-ledger S6).
expect_eq "budget ignores live pressure (never re-derived from readings)" \
  "$B4" "$(BIONIC_PROBE_FREE_MB=64 BIONIC_PROBE_LOAD_1M=99.0 resources_budget 18 128 1700)"

# Degenerate machines must still answer a runnable budget rather than zero or a crash.
B5="$(resources_budget 1 1 1)"
expect_eq "1c/1GB/1GB → suites 1 (memory term would be 0)"  "1" "$(field "$B5" suites)"
expect_eq "1c/1GB/1GB → writers 5"                          "5" "$(field "$B5" writers)"
expect_eq "1c/1GB/1GB → test_jobs 4"                        "4" "$(field "$B5" test_jobs)"
expect_eq "1c/1GB/1GB → worktrees 2 (clamped up)"           "2" "$(field "$B5" worktrees)"

# Junk in must not become a plausible-looking budget out.
resources_budget 8 abc 100 >/dev/null 2>&1
expect_true "non-numeric argument is refused (non-zero exit)" [ "$?" -ne 0 ]
resources_budget 8 8 >/dev/null 2>&1
expect_true "a missing argument is refused (non-zero exit)" [ "$?" -ne 0 ]

# ════════════════════════════════════════════════════════════ §C — resources_probe

section "C — resources_probe reads THIS machine (AC-24; shape and plausibility only)"

P="$(resources_probe)"
expect_regex "probe prints all five keys in order" '^cores=[0-9]+ mem_gb=[0-9]+ disk_free_gb=[0-9]+ load_1m=[0-9]+(\.[0-9]+)? os=(darwin|linux)$'\
  "$P"

P_CORES="$(field "$P" cores)"; P_MEM="$(field "$P" mem_gb)"
P_DISK="$(field "$P" disk_free_gb)"; P_OS="$(field "$P" os)"

expect_true "cores is at least 1"       [ "$P_CORES" -ge 1 ]
expect_true "mem_gb is at least 1"      [ "$P_MEM" -ge 1 ]
expect_true "disk_free_gb is not negative" [ "$P_DISK" -ge 0 ]

case "$(uname -s)" in
  Darwin) expect_eq "os is darwin on this host" "darwin" "$P_OS"
          expect_eq "cores agrees with sysctl hw.ncpu" "$(sysctl -n hw.ncpu)" "$P_CORES"
          expect_eq "mem_gb agrees with sysctl hw.memsize" \
            "$(( $(sysctl -n hw.memsize) / 1073741824 ))" "$P_MEM" ;;
  Linux)  expect_eq "os is linux on this host" "linux" "$P_OS"
          expect_eq "cores agrees with nproc" "$(nproc)" "$P_CORES" ;;
  *)      ok "os arm: host is neither Darwin nor Linux; shape assertions above stand" ;;
esac

# The probe's own numbers must be a legal budget input — the two halves are one pipeline.
PB="$(resources_budget "$P_CORES" "$P_MEM" "$P_DISK")"
expect_regex "probe output feeds resources_budget without editing" '^writers=[0-9]+ suites=[0-9]+ worktrees=[0-9]+ test_jobs=[0-9]+$'\
  "$PB"

# ════════════════════════════════════════════════════════════ §D — resources_pressure

section "D — resources_pressure: HOLD and EMERGENCY thresholds (AC-30)"

pressure() {  # <free_mb> <load_1m> <cores>
  BIONIC_PROBE_FREE_MB="$1" BIONIC_PROBE_LOAD_1M="$2" resources_pressure "$3"
}

R="$(pressure 8000 2.0 18)"
expect_eq "ample memory, load well under cores×1.5 → ok" "ok" "$(field "$R" state)"
expect_regex "pressure prints the three original keys, in order and first" '^state=(ok|hold|emergency) free_mb=[0-9]+ load_1m=[0-9]+(\.[0-9]+)? '\
  "$R"
expect_eq "pressure echoes the free reading it judged"  "8000" "$(field "$R" free_mb)"
expect_eq "pressure echoes the load reading it judged"  "2.0"  "$(field "$R" load_1m)"

# HOLD arm 1 — free memory below HOLD_FREE_MB (half the 2 GB reserve).
expect_eq "free 1023 MB (below HOLD_FREE_MB) → hold" "hold" \
  "$(field "$(pressure 1023 1.0 18)" state)"
expect_eq "free exactly 1024 MB is not yet hold"     "ok" \
  "$(field "$(pressure 1024 1.0 18)" state)"

# HOLD arm 2 — load above cores × HOLD_LOAD_FACTOR. Strictly above: 18 × 1.5 = 27.
expect_eq "load 27.1 on 18 cores (> 27) → hold" "hold" \
  "$(field "$(pressure 8000 27.1 18)" state)"
expect_eq "load exactly 27.0 on 18 cores is not hold" "ok" \
  "$(field "$(pressure 8000 27.0 18)" state)"
expect_eq "load 26.9 on 18 cores → ok" "ok" \
  "$(field "$(pressure 8000 26.9 18)" state)"
# The factor is per-core, so the same load is fine on a big machine and a hold on a small one.
expect_eq "load 4.0 on 2 cores (> 3) → hold" "hold" \
  "$(field "$(pressure 8000 4.0 2)" state)"
expect_eq "load 4.0 on 18 cores → ok"       "ok" \
  "$(field "$(pressure 8000 4.0 18)" state)"

# EMERGENCY — the kernel-kill floor. Measured: the SIGKILL landed at ~188 MB free.
expect_eq "free 255 MB (below EMERGENCY_FREE_MB) → emergency" "emergency" \
  "$(field "$(pressure 255 1.0 18)" state)"
expect_eq "free 188 MB (the measured kill point) → emergency" "emergency" \
  "$(field "$(pressure 188 1.0 18)" state)"
expect_eq "free exactly 256 MB is hold, not emergency" "hold" \
  "$(field "$(pressure 256 1.0 18)" state)"
# Emergency outranks a merely-high load: the scarcer resource decides.
expect_eq "free 100 MB with a calm load is still emergency" "emergency" \
  "$(field "$(pressure 100 0.1 18)" state)"

# With no overrides it must read the live machine and still answer one of the three states.
R_LIVE="$(resources_pressure "$P_CORES")"
expect_regex "live pressure answers a legal state" '^state=(ok|hold|emergency) free_mb=[0-9]+ load_1m=[0-9]+(\.[0-9]+)? '\
  "$R_LIVE"

# ════════════════════════════════════════════════════════════ §E — attestation v2

section "E — the preflight attestation is version 2 and carries the machine + the budget (AC-25)"

SESSION_A="6c85684c-9588-45a0-bd26-e8c46956c94f"   # fixture-fidelity: SHAPE-ONLY uuid
SESSION_V1="2b7d90aa-51c4-4f8e-9d21-6c0b3ea4517f"  # fixture-fidelity: SHAPE-ONLY uuid

SBX="$TMPROOT/sbx"
mkdir -p "$SBX/home/.claude/projects/proj" "$SBX/repo"
( cd "$SBX/repo" && git init -q . && git config user.email t@e && git config user.name t ) >/dev/null 2>&1
: > "$SBX/home/.claude/projects/proj/$SESSION_A.jsonl"
STATE_REL=".bionic/tmp/preflight-$SESSION_A.state"

run_probe() {  # runs the probe in the sandbox as SESSION_A
  ( cd "$SBX/repo" && \
    HOME="$SBX/home" CLAUDE_CONFIG_DIR="$SBX/home/.claude" \
    ANTHROPIC_API_KEY=fixture-not-a-real-key \
    CLAUDE_CODE_SESSION_ID="$SESSION_A" \
    bash "$PROBE" ) >"$TMPROOT/probe.out" 2>"$TMPROOT/probe.err"
}

run_probe
PRC=$?
expect_true "the probe still exits 0 on a healthy sandbox" [ "$PRC" -eq 0 ]
ATT="$SBX/repo/$STATE_REL"
expect_true "an attestation was written" [ -f "$ATT" ]

att_field() { grep -m1 "^$1=" "$ATT" 2>/dev/null | cut -d= -f2-; }

expect_eq "the attestation declares version 2" "2" "$(att_field version)"
expect_eq "kind is unchanged"      "preflight-attestation" "$(att_field kind)"
expect_eq "session_id is unchanged" "$SESSION_A"           "$(att_field session_id)"

# The five probe fields, by key.
for _k in cores mem_gb disk_free_gb load_1m os; do
  if [ -n "$(att_field "$_k")" ]; then ok "attestation carries $_k"; else no "attestation carries $_k"; fi
done
expect_regex "attestation cores is an integer" '^[0-9]+$' "$(att_field cores)"
expect_regex "attestation mem_gb is an integer" '^[0-9]+$' "$(att_field mem_gb)"
expect_regex "attestation disk_free_gb is an integer" '^[0-9]+$' "$(att_field disk_free_gb)"
expect_regex "attestation load_1m is a number" '^[0-9]+(\.[0-9]+)?$' "$(att_field load_1m)"
expect_regex "attestation os is darwin or linux" '^(darwin|linux)$' "$(att_field os)"

# The recorded machine must be THIS machine — the attestation is a record, not a template.
expect_eq "attestation cores match the live probe"  "$P_CORES" "$(att_field cores)"
expect_eq "attestation mem_gb matches the live probe" "$P_MEM"  "$(att_field mem_gb)"

# The budget line, in the same shape the plan frontmatter's `parallel-budget:` carries, so
# WALLS and DOCTOR read one string rather than re-deriving anything (ownership table).
BUD="$(att_field budget)"
expect_regex "attestation carries a budget line in parallel-budget shape" '^writers=[0-9]+ suites=[0-9]+ worktrees=[0-9]+ test_jobs=[0-9]+ source=probe$'\
  "$BUD"
expect_eq "the recorded budget is what the library derives from the recorded machine" \
  "$(resources_budget "$(att_field cores)" "$(att_field mem_gb)" "$(att_field disk_free_gb)") source=probe" \
  "$BUD"

# ════════════════════════════════════════════════════════════ §F — the reader takes 1 and 2

section "F — the attestation reader accepts version 1 and version 2 (AC-25)"

read_att() { bash "$PROBE" --read "$1" >"$TMPROOT/read.out" 2>"$TMPROOT/read.err"; }

read_att "$ATT"
expect_true "reader accepts the v2 record it just wrote" [ "$?" -eq 0 ]
expect_true "reader echoes the budget line" grep -q "^budget=" "$TMPROOT/read.out"

# fixture-fidelity: a v1 record — the exact field set hooks/preflight-probe.sh wrote before
# this slice, which tests/preflight-probe.test.sh drives today.
V1="$TMPROOT/preflight-$SESSION_V1.state"
cat > "$V1" <<EOF
# bionic environment attestation — machine-local, safe to delete
version=1
kind=preflight-attestation
session_id=$SESSION_V1
written_at=1756800000
written_at_iso=2026-09-02T12:00:00Z
repo=/somewhere
git_branch=main
git_head=deadbee
git_dirty=0
credential_source=environment
other_sessions=0
EOF

read_att "$V1"
expect_true "reader still accepts a version 1 record" [ "$?" -eq 0 ]
expect_false "a v1 record carries no budget line" grep -q "^budget=" "$TMPROOT/read.out"

# An unknown future version must be refused loudly rather than half-parsed.
V9="$TMPROOT/preflight-v9.state"
sed 's/^version=1$/version=9/' "$V1" > "$V9"
read_att "$V9"
expect_true "reader refuses an unrecognised version" [ "$?" -ne 0 ]
expect_true "the refusal names the version it saw" grep -q '9' "$TMPROOT/read.err"

# A record with no version line at all is not an attestation.
V0="$TMPROOT/preflight-v0.state"
grep -v '^version=' "$V1" > "$V0"
read_att "$V0"
expect_true "reader refuses a record with no version line" [ "$?" -ne 0 ]

read_att "$TMPROOT/definitely-absent.state"
expect_true "reader refuses an absent file" [ "$?" -ne 0 ]

# The read mode must be READ-ONLY: it may not write, prune, or take an attestation.
BEFORE="$(ls "$SBX/repo/.bionic/tmp" | sort | tr '\n' ' ')"
read_att "$ATT"
AFTER="$(ls "$SBX/repo/.bionic/tmp" | sort | tr '\n' ' ')"
expect_eq "--read changes nothing in the state directory" "$BEFORE" "$AFTER"

# ════════════════════════════════════════════════════════════ §G — degraded library

section "G — a missing library degrades the attestation to v1, never blocks the probe (fail-open)"

# Resources are a CONTEXT probe, not a blocking one: a machine whose library cannot be read
# must still be able to take an attestation and dispatch. The honest record of that is a v1
# attestation — the version the reader still accepts — not a v2 with empty fields.
DEG="$TMPROOT/degraded"
mkdir -p "$DEG/hooks" "$DEG/scripts/lib"
cp "$PROBE" "$DEG/hooks/preflight-probe.sh"
# every OTHER lib is present; only resources.sh is missing (mirrors hooks/ + scripts/lib,
# the pattern POKER/4 and ADOPT/9 use for a hook copied out of the shipped tree — without
# this, the loader idiom's own required libs (root.sh, session.sh) are ALSO absent, the
# probe never resolves a project root or session key, and no attestation is written at
# all: the degraded-attestation path is never reached).
cp "$REPO_ROOT/payload/scripts/lib/"*.sh "$DEG/scripts/lib/"
rm -f "$DEG/scripts/lib/resources.sh"
mkdir -p "$DEG/home/.claude/projects/proj" "$DEG/repo"
( cd "$DEG/repo" && git init -q . ) >/dev/null 2>&1
: > "$DEG/home/.claude/projects/proj/$SESSION_A.jsonl"
( cd "$DEG/repo" && \
  HOME="$DEG/home" CLAUDE_CONFIG_DIR="$DEG/home/.claude" \
  ANTHROPIC_API_KEY=fixture-not-a-real-key \
  CLAUDE_CODE_SESSION_ID="$SESSION_A" \
  bash "$DEG/hooks/preflight-probe.sh" ) >"$TMPROOT/deg.out" 2>"$TMPROOT/deg.err"
DRC=$?
expect_true "the probe still exits 0 with the library missing" [ "$DRC" -eq 0 ]
DATT="$DEG/repo/$STATE_REL"
expect_true "an attestation was still written" [ -f "$DATT" ]
expect_eq "the degraded attestation declares version 1" "1" \
  "$(grep -m1 '^version=' "$DATT" 2>/dev/null | cut -d= -f2-)"
expect_false "the degraded attestation carries no budget line" \
  grep -q '^budget=' "$DATT"

# Differential control: put resources.sh BACK into the same tree and re-run against the
# same session id (same DATT path, so a real flip overwrites the v1 record). This proves
# the v1 result above is caused by the missing library, not by some other defect in the
# fixture that would yield v1 regardless — the anti-vacuity pattern L-ROOT/7 names.
cp "$REPO_ROOT/payload/scripts/lib/resources.sh" "$DEG/scripts/lib/resources.sh"
( cd "$DEG/repo" && \
  HOME="$DEG/home" CLAUDE_CONFIG_DIR="$DEG/home/.claude" \
  ANTHROPIC_API_KEY=fixture-not-a-real-key \
  CLAUDE_CODE_SESSION_ID="$SESSION_A" \
  bash "$DEG/hooks/preflight-probe.sh" ) >"$TMPROOT/undeg.out" 2>"$TMPROOT/undeg.err"
URC=$?
expect_true "the probe still exits 0 with the library restored" [ "$URC" -eq 0 ]
expect_eq "restoring resources.sh flips the same attestation to version 2" "2" \
  "$(grep -m1 '^version=' "$DATT" 2>/dev/null | cut -d= -f2-)"
expect_true "the restored attestation carries a budget line" \
  grep -q '^budget=' "$DATT"

# ════════════════════════════════════════════ §H — the percentage sensors (AC-13)

section "H — resources_pressure reads free % and swap %, behind env pins (AC-13)"

# FIXTURE FIDELITY. The two stubs below reproduce THIS machine's raw output verbatim
# (research-code-map §2.5, measured 2026-09-04): `memory_pressure` ends in
# `System-wide memory free percentage: 44%` after a stats block whose shape varies, and
# `sysctl vm.swapusage` reports total = 3072.00M used = 2132.44M — 69 % consumed. The
# assertions below are the numbers that machine produces, so the parse is pinned against
# the real surface and never against a convenient constant.
STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/memory_pressure" <<'STUB'
#!/bin/bash
cat <<'OUT'
The system has 8589934592 (524288 pages with a page size of 16384).

Stats:
Pages free: 5837
Pages purgeable: 1929
Pages purged: 3520941

Swap I/O:
Swapins: 616876
Swapouts: 910136

Page Q counts:
Pages active: 107807
Pages inactive: 105366
Pages speculative: 2097
Pages throttled: 0
Pages wired down: 117511

Compressor Stats:
Pages used by compressor: 153455

File I/O:
Pageins: 13004722
Pageouts: 394999

System-wide memory free percentage: 44%
OUT
STUB

cat > "$STUBS/sysctl" <<'STUB'
#!/bin/bash
case "$*" in
  "vm.swapusage")    echo "vm.swapusage: total = 3072.00M  used = 2132.44M  free = 939.56M  (encrypted)" ;;
  "-n vm.swapusage") echo "total = 3072.00M  used = 2132.44M  free = 939.56M  (encrypted)" ;;
  "-n vm.loadavg")   echo "{ 1.60 1.20 1.10 }" ;;
  "-n hw.ncpu")      echo "8" ;;
  "-n hw.memsize")   echo "8589934592" ;;
  *) exit 1 ;;
esac
STUB

# A machine with swap configured but nothing in it — the divide-by-total guard.
cat > "$STUBS/sysctl-noswap" <<'STUB'
#!/bin/bash
case "$*" in
  "vm.swapusage")    echo "vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)" ;;
  *) exit 1 ;;
esac
STUB

# A sensor that is simply not there (the AC-13 "unreadable input" case).
cat > "$STUBS/memory_pressure-broken" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$STUBS/memory_pressure" "$STUBS/sysctl" "$STUBS/sysctl-noswap" "$STUBS/memory_pressure-broken"

# The new fields are appended, so the record's shape assertion moves with them.
R="$(BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 pressure 8000 2.0 18)"
expect_regex "pressure prints all five keys in order" '^state=(ok|hold|emergency) free_mb=[0-9]+ load_1m=[0-9]+(\.[0-9]+)? free_pct=-?[0-9]+ swap_pct=-?[0-9]+$'\
  "$R"
expect_eq "the existing three fields are unchanged by the two new ones" \
  "ok 8000 2.0" "$(field "$R" state) $(field "$R" free_mb) $(field "$R" load_1m)"

expect_eq "BIONIC_PROBE_FREE_PCT pins the free percentage" "44" "$(field "$R" free_pct)"
expect_eq "BIONIC_PROBE_SWAP_PCT pins the swap percentage" "69" "$(field "$R" swap_pct)"

# ── the Darwin sensor against this machine's own raw output.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  RS="$(PATH="$STUBS:$PATH" BIONIC_PROBE_FREE_MB=8000 BIONIC_PROBE_LOAD_1M=1.6 resources_pressure 8)"
  expect_eq "Darwin: memory_pressure's LAST line gives free_pct 44" "44" "$(field "$RS" free_pct)"
  expect_eq "Darwin: sysctl vm.swapusage used/total gives swap_pct 69" "69" "$(field "$RS" swap_pct)"
  expect_eq "Darwin: the stats block above the percentage line does not confuse the parse" \
    "state=ok free_mb=8000 load_1m=1.6 free_pct=44 swap_pct=69" "$RS"

  # SYNTHETIC FIXTURE, declared: a `memory_pressure` whose stats block carries an EARLIER
  # line matching the same phrase. Real output has one such line, at the end; this pins the
  # documented rule — the LAST match wins — so a new section appearing above the percentage
  # in a future macOS release cannot silently change the reading.
  mkdir -p "$TMPROOT/stub-double"
  cat > "$TMPROOT/stub-double/memory_pressure" <<'STUB'
#!/bin/bash
cat <<'OUT'
The system has 8589934592 (524288 pages with a page size of 16384).

Historic:
System-wide memory free percentage: 99%

Stats:
Pages free: 5837

System-wide memory free percentage: 44%
OUT
STUB
  cp "$STUBS/sysctl" "$TMPROOT/stub-double/sysctl"
  chmod +x "$TMPROOT/stub-double/memory_pressure" "$TMPROOT/stub-double/sysctl"
  RD="$(PATH="$TMPROOT/stub-double:$PATH" BIONIC_PROBE_FREE_MB=8000 BIONIC_PROBE_LOAD_1M=1.6 \
        resources_pressure 8)"
  expect_eq "Darwin: the LAST matching percentage line is the reading" "44" "$(field "$RD" free_pct)"

  # The env pins outrank the sensor: same stubs, pinned answers.
  RP="$(PATH="$STUBS:$PATH" BIONIC_PROBE_FREE_MB=8000 BIONIC_PROBE_LOAD_1M=1.6 \
        BIONIC_PROBE_FREE_PCT=7 BIONIC_PROBE_SWAP_PCT=91 resources_pressure 8)"
  expect_eq "Darwin: the free-% pin overrides the live sensor" "7"  "$(field "$RP" free_pct)"
  expect_eq "Darwin: the swap-% pin overrides the live sensor" "91" "$(field "$RP" swap_pct)"

  # Swap with a zero total is 0 % used, not a division fault.
  mkdir -p "$TMPROOT/stub-noswap"
  cp "$STUBS/sysctl-noswap" "$TMPROOT/stub-noswap/sysctl"
  cp "$STUBS/memory_pressure" "$TMPROOT/stub-noswap/memory_pressure"
  chmod +x "$TMPROOT/stub-noswap/sysctl" "$TMPROOT/stub-noswap/memory_pressure"
  RZ="$(PATH="$TMPROOT/stub-noswap:$PATH" BIONIC_PROBE_FREE_MB=8000 BIONIC_PROBE_LOAD_1M=1.6 \
        resources_pressure 8)"
  expect_eq "Darwin: a zero swap total reads 0 %, never a divide fault" "0" "$(field "$RZ" swap_pct)"
  expect_eq "Darwin: the free-% read still lands beside the zero swap" "44" "$(field "$RZ" free_pct)"

  # An unreadable sensor degrades to -1 — a field the band ignores, never a hold (AC-13).
  mkdir -p "$TMPROOT/stub-broken"
  cp "$STUBS/memory_pressure-broken" "$TMPROOT/stub-broken/memory_pressure"
  cp "$STUBS/sysctl" "$TMPROOT/stub-broken/sysctl"
  chmod +x "$TMPROOT/stub-broken/memory_pressure" "$TMPROOT/stub-broken/sysctl"
  RB="$(PATH="$TMPROOT/stub-broken:$PATH" BIONIC_PROBE_FREE_MB=8000 BIONIC_PROBE_LOAD_1M=1.6 \
        resources_pressure 8)"
  expect_eq "Darwin: an unreadable free-% sensor reads -1"        "-1" "$(field "$RB" free_pct)"
  expect_eq "Darwin: the readable swap sensor beside it still answers" "69" "$(field "$RB" swap_pct)"
  expect_eq "Darwin: an unreadable sensor does not move state off ok" "ok" "$(field "$RB" state)"
else
  # Not Darwin: the same three claims are made against the live Linux sensor, by shape.
  RL="$(BIONIC_PROBE_FREE_MB=8000 BIONIC_PROBE_LOAD_1M=1.6 resources_pressure 8)"
  expect_regex "non-Darwin: free_pct is a percentage or the -1 degrade" \
    '^(-1|100|[0-9]{1,2})$' "$(field "$RL" free_pct)"
  expect_regex "non-Darwin: swap_pct is a percentage or the -1 degrade" \
    '^(-1|100|[0-9]{1,2})$' "$(field "$RL" swap_pct)"
  expect_eq "non-Darwin: an unreadable sensor does not move state off ok" "ok" "$(field "$RL" state)"
fi

# The live machine, no stubs and no pins: shape and range only (the §C convention).
R_LIVE_PCT="$(resources_pressure "$P_CORES")"
expect_regex "live pressure carries both percentages in range" '^state=(ok|hold|emergency) free_mb=[0-9]+ load_1m=[0-9]+(\.[0-9]+)? free_pct=(-1|100|[0-9]{1,2}) swap_pct=(-1|100|[0-9]{1,2})$'\
  "$R_LIVE_PCT"

# ════════════════════════════════════════════════ §I — pressure_band (AC-13, AC-14)

section "I — pressure_band: the four bands and their exact edges (AC-14)"

band() { pressure_band "$1" "$2" "$3" "$4"; }

# The plan's table, verbatim. 8 cores → the load line is 12.0.
expect_eq "(44,69,1.6,8) — this machine at design time → clear" "clear"     "$(band 44 69 1.6 8)"
expect_eq "(20,69,1.6,8) — free under 25 → warning"             "warning"   "$(band 20 69 1.6 8)"
expect_eq "(44,85,1.6,8) — swap at 85 → warning"                "warning"   "$(band 44 85 1.6 8)"
expect_eq "(44,69,13,8)  — load 13 over 8×1.5 → warning"        "warning"   "$(band 44 69 13 8)"
expect_eq "(10,50,1,8)   — free under 12 → critical"            "critical"  "$(band 10 50 1 8)"
expect_eq "(30,95,1,8)   — swap at 95 → critical"               "critical"  "$(band 30 95 1 8)"
expect_eq "(4,0,0,8)     — free under 5 → emergency"            "emergency" "$(band 4 0 0 8)"

# Every threshold is a half-open interval; the edge itself belongs to the calmer band.
expect_eq "free exactly 5 is critical, not emergency" "critical" "$(band 5 0 1 8)"
expect_eq "free exactly 12 is warning, not critical"  "warning"  "$(band 12 0 1 8)"
expect_eq "free exactly 25 is clear, not warning"     "clear"    "$(band 25 0 1 8)"
expect_eq "swap exactly 80 is warning"                "warning"  "$(band 44 80 1 8)"
expect_eq "swap exactly 79 is clear"                  "clear"    "$(band 44 79 1 8)"
expect_eq "swap exactly 92 is critical"               "critical" "$(band 44 92 1 8)"
expect_eq "swap exactly 91 is warning, not critical"  "warning"  "$(band 44 91 1 8)"
expect_eq "load exactly 12.0 on 8 cores is clear (strictly above)" "clear" "$(band 44 0 12.0 8)"
expect_eq "load 12.1 on 8 cores is warning"           "warning"  "$(band 44 0 12.1 8)"
# Per-core, like the HOLD arm it shares HOLD_LOAD_FACTOR with.
expect_eq "load 4.0 on 2 cores is warning"            "warning"  "$(band 44 0 4.0 2)"
expect_eq "load 4.0 on 18 cores is clear"             "clear"    "$(band 44 0 4.0 18)"

# An unreadable reading is -1, and the band IGNORES it rather than treating it as 0 %.
expect_eq "free_pct -1 is ignored, the rest still decides"   "clear"   "$(band -1 69 1.6 8)"
expect_eq "swap_pct -1 is ignored, the rest still decides"   "clear"   "$(band 44 -1 1.6 8)"
expect_eq "both percentages unreadable → load alone decides" "warning" "$(band -1 -1 20 8)"
expect_eq "both percentages unreadable and a calm load → clear" "clear" "$(band -1 -1 1 8)"
expect_eq "free_pct -1 does not mask a critical swap"        "critical" "$(band -1 95 1 8)"

# Precedence: the scarcer resource decides, exactly as the state= arm does.
expect_eq "free 4 with a clean swap is emergency, not critical" "emergency" "$(band 4 10 1 8)"
expect_eq "free 4 with a critical swap is still emergency"      "emergency" "$(band 4 99 1 8)"
expect_eq "critical outranks warning when both fire"            "critical"  "$(band 10 85 20 8)"

# Bad arguments refuse rather than answer.
pressure_band 44 69 1.6 0 >/dev/null 2>&1; expect_eq "cores 0 refuses with 2" "2" "$?"
pressure_band 44 69 1.6 >/dev/null 2>&1;   expect_eq "a missing argument refuses with 2" "2" "$?"
pressure_band xx 69 1.6 8 >/dev/null 2>&1; expect_eq "a non-numeric percentage refuses with 2" "2" "$?"

# ═════════════════════════════════════════════════════ §J — the ring (AC-16)

section "J — pressure_sample appends one line and prunes to the window (AC-16)"

RING="$TMPROOT/ring/pressure.ring"
sample() {  # <epoch> [<cores>]
  BIONIC_PRESSURE_RING="$RING" BIONIC_NOW_EPOCH="$1" \
  BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
    pressure_sample "${2:-8}"
}

expect_eq "PRESSURE_WINDOW_S is the five-minute smoothing window" "300" "${PRESSURE_WINDOW_S:-unset}"

sample 1000 >/dev/null 2>&1
expect_true "the first sample creates the ring and its parent directory" [ -f "$RING" ]
expect_eq   "one append, one line" "1" "$(wc -l < "$RING" | tr -d ' ')"
expect_regex "the line is epoch|free|swap|load|cores" \
  '^1000\|44\|69\|1\.6\|8$' "$(head -1 "$RING")"

sample 1001 >/dev/null 2>&1
sample 1002 >/dev/null 2>&1
expect_eq "three appends inside the window keep three lines" "3" "$(wc -l < "$RING" | tr -d ' ')"
expect_eq "the samples are kept oldest first" "1000 1001 1002" \
  "$(cut -d'|' -f1 < "$RING" | tr '\n' ' ' | sed 's/ $//')"

# THE WINDOW IS A READ-SIDE RULE, AND SINCE THE C-1 = S-3 REPAIR IT IS ONLY A READ-SIDE
# RULE. The sample path used to rewrite the whole ring from a filtered read on EVERY
# append, and that rewrite is what lost concurrent samples (§J.3). What AC-14 and AC-16
# need is that what a CONSUMER reads is the window — `_pressure_window_lines` is the one
# owner of that question and both the reader and the prune call it. The file itself may
# carry more, and is rewritten only when it grows past PRESSURE_RING_MAX_LINES (§J.2).
# These rows moved from asserting the FILE's length to asserting the WINDOW's, which is
# the property the rung actually rests on.
window_ts() {  # <ring> <now> -> the in-window timestamps, space separated
  _pressure_window_lines "$1" "$2" | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//'
}

sample 1402 >/dev/null 2>&1
expect_eq "a sample 400 s later is APPENDED — the sample path rewrites nothing" "4" \
  "$(wc -l < "$RING" | tr -d ' ')"
expect_eq "and the window a consumer reads holds only the new one" "1402" \
  "$(window_ts "$RING" 1402)"

# The boundary: exactly PRESSURE_WINDOW_S old is still in the window.
rm -f "$RING"
sample 2000 >/dev/null 2>&1
sample 2300 >/dev/null 2>&1
expect_eq "a sample exactly 300 s old is inside the window" "2000 2300" \
  "$(window_ts "$RING" 2300)"
sample 2301 >/dev/null 2>&1
expect_eq "at 301 s it drops out of the window" "2300 2301" "$(window_ts "$RING" 2301)"
expect_eq "the file still carries all three — extra lines are harmless, missing ones are not" \
  "3" "$(wc -l < "$RING" | tr -d ' ')"

# Garbage in the file is dropped by the same reader, not carried into the median.
printf 'not-a-sample\n' >> "$RING"
expect_eq "a malformed line is not a sample and never enters the window" "2300 2301" \
  "$(window_ts "$RING" 2301)"

# --- §J.2 — THE PRUNE: rare, mktemp-named, and it keeps every in-window line ----------
#
# It fires only above PRESSURE_RING_MAX_LINES, which is why the appends above rewrote
# nothing. Planted: 600 stale lines (well outside the window) plus three inside it.
expect_eq "PRESSURE_RING_MAX_LINES is the rewrite threshold, not the window" \
  "512" "${PRESSURE_RING_MAX_LINES:-unset}"

PRING="$TMPROOT/ring-prune/pressure.ring"
mkdir -p "$(dirname "$PRING")"
: > "$PRING"
pi=1; while [ $pi -le 600 ]; do printf '1000|44|69|1.6|8\n' >> "$PRING"; pi=$((pi + 1)); done
printf '9000|44|69|1.6|8\n9100|20|69|1.6|8\n9200|44|69|1.6|8\n' >> "$PRING"
expect_eq "the planted ring is over the threshold" "603" "$(wc -l < "$PRING" | tr -d ' ')"

BIONIC_PRESSURE_RING="$PRING" BIONIC_NOW_EPOCH=9300 \
  BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
  pressure_sample 8 >/dev/null 2>&1

expect_eq "over the threshold the prune fires and drops the stale lines" "4" \
  "$(wc -l < "$PRING" | tr -d ' ')"
expect_eq "the prune keeps EVERY line inside the 300 s window, and the new one" \
  "9000 9100 9200 9300" "$(cut -d'|' -f1 < "$PRING" | tr '\n' ' ' | sed 's/ $//')"
expect_eq "and it leaves no temp file behind in the ring's directory" "0" \
  "$(find "$(dirname "$PRING")" -name 'pressure.ring.prune.*' | grep -c .)"

# --- §J.3 — CONCURRENCY: no sampler loses another sampler's line (review C-1) ---------
#
# The defect: `${ring}.tmp.$$` is the PARENT shell's pid, so every background subshell of
# one shell wrote and renamed ONE temp path. Measured pre-fix: 12 concurrent samplers left
# 0 lines, and 12 separate processes left 3-6 of 12.
CRING="$TMPROOT/ring-conc/pressure.ring"
mkdir -p "$(dirname "$CRING")"
: > "$CRING"
ci=1; while [ $ci -le 12 ]; do
  ( BIONIC_PRESSURE_RING="$CRING" BIONIC_NOW_EPOCH=$((7000 + ci)) \
    BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
    pressure_sample 8 >/dev/null 2>&1 ) &
  ci=$((ci + 1))
done
wait
expect_eq "12 concurrent samplers as subshells of ONE shell leave 12 lines" "12" \
  "$(wc -l < "$CRING" | tr -d ' ')"

PRING2="$TMPROOT/ring-conc2/pressure.ring"
mkdir -p "$(dirname "$PRING2")"
: > "$PRING2"
pj=1; while [ $pj -le 12 ]; do
  BIONIC_PRESSURE_RING="$PRING2" BIONIC_NOW_EPOCH=$((7000 + pj)) \
  BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
    bash -c '. "$1"; pressure_sample 8' _ "$LIB" >/dev/null 2>&1 &
  pj=$((pj + 1))
done
wait
expect_eq "12 samplers in 12 SEPARATE processes leave 12 lines" "12" \
  "$(wc -l < "$PRING2" | tr -d ' ')"

# --- §J.4 — the old predictable temp path is not written through ---------------------
#
# `>` follows a symlink and truncates its target, and `${ring}.tmp.$$` was fully
# predictable. Nothing writes that name any more.
SRING="$TMPROOT/ring-sym/pressure.ring"
mkdir -p "$(dirname "$SRING")"
: > "$SRING"
printf 'PRECIOUS\n' > "$TMPROOT/ring-sym/victim.txt"
( BIONIC_PRESSURE_RING="$SRING" BIONIC_NOW_EPOCH=8000 \
  BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
  bash -c '
    . "$1"
    ln -sfn "$2" "${BIONIC_PRESSURE_RING}.tmp.$$"
    pressure_sample 8
  ' _ "$LIB" "$TMPROOT/ring-sym/victim.txt" ) >/dev/null 2>&1
expect_eq "a symlink pre-planted at the old temp path is not followed" "PRECIOUS" \
  "$(cat "$TMPROOT/ring-sym/victim.txt")"
expect_eq "and the sample still landed on the ring" "1" \
  "$(wc -l < "$SRING" | tr -d ' ')"

# The default path is machine-scoped under the config dir (AC-16, D4).
RHOME="$TMPROOT/ringhome"
mkdir -p "$RHOME"
( unset BIONIC_PRESSURE_RING
  CLAUDE_CONFIG_DIR="$RHOME/cfg" BIONIC_NOW_EPOCH=3000 BIONIC_PROBE_FREE_PCT=44 \
  BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 pressure_sample 8 ) >/dev/null 2>&1
expect_true "with no override the ring lands under CLAUDE_CONFIG_DIR/bionic/pressure.ring" \
  [ -f "$RHOME/cfg/bionic/pressure.ring" ]
( unset BIONIC_PRESSURE_RING CLAUDE_CONFIG_DIR
  HOME="$RHOME/hm" BIONIC_NOW_EPOCH=3000 BIONIC_PROBE_FREE_PCT=44 \
  BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 pressure_sample 8 ) >/dev/null 2>&1
expect_true "and with no config dir either, under \$HOME/.claude/bionic/pressure.ring" \
  [ -f "$RHOME/hm/.claude/bionic/pressure.ring" ]

# Two rings are independent; two project roots on ONE ring path share it (AC-16).
RA="$TMPROOT/ring-a/pressure.ring"
RB="$TMPROOT/ring-b/pressure.ring"
BIONIC_PRESSURE_RING="$RA" BIONIC_NOW_EPOCH=4000 BIONIC_PROBE_FREE_PCT=44 \
  BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 pressure_sample 8 >/dev/null 2>&1
BIONIC_PRESSURE_RING="$RB" BIONIC_NOW_EPOCH=4000 BIONIC_PROBE_FREE_PCT=10 \
  BIONIC_PROBE_SWAP_PCT=50 BIONIC_PROBE_LOAD_1M=1.0 pressure_sample 8 >/dev/null 2>&1
expect_eq "two ring paths hold their own samples — A" "4000|44|69|1.6|8" "$(cat "$RA")"
expect_eq "two ring paths hold their own samples — B" "4000|10|50|1.0|8" "$(cat "$RB")"

mkdir -p "$TMPROOT/root-one" "$TMPROOT/root-two"
RSHARED="$TMPROOT/ring-shared/pressure.ring"
( cd "$TMPROOT/root-one" && BIONIC_PRESSURE_RING="$RSHARED" BIONIC_NOW_EPOCH=5000 \
    BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
    pressure_sample 8 ) >/dev/null 2>&1
( cd "$TMPROOT/root-two" && BIONIC_PRESSURE_RING="$RSHARED" BIONIC_NOW_EPOCH=5001 \
    BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
    pressure_sample 8 ) >/dev/null 2>&1
expect_eq "two project roots on one machine write the SAME ring" "2" \
  "$(wc -l < "$RSHARED" | tr -d ' ')"

# ═══════════════════════════════════════════ §K — pressure_level, the rung (AC-14)

section "K — pressure_level: median band over the ring → a rung inside the ceiling (AC-14)"

# Sample lines whose band is known by §I: the four rows of the plan's table.
S_CLEAR='44|69|1.6|8'
S_WARN='20|69|1.6|8'
S_CRIT='10|50|1|8'
S_EMERG='4|0|0|8'

LRING="$TMPROOT/level/pressure.ring"
mkdir -p "$(dirname "$LRING")"
ring_of() {  # <epoch-base> <sample>... — rewrite the ring with one line per sample
  local t="$1"; shift
  : > "$LRING"
  local s
  for s in "$@"; do printf '%s|%s\n' "$t" "$s" >> "$LRING"; t=$((t + 1)); done
}
level() { BIONIC_PRESSURE_RING="$LRING" BIONIC_NOW_EPOCH="${LNOW:-6000}" pressure_level "$1"; }
level_err() { BIONIC_PRESSURE_RING="$LRING" BIONIC_NOW_EPOCH="${LNOW:-6000}" pressure_level "$1" 2>&1 >/dev/null; }

LNOW=6000
# AC-14's sequence, ceiling 8: clear → warning → critical → clear yields 8 → 4 → 2 → 8.
ring_of 6000 "$S_CLEAR" "$S_CLEAR" "$S_CLEAR"
expect_eq "a clear ring runs at the full ceiling"      "8" "$(level 8)"
ring_of 6000 "$S_WARN" "$S_WARN" "$S_WARN"
expect_eq "a warning ring halves it"                   "4" "$(level 8)"
ring_of 6000 "$S_CRIT" "$S_CRIT" "$S_CRIT"
expect_eq "a critical ring quarters it"                "2" "$(level 8)"
ring_of 6000 "$S_CLEAR" "$S_CLEAR" "$S_CLEAR"
expect_eq "and a ring that clears returns to the ceiling" "8" "$(level 8)"
ring_of 6000 "$S_EMERG" "$S_EMERG" "$S_EMERG"
expect_eq "an emergency ring floors at 1"              "1" "$(level 8)"

# The ceiling is never exceeded and the floor is never breached.
ring_of 6000 "$S_CLEAR" "$S_CLEAR" "$S_CLEAR"
expect_eq "ceiling 1, clear ring → 1"     "1" "$(level 1)"
ring_of 6000 "$S_WARN" "$S_WARN" "$S_WARN"
expect_eq "ceiling 1, warning ring → 1"   "1" "$(level 1)"
ring_of 6000 "$S_CRIT" "$S_CRIT" "$S_CRIT"
expect_eq "ceiling 1, critical ring → 1"  "1" "$(level 1)"
ring_of 6000 "$S_EMERG" "$S_EMERG" "$S_EMERG"
expect_eq "ceiling 1, emergency ring → 1" "1" "$(level 1)"

# The halves round UP, so a rung is never rounded to zero work.
ring_of 6000 "$S_WARN" "$S_WARN" "$S_WARN"
expect_eq "ceiling 3, warning → ceil(3/2) = 2"  "2" "$(level 3)"
ring_of 6000 "$S_CRIT" "$S_CRIT" "$S_CRIT"
expect_eq "ceiling 3, critical → ceil(3/4) = 1" "1" "$(level 3)"
ring_of 6000 "$S_WARN" "$S_WARN" "$S_WARN"
expect_eq "ceiling 6, warning → 3"  "3" "$(level 6)"
ring_of 6000 "$S_CRIT" "$S_CRIT" "$S_CRIT"
expect_eq "ceiling 6, critical → ceil(6/4) = 2" "2" "$(level 6)"

# It is a MEDIAN, not the worst reading and not the latest one.
ring_of 6000 "$S_CLEAR" "$S_CLEAR" "$S_CRIT"
expect_eq "one critical spike among two clears does not move the rung" "8" "$(level 8)"
ring_of 6000 "$S_CLEAR" "$S_CRIT" "$S_CRIT"
expect_eq "two criticals against one clear do move it" "2" "$(level 8)"
ring_of 6000 "$S_CRIT" "$S_CLEAR" "$S_CLEAR"
expect_eq "the newest sample does not decide on its own" "8" "$(level 8)"
# An even count takes the higher of the two middles — the pessimistic side.
ring_of 6000 "$S_CLEAR" "$S_WARN"
expect_eq "an even split resolves to the worse band" "4" "$(level 8)"

# Stale samples are outside the window and do not vote.
: > "$LRING"
printf '%s|%s\n' 5000 "$S_CRIT" >> "$LRING"
printf '%s|%s\n' 5001 "$S_CRIT" >> "$LRING"
printf '%s|%s\n' 5990 "$S_CLEAR" >> "$LRING"
expect_eq "samples older than the window do not vote" "8" "$(level 8)"

# The stderr line names the rung, the ceiling, the band and the sample count.
ring_of 6000 "$S_WARN" "$S_WARN" "$S_WARN"
expect_eq "the stderr line reports rung, ceiling, band and count" \
  "rung=4/8 band=warning samples=3" "$(level_err 8)"
ring_of 6000 "$S_CLEAR" "$S_CLEAR" "$S_CLEAR"
expect_eq "…and follows the band it computed" \
  "rung=8/8 band=clear samples=3" "$(level_err 8)"
expect_eq "the answer on stdout is the rung alone" "8" "$(level 8)"

# PURE: two calls agree and the ring is untouched (AC-14 'nothing stores a current level').
ring_of 6000 "$S_WARN" "$S_WARN" "$S_WARN"
BEFORE="$(cat "$LRING")"
L1="$(level 8)"; L2="$(level 8)"
expect_eq "two calls over one ring return one answer, and it is the warning rung" \
  "4 4" "$L1 $L2"
expect_eq "pressure_level writes nothing to the ring" "$BEFORE" "$(cat "$LRING")"
expect_eq "no file records a 'current level' beside the ring" "1" \
  "$(ls "$(dirname "$LRING")" | wc -l | tr -d ' ')"

# An empty ring takes one fresh sample first, then answers from it.
ERING="$TMPROOT/level-empty/pressure.ring"
EL="$(BIONIC_PRESSURE_RING="$ERING" BIONIC_NOW_EPOCH=7000 BIONIC_PROBE_FREE_PCT=44 \
      BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 pressure_level 8 2>/dev/null)"
expect_eq   "an empty ring answers from one fresh sample" "8" "$EL"
expect_true "…and that sample is now in the ring" [ -f "$ERING" ]
expect_eq   "…exactly one of them" "1" "$(wc -l < "$ERING" | tr -d ' ')"
EE="$(BIONIC_PRESSURE_RING="$TMPROOT/level-empty2/pressure.ring" BIONIC_NOW_EPOCH=7000 \
      BIONIC_PROBE_FREE_PCT=10 BIONIC_PROBE_SWAP_PCT=50 BIONIC_PROBE_LOAD_1M=1.0 \
      pressure_level 8 2>&1 >/dev/null)"
expect_eq "the fresh sample is the one that decides" "rung=2/8 band=critical samples=1" "$EE"

# Bad arguments refuse rather than answer.
BIONIC_PRESSURE_RING="$LRING" pressure_level 0 >/dev/null 2>&1
expect_eq "ceiling 0 refuses with 2" "2" "$?"
BIONIC_PRESSURE_RING="$LRING" pressure_level >/dev/null 2>&1
expect_eq "a missing ceiling refuses with 2" "2" "$?"
BIONIC_PRESSURE_RING="$LRING" pressure_level nine >/dev/null 2>&1
expect_eq "a non-numeric ceiling refuses with 2" "2" "$?"

# --- §K.2 — the inlined banding and `pressure_band` answer identically ---------------
#
# Step-6 review P-3. `pressure_level` used to fork `pressure_band` once per sample in the
# window, and the window holds whatever the sample RATE put there — 144 samples measured
# 0.20 s of pure fork, and a busier machine makes its own rung read slower. The banding is
# now inlined into the same awk that filters the window: 0.20 s -> 0.02 s at 144 samples.
#
# TWO TRANSCRIPTIONS CAN DRIFT, so this is the row that forbids it. Each sample below is
# driven BOTH ways — through `pressure_band` directly, and through `pressure_level` over a
# ring holding exactly that one sample, where the median of one IS that sample's band. A
# threshold edited in one place and not the other splits this table.
K2_RING="$TMPROOT/k2/pressure.ring"
mkdir -p "$(dirname "$K2_RING")"
K2_NOW=9000000

k2_level_band() {  # <free> <swap> <load> <cores> -> the band pressure_level reports
  printf '%s|%s|%s|%s|%s\n' "$K2_NOW" "$1" "$2" "$3" "$4" > "$K2_RING"
  BIONIC_PRESSURE_RING="$K2_RING" BIONIC_NOW_EPOCH="$K2_NOW" pressure_level 8 2>&1 >/dev/null \
    | sed -n 's/.*band=\([a-z]*\).*/\1/p'
}
k2_level_samples() {  # <free> <swap> <load> <cores> -> the sample COUNT it counted
  printf '%s|%s|%s|%s|%s\n' "$K2_NOW" "$1" "$2" "$3" "$4" > "$K2_RING"
  BIONIC_PRESSURE_RING="$K2_RING" BIONIC_NOW_EPOCH="$K2_NOW" pressure_level 8 2>&1 >/dev/null \
    | sed -n 's/.*samples=\([0-9]*\).*/\1/p'
}

# Every row of §I's table, plus the -1 arms and the load term, driven both ways.
K2_ROWS='44|69|1.6|8
25|69|1.6|8
24|69|1.6|8
12|69|1.6|8
11|69|1.6|8
5|69|1.6|8
4|69|1.6|8
44|79|1.6|8
44|80|1.6|8
44|92|1.6|8
44|69|12.1|8
44|69|12.0|8
-1|69|1.6|8
44|-1|1.6|8
-1|-1|1.6|8
-1|-1|20|8
0|0|0|1'
K2_DISAGREE=""
while IFS='|' read -r k2f k2s k2l k2c; do
  [ -n "${k2f:-}" ] || continue
  k2_direct="$(pressure_band "$k2f" "$k2s" "$k2l" "$k2c" 2>/dev/null)" || k2_direct="REFUSED"
  k2_via="$(k2_level_band "$k2f" "$k2s" "$k2l" "$k2c")"
  [ "$k2_direct" = "$k2_via" ] || \
    K2_DISAGREE="${K2_DISAGREE}${k2f}|${k2s}|${k2l}|${k2c}: band=${k2_direct} level=${k2_via}
"
done <<EOF
$K2_ROWS
EOF
expect_eq "every sample bands identically through pressure_band and through pressure_level" \
  "" "$K2_DISAGREE"
# Non-vacuity: the table really does exercise all four bands.
K2_SEEN=""
while IFS='|' read -r k2f k2s k2l k2c; do
  [ -n "${k2f:-}" ] || continue
  K2_SEEN="${K2_SEEN}$(pressure_band "$k2f" "$k2s" "$k2l" "$k2c" 2>/dev/null) "
done <<EOF
$K2_ROWS
EOF
for k2b in clear warning critical emergency; do
  expect_regex "…and the table reaches the $k2b band" "(^| )$k2b( |$)" "$K2_SEEN"
done

# THE REFUSALS AGREE TOO: a sample `pressure_band` will not band is a sample
# `pressure_level` does not count. Its own window filter already drops NF != 5 and a
# non-numeric timestamp, so these are the field-level refusals only.
K2_BAD='xx|69|1.6|8
44|yy|1.6|8
44|69|zz|8
44|69|1.6|0
44|69|1.6|nine'
K2_BAD_DISAGREE=""
while IFS='|' read -r k2f k2s k2l k2c; do
  [ -n "${k2f:-}" ] || continue
  pressure_band "$k2f" "$k2s" "$k2l" "$k2c" >/dev/null 2>&1 && k2_rc=0 || k2_rc=$?
  k2_n="$(k2_level_samples "$k2f" "$k2s" "$k2l" "$k2c")"
  # pressure_band refuses (rc 2) <=> pressure_level counts zero samples.
  if [ "$k2_rc" -eq 2 ] && [ "${k2_n:-}" = "0" ]; then :; else
    K2_BAD_DISAGREE="${K2_BAD_DISAGREE}${k2f}|${k2s}|${k2l}|${k2c}: band_rc=${k2_rc} samples=${k2_n}
"
  fi
done <<EOF
$K2_BAD
EOF
expect_eq "a sample pressure_band refuses is a sample pressure_level does not count" \
  "" "$K2_BAD_DISAGREE"

finish
