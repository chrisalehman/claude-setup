---
paths:
  - "tests/*.sh"
---

# Test harness traps

Migrated from `.bionic/memory/INDEX.md` (epic-12 wave-01 slice 6). Both entries are
`installer-behavior.test.sh` gotchas that existed nowhere else in the corpus. That suite and
the `claude-bootstrap.sh` installer it exercised were both deleted at epic-17 W5 4/6 (commit
`2ac5d48`) — the traps below are kept as historical record of a shape a future suite could
still fall into, not as live coverage; nothing in the current tree pins either lesson.

- **`tests/installer-behavior.test.sh` used to extract ONLY functions named in its `for fn in` awk
  loop — internal callees were NOT pulled in implicitly.** A missing callee 127s silently
  inside `step_stream` (swallowed as a normal step failure). Any harness built the same way should
  list every helper it calls too. Bit epic-04 slice 4/2, 2026-07-15.

- **`tests/installer-behavior.test.sh` ran `set -uo pipefail` but `claude-bootstrap.sh` ran
  `set -euo pipefail` — errexit behavior went untested by default.** Any fail-open claim about a
  script pair shaped this way needs a `(set -e; fn)` subshell regression test. Bit epic-06: a bare
  `cat` command-substitution aborted the whole bootstrap on an unreadable `.links` entry.

- **`bash tests/run.sh` is the one gating command.** Its roster is every `tests/*.test.sh`,
  sorted and read at run time — location is the declaration (fixit 1.5.1, D-1): a suite gates
  by being in the directory, and a roster wall refuses any glob match that isn't shaped like a
  suite. See `tests/run.sh` for the wall's shape rule — it is not repeated here
  to avoid a second stale count. (There was once a Docker mock e2e suite,
  `tests/bootstrap-e2e-docker.sh`, run alongside this roster; it was deleted at epic-17 W5
  alongside the installer it exercised — `tests/run.sh`'s own header records it — and nothing
  in the current roster replaces it.) There is no CI — this suite is the gate. A green run still says nothing about the hooks a SESSION actually loads: the
  suite exercises `hooks/*.sh` in the tree, while what gates a tool call is the copy inside
  the payload the CLI resolved for the installed plugin. After a hook change, install the
  plugin and let `/bionic:doctor` say which root answered before believing a wall is live.

- **The roster is the directory. A new `tests/foo.test.sh` gates on the very next run** —
  no `run` line to add, no second list to keep in step (fixit 1.5.1, D-1). This corrects a
  real failure, not a hypothetical: a since-deleted root wrapper script once hand-listed its
  own suites and produced exactly this false green when it forgot one, which is why
  `tests/run.sh`'s roster wall now refuses any glob match that isn't shaped like a suite.
