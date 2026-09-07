# payload/scripts/lib/resources.sh — ONE READER FOR "how much machine is there, and how
# much of it is left".
#
# WHAT IT OWNS. Three questions, kept apart on purpose:
#
#   resources_probe                          what this machine IS      (facts)
#   resources_budget <cores> <mem> <disk>    how wide a wave may run   (a ceiling)
#   resources_pressure <cores>               how it is doing right now (a live reading)
#
# WHY IT EXISTS (spec AC-24, wave-bionic-1.4.0-update). Fan-out width was a number a human
# guessed and then restated into every brief. It drifted, and it was wrong in both
# directions: too high on a small machine (a kernel SIGKILL, below) and needlessly low on a
# large one. The cure is to derive it once, from facts, and read it from where it was
# written — never to re-derive it from whatever the machine happens to be doing.
#
# THE ONE RULE THAT SHAPES EVERY CONSTANT HERE: MEMORY IS HARD, COMPUTE IS SOFT
# (user 2026-09-02, "1 amended"). Over-subscribing cores costs wall time and nothing else.
# Over-subscribing memory destroys work: the measured failure is a kernel SIGKILL, seven
# concurrent suites on an 8 GB machine driving free memory to ~188 MB and a suite dying
# mid-run (tests/run.sh:81-87, W7 assumption A4.2). So the memory term is measured and
# binding; the compute term is a placeholder that degenerates to `cores` until AC-32's live
# run at the wave head measures it.
#
# THE BUDGET IS A CEILING, NOT A CONTROLLER (design-ledger S6, S7). `resources_budget` is a
# PURE function of its three arguments — it opens no file, runs no command, reads no
# environment variable. That is what makes it re-derivable and auditable: the same machine
# facts always answer the same budget. `resources_pressure` is the separate live question,
# and the only thing a caller may do with it is HOLD, size down by the rung, or (at the kill
# floor) stop something. Pressure never raises or lowers the ceiling; a moving ceiling is
# precisely the drift class this file was written to remove.
#
# WHO READS IT. hooks/preflight-probe.sh (records probe + budget into the version-2
# attestation), the canonical-sdlc Step 0 display and the plan header it writes, the
# dispatch wall's budget arm, `session-poker.sh tick` (FILL/HOLD/EMERGENCY, sized by the
# rung), and doctor's resources section. Every one of them READS; none of them re-derives.
#
# BASH 3.2. No associative arrays, no `${var^^}`, no `mapfile`, and no floating-point
# arithmetic — bash has none. The two non-integer constants (1.2 GB per suite, 0.5 GB per
# tree) are converted to hundredths by `_res_hundredths` and the whole budget is computed in
# integers; awk appears exactly once, for the one genuine float comparison in
# `resources_pressure` (load_1m against cores × 1.5).
#
# EVERY CONSTANT CARRIES ITS DATUM (AC-24). A number with no provenance is the thing this
# file exists to replace, so the comment beside each assignment is part of the contract and
# tests/resources.test.sh asserts its presence.
#
# [WALL: tests/resources.test.sh]

# ─────────────────────────────────────────────────────────────────── constants

# Memory the machine must keep for itself — the OS, the editor, the agent processes, and
# the headroom between "slow" and "the kernel starts killing things".
MEM_RESERVE_GB=2       # datum: 2026-08 measurement, tests/run.sh:81-87 — the 8 GB machine
                       # died at ~188 MB free, so a 2 GB floor is the nearest round reserve
                       # that keeps the kill point out of reach.

# What one concurrent test suite costs in resident memory. THE BINDING TERM.
MEM_PER_SUITE_GB=1.2   # datum: 8 GB, 7 concurrent suites, ~188 MB free, kernel SIGKILL,
                       # tests/run.sh:81-87 — (8 − 2) GB across 7 suites is ~0.86 GB each
                       # with nothing left; 1.2 GB is that measurement with headroom.

# What one concurrent suite costs in cores. THE SOFT TERM, measured once at the wave head
# (AC-32): the whole `tests/run.sh` at 18 jobs, alone on an 18-core M5 Max, averaged 1.61
# cores over its 8m07s wall (user 279.27 s + sys 505.57 s over real 487.38 s) — the runner
# is spawn- and sleep-bound, not CPU-bound. Read as the per-suite constant the formula
# names, it makes the compute term floor(18/1.61) = 11 concurrent full suites here, which
# is the conservative side of the Batch-0 datum (six concurrent full suites starved).
CORES_PER_SUITE=1.61   # measured 2026-09-03 at BIONIC_TEST_JOBS=18, user+sys/wall over
                       # tests/run.sh at 97afec9: 784.84 s / 487.38 s
                       # (record/wave-1.4.0/step5-full-suite-report.md)

# Disk a checked-out worktree costs. Trees are cheap; this term only binds on a full disk.
DISK_PER_TREE_GB=0.5   # datum: 2026-09-02, this repo — a `git worktree add` checkout of
                       # bionic measures well under 100 MB; 0.5 GB is that rounded up five
                       # times over to cover build artefacts and a venv.

# Writers exceed suites because not every writer is running a suite at once — most of a
# writer's life is reading, editing and committing.
WRITERS_EXTRA=4        # datum: 2026-09-02 stand-up — hand-derived budget for this machine
                       # was writers 22 against suites 18, the ratio this wave is running.

