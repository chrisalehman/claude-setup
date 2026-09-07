#!/bin/bash
# worktree.sh — the worktree LEASE (bionic 1.4.0, spec AC-11/AC-28; design
# ledger C1 "worktree lease", C2 ".bionic symlink retired").
#
# WHAT THIS FILE OWNS. A spawned worktree is a leased slot, bound to the ledger
# row that dispatched its writer. The lease ends when the row is
# fact-discharged, and ending it is ONE act: merge the branch, remove the tree,
# prune. Three callers need that act and the two facts around it —
# `spawn-worktree.sh land`, `hooks/stop-orders.sh standdown`, and the Patrol
# tick's lease-overrun line — so the behaviour lives here and each caller is a
# call site rather than a fourth definition of "discharged".
#
# SOURCED, NOT EXECUTED. Function names are prefixed `worktree_` (public) or
# `_wt_` (internal); nothing here runs at source time and nothing here exits.
#
# THE SYMLINK IS RETIRED (C2). `<worktree>/.bionic -> <main-root>/.bionic` is no
# longer planted by anything; a writer in a spawned tree reaches the state
# directory through project_root's git-common-dir mapping instead. What remains
# is the cleanup: `worktree_legacy_links` lists the ones an older bionic left
# behind, and the teardown verbs delete one when they meet it.
#
# NO `--force`, ANYWHERE. git's refusal to discard uncommitted work is the
# feature; a land that forced would be a lease that ate a writer's work.

_wt_self_dir() { dirname "${BASH_SOURCE[0]}"; }
# roots.sh, THE SOFT SOURCE — the idiom this file already uses for git-argv.sh, taken at
# source time because two of this file's roots are wanted on every path through it. Every
# root resolver in the tree has one definition there (epic-22 wave-01, N1); this file is a
# caller of `claude_home` (three copies before N1: here, lib/patrol.sh, lib/deps.sh) and
# `worktree_root` (three: here as `_wt_main_root`, lib/patrol.sh, spawn-worktree.sh).
if ! declare -F claude_home >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$( cd "$(_wt_self_dir)" 2>/dev/null && pwd -P )/roots.sh"
fi

# Physical absolute path of a directory. No `realpath`: BSD's is flagless and it
# is absent on some targets, and every path this file canonicalises is a
# directory (the same finding as lib/root.sh's).
_wt_abs() {  # <dir>
  [ -d "${1:-}" ] || return 1
  ( cd "$1" 2>/dev/null && pwd -P )
}

# Is this branch one no automated write may reach? THE LIST HAS ONE HOME:
# `git_branch_protected` in the sibling git-argv.sh, which hooks/protect-main.sh
# already sources for exactly the same question about a `git push`. That wall
# reads push argv and never sees a merge, so `land` is the second reader of the
# same list — and a second COPY of the list is how two walls come to disagree
# about which branch is the branch.
#
# LOADED LAZILY, from this file's own directory, the way lib/detect.sh loads
# lib/deps.sh: every caller of this library pays for git-argv.sh only if it
# actually asks, and a caller that already sourced it pays nothing.
#
# FAIL CLOSED (design ledger S4). Exit 2 means "unknowable", not "not
# protected": a wall that cannot read its own list must refuse rather than wave
# the merge through.
_wt_branch_protected() {  # <branch> -> 0 protected, 1 not, 2 unknowable
  local lib
  if ! declare -f git_branch_protected >/dev/null 2>&1; then
    lib="$( cd "$(_wt_self_dir)" 2>/dev/null && pwd -P )/git-argv.sh"
    [ -r "$lib" ] || return 2
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || return 2
    declare -f git_branch_protected >/dev/null 2>&1 || return 2
  fi
  git_branch_protected "${1:-}"
}


