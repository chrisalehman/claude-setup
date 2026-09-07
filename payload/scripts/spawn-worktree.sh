#!/bin/bash
# spawn-worktree.sh — the universal worktree contract (epic-17 wave-03, spec
# AC-10; design ledger D4, ratified 2026-08-17 with the universality amendment).
#
# WHAT THIS FILE OWNS. The creation and teardown of the isolated trees parallel
# writers work in. One discipline, keyed to work-shape rather than to role:
# whoever dispatches a parallel writer creates that writer's tree, at every
# level, orchestrator included. Creation authority follows dispatch authority.
#
# THE ATTESTATION IS THE PRODUCT. A worktree is not a deliverable — a worktree
# somebody can PROVE is at the intended base is. Every successful create prints
# exactly one line, and the dispatcher quotes that line into its ledger row:
#
#   spawn-worktree: OK path=<abs> branch=<b> head=<sha> base=<sha>
#
# That is why `head=` and `base=` are both full 40-character SHAs even when the
# caller named the base with a short one: the whole point of the field pair is
# that a reader — or a grep — can see they are equal without resolving anything.
# The line is pinned byte-exactly by tests/spawn-worktree.test.sh; changing its
# shape changes what every ledger row downstream means.
#
# SELF-VERIFICATION, NOT OPTIMISM. `git worktree add` succeeding is not
# evidence: the failure this contract exists to end was a worktree that was
# quietly based on the wrong commit (three times out of three in wave-01, which
# is what the interim pin-and-verify-HEAD discipline was patching). So the
# script reads the result back — HEAD, branch, and the symlink's resolved
# target — and an attestation is printed only for what it re-measured. On any
# failure it removes what it created and refuses. There is never an unattested
# worktree: no half-built tree, no orphan branch.
#
# NO SYMLINK, AND THAT IS THE POINT (bionic 1.4.0, design ledger C2). This
# script used to plant `<worktree>/.bionic` -> `<main-root>/.bionic` so a writer
# in a spawned tree reached the same plan, ledger and record files as everyone
# else. It reaches them now through `project_root`, which maps a linked
# worktree to the main checkout by `--git-common-dir` — the same answer without
# a link in the tree to be followed by the wrong reader, chased by a cleanup, or
# checked out over. `create` plants nothing; `remove` and `land` DELETE a legacy
# link an older bionic left behind, and `worktree_legacy_links` in
# payload/scripts/lib/worktree.sh lists them for doctor.
#
# THE MAIN ROOT, NOT THE CURRENT ONE. Paths resolve against the main checkout,
# found through `--git-common-dir` rather than `--show-toplevel`, and a
# relative parent directory resolves against that root rather than against the
# caller's cwd. Both exist for the same recorded accident: `git worktree add`
# resolves relative paths against pwd, so a dispatcher running inside a
# worktree once produced a worktree nested inside a worktree
# (.claude/rules/git-worktree-docs.md). A dispatcher spawning from inside a
# tree gets a SIBLING.
#
# TEARDOWN IS NEVER AUTOMATIC, AND NEVER DELETES THE BRANCH. `remove` gives
# back a tree; whether the work on it merges is the orchestrator's decision,
# taken later. Nor does it force: git's own refusal to discard uncommitted work
# is a feature this script declines to override.
#
# TEARDOWN IS NEVER AUTOMATIC — BUT IT IS ONE ACT WHEN IT COMES (bionic 1.4.0,
# design ledger C1). A spawned tree is a LEASED slot bound to the ledger row
# that dispatched its writer, and the lease ends when that row is
# fact-discharged. `land` ends it: merge the branch --no-ff into the main
# checkout's current branch, remove the tree, prune — refusing, and saying
# exactly why, when the tree is dirty, when there is nothing to land, or when a
# suite is running (D1). The behaviour lives in payload/scripts/lib/worktree.sh
# because `hooks/stop-orders.sh standdown` and the Patrol tick need the same
# act and the same predicate; this verb is a call site.
#
# Usage:
#   spawn-worktree.sh create <base-sha> <branch-name> [worktree-parent-dir]
#   spawn-worktree.sh remove <worktree-path>
#   spawn-worktree.sh land   <worktree-path>