# BIONIC_TEST_JOBS bounds. The floor keeps a 1-core machine from serializing to a crawl; the
# ceiling is where added width stopped paying on the measured runs.
TEST_JOBS_MIN=4        # datum: tests/run.sh:81-87 — 4 was "the width with headroom" on the
                       # 8 GB measurement, and is the documented pre-2026-08-22 default.
TEST_JOBS_MAX=24       # datum: 2026-08-22 (ef23f75) raised the default to 8 with the note
                       # that BIONIC_TEST_JOBS exists "for a machine with less or more"; 24
                       # is three times that, past any width measured to help.

# Live worktree bounds. The floor keeps the lease mechanism usable on a small disk; the
# ceiling is a sprawl guard, not a resource one.
WORKTREES_MIN=2        # datum: 2026-09-02 design-ledger C1 — a lease needs at least the
                       # tree being landed plus the next one being cut.
WORKTREES_MAX=32       # datum: 2026-09-02 stand-up — hand-derived worktrees 32 on a 1.7 TiB
                       # disk, where the disk term (3400) is meaningless and sprawl is the
                       # real limit.

# Concurrent writer bounds, same shape and the same reasoning as the worktree pair.
WRITERS_MIN=2          # datum: 2026-09-02 — one writer is not a fan-out; two is the floor
                       # at which the dispatch wall's budget arm means anything.
WRITERS_MAX=32         # datum: 2026-09-02 stand-up — the hand-derived ceiling, and the
                       # point past which an orchestrator cannot read the returns.

# ── pressure thresholds (AC-30). These decide HOLD and EMERGENCY, never the ceiling.

HOLD_FREE_MB=1024      # datum: half MEM_RESERVE_GB — the reserve is the line the budget was
                       # built to protect, so eating half of it is the warning, not the
                       # emergency.
HOLD_LOAD_FACTOR=1.5   # datum: 2026-09-02 — load_1m above 1.5 × cores is sustained
                       # oversubscription rather than a burst; below it, queueing is normal
                       # for a machine running suites.
EMERGENCY_FREE_MB=256  # datum: kill at ~188 MB (tests/run.sh:81-87) — the floor sits just
                       # above the measured kernel SIGKILL point, so the tick acts before
                       # the kernel does.

# ── pressure BANDS (AC-13, AC-14, design-ledger D3). These decide the RUNG — how much of
# the Step-0 ceiling a consumer may use right now. They are constants beside the sensor and
# NOT a config knob: a threshold a project could move is a threshold no wave can reason
# about (D3, rejected alternatives). They are calibrated against the 8 GB / 8-core machine
# this wave was designed on, which read free 44 % / swap 69 % while `free_mb` said ok — the
# divergence B-3 exists to catch (research-code-map §2.5). A 128 GB machine reads clear
# almost always, which is the correct answer for it.

BAND_FREE_EMERGENCY_PCT=5   # datum: 2026-09-04 charter B-3 — under 5 % free the machine is
                            # already swapping to stay alive; one writer is all that is safe.
BAND_FREE_CRITICAL_PCT=12   # datum: 2026-09-04 charter B-3 — the level at which the design
                            # machine's swap climbed while free_mb still read ok.
BAND_FREE_WARNING_PCT=25    # datum: 2026-09-04 charter B-3 — a quarter of memory is the
                            # nearest round line above the 44 % this machine idles at.
BAND_SWAP_CRITICAL_PCT=92   # datum: 2026-09-04 charter B-3 — swap nearly full is the state
                            # that preceded the measured kernel SIGKILL.
BAND_SWAP_WARNING_PCT=80    # datum: charter B-3 — "swap at 84 % was the real signal" while
                            # the free-MB sensor read healthy; 80 is that reading rounded down.

# How far back the rung looks. The median over this window is what stops a one-second spike
# from setting a whole suite's width (D3, "a bare fresh reading" rejected).
PRESSURE_WINDOW_S=300       # datum: design-ledger D3 — "median of the readings in the last
                            # few minutes"; five minutes is the smoothing window ratified there.

# HOW LARGE THE FILE MAY GET BEFORE IT IS REWRITTEN — not how far back the rung looks. The
# two are different bounds and only the first one costs a rewrite. Measured: the live ring
# on this machine held 184 samples inside its 300 s window while the recorder sampled on
# every Bash call, so the steady state is a couple of hundred lines; 512 is that with
# headroom, and a ring of 512 lines is under 13 KB. It is deliberately far ABOVE the window
# so that the overwhelming majority of appends rewrite nothing at all — see pressure_sample.
PRESSURE_RING_MAX_LINES=512

# ─────────────────────────────────────────────────────────── integer arithmetic helpers

# bash has no floats. Every non-integer constant above is converted here to HUNDREDTHS, and
# the budget arithmetic below is plain integer division on those. Two decimal places is
# enough for every constant this file has and for the measured CORES_PER_SUITE that AC-32
# will write in.
_res_hundredths() {  # <decimal string> -> integer hundredths ("1.2" -> 120, "0.5" -> 50)
  local v="$1" int frac
  case "$v" in
    *.*) int="${v%%.*}"; frac="${v#*.}" ;;
    *)   int="$v";       frac="" ;;
  esac
  [ -n "$int" ] || int=0
  frac="${frac}00"
  frac="${frac:0:2}"
  # 10# forces base ten: an unprefixed "08" is an invalid octal literal to bash.
  printf '%s' "$(( int * 100 + 10#$frac ))"
}

