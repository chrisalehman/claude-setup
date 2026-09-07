# payload/scripts/lib/run.sh — ONE READER FOR "is there a run to protect", and for
# "WHICH run answers for THIS session".
#
# WHAT IT OWNS (L-RUN, wave-bionic-1.4.0-update, spec AC-8; design-ledger S1). Pure
# functions of disk, no writes:
#   active_plan <root> -> the newest *.md (by mtime, to the SECOND under bash 3.2 — see
#                         the compare site) under <docs_root>/plans (depth <= 2)
#                         and <docs_root>/incidents (depth <= 2) that carries a flush-left
#                         `## SDLC State` heading; exit 1 and silent if none.
#   run_open <plan>    -> exit 0 iff THAT ONE FILE reads as an open run: its flush-left
#                         `current:` value is 0-8, or 9 with no `- Step 9:` line carrying
#                         `delivered:`, or a task-scale `current: T<n>` — AND its own
#                         frontmatter carries no `abandoned:` line; else exit 1. Silent
#                         both ways: the caller already holds the path.
#   active_run <root>  -> exit 0 + the plan path iff active_plan finds a file and run_open
#                         holds on it; else exit 1, silent.
#   open_runs <root>   -> every file _run_candidates finds for which run_open holds, one
#                         absolute path per line, NEWEST MTIME FIRST; exit 1 if none.
#
# AND, SINCE wave-roster-lifecycle (2026-09-05, spec AC-1/AC-22), the candidate walk both
# readers share and the LIVE subset engagement binds on:
#   _run_candidates <droot> -> every qualifying candidate under <droot>, NUL-separated, in
#                         walk order. The ONE fence-aware walk; active_plan and open_runs
#                         are now a selection and a filter over it and nothing else.
#   live_runs <root>   -> the subset of open_runs whose plan mtime is within the
#                         `live-window:` config value (default 7d) of now, same order.
#                         `BIONIC_NOW_EPOCH` overrides now, so a suite can backdate a plan
#                         without touching the clock.
#
# AND, SINCE wave-session-bound-run (2026-09-04, spec AC-1/AC-3/AC-6), the session's own
# answer — see the ENGAGEMENT section below for why the root-keyed answer was not enough:
#   session_plan <root> <sid> -> the marker's `plan=` value; exit 1 when there is no binding.
#   session_run <root> <sid>  -> one of `bound-open <p>` (0), `bound-closed <p>` (2),
#                                `fallback <p>` (0), `none` (1).
#
# WHY A DEDICATED FUNCTION (design-ledger S1, rejecting a time-bounded or stamp-keyed
# "active"). A run stays active until CLOSED (current: 9 with delivered:) or ABANDONED
# (frontmatter abandoned:) explicitly — never by a clock or a day-N silent disarm, because
# the thing walls check must be the thing that can arm them. Every always-on hook (ADOPT,
# Batch 1) calls `active_run "$ROOT"` and does its own work only when it succeeds.
#
# DELIBERATELY SIMPLER than hooks/canonical-sdlc-evidence-gate.sh's plan search (read for
# shape, not copied): no fence-awareness, no misplacement sweep, no task-ledger validation.
# Those exist there to keep a COMMIT gate from mis-firing on a documentation example; this
# predicate answers a narrower question for a WALL that fails open on any doubt, so a false
# "active" here costs nothing a fail-open hook cannot already absorb, and a false "inactive"
# is caught the same way every hook's own always-on fixture catches it.
#
# BASH 3.2. No associative arrays, no `${var^^}`, no `mapfile`.
#
# WHERE THE ROOTS WENT (epic-22 wave-01, N1). `docs_root` and `config_value` were defined
# here; they are lib/roots.sh's now, with every other root resolver in the tree, and this
# file is one of their callers. The soft source below is the only top-level command in this
# file — it defines functions, reads nothing and prints nothing — and it is what keeps
# `. lib/run.sh` on its own a complete thing, for tests/run-predicate.test.sh and for any
# caller that has not declared roots.sh through the loader idiom.
#
# FUNCTIONS ONLY OTHERWISE — nothing else here runs at source time and nothing here prints.
#
# [WALL: tests/run-predicate.test.sh]