set -uo pipefail

PROG="spawn-worktree"

# The lease library, beside this script. `land` is its call site; `create` and
# `remove` do not need it, so a missing library is refused only where it is
# actually used rather than at the top of the file.
LIB_WORKTREE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/worktree.sh"

# THE ROOTS LIBRARY, WHICH ALL THREE VERBS NEED. `worktree_root` is the one resolver for
# "the main checkout from anywhere inside this repository" (epic-22 wave-01, N1); this
# script carried the third copy of it as `resolve_main_root`, beside lib/worktree.sh's
# `_wt_main_root` and lib/patrol.sh's own root question, none of them held together by any
# test. Sourced at the top rather than per-verb because every verb resolves that root, and a
# script that cannot find it can do nothing at all — which is what the refusal below says.
LIB_ROOTS="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/roots.sh"
# shellcheck source=/dev/null
. "$LIB_ROOTS" 2>/dev/null || { printf '%s: FAIL reason=roots-library-missing path=%s\n' "spawn-worktree" "$LIB_ROOTS"; exit 1; }

# Contract lines go to STDOUT — all three of them. OK, FAIL and REMOVED are not
# log output; they are this script's product. Splitting them across two channels
# would leave a caller that captured stdout with an attestation on success and
# silence on failure, which is the shape a ledger row cannot record.
contract() { printf '%s: %s\n' "$PROG" "$*"; }

usage() {
  cat <<'USAGE'
Usage:
  spawn-worktree.sh create <base-sha> <branch-name> [worktree-parent-dir]
  spawn-worktree.sh remove <worktree-path>
  spawn-worktree.sh land   <worktree-path>

create  makes the branch AND the worktree at exactly <base-sha>, verifies
        both, and prints one OK attestation line. Nothing is planted in the
        tree. Default parent: <main-root>/.worktrees. A relative parent
        resolves against the main root, never against pwd.
remove  removes the worktree and KEEPS the branch, deleting a legacy
        <worktree>/.bionic symlink first if an older bionic left one.
land    ends the lease in one act: merges the tree's branch --no-ff into the
        main checkout's CURRENT branch, removes the tree, prunes. Keeps the
        branch. Refuses — naming why — on a dirty tree, on nothing to land,
        or while a suite is running.
USAGE
}

# Two failure classes, two exit codes, because callers distinguish them:
#   2  refused — a precondition said no; nothing was created, nothing to undo.
#   1  aborted — creation had begun and verification failed; it has been undone.
refuse() { contract "FAIL reason=$1"; exit 2; }

main_root=""; wt=""; branch=""; created=0

cleanup_partial() {
  [ -n "$wt" ] || return 0
  # A legacy link (C2) would make git refuse the removal below; nothing here
  # plants one any more, but an aborted create on a tree that already had one
  # must still come away clean.
  if [ -L "${wt}/.bionic" ]; then rm -f "${wt}/.bionic"; fi
  if [ -n "$main_root" ] && [ -d "$wt" ]; then
    git -C "$main_root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$main_root" worktree prune >/dev/null 2>&1
  fi
  if [ "$created" -eq 1 ] && [ -n "$main_root" ] && [ -n "$branch" ]; then
    git -C "$main_root" branch -D "$branch" >/dev/null 2>&1
  fi
  return 0
}

abort_created() {
  cleanup_partial
  contract "FAIL reason=$1"
  exit 1
}