_res_clamp() {  # <n> <min> <max>
  local n="$1"
  [ "$n" -lt "$2" ] && n="$2"
  [ "$n" -gt "$3" ] && n="$3"
  printf '%s' "$n"
}

_res_is_uint() {  # <string> — a non-negative decimal integer and nothing else
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *)           return 0 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────── resources_probe

_res_free_mb() {  # currently reclaimable memory, in MB
  # The override is what makes tests/resources.test.sh hermetic: a suite that had to wait
  # for the machine to be quiet would be a suite nobody runs. It is read here rather than
  # inside resources_pressure so the probe and the pressure reading agree.
  if [ -n "${BIONIC_PROBE_FREE_MB:-}" ]; then
    printf '%s' "${BIONIC_PROBE_FREE_MB}"
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      # free + speculative + inactive is macOS's nearest equivalent to Linux MemAvailable:
      # all three are reclaimable without swapping. `Pages free` ALONE is not the reading to
      # take — a healthy macOS keeps it small on purpose, and a HOLD on that number would
      # fire constantly on an idle machine.
      vm_stat 2>/dev/null | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") { ps = $(i+1); break } }
        /^Pages free:/        { f = $3 }
        /^Pages speculative:/ { s = $3 }
        /^Pages inactive:/    { n = $3 }
        END {
          gsub(/\./, "", f); gsub(/\./, "", s); gsub(/\./, "", n)
          if (ps == "" || ps + 0 == 0) ps = 4096
          printf "%d", ((f + s + n) * ps) / 1048576
        }'
      ;;
    Linux)
      # MemAvailable is the kernel's own answer and is preferred over MemFree for exactly
      # the reason above. Older kernels without it fall back to MemFree + Cached.
      awk '
        /^MemAvailable:/ { avail = $2 }
        /^MemFree:/      { free  = $2 }
        /^Cached:/       { if (cached == "") cached = $2 }
        END { printf "%d", (avail != "" ? avail : free + cached) / 1024 }' /proc/meminfo 2>/dev/null
      ;;
    *) printf '0' ;;
  esac
}

_res_load_1m() {  # one-minute load average
  if [ -n "${BIONIC_PROBE_LOAD_1M:-}" ]; then
    printf '%s' "${BIONIC_PROBE_LOAD_1M}"
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }' ;;
    Linux)  awk '{ print $1 }' /proc/loadavg 2>/dev/null ;;
    *)      printf '0' ;;
  esac
}

# _res_free_pct / _res_swap_pct — the two readings `free_mb` alone could not give (AC-13).
#
# WHY THEY EXIST. `_res_free_mb` answers "how many MB are reclaimable", and on the machine
# this wave was designed on that number read healthy (1767 MB, above HOLD_FREE_MB) while
# swap sat at 69 % consumed — the charter's B-3 divergence exactly. A percentage is also
# the only reading that means the same thing on an 8 GB machine and a 128 GB one, which is
# what lets ONE band table serve both.
#
# UNREADABLE IS -1, NEVER 0. A sensor that cannot be read must not read as "nothing free":
# that would be an emergency invented out of a missing command. `pressure_band` ignores a
# -1 term outright, so an absent sensor degrades to the other terms — AC-13's "an
# unreadable input degrades to today's reading, never to a hold".
#
# BOTH HONOUR AN ENV PIN, the BIONIC_PROBE_* idiom the other two readings already use
# (resources.sh:154), so tests/resources.test.sh drives the bands without waiting for a
# machine to get into trouble, and without a convenient constant inside the sensor.

_res_free_pct() {  # system-wide free memory as a percentage, or -1 if unreadable
  if [ -n "${BIONIC_PROBE_FREE_PCT:-}" ]; then
    printf '%s' "${BIONIC_PROBE_FREE_PCT}"
    return 0
  fi
  local v=''
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      # `memory_pressure`'s PARSEABLE line is its LAST one — everything above it is a stats
      # block whose sections vary by release (research-code-map §2.5). Matching the phrase
      # and keeping the last match is what makes this robust to a new section appearing.
      v="$(memory_pressure 2>/dev/null | awk '
        /System-wide memory free percentage:/ { line = $0 }
        END {
          if (line == "") exit 1
          sub(/.*percentage:[ \t]*/, "", line)
          sub(/%.*/, "", line)
          if (line !~ /^[0-9]+$/) exit 1
          printf "%d", line + 0
        }')" || v=''
      ;;
    Linux)
      # MemAvailable over MemTotal — the kernel's own answer, the same reading `_res_free_mb`
      # prefers, expressed as the share of the machine rather than an absolute.
      v="$(awk '
        /^MemTotal:/     { total = $2 }
        /^MemAvailable:/ { avail = $2 }
        END {
          if (total == "" || total + 0 == 0 || avail == "") exit 1
          printf "%d", (avail * 100) / total
        }' /proc/meminfo 2>/dev/null)" || v=''
      ;;
  esac
  _res_is_uint "$v" || v=-1
  printf '%s' "$v"
}