# roots.sh, THE SOFT SOURCE — the idiom lib/detect.sh uses for lib/deps.sh and lib/checks.sh
# for lib/patrol.sh. Guarded on the function, so a caller that already has it pays nothing.
_run_self_dir() {
  local self="${BASH_SOURCE[0]}"
  case "$self" in */*) echo "${self%/*}" ;; *) echo "." ;; esac
}
if ! declare -F docs_root >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(_run_self_dir)" && pwd -P)/roots.sh"
fi

# _run_lines <file> -> the file with its line endings TRANSLATED to \n, never deleted.
# A trailing \r is stripped from each record (CRLF) and any remaining lone \r becomes a
# real newline (classic-Mac CR-only). Every read in this file is line-anchored, so it
# must see real newlines: `tr -d '\r'` would collapse a CR-only plan to one line, every
# match would miss, and the run would read as CLOSED while it was live — the
# fail-dangerous direction (.claude/rules/hook-authoring.md).
_run_lines() {
  awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }' "$1" 2>/dev/null
}

# _run_candidates <droot> -> every file under <droot>/plans and <droot>/incidents (each
# walked to depth <= 2) that carries a flush-left `## SDLC State`, NUL-separated, in walk
# order: plans/ then incidents/, and within each whatever order `find` produced. Prints
# nothing and exits 0 when there is no candidate; the caller counts.
#
# ONE WALK, TWO READERS (wave-roster-lifecycle S1, spec AC-22, R7 "one site per concept").
# This block ran twice — once inside `active_plan`, once inside `open_runs` — and the copy
# was deliberate for exactly one wave, because tests/cross-gate-agreement.test.sh §S.2
# pinned `active_plan`'s body BY SUBSTRING and factoring the walk out would have emptied
# the pins rather than failed them. §S.2 is behavioural now (it drives both readers over one
# fixture and raises the depth bound on a copy to prove it discriminates), so the copy has
# no reason left to exist. `active_plan` is a SELECTION over this list and `open_runs` is a
# FILTER over it; neither carries a walk of its own any more, and neither can drift from the
# other because there is nothing left to drift.
#
# NUL-SEPARATED, because a plan path may contain anything but NUL — run-predicate R6g builds
# its fixtures with spaces in every filename for this reason.
#
# DEPTH 2, AND IT IS THE FLEET'S ONLY BOUND (POKER/2, ratified 2026-09-03). This walk shipped
# at 3 and the readers it replaced walked 2, which is the bionic layout's own depth:
# `plans/<epic>/<wave>.plan.md`. For one wave the two bounds ran side by side and
# tests/cross-gate-agreement.test.sh §S.3d PINNED the disagreement rather than papering over
# it. It is resolved here, at 2, on the layout's own terms — a file three levels down under
# plans/ is a note, a fixture or a scratch draft, and admitting it re-opens the newest-race
# the `## SDLC State` filter exists to close. Every hook reads this one walk now, so the
# bound is stated once and pinned by number in three suites (run-predicate §R3,
# cross-gate §S.2, and the fixture battery's `nested-three-deep`).
_run_candidates() {
  local droot="$1"
  local f d
  for d in "$droot/plans" "$droot/incidents"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do
      # FENCE-AWARE, and line endings TRANSLATED rather than deleted. Two failure modes,
      # opposite directions, both recorded:
      #   - a `## SDLC State` heading that appears only inside a ``` fenced example is
      #     DOCUMENTATION. Counting it makes a page about the lifecycle look like a live
      #     run, and every always-on hook then binds in a project that has none.
      #   - `tr -d '\r'` collapses a CR-only (classic-Mac) file to a single line, every
      #     line-anchored match misses, and a real plan becomes invisible to the whole
      #     fleet while a wave is live (.claude/rules/hook-authoring.md).
      # awk splits on \n, so a CR-only file arrives as one record that gsub re-splits
      # into real lines. The evidence gate carries the same reading at its own parse.
      _run_lines "$f" | awk '
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        /^## SDLC State/ { found = 1 }
        END { exit !found }' || continue
      printf '%s\0' "$f"
    done < <(find "$d" -maxdepth 2 -type f -name '*.md' -print0 2>/dev/null)
  done
}

# active_plan <root> -> the newest *.md by mtime under <docs_root>/plans and
# <docs_root>/incidents (each walked to depth <= 2) that contains a flush-left
# `## SDLC State` line; exit 1 and print nothing when no candidate qualifies.
#
# The walk, its depth bound and the reasons for both are `_run_candidates`' (above). This
# function walks nothing: it is a SELECTION over that list. The paragraph used to be copied
# here in full and, once the walk moved, argued with its own code — "this function shipped at
# 3", "every hook reads this one walk now" — about a body that no longer contains a `find`.
active_plan() {
  local root="$1"
  local droot
  droot=$(docs_root "$root")
  local plan="" f
  while IFS= read -r -d '' f; do
    # THE COMPARATOR IS THE SHELL'S, AND UNDER BASH 3.2 THAT IS WHOLE SECONDS
    # (wave-01 S4, AC-9 — the documented outcome, not the portable one). `-nt`
    # compares `st_mtime` to the second under /bin/bash 3.2, the interpreter
    # ADR-001 pins the hooks to, and to the full timespec under bash 4.2+. So
    # two plans written inside ONE SECOND tie here, and a tie keeps the first
    # candidate the walk produced — directory order, which is not a fact about
    # the plans. tests/patrol-revive.test.sh rows 33/34 are the fixture that
    # meets it; a fixture that sets its mtimes with `touch -t` never can.
    #
    # WHY IT IS NOT FIXED WITH `stat`, WHICH BOTH PLATFORMS CAN ANSWER
    # SUB-SECOND (`stat -f %Fm` / `stat -c %Y.%N`): `open_runs` below orders the
    # same candidates with the same `-nt`, and "line 1 is `active_run`'s answer"
    # is the invariant run-predicate R6 and cross-gate §OR.1 pin. A finer
    # comparator HERE and the shell's THERE disagree for exactly the candidates
    # that share a second, which is the failure the block under `open_runs`
    # records as measured — identical set, 21 lines in a different order — when
    # a `stat`-keyed sort was built and rejected there. Making both finer costs
    # a `stat` pair per comparison in a loop that was deliberately taken from
    # 125,000 stat pairs down to ~9. So the two stay wrong in the same
    # direction, which is what makes them agree, and the ambiguity is a
    # documented property of the selection rather than a defect in one caller.
    if [ -z "$plan" ] || [ "$f" -nt "$plan" ]; then
      plan="$f"
    fi
  done < <(_run_candidates "$droot")
  [ -n "$plan" ] || return 1
  printf '%s\n' "$plan"
}

# run_open <plan-path> -> exit 0 iff THAT ONE FILE reads as an open run. Silent both ways.
#
# THE VERDICT MOVED HERE, UNCHANGED (wave-session-bound-run S1, 2026-09-04). Until this wave
# the open/closed decision was reachable only through `active_run <root>`, which picks the
# file for you: the newest plan in the root. Two engaged sessions in one repository therefore
# shared one run identity — the bug this wave exists to fix. A session bound to a plan needs
# the verdict on THAT file, and `open_runs` needs it on every candidate, so the body below is
# lifted out of `active_run` row for row and `active_run` is now `active_plan` + `run_open`.
# tests/run-predicate.test.sh R5 pins every row of the table AND the agreement between the
# two, so a verdict that drifted in either direction goes red on both sides.
#
# A PATH THAT IS NOT A READABLE FILE IS NOT AN OPEN RUN. `active_run` never asked, because
# `active_plan` only ever hands it a file `find -type f` just produced; `session_run` asks
# constantly, because a binding outlives the file it names (the plan is deleted, moved, or
# was written into a worktree that is now gone). Closed is the right answer there and the
# safe one: a session whose bound plan has vanished has no run to protect, and AC-6 forbids
# falling through to somebody else's.
run_open() {
  local plan="$1"
  [ -n "$plan" ] || return 1
  [ -f "$plan" ] || return 1

  # THE WHOLE FILE, READ ONCE, HELD IN A VARIABLE — every match below tests this
  # variable via a here-string, never a live pipe fed by _run_lines/awk. `grep -q`
  # (and `-m1`) exit at their FIRST match; piped directly to a still-writing producer,
  # that early exit closes the read end while the producer is mid-write, the producer
  # takes SIGPIPE and reports 141, and every caller of this file runs under
  # `set -o pipefail`, which promotes that 141 to the whole pipeline's own status. An
  # `if pipeline; then return 1; fi` guarded that way reads 141 as false: a plan that
  # DOES carry `delivered:` (or `abandoned:`) falls through as if it did not, and a
  # closed run reads open — the fail-dangerous direction. A here-string is fully
  # written by the shell before the reader ever starts, so there is no live writer left
  # to signal, regardless of match position or file size (measured: a `delivered:` line
  # near the top of a file past ~16-20 KB with pipefail on reproduces this at the
  # `_run_lines "$plan" | grep -qE …` shape; tests/run-predicate.test.sh §R4, AC-21;
  # sibling note tests/cross-gate-agreement.test.sh:1502, `producer | grep -q` under
  # pipefail exits 141 on large files).
  local lines
  lines=$(_run_lines "$plan")

  # Frontmatter close: a plan explicitly abandoned is never active, regardless of `current:`.
  local frontmatter
  frontmatter=$(awk '
    NR == 1 && $0 == "---" { f = 1; next }
    f && $0 == "---" { exit }
    f { print }
  ' <<< "$lines")
  if grep -q '^abandoned:' <<< "$frontmatter"; then
    return 1
  fi

  # The `current:` line. LEADING WHITESPACE IS TOLERATED and the read is fence-aware, for
  # the same reason the marker test above is: this is the exact tolerance the five
  # hand-copies in hooks/ carried, and a predicate that is stricter than the walls it
  # replaces goes silently inert on a plan those walls read perfectly well.
  local body
  body=$(awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    { print }' <<< "$lines")
  local current
  current=$(grep -m1 -E '^[[:space:]]*current[[:space:]]*:' <<< "$body" \
    | sed -E 's/^[[:space:]]*current[[:space:]]*:[[:space:]]*//' \
    | tr -d '[:space:]')
  [ -n "$current" ] || return 1

  # Task-scale: current: T<n> is always active (no numbered close).
  if grep -qE '^T[0-9]+$' <<< "$current"; then
    return 0
  fi

  # THE STEP NUMBER MAY CARRY A SUB-STEP LETTER — `8a`, `8b` — which the lifecycle uses
  # and every wall this replaces accepted (`^[0-9]+[ab]?$`). A predicate that read `8b`
  # as malformed would call a live run closed for the whole of step 8, which is where
  # implementation happens. The letter is stripped; what decides is the number.
  local step="${current%[ab]}"
  case "$step" in
    ''|*[!0-9]*) return 1 ;;
  esac

  # Steps 0-8: open by definition.
  if [ "$((10#$step))" -lt 9 ]; then
    return 0
  fi

  # Step 9: open unless a Step-9 evidence line records delivery. Anything past 9 is not a
  # step this lifecycle has, and an unrecognised state is not an open run.
  if [ "$((10#$step))" -eq 9 ]; then
    if grep -qE '^[[:space:]]*-?[[:space:]]*Step 9:.*delivered:' <<< "$lines"; then
      return 1
    fi
    return 0
  fi

  # Anything else (out-of-range current:, malformed) is not a recognized open state.
  return 1
}