cmd_create() {
  local base="${1:-}" parent="${3:-}"
  branch="${2:-}"

  [ -n "$base" ] && [ -n "$branch" ] || { usage >&2; refuse usage; }

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse not-a-git-repo
  main_root="$(worktree_root)" || refuse repo-root-unresolvable
  [ -n "$main_root" ] || refuse repo-root-unresolvable

  # The state directory has to be there BEFORE anything is created: planting a
  # link to a directory that does not exist would produce an attestation whose
  # last field names nothing, which is worse than no worktree.
  [ -d "$(bionic_root "$main_root")" ] || refuse no-bionic-dir

  local base_sha
  base_sha="$(git -C "$main_root" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null)"
  [ -n "$base_sha" ] || refuse base-not-a-commit

  git check-ref-format --branch "$branch" >/dev/null 2>&1 || refuse invalid-branch-name
  if git -C "$main_root" show-ref --verify --quiet "refs/heads/${branch}"; then
    refuse branch-exists
  fi

  # `..` as a path COMPONENT only: a directory whose name merely contains dots
  # is nobody's escape attempt.
  case "/${parent}/" in */../*) refuse parent-traversal ;; esac

  local parent_abs
  if [ -z "$parent" ]; then
    parent_abs="${main_root}/.worktrees"
  else
    case "$parent" in
      /*) parent_abs="$parent" ;;
      *)  parent_abs="${main_root}/${parent}" ;;
    esac
  fi
  mkdir -p "$parent_abs" 2>/dev/null || refuse parent-dir-uncreatable
  parent_abs="$(cd "$parent_abs" && pwd -P)" || refuse parent-dir-unresolvable

  # A slashed branch name (wave/17-03-command-surface) becomes a flat directory
  # named for its last component. Two branches whose last components collide
  # are caught by the existing-path refusal below rather than by silently
  # nesting one inside the other.
  wt="${parent_abs}/${branch##*/}"
  if [ -e "$wt" ] || [ -L "$wt" ]; then refuse target-path-exists; fi

  created=1
  git -C "$main_root" worktree add --quiet -b "$branch" "$wt" "$base_sha" >/dev/null 2>&1 \
    || abort_created worktree-add-failed

  # Read everything back. Nothing below is taken from an argument. A `.bionic`
  # path the branch itself carries is checked out here like any other tracked
  # content and is left exactly alone: since C2 this script plants nothing into
  # the tree, so there is no target for it to occupy.
  local head
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ "$head" = "$base_sha" ] || abort_created head-mismatch
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ] \
    || abort_created branch-mismatch

  contract "OK path=${wt} branch=${branch} head=${head} base=${base_sha}"
}

cmd_remove() {
  local target="${1:-}"
  [ -n "$target" ] || { usage >&2; refuse usage; }
  [ -d "$target" ] || refuse no-such-worktree

  # A linked worktree's `.git` is a FILE pointing into the shared repository;
  # the main checkout's is a directory. That distinction is the guard against
  # being handed the main checkout to delete.
  [ -f "${target}/.git" ] || refuse not-a-linked-worktree

  local wt_abs; wt_abs="$(cd "$target" && pwd -P)" || refuse no-such-worktree
  local wt_branch; wt_branch="$(git -C "$wt_abs" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$wt_branch" ] || refuse worktree-head-unreadable

  local root; root="$(worktree_root "$wt_abs")"
  [ -n "$root" ] || refuse repo-root-unresolvable

  # A LEGACY link (C2) — one an older bionic planted, since nothing plants one
  # now. git reads it as an untracked file and would refuse to remove the tree
  # over it, so it is taken away first, and it is NOT put back: the retirement
  # is the point, and a refusal that restored it would leave the next call to
  # meet the same obstacle.
  if [ -L "${wt_abs}/.bionic" ]; then
    rm -f "${wt_abs}/.bionic"
  fi

  if ! git -C "$root" worktree remove "$wt_abs" >/dev/null 2>&1; then
    refuse worktree-remove-refused
  fi

  # kept=yes is not a status field, it is the contract: the merge decision
  # belongs to the orchestrator, so the branch outlives its tree.
  contract "REMOVED path=${wt_abs} branch=${wt_branch} kept=yes"
}

cmd_land() {
  local target="${1:-}"
  if [ ! -f "$LIB_WORKTREE" ]; then
    contract "REFUSED reason=library-missing path=${LIB_WORKTREE}"
    exit 2
  fi
  # shellcheck source=/dev/null
  . "$LIB_WORKTREE" || { contract "REFUSED reason=library-unloadable path=${LIB_WORKTREE}"; exit 2; }
  WORKTREE_CONTRACT_PROG="$PROG" worktree_land "$target"
  exit $?
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  land)   shift; cmd_land "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage >&2; refuse usage ;;
  *) usage >&2; refuse unknown-verb ;;
esac