_res_swap_pct() {  # swap in use as a percentage of swap configured, or -1 if unreadable
  if [ -n "${BIONIC_PROBE_SWAP_PCT:-}" ]; then
    printf '%s' "${BIONIC_PROBE_SWAP_PCT}"
    return 0
  fi
  local v=''
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      # `sysctl vm.swapusage` → `total = 3072.00M  used = 2132.44M  free = 939.56M`. The
      # values are read BY KEYWORD and their unit suffix is parsed, never assumed: macOS
      # prints G once swap grows past a gigabyte, and a unit read as a bare number would put
      # the ratio out by 1024.
      v="$(sysctl vm.swapusage 2>/dev/null | awk '
        function mb(s,   n, u) {
          n = s; sub(/[A-Za-z]+$/, "", n)
          u = s; sub(/^[0-9.]+/, "", u)
          if (u ~ /^[Gg]/) return (n + 0) * 1024
          if (u ~ /^[Kk]/) return (n + 0) / 1024
          return n + 0
        }
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "total" && $(i + 1) == "=") total = mb($(i + 2))
            if ($i == "used"  && $(i + 1) == "=") used  = mb($(i + 2))
          }
        }
        END {
          if (total == "") exit 1
          # No swap configured is 0 % used, not a division fault and not an unknown.
          if (total + 0 == 0) { printf "0"; exit 0 }
          if (used == "") exit 1
          printf "%d", (used * 100) / total
        }')" || v=''
      ;;
    Linux)
      v="$(awk '
        /^SwapTotal:/ { total = $2 }
        /^SwapFree:/  { free = $2 }
        END {
          if (total == "" || free == "") exit 1
          if (total + 0 == 0) { printf "0"; exit 0 }
          printf "%d", ((total - free) * 100) / total
        }' /proc/meminfo 2>/dev/null)" || v=''
      ;;
  esac
  _res_is_uint "$v" || v=-1
  printf '%s' "$v"
}

_res_is_pct() {  # a percentage reading: a non-negative integer, or the -1 "unreadable"
  case "${1:-}" in
    -1)          return 0 ;;
    ''|*[!0-9]*) return 1 ;;
    *)           return 0 ;;
  esac
}

_res_cores() {  # this machine's core count, floored at 1 — pressure_sample's default
  local c=''
  case "$(uname -s 2>/dev/null)" in
    Darwin) c="$(sysctl -n hw.ncpu 2>/dev/null)" ;;
    Linux)  c="$(nproc 2>/dev/null)" ;;
  esac
  if ! _res_is_uint "$c" || [ "$c" -lt 1 ]; then c=1; fi
  printf '%s' "$c"
}

_res_now() {  # the epoch second this call is happening at
  if [ -n "${BIONIC_NOW_EPOCH:-}" ]; then
    printf '%s' "${BIONIC_NOW_EPOCH}"
    return 0
  fi
  date +%s 2>/dev/null
}

# resources_probe — the five machine facts, one line, `key=value` space-separated.
#
#   cores=<n> mem_gb=<n> disk_free_gb=<n> load_1m=<f> os=<darwin|linux>
#
# Read the answer BY KEY, never by position: this record's field order is stable today and
# a later field would be appended, but every reader in the repo (the attestation schema
# included) is written key-first for exactly that reason.
#
# disk_free_gb is measured at the CURRENT DIRECTORY, because the thing it bounds is
# worktrees, and worktrees are cut beside the repo the caller is standing in.
resources_probe() {
  local os cores mem_gb disk_free_gb load_1m

  case "$(uname -s 2>/dev/null)" in
    Darwin) os=darwin ;;
    Linux)  os=linux  ;;
    *)      os=unknown ;;
  esac

  case "$os" in
    darwin)
      cores="$(sysctl -n hw.ncpu 2>/dev/null)"
      mem_gb="$(sysctl -n hw.memsize 2>/dev/null)"
      # GiB, not GB: hw.memsize is a byte count of physical RAM, and 128 GiB is what a
      # "128 GB" machine reports. Integer division floors, which is the safe direction.
      _res_is_uint "$mem_gb" && mem_gb=$(( mem_gb / 1073741824 )) || mem_gb=0
      # -P forces the POSIX one-line-per-filesystem format, so a long device name cannot
      # wrap and shift the column this reads. -g is 1 GiB blocks; column 4 is Available.
      disk_free_gb="$(df -Pg . 2>/dev/null | tail -1 | awk '{ print $4 }')"
      ;;
    linux)
      cores="$(nproc 2>/dev/null)"
      # MemTotal is in kB; round to the nearest GiB rather than flooring, so a 16 GB machine
      # reporting 15.6 GiB of usable RAM does not budget as a 15 GB one.
      mem_gb="$(awk '/^MemTotal:/ { printf "%d", ($2 + 524288) / 1048576 }' /proc/meminfo 2>/dev/null)"
      disk_free_gb="$(df -BG -P . 2>/dev/null | tail -1 | awk '{ v = $4; sub(/G$/, "", v); print v }')"
      ;;
    *)
      cores=1; mem_gb=1; disk_free_gb=0
      ;;
  esac

  load_1m="$(_res_load_1m)"

  # A probe that cannot read a fact answers a SAFE fact, never an empty field: an empty
  # field would flow into the attestation and out the other side as a budget of nothing.
  _res_is_uint "$cores"        || cores=1
  [ "$cores" -ge 1 ]           || cores=1
  _res_is_uint "$mem_gb"       || mem_gb=1
  [ "$mem_gb" -ge 1 ]          || mem_gb=1
  _res_is_uint "$disk_free_gb" || disk_free_gb=0
  case "${load_1m:-}" in
    ''|*[!0-9.]*) load_1m=0 ;;
  esac

  printf 'cores=%s mem_gb=%s disk_free_gb=%s load_1m=%s os=%s\n' \
    "$cores" "$mem_gb" "$disk_free_gb" "$load_1m" "$os"
}