# active_run <root> -> exit 0 + the plan path iff active_plan succeeds and that plan's state
# is open; else exit 1, silent. Its verdict is run_open's, byte for byte — this function now
# only chooses WHICH file the verdict is asked about.
active_run() {
  local root="$1"
  local plan
  plan=$(active_plan "$root") || return 1
  run_open "$plan" || return 1
  printf '%s\n' "$plan"
}

# open_runs <root> -> every candidate of active_plan's walk for which run_open holds, one
# absolute path per line, NEWEST MTIME FIRST; exit 1 and silent when the set is empty.
#
# WHY A SET AND NOT A WINNER (wave-session-bound-run, spec §Design "Open-run set"). Three
# callers need the whole set, and none of them can be served by `active_run`'s single
# answer: engagement binds a session only when the set has exactly one member, session-start
# lists every member when it has several, and poker's `bind` verb refuses a plan that is not
# a member. Nothing in the fleet could name the set before this wave.
#
# LINE 1 IS active_run's ANSWER whenever active_run has one. Ordering is newest-mtime-first
# with ties keeping discovery order, which is exactly `active_plan`'s own `-nt` tie-break, so
# the two agree by construction. They part company in one case and it is deliberate: when the
# NEWEST plan is closed, `active_run` has no answer at all while the set is non-empty. That
# is the state a session-keyed reader exists to survive — the run that just closed is still
# the newest file in the root (run-predicate R6d).
#
# THE WALK IS SHARED NOW (wave-roster-lifecycle S1, spec AC-22). It was restated here for one
# wave, because tests/cross-gate-agreement.test.sh §S.2 pinned `active_plan`'s body by
# substring and the extraction would have emptied those pins rather than failed them. §S.2 is
# behavioural as of this slice, so `_run_candidates` above is the only walk in this file and
# this function is a filter over its output. run-predicate R6e still drives the three
# properties — two trees, depth 2, fence-aware — through `open_runs` and checks the answer
# against `active_plan`'s, which is now an agreement between two callers of one walk rather
# than between two copies of one block.
#
# EACH CANDIDATE IS READ TWICE AND THAT WAS MEASURED, NOT ASSUMED (S10a, review P2a). The
# `## SDLC State` filter and `run_open` each run `_run_lines` on the same file. Collapsing
# them — capture once, hand the text to the verdict — was built and timed against this tree
# and is NOT taken: it moves 500 small plans from 8.4s to 8.1s and moves THIS repository's
# 104 candidates from 1.33s to 1.45s, because bash copies a 46 KB plan through the capture,
# the argument and the callee's local where the streamed pipe copies it none. The read that
# is actually worth removing is the one inside `run_open`, which reads its own text four
# more times through here-strings; that is the awk-rewrite promoted out of this slice.
open_runs() {
  local root="$1"
  local droot
  droot=$(docs_root "$root")
  local f i j lo hi mid
  local cnt=0
  local -a ord
  while IFS= read -r -d '' f; do
    run_open "$f" || continue
    # BINARY INSERTION, newest first (S10a, review P2c). The comparator is `-nt`, which is
    # `active_plan`'s own and the whole reason this is not a `stat`-and-`sort` pass — see
    # the block below the loop. What changed is only HOW MANY times it is asked: the linear
    # scan this replaces did one compare per element already placed — 125,000 stat pairs at
    # 500 open runs, measured at 1.15s standalone — and the binary search does ~9.
    #
    # IT FINDS THE SAME INDEX THE LINEAR SCAN DID, so the output is unchanged byte for byte.
    # `ord` is ordered newest-first, so `[ "$f" -nt "${ord[$i]}" ]` is FALSE for a prefix
    # and TRUE for the rest — monotone in `i` — and the boundary is exactly where the
    # linear scan broke. Ties keep discovery order, because `-nt` is STRICTLY newer.
    #
    # Bash 3.2: element-wise reads and writes only — `"${ord[@]}"` is an unbound-variable
    # error on an EMPTY array under the `set -u` every calling hook runs with.
    lo=0; hi="$cnt"
    while [ "$lo" -lt "$hi" ]; do
      mid=$(( (lo + hi) / 2 ))
      if [ "$f" -nt "${ord[$mid]}" ]; then hi="$mid"; else lo=$((mid + 1)); fi
    done
    j="$cnt"
    while [ "$j" -gt "$lo" ]; do
      ord[$j]="${ord[$((j - 1))]}"
      j=$((j - 1))
    done
    ord[$lo]="$f"
    cnt=$((cnt + 1))
  done < <(_run_candidates "$droot")
  [ "$cnt" -gt 0 ] || return 1

  # WHY NOT ONE `stat` AND ONE `sort`, which is the obvious O(n log n) rewrite and was
  # BUILT AND MEASURED BEFORE IT WAS REJECTED (S10a, review P2c). Keying on `stat`'s
  # nanosecond mtime and sorting once takes 500 open runs from 10.3s to 8.3s, against 9.2s
  # for the binary insertion above — and it silently breaks the one invariant this function
  # is held to.
  #
  # `-nt` IS NOT A TIMESTAMP COMPARISON, IT IS THE SHELL'S. Measured on this machine: bash
  # 3.2 (`/bin/bash` on macOS, the interpreter the hooks are written for) compares WHOLE
  # SECONDS, while bash 5.3 compares the full timespec. `active_plan` selects with `-nt`, so
  # any key of our own that is finer or coarser than the running shell's disagrees with it
  # for candidates sharing a second — and "LINE 1 IS active_run's ANSWER" is exactly what
  # run-predicate R6 and cross-gate §OR.1 pin. The disagreement is invisible to every fixture
  # that sets mtimes with `touch -t`, and it showed up only on a 500-plan tree built in one
  # burst: identical SET, 21 lines in a different order.
  #
  # So the comparator stays the shell's. The cost that was actually worth removing is the
  # NUMBER of comparisons, which the binary search takes from O(n²) to O(n log n) without
  # introducing a second opinion about which of two files is newer.
  i=0
  while [ "$i" -lt "$cnt" ]; do
    printf '%s\n' "${ord[$i]}"
    i=$((i + 1))
  done
  return 0
}