# Every legacy `<main-root>/.worktrees/*/.bionic` that is a SYMLINK, absolute,
# one per line. A real `.bionic` directory in a tree is the branch's own content
# and is never listed: the difference between deleting a dead link and deleting
# a writer's state is this test.
worktree_legacy_links() {  # <main-root> -> <abs path> per line
  local root d link
  root="$(_wt_abs "${1:-}")" || return 0
  [ -d "${root}/.worktrees" ] || return 0
  for d in "${root}/.worktrees"/*; do
    [ -d "$d" ] || continue
    link="${d}/.bionic"
    [ -L "$link" ] || continue
    printf '%s\n' "$link"
  done
}

# Delete a legacy link if one is there, and say whether it did. Never touches a
# directory, and never follows the link.
_wt_drop_legacy_link() {  # <worktree abs> -> 0 if one was deleted
  local link="${1:-}/.bionic"
  [ -L "$link" ] || return 1
  rm -f "$link" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# D1 — "never merge under a running suite", as one predicate.
#
# A CONJUNCTION, and deliberately so. `busy` alone is every session that is
# doing anything at all, and a live `tests/run.sh` alone belongs to whichever
# project started it. Together they are the world the constraint names: this
# project has a session working, and a suite is running on the machine. The
# session half carries the project scoping — a session file states its cwd —
# and the process half carries the suite scoping.
#
# A SESSION FILE OUTLIVES ITS PROCESS. `kill -0` is a builtin, so the liveness
# question is asked of the kernel rather than of the file, exactly as
# lib/patrol.sh asks it: a stale file left by a crashed CLI must never be able
# to hold a lease open forever.

# Existence only. Same shape as hooks/stop-check.sh's and session-sweeper.sh's,
# for the same reason: `pgrep -f` matches the full command line, and `ps` covers
# a machine without pgrep.
_wt_proc_running() {  # <pattern>
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f -- "$1" >/dev/null 2>&1
    return $?
  fi
  ps -eo command 2>/dev/null | grep -qF -- "$1"
}

# Is <cwd> this project? The main checkout itself, or any linked worktree under
# its `.worktrees` — which is where a writer running a suite actually sits, and
# so the case that matters most.
_wt_cwd_in_project() {  # <cwd> <main-root>
  local cwd="${1:-}" root="${2:-}"
  [ -n "$cwd" ] && [ -n "$root" ] || return 1
  [ "$cwd" = "$root" ] && return 0
  case "$cwd/" in "$root"/*) return 0 ;; esac
  return 1
}

# The D1 predicate. Prints `session=<name> pid=<pid> cwd=<cwd>` for the first
# session that satisfies it and returns 0; returns 1 when nothing does.
#
# NO JQ, NO OPINION. jq is this repo's only parser, and a machine without it
# cannot be shown a busy session — so the predicate answers "not proven" and the
# land proceeds. Refusing on a missing parser would make the verb unusable on
# exactly the degraded machine whose trees most need giving back, and D1 is a
# guard against a merge under a suite, not a guard against an unreadable
# directory.
_wt_busy_suite() {  # <main-root> -> session=... pid=... cwd=...
  local root="${1:-}" dir f pid cwd status name
  dir="$(claude_home)/sessions"
  [ -d "$dir" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  _wt_proc_running 'tests/run.sh' || return 1
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    status="$(jq -r '.status // empty' "$f" 2>/dev/null)"
    [ "$status" = "busy" ] || continue
    cwd="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
    _wt_cwd_in_project "$cwd" "$root" || continue
    kill -0 "$pid" 2>/dev/null || continue
    name="$(jq -r '.name // .sessionId // empty' "$f" 2>/dev/null)"
    printf 'session=%s pid=%s cwd=%s' "${name:-unknown}" "$pid" "$cwd"
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# The land verb.
#
# ONE ACT (C1). Merge the tree's branch --no-ff into the main checkout's CURRENT
# branch, remove the tree, prune. A land that did two of the three is a lease
# half-ended, and the third would be somebody's later chore.
#
# EVERY REFUSAL BEFORE THE MERGE. The order is cheapest-and-most-local first,
# and every one of them is checked before anything is changed, so a refused land
# leaves the repository exactly as it found it — with the single, deliberate
# exception of a legacy `.bionic` link, which is deleted on the way in because
# C2 retires it whatever the verdict.
#
# TWO BOUNDS ON THE POWER (security review F1). This function merges into the
# main checkout's current branch and deletes a worktree; both of those are
# irreversible enough that WHICH branch and WHICH tree cannot be left to the
# caller's word for it.
#
#   PROTECTED BRANCH. The branch merged into is never `main`/`master`.
#   hooks/protect-main.sh is the wall that keeps unreviewed work off those
#   branches, and it reads `git push` argv — a local `git merge --no-ff` is
#   invisible to it. Without this refusal a main checkout left on `main` (which
#   is where every checkout starts) turned an ordinary `land` into an unwalled
#   write to the protected branch, with the unmerged tree deleted in the same
#   call. The list is `git_branch_protected`'s, not a second copy of it.
#
#   INSIDE THE FARM. The tree landed sits under `<main-root>/.worktrees/`,
#   the only place this lease ever hands one out. `.git`-is-a-file proves the
#   path is A linked worktree of this repository; it does not prove the lease
#   issued it, and `spawn-worktree.sh land <path>` will take any path a caller
#   names. Any other linked worktree is somebody else's and is refused rather
#   than merged and removed.
#
# Both are checked before the legacy-link deletion above, so the deliberate
# exception applies only to a tree this lease is actually entitled to touch.
#
# A CONSEQUENCE, stated rather than hidden: `spawn-worktree.sh create` honours
# an absolute parent directory outside the checkout, and a tree created that way
# is not landable by this verb. Remove it, or merge it by hand.
#
# THE BRANCH IS NEVER DELETED. Same contract as `remove`: the tree is the leased
# resource, the branch is the work.
_wt_say() { printf '%s: %s\n' "${WORKTREE_CONTRACT_PROG:-spawn-worktree}" "$*"; }
_wt_refuse() { _wt_say "REFUSED reason=$*"; return 2; }

worktree_land() {  # <worktree path> -> LANDED | REFUSED
  local target="${1:-}" wt_abs root branch main_branch ahead busy merge_sha

  [ -n "$target" ] && [ -d "$target" ] || { _wt_refuse "no-such-worktree path=${target:-<none>}"; return 2; }
  # A linked worktree's `.git` is a FILE pointing into the shared repository;
  # the main checkout's is a directory. That is the guard against being handed
  # the main checkout to dismantle.
  [ -f "${target}/.git" ] || { _wt_refuse "not-a-linked-worktree path=${target}"; return 2; }

  wt_abs="$(_wt_abs "$target")" || { _wt_refuse "no-such-worktree path=${target}"; return 2; }
  root="$(worktree_root "$wt_abs")" || { _wt_refuse "repo-root-unresolvable path=${wt_abs}"; return 2; }
  [ -n "$root" ] || { _wt_refuse "repo-root-unresolvable path=${wt_abs}"; return 2; }

  # INSIDE THE FARM. Both sides are already physical absolute paths, so this is
  # a path-SEGMENT test and not a string-prefix one: the trailing slash is what
  # makes `<root>/.worktrees-decoy/x` a sibling rather than a member, and `?*`
  # is what keeps `<root>/.worktrees/` itself — the farm, not a tree — out.
  case "$wt_abs" in
    "${root}/.worktrees/"?*) : ;;
    *) _wt_refuse "outside-worktrees path=${wt_abs} root=${root}"; return 2 ;;
  esac

  # THE BRANCH MERGED INTO, read and judged before anything is touched.
  main_branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$main_branch" ] || { _wt_refuse "main-head-unreadable root=${root}"; return 2; }
  _wt_branch_protected "$main_branch"
  case $? in
    0) _wt_refuse "protected-branch branch=${main_branch} root=${root}"; return 2 ;;
    2) _wt_refuse "protected-branch-unknowable branch=${main_branch} root=${root}"; return 2 ;;
  esac

  branch="$(git -C "$wt_abs" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || { _wt_refuse "worktree-head-unreadable path=${wt_abs}"; return 2; }

  # C2's retirement, taken on the way in: a legacy link is untracked work as far
  # as git is concerned and would refuse the removal below over it.
  _wt_drop_legacy_link "$wt_abs" || :

  if [ -n "$(git -C "$wt_abs" status --porcelain 2>/dev/null)" ]; then
    _wt_refuse "dirty-tree path=${wt_abs} branch=${branch}"; return 2
  fi

  ahead="$(git -C "$root" rev-list --count "HEAD..${branch}" 2>/dev/null)"
  case "$ahead" in ''|*[!0-9]*) _wt_refuse "branch-unreadable branch=${branch}"; return 2 ;; esac
  if [ "$ahead" -eq 0 ]; then
    _wt_refuse "nothing-to-land branch=${branch} onto=${main_branch}"; return 2
  fi

  busy="$(_wt_busy_suite "$root")" && {
    _wt_refuse "suite-running ${busy}"; return 2
  }

  # --no-ff ALWAYS: a fast-forward would erase the fact that this was a slice,
  # and the merge commit is what the ledger row points at.
  if ! git -C "$root" merge --no-ff -m "merge ${branch} (land)" "$branch" >/dev/null 2>&1; then
    git -C "$root" merge --abort >/dev/null 2>&1
    _wt_refuse "merge-failed branch=${branch} onto=${main_branch}"; return 2
  fi
  merge_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"

  # No --force here either. If git refuses now, the merge has landed and the
  # tree has not gone; the line says both so the operator is not left guessing
  # which half happened.
  if ! git -C "$root" worktree remove "$wt_abs" >/dev/null 2>&1; then
    _wt_refuse "worktree-remove-refused path=${wt_abs} merged=${merge_sha}"; return 2
  fi
  git -C "$root" worktree prune >/dev/null 2>&1

  _wt_say "LANDED branch=${branch} merge=${merge_sha} removed=${wt_abs}"
  return 0
}

# ---------------------------------------------------------------------------
# Lease overruns — a tree still standing after its row was discharged.
#
# C1's tick finding, and only a finding: this function lands nothing and
# removes nothing. A tree whose lease has ended is a slot counted against the
# worktree budget that nobody holds, and the Patrol's job is to say so.
#
# THE WALK STARTS AT THE TREES, not at the rows: what is being reported is disk
# that outlived a contract, so a discharged row with no tree is silent (its
# lease ended correctly) and a tree with no discharged row is silent (its lease
# is still running).
#
# THE MAPPING IS BY CONVENTION, and it has to be: the roster carries a row's
# name, its deliverable and its addresses, but no worktree path — nothing writes
# one. A tree at `.worktrees/<dir>` belongs to the row named `W-<DIR>`
# uppercased, which is the spelling every wave in this repo has dispatched
# under; the bare `<dir>` is accepted too, for a caller that names its rows
# without the prefix.

# One `|`-delimited field, BY KEY. Position would read the wrong value on a line
# whose schema gained a field, which is the same reason every other reader in
# this repo does it this way.
_wt_field() {  # <line> <key>
  local f
  while IFS= read -r f; do
    case "$f" in "${2}="*) printf '%s' "${f#"${2}="}"; return 0 ;; esac
  done <<EOF
$(printf '%s' "${1:-}" | tr '|' '\n')
EOF
  printf ''
}

# The discharge set, spelled the way hooks/stop-orders.sh and hooks/stop-guard.sh
# spell it: an ack, or a WAIVED contract, or a MET one. `status=` is read as well
# as `state=` so a roster row that records its own closure is understood by the
# same predicate as a sweeper verdict line.
_wt_discharged() {  # <line>
  local v
  [ "$(_wt_field "$1" acked)" = "yes" ] && return 0
  v="$(_wt_field "$1" state)"
  case "$v" in MET|CLOSED|WAIVED) return 0 ;; esac
  v="$(_wt_field "$1" status)"
  case "$v" in MET|CLOSED|WAIVED) return 0 ;; esac
  return 1
}

_wt_row_discharged() {  # <file> <row name>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    [ "$(_wt_field "$line" name)" = "$2" ] || continue
    _wt_discharged "$line" && return 0
  done < "$1"
  return 1
}

worktree_lease_overruns() {  # <main-root> <verdict-or-roster-file> -> <path>\t<row-id>
  local root="" file="${2:-}" d base id
  root="$(_wt_abs "${1:-}")" || return 0
  [ -n "$root" ] || return 0
  [ -f "$file" ] || return 0
  [ -d "${root}/.worktrees" ] || return 0
  for d in "${root}/.worktrees"/*; do
    [ -d "$d" ] || continue
    base="${d##*/}"
    id="W-$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
    if _wt_row_discharged "$file" "$id"; then
      printf '%s\t%s\n' "$d" "$id"
    elif _wt_row_discharged "$file" "$base"; then
      printf '%s\t%s\n' "$d" "$base"
    fi
  done
}

# The tree a row holds, by that same convention. Exported because the standdown
# call site needs the mapping and a second spelling of it there is a second
# definition of which tree belongs to whom.
worktree_for_row() {  # <main-root> <row name> -> path (whether or not it exists)
  printf '%s/.worktrees/%s' "${1%/}" "$(printf '%s' "${2#W-}" | tr '[:upper:]' '[:lower:]')"
}