# ────────────────────────────────────────────────────────────────── resources_budget

# resources_budget <cores> <mem_gb> <disk_free_gb> — the ceiling, one line:
#
#   writers=<n> suites=<n> worktrees=<n> test_jobs=<n>
#
#   suites    = max(1, min(floor((mem_gb − MEM_RESERVE_GB) / MEM_PER_SUITE_GB),
#                          floor(cores / CORES_PER_SUITE)))
#   test_jobs = clamp(cores, TEST_JOBS_MIN, TEST_JOBS_MAX)
#   worktrees = clamp(floor(disk_free_gb / DISK_PER_TREE_GB), WORKTREES_MIN, WORKTREES_MAX)
#   writers   = clamp(suites + WRITERS_EXTRA, WRITERS_MIN, WRITERS_MAX)
#
# min over resources of "available ÷ unit cost" — the memory term measured and binding, the
# compute term soft until AC-32, the disk term bounding leases. `max(1, …)` is not
# cosmetic: a 4 GB machine's memory term is 1 and a 3 GB machine's is 0, and a budget of
# zero suites is a machine that can never prove anything.
#
# PURE. No file, no command, no environment variable — pass the probe's numbers in.
resources_budget() {
  if [ "$#" -ne 3 ]; then
    printf 'resources_budget: need <cores> <mem_gb> <disk_free_gb>, got %s argument(s)\n' "$#" >&2
    return 2
  fi
  local cores="$1" mem_gb="$2" disk_gb="$3"
  local a
  for a in "$cores" "$mem_gb" "$disk_gb"; do
    if ! _res_is_uint "$a"; then
      printf 'resources_budget: not a non-negative integer: %s\n' "$a" >&2
      return 2
    fi
  done

  local mem_avail=$(( mem_gb - MEM_RESERVE_GB ))
  [ "$mem_avail" -lt 0 ] && mem_avail=0

  local per_suite per_core per_tree
  per_suite="$(_res_hundredths "$MEM_PER_SUITE_GB")"
  per_core="$(_res_hundredths "$CORES_PER_SUITE")"
  per_tree="$(_res_hundredths "$DISK_PER_TREE_GB")"
  # A constant edited to zero would divide by zero rather than say so. Refuse instead.
  if [ "$per_suite" -le 0 ] || [ "$per_core" -le 0 ] || [ "$per_tree" -le 0 ]; then
    printf 'resources_budget: a per-unit constant is zero or negative; refusing to divide\n' >&2
    return 2
  fi

  local mem_term=$(( mem_avail * 100 / per_suite ))
  local cpu_term=$(( cores * 100 / per_core ))
  local suites="$mem_term"
  [ "$cpu_term" -lt "$suites" ] && suites="$cpu_term"
  [ "$suites" -lt 1 ] && suites=1

  local worktrees test_jobs writers
  worktrees="$(_res_clamp "$(( disk_gb * 100 / per_tree ))" "$WORKTREES_MIN" "$WORKTREES_MAX")"
  test_jobs="$(_res_clamp "$cores" "$TEST_JOBS_MIN" "$TEST_JOBS_MAX")"
  writers="$(_res_clamp "$(( suites + WRITERS_EXTRA ))" "$WRITERS_MIN" "$WRITERS_MAX")"

  printf 'writers=%s suites=%s worktrees=%s test_jobs=%s\n' \
    "$writers" "$suites" "$worktrees" "$test_jobs"
}

# ──────────────────────────────────────────────────────────────── resources_pressure

# resources_pressure <cores> — the live reading, one line:
#
#   state=<ok|hold|emergency> free_mb=<n> load_1m=<f> free_pct=<n> swap_pct=<n>
#
# The two readings are echoed alongside the state so a caller can PRINT THE MEASUREMENT
# rather than the verdict alone — AC-30 requires `HOLD <measurement>`, because a HOLD with
# no number is indistinguishable from a bug.
#
# Precedence: emergency, then the memory hold, then the load hold. Memory outranks load
# because memory is what kills; a busy machine finishes late, a starved one loses work.
#
# The one float comparison in this file is the load test, and it is done in awk. Both
# readings honour BIONIC_PROBE_FREE_MB / BIONIC_PROBE_LOAD_1M so the thresholds can be
# driven from either side without waiting on a real machine to get into trouble.
resources_pressure() {
  local cores="${1:-}"
  if ! _res_is_uint "$cores" || [ "$cores" -lt 1 ]; then
    printf 'resources_pressure: need <cores> as a positive integer, got: %s\n' "${1:-}" >&2
    return 2
  fi

  local free_mb load_1m free_pct swap_pct state
  free_mb="$(_res_free_mb)"
  load_1m="$(_res_load_1m)"
  _res_is_uint "$free_mb" || free_mb=0
  case "${load_1m:-}" in
    ''|*[!0-9.]*) load_1m=0 ;;
  esac
  # The two percentage readings are REPORTED, not judged here: `state=` keeps its exact
  # HOLD/EMERGENCY meaning (the tick still reads it as advice to the model), and the bands
  # that do read the percentages live in `pressure_band` below.
  free_pct="$(_res_free_pct)"
  swap_pct="$(_res_swap_pct)"
  _res_is_pct "$free_pct" || free_pct=-1
  _res_is_pct "$swap_pct" || swap_pct=-1

  state=ok
  if [ "$free_mb" -lt "$EMERGENCY_FREE_MB" ]; then
    state=emergency
  elif [ "$free_mb" -lt "$HOLD_FREE_MB" ]; then
    state=hold
  elif awk -v l="$load_1m" -v c="$cores" -v f="$HOLD_LOAD_FACTOR" \
         'BEGIN { exit !(l + 0 > c * f) }'; then
    state=hold
  fi

  printf 'state=%s free_mb=%s load_1m=%s free_pct=%s swap_pct=%s\n' \
    "$state" "$free_mb" "$load_1m" "$free_pct" "$swap_pct"
}