# live_runs <root> -> the subset of `open_runs <root>` whose plan mtime is within the
# `live-window:` config value of now, one absolute path per line, in open_runs' own
# newest-first order; exit 1 and print nothing when the subset is empty.
#
# LIVE ⊆ OPEN, ALWAYS (spec AC-1, R1; design §1 "Run"). This is a FILTER over `open_runs`'
# answer, not a second walk with a second predicate. That is the whole safety property: no
# gate that measures against the open rule can be loosened by anything decided here, because
# a file that is not open never reaches this function. `open_runs` is unchanged and no gate
# calls this one — `engage.sh` binds on it and `session-start.sh` counts the difference.
#
# WHY THE DISTINCTION EXISTS AT ALL. `open_runs` answers "not finished", and a repository
# accumulates those: a wave abandoned in spirit but never marked, a plan parked for a month
# behind the one being worked. Engagement needs "not finished AND being worked" so it can
# bind when exactly one run answers that, and session-start needs the difference so it can
# COUNT the quiet ones instead of listing them. Neither question is answerable from the open
# set alone, and neither is a good enough reason to start writing a liveness fact down.
#
# THE CLOCK IS AN INPUT. `BIONIC_NOW_EPOCH` overrides "now" so a suite can put a plan eight
# days in the past with `touch -t` and read the window from a fixed instant, rather than
# racing the machine's date (fixtures go inert by env pin — resources.sh's `BIONIC_PROBE_*`
# idiom). An empty or non-numeric pin is ignored rather than trusted: the wall-clock read is
# the safe default, and a fixture that meant to set it will fail loudly on its own assertion.
#
# THE WINDOW IS PROSE, AND AN UNREADABLE ONE IS THE DEFAULT RATHER THAN A GUESS. The grammar
# is the poker's `parse_seconds` widened by one unit — `Nd|Nh|Nm|Ns` — because days are what
# the key is written in and the unit that grammar lacks. It is restated here rather than
# shared because `parse_seconds` lives in two HOOKS (session-poker.sh:445,
# session-sweeper.sh:439) and a library cannot source a hook; §O already holds those two
# copies to each other. Both failure directions are silent if guessed at — a window of zero
# empties the live set and an unbounded one makes `live` mean `open` — so an unparseable
# value falls back to the same default an absent one gets.
live_runs() {
  local root="$1"
  local open_set raw try n u mult secs="" now cutoff f mt cnt=0
  local window_default="7d"

  open_set=$(open_runs "$root") || return 1

  raw=$(config_value "$root" "live-window" "$window_default")
  for try in "$raw" "$window_default"; do
    n="${try%[dhms]}"
    u="${try#"$n"}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    case "$u" in
      d) mult=86400 ;;
      h) mult=3600 ;;
      m) mult=60 ;;
      s) mult=1 ;;
      *) continue ;;
    esac
    # BASE 10 EXPLICITLY: bash reads a leading zero as octal, so an `08d` window would be an
    # arithmetic error and `07d` would silently work for the wrong reason.
    secs=$(( 10#$n * mult ))
    break
  done
  [ -n "$secs" ] || return 1

  now="${BIONIC_NOW_EPOCH:-}"
  case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  cutoff=$(( now - secs ))

  # THE MTIME READ IS THE FLEET'S (hooks/session-poker.sh:422 et al.): BSD `stat -f` first,
  # GNU `stat -c` second. A path this cannot stat is NOT live — the fail-closed direction,
  # because the cost of dropping it is `plan=none` and a bind the model makes by hand, while
  # the cost of admitting it is a session bound to a file nothing can read.
  #
  # WHOLE SECONDS, AND THAT IS FINE HERE. `open_runs` ORDERS with the shell's own `-nt`
  # precisely because a stat-derived key disagrees with it for candidates sharing a second;
  # this function does not order anything, it compares each mtime against a cutoff days away,
  # and it preserves the order it was handed line for line.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || mt=""
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    [ "$mt" -ge "$cutoff" ] || continue
    printf '%s\n' "$f"
    cnt=$((cnt + 1))
    # A HERE-STRING, NOT A HERE-DOC: `<<EOF` would expand `$` and backticks in a plan PATH,
    # and a pipe would put `cnt` in a subshell where the count never comes back.
  done <<<"$open_set"

  [ "$cnt" -gt 0 ] || return 1
  return 0
}

# ---------- ENGAGEMENT: the single switch every bionic hook reads FIRST ----------
#
# task-engaged-session (Chris, 2026-09-03): "all guardrails imposed by bionic should only
# apply when exercising bionic. Nothing should apply until bionic is triggered" — and the
# trigger is the canonical-sdlc skill, nothing else. `hooks/engage.sh` writes the marker at
# the instant of invocation; every hook asks this before it asks anything else, and exits
# silently when it is false. Engagement decides WHETHER a hook acts; a hook that finds the
# marker and no run at all runs its plan-free walls and skips the plan-bound ones. The
# marker is never removed during the session: `disarm` removes the Patrol stamp only, and a
# session that invoked the skill is bionic's for its whole life.
#
# WHAT DECIDES *WHAT* CHANGED IN wave-session-bound-run (2026-09-04, spec AC-1/AC-3/AC-6).
# This header used to read "the plan (`active_run`, above) decides WHAT", and that sentence
# was the bug in the codebase's own words: WHETHER was session-keyed and WHAT was
# ROOT-keyed. Two engaged sessions in one repository shared one run identity, so the
# evidence gate validated the wrong plan, `adopt` offered another run's agents, and
# session-start steered a new session at the existing run. The rule now:
#
#   THE SESSION'S BINDING DECIDES WHAT. `engaged-<sid>.state` has carried a `plan=` field
#   since 1.4.1 and nothing read it; `session_plan` reads it and `session_run` rules on it.
#   A bound session gets its OWN plan's verdict and never another's — a binding whose plan
#   is delivered, abandoned or gone answers `bound-closed`, which is engaged-with-no-run,
#   NOT a licence to fall through to whatever is newest (AC-6: a binding is a commitment).
#
#   NEWEST-PLAN IS THE ANNOUNCED FALLBACK, not the default. A session with no binding —
#   never engaged, or `plan=none`, which is what engagement writes when the root holds zero
#   or several open runs — resolves exactly as it did before this wave, by `active_run`, and
#   every consumer THAT ACTS ON THE RESOLUTION says `fallback` out loud, so the resolution
#   it used is visible (AC-3). Two callers announce nothing and are right not to:
#   `hooks/engage.sh` is deciding a binding rather than acting on a verdict, and
#   `hooks/session-start.sh` prints its own listing instead.
#
# The marker is still never written from here: this file reads disk and nothing else. The
# one writer is `payload/scripts/lib/binding.sh`.
#
# FAIL DIRECTION IS INVERTED HERE, deliberately: this is the one artifact whose PRESENCE
# opens walls. Every unreadable state — absent, symlink, foreign sid, empty sid, the
# `unknown` fallback two advisories use — reads as NOT engaged, because the arming
# partition is the consent boundary (1.3.2 close-out ruling) and a wall that binds a
# session which never consented is the bug this exists to fix.

# engaged_marker_path <root> <sid> -> the marker path, or exit 1 on a sid that is empty,
# `unknown`, or carries any character outside [A-Za-z0-9_-] (the stamp's own shape rule).
engaged_marker_path() {
  local root="$1" sid="$2"
  [ -n "$root" ] && [ -n "$sid" ] || return 1
  [ "$sid" = "unknown" ] && return 1
  case "$sid" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s/.bionic/tmp/engaged-%s.state\n' "$root" "$sid"
}

# engaged_session <root> <sid> -> exit 0 iff a REGULAR file exists at the marker path. A
# symlink there is refused before it is followed, matching the stamp guard. Silent both ways.
engaged_session() {
  local f
  f=$(engaged_marker_path "$1" "$2") || return 1
  [ -L "$f" ] && return 1
  [ -f "$f" ]
}

# ---------- THE SESSION'S OWN RUN ----------

# session_plan <root> <sid> -> the marker's `plan=` value on stdout, exit 0; exit 1 and
# silent when there is no binding to report.
#
# NOT A VERDICT, DELIBERATELY. It reports what the marker says and stops; `session_run`
# decides what that means. FOUR SHAPES ARE "NO BINDING", and all four are states the fleet
# actually produces: the file is ABSENT (a session that never engaged), EMPTY (which is what
# tests/session-poker.test.sh:82 plants — `: > .../engaged-$SID.state` — so a reader that
# treated it as anything else would break that suite's entire fixture set), carries no
# `plan=` line, or carries the literal `plan=none`, which is what engagement writes when the
# root holds zero or several open runs.
#
# THE MARKER-PATH GUARDS ARE `engaged_session`'s, RESTATED: the sid shape rule via
# `engaged_marker_path`, and a symlink refused BEFORE it is followed, so a planted link
# cannot make a session read its `plan=` out of a file outside the tree.
#
# LINE ENDINGS TRANSLATED, NEVER DELETED — `_run_lines`, for the reason stated at its
# definition. A marker written through a CRLF-normalising tool must not yield a plan path
# with a trailing CR: every consumer compares that value against a path.
session_plan() {
  local root="$1" sid="$2"
  local f
  f=$(engaged_marker_path "$root" "$sid") || return 1
  [ -L "$f" ] && return 1
  [ -f "$f" ] || return 1
  local lines val
  lines=$(_run_lines "$f")
  val=$(grep -m1 -E '^plan=' <<< "$lines" | sed -E 's/^plan=//')
  case "$val" in
    ''|none) return 1 ;;
  esac
  printf '%s\n' "$val"
}