# ──────────────────────────────────────────────────── the band, the ring and the rung

# WHAT THIS SECTION ADDS (spec R4; AC-13, AC-14, AC-16; design-ledger D3, D4).
#
#   pressure_band <free%> <swap%> <load> <cores>   one reading  -> clear|warning|critical|emergency
#   pressure_sample [<cores>]                      take a reading and append it to the ring
#   pressure_level <ceiling>                       the ring + the ceiling -> a rung in [1, ceiling]
#
# WHY A RING AND A MEDIAN. A bare fresh reading lets one second of noise set a whole suite's
# width, and a controller that remembers its last decision stores a fact it does not own
# (D3, both rejected). The cure is a short window of readings on disk and a MEDIAN over it:
# every consumer that samples adds to the same evidence, and the level is recomputed from
# that evidence at the moment of use. NOTHING STORES A CURRENT LEVEL — `pressure_level`
# writes nothing (the one exception is an empty ring, where it takes a single reading so it
# has something to answer from), so two consumers at one moment compute one answer.
#
# WHY THE RING IS MACHINE-SCOPED (D4). Pressure describes the machine, so the ring lives at
# the machine's scope — one file under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bionic/, written
# and read by every bionic session in every project. A per-root ring would partition one
# machine's readings by directory and let two roots starve each other while each read clear.
# No run owns it and Step 8 does not wipe it. Appends are single O_APPEND writes and never
# rewrite the file; a prune runs only once the file passes PRESSURE_RING_MAX_LINES, through a
# mktemp-named copy, so it never grows without bound — while every READER sees only the samples
# inside the smoothing window, which is where the window guarantee lives (S20 C-1; auditor F-20).
#
# THE RUNG IS A FRACTION OF THE STEP-0 CEILING, NEVER A NUMBER OF ITS OWN: clear = ceiling,
# warning = half, critical = a quarter, emergency = 1. Both halvings round UP, so a small
# ceiling degrades to 1 rather than to 0. The ceiling itself is never exceeded and never
# re-derived here — the same rule the budget block above lives under.

pressure_band() {  # <free_pct> <swap_pct> <load_1m> <cores> -> clear|warning|critical|emergency
  local free_pct="${1:-}" swap_pct="${2:-}" load_1m="${3:-}" cores="${4:-}"

  if ! _res_is_pct "$free_pct" || ! _res_is_pct "$swap_pct"; then
    printf 'pressure_band: need <free_pct> <swap_pct> as integers or -1, got: %s %s\n' \
      "${1:-}" "${2:-}" >&2
    return 2
  fi
  case "${load_1m:-}" in
    ''|*[!0-9.]*)
      printf 'pressure_band: need <load_1m> as a non-negative number, got: %s\n' "${3:-}" >&2
      return 2 ;;
  esac
  if ! _res_is_uint "$cores" || [ "$cores" -lt 1 ]; then
    printf 'pressure_band: need <cores> as a positive integer, got: %s\n' "${4:-}" >&2
    return 2
  fi

  # A -1 term is UNREADABLE, not zero: every test below is guarded on `>= 0` first, so a
  # missing sensor drops out of the decision instead of driving it (AC-13).
  if [ "$free_pct" -ge 0 ] && [ "$free_pct" -lt "$BAND_FREE_EMERGENCY_PCT" ]; then
    printf 'emergency\n'; return 0
  fi
  if { [ "$free_pct" -ge 0 ] && [ "$free_pct" -lt "$BAND_FREE_CRITICAL_PCT" ]; } ||
     { [ "$swap_pct" -ge 0 ] && [ "$swap_pct" -ge "$BAND_SWAP_CRITICAL_PCT" ]; }; then
    printf 'critical\n'; return 0
  fi
  # The load term shares HOLD_LOAD_FACTOR with the `state=` arm above — one owner for "how
  # much queueing is normal" — and is the one float comparison here, so it is done in awk.
  if { [ "$free_pct" -ge 0 ] && [ "$free_pct" -lt "$BAND_FREE_WARNING_PCT" ]; } ||
     { [ "$swap_pct" -ge 0 ] && [ "$swap_pct" -ge "$BAND_SWAP_WARNING_PCT" ]; } ||
     awk -v l="$load_1m" -v c="$cores" -v f="$HOLD_LOAD_FACTOR" \
       'BEGIN { exit !(l + 0 > c * f) }'; then
    printf 'warning\n'; return 0
  fi
  printf 'clear\n'
}

_pressure_ring_path() {  # the one machine-scoped ring (D4); BIONIC_PRESSURE_RING overrides
  if [ -n "${BIONIC_PRESSURE_RING:-}" ]; then
    printf '%s' "${BIONIC_PRESSURE_RING}"
    return 0
  fi
  printf '%s/bionic/pressure.ring' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# _pressure_window_lines <ring> <now> — the well-formed samples inside the smoothing window.
# ONE OWNER for "what counts as in-window": the prune on append and the read in
# pressure_level both call this, so a sample can never be pruned by one rule and counted by
# another. A line the parser does not recognise is not a sample and is dropped on the next
# append rather than defaulting to some band.
_pressure_window_lines() {
  local ring="$1" now="$2"
  [ -r "$ring" ] || return 0
  awk -F'|' -v now="$now" -v w="$PRESSURE_WINDOW_S" '
    NF == 5 && $1 ~ /^[0-9]+$/ && ($1 + 0) >= (now - w) && ($1 + 0) <= (now + w) { print }
  ' "$ring" 2>/dev/null
}

# _pressure_ring_lines <ring> — the ring's line count as a plain integer, 0 when it cannot
# be read. `wc -l` pads on BSD and prints nothing on a missing file, so both go through
# arithmetic before any caller compares them.
_pressure_ring_lines() {
  local n
  n="$(wc -l < "$1" 2>/dev/null)" || n=0
  case "${n:-}" in ''|*[!0-9\ \	]*) n=0 ;; esac
  printf '%s' "$(( n + 0 ))"
}

# pressure_sample [<cores>] — THE ONE WRITER. Takes a reading, appends it, prunes the ring.
#
# The consumers sample (D3 amendment): plugin hooks were not observed firing inside
# subagents, so "activity writes the ring" would starve it exactly when writers are running.
# A suite start, a fill and the orchestrator's own recorder each append one reading, and all
# three read the same evidence back.
#
# THE APPEND IS THE SAMPLE PATH AND IT IS ONE `printf >>`, NOTHING ELSE (Step-6 review
# C-1 = S-3). It used to append and then REWRITE the whole ring from a filtered read on
# every single call, through a temp file named `${ring}.tmp.$$`. Two defects lived in that:
# `$$` is the PARENT shell's pid, so every background subshell of one shell wrote and
# renamed ONE temp path and they truncated each other (measured: 12 concurrent samplers
# left 0 lines); and even with distinct pids the read-then-rename discards any append that
# landed between them (12 separate processes left 3–6 of 12). The ring is the evidence
# AC-14's median smooths, so losing samples silently turns the median into the bare fresh
# reading D3 rejected. A sample is now appended with a single O_APPEND write and nothing on
# the sample path ever rewrites the file.
#
# THE PRUNE IS RARE, AND IT FAILS TOWARD EXTRA LINES. It fires only when the file exceeds
# PRESSURE_RING_MAX_LINES — far above the window's steady state, so almost every call skips
# it — writes through a `mktemp` name in the ring's own directory (the old predictable path
# was followed through a pre-planted symlink and truncated its target), and renames only if
# the ring's line count is unchanged since the count that triggered the prune. A lost race
# therefore leaves the ring LONGER than the window, never shorter: `_pressure_window_lines`
# filters on the READ side too, so extra lines cost nothing but bytes while a missing line
# is evidence that no longer exists. The residual is one syscall wide — an append landing
# between the recount and the rename — and it is reachable only on the rare prune.
pressure_sample() {
  local cores="${1:-}"
  [ -n "$cores" ] || cores="$(_res_cores)"
  if ! _res_is_uint "$cores" || [ "$cores" -lt 1 ]; then
    printf 'pressure_sample: need <cores> as a positive integer, got: %s\n' "${1:-}" >&2
    return 2
  fi

  local ring now free_pct swap_pct load_1m dir tmp
  ring="$(_pressure_ring_path)"
  now="$(_res_now)"
  if ! _res_is_uint "$now"; then
    printf 'pressure_sample: unreadable clock, got: %s\n' "${now:-}" >&2
    return 2
  fi

  free_pct="$(_res_free_pct)"
  swap_pct="$(_res_swap_pct)"
  load_1m="$(_res_load_1m)"
  _res_is_pct "$free_pct" || free_pct=-1
  _res_is_pct "$swap_pct" || swap_pct=-1
  case "${load_1m:-}" in ''|*[!0-9.]*) load_1m=0 ;; esac

  dir="$(dirname "$ring")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    printf 'pressure_sample: cannot create the ring directory %s\n' "$dir" >&2
    return 2
  fi
  printf '%s|%s|%s|%s|%s\n' "$now" "$free_pct" "$swap_pct" "$load_1m" "$cores" >> "$ring" || {
    printf 'pressure_sample: cannot append to %s\n' "$ring" >&2
    return 2
  }

  # The opportunistic prune, per the header. `wc -l` pads its output on BSD, so the count
  # goes through arithmetic rather than a string compare.
  local n1 n2
  n1="$(_pressure_ring_lines "$ring")"
  [ "$n1" -gt "$PRESSURE_RING_MAX_LINES" ] || return 0

  tmp="$(mktemp "${dir}/pressure.ring.prune.XXXXXX" 2>/dev/null)" || return 0
  [ -n "$tmp" ] || return 0
  if _pressure_window_lines "$ring" "$now" > "$tmp" 2>/dev/null; then
    n2="$(_pressure_ring_lines "$ring")"
    if [ "$n2" -eq "$n1" ]; then
      mv -f "$tmp" "$ring" 2>/dev/null || rm -f "$tmp"
    else
      # Somebody appended while we were reading. Leave the ring alone: too long is
      # harmless, too short is lost evidence.
      rm -f "$tmp"
    fi
  else
    rm -f "$tmp"
  fi
  return 0
}