# session_run <root> <sid> -> ONE line naming the verdict, and an exit status per verdict:
#
#   bound-open <path>    0   the session's own plan, and it is open
#   bound-closed <path>  2   the session's own plan: delivered, abandoned, or gone
#   fallback <path>      0   no binding; today's root-keyed answer, said out loud
#   none                 1   no binding and no open run in the root
#
# THE INVARIANT (spec §Design "Run verdict"; AC-6): A BOUND SESSION NEVER YIELDS `fallback`.
# `bound-closed` is a terminal answer, not a miss to recover from — the moment a run closes
# is exactly the moment a scan would hand its session somebody else's run, which is the
# failure this wave was opened on. Consumers take `bound-closed` and `none` through the same
# engaged-with-no-run branch they already have.
#
# IT DOES NOT ASK WHETHER THE SESSION IS ENGAGED. An unengaged caller is simply unbound and
# gets the fallback; `engaged_session` answers the other question, and every hook asks it
# first and separately. Two readers, two questions, no coupling.
#
# EXIT 2 IS A THIRD VALUE ON PURPOSE. `bound-closed` is neither "here is your run" (0) nor
# "this root has none" (1), and a consumer that only ever tests `if session_run …` would
# read a 2 as false and land in the no-run branch — which is the correct branch. The
# distinct status is there for the consumers that print the reason.
session_run() {
  local root="$1" sid="$2"
  local plan
  if plan=$(session_plan "$root" "$sid"); then
    if run_open "$plan"; then
      printf 'bound-open %s\n' "$plan"
      return 0
    fi
    printf 'bound-closed %s\n' "$plan"
    return 2
  fi
  if plan=$(active_run "$root"); then
    printf 'fallback %s\n' "$plan"
    return 0
  fi
  printf 'none\n'
  return 1
}