# pressure_level <ceiling> — the rung, on stdout; `rung=<n>/<ceiling> band=<b> samples=<k>`
# on stderr so a caller can print the reasoning beside the number (the same rule the
# HOLD line above lives under: a verdict with no measurement is indistinguishable from a bug).
#
# PURE, with one stated exception: it reads the ring and writes nothing, so two consumers at
# one moment agree and calling it twice cannot move the answer. The exception is an EMPTY
# ring, where it takes a single sample first — a first consumer on a cold machine must have
# something to answer from, and answering from no evidence at all is the failure mode.
#
# An even number of samples resolves to the HIGHER of the two middle bands. Pressure is
# asymmetric: reading calm when the machine is not costs work, reading busy when it is calm
# costs wall time (the file's opening rule — memory is hard, compute is soft).
pressure_level() {
  local ceiling="${1:-}"
  if ! _res_is_uint "$ceiling" || [ "$ceiling" -lt 1 ]; then
    printf 'pressure_level: need <ceiling> as a positive integer, got: %s\n' "${1:-}" >&2
    return 2
  fi

  local ring now lines
  ring="$(_pressure_ring_path)"
  now="$(_res_now)"
  _res_is_uint "$now" || now=0
  lines="$(_pressure_window_lines "$ring" "$now")"
  if [ -z "$lines" ]; then
    pressure_sample >/dev/null 2>&1
    now="$(_res_now)"
    _res_is_uint "$now" || now=0
    lines="$(_pressure_window_lines "$ring" "$now")"
  fi

  # ONE AWK, NOT ONE SUBSHELL PER SAMPLE (Step-6 review P-3). This loop used to call
  # `pressure_band` in a command substitution once per line in the window, and the window
  # holds whatever the sample RATE put there — the recorder samples on every engaged Bash
  # call, so a busy session measured 144 samples and 0.36 s of pure fork here, and the
  # busier the machine the slower its own rung read. The banding is arithmetic on four
  # fields; awk does it in the same pass that already reads them.
  #
  # `pressure_band` REMAINS THE OWNER of the thresholds and is still the function every
  # other caller uses; this is its rules transcribed into the one place that needs them at
  # volume. Two transcriptions can drift, so tests/resources.test.sh §K.2 drives both over
  # the same table of samples and requires identical answers on every row, including the
  # refusals — that agreement row is what makes this an optimisation rather than a second
  # opinion.
  local n=0 ranks=''
  if [ -n "$lines" ]; then
    ranks="$(printf '%s\n' "$lines" | LC_ALL=C awk -F'|' \
      -v fe="$BAND_FREE_EMERGENCY_PCT" -v fc="$BAND_FREE_CRITICAL_PCT" \
      -v fw="$BAND_FREE_WARNING_PCT"   -v sc="$BAND_SWAP_CRITICAL_PCT" \
      -v sw="$BAND_SWAP_WARNING_PCT"   -v lf="$HOLD_LOAD_FACTOR" '
      # `-1` is UNREADABLE, not zero, so every percentage test is guarded on >= 0 first
      # and a missing sensor drops out of the decision instead of driving it (AC-13).
      function ispct(v) { return (v == "-1") || (v ~ /^[0-9]+$/) }
      $0 == "" { next }
      # The same refusals pressure_band makes, and a refused sample is not counted.
      !ispct($2) || !ispct($3) { next }
      $4 == "" || $4 !~ /^[0-9.]+$/ { next }
      $5 !~ /^[0-9]+$/ || ($5 + 0) < 1 { next }
      {
        f = $2 + 0; s = $3 + 0; l = $4 + 0; c = $5 + 0
        if (f >= 0 && f < fe)                                  { print 3; next }
        if ((f >= 0 && f < fc) || (s >= 0 && s >= sc))         { print 2; next }
        if ((f >= 0 && f < fw) || (s >= 0 && s >= sw) || (l > c * lf)) { print 1; next }
        print 0
      }
    ')" || ranks=""
    n="$(printf '%s' "$ranks" | grep -c . 2>/dev/null)" || n=0
    case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  fi

  # No evidence is not an emergency. A ring that could not be read or held nothing usable
  # degrades to clear — the ceiling Step 0 already derived from the machine's facts — for
  # the same reason an unreadable sensor never becomes a hold (AC-13).
  local rank=0
  if [ "$n" -gt 0 ]; then
    rank="$(printf '%s' "$ranks" | sort -n | awk -v k="$n" 'NR == int(k / 2) + 1 { print; exit }')"
  fi
  case "${rank:-0}" in 0|1|2|3) : ;; *) rank=0 ;; esac

  local band rung
  case "$rank" in
    3) band=emergency; rung=1 ;;
    2) band=critical;  rung=$(( (ceiling + 3) / 4 )) ;;
    1) band=warning;   rung=$(( (ceiling + 1) / 2 )) ;;
    *) band=clear;     rung="$ceiling" ;;
  esac
  if [ "$rung" -lt 1 ]; then rung=1; fi
  if [ "$rung" -gt "$ceiling" ]; then rung="$ceiling"; fi

  printf 'rung=%s/%s band=%s samples=%s\n' "$rung" "$ceiling" "$band" "$n" >&2
  printf '%s\n' "$rung"
}

