#!/usr/bin/env bash
# Create a linked worktree under the ONE canonical root per fleet, <repos-root>/.worktrees/.
#
# Usage: worktree-add.sh <repo> <slug> <branch> [base]
#   <repo>   a PATH to the repo (the worktree lands next to it; needs no root and no config),
#            or a directory name under $REPOS_ROOT (default ~/Repos/YourRepos)
#   <slug>   suffix for the dir: .worktrees/<repo>-<slug>
#   <branch> new branch to create there
#   [base]   start point; default = origin's default branch (the harness repo: local master)
# Prints the worktree path on stdout (last line) so callers can `git -C "$(...)"`.
#
# Why one root: five conventions had piled up (~90 worktrees). `.worktrees/` is hidden, so
# fleet-repo-state.sh's `"$ROOT"/*/` walk does not list a worktree as if it were a repo.
# node_modules: `npm ci` in the new tree. NEVER junction it to the main clone --
# worktree-junction-remove-gate.sh exists because `git worktree remove` followed one.
set -u

ROOT="${REPOS_ROOT:-$HOME/Repos/YourRepos}"
repo="${1:-}"; slug="${2:-}"; branch="${3:-}"; base="${4:-}"
[ -n "$repo" ] && [ -n "$slug" ] && [ -n "$branch" ] || { echo "usage: worktree-add.sh <repo> <slug> <branch> [base]" >&2; exit 2; }

src="$ROOT/$repo"
# A path to the repo (2026-11-19): its parent is the root, so nothing has to be configured.
# Only when the name is not a repo under the root already (the name form keeps its meaning).
if [ ! -e "$src/.git" ] && [ -e "$repo/.git" ] && p="$(cd "$repo" 2>/dev/null && pwd)" && [ -n "$p" ]; then
  ROOT="${p%/*}"; repo="${p##*/}"; src="$p"
fi
[ -e "$src/.git" ] || { echo "worktree-add: $src is not a git repo" >&2; exit 1; }

defaulted=0
if [ -z "$base" ]; then
  defaulted=1
  if [ "$repo" = "claude-harness" ]; then
    base="master"
  else
    base="$(git -C "$src" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    [ -n "$base" ] || base="origin/develop"
  fi
fi

# Fetch only a remote-tracking base; fail soft (offline / VPN down) and use what is local.
case "$base" in
  origin/*) git -C "$src" fetch --quiet origin "${base#origin/}" 2>/dev/null || echo "worktree-add: fetch failed, using local $base" >&2 ;;
esac
# A DEFAULTED base that still does not exist (a repo with no remote yet, or no origin/develop):
# branch from where the repo stands instead of failing. A base the caller named is never swapped.
if [ "$defaulted" = 1 ] && ! git -C "$src" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
  base="$(git -C "$src" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)"
  echo "worktree-add: no default remote branch here, branching from $base" >&2
fi

wt="$ROOT/.worktrees/$repo-$slug"
[ -e "$wt" ] && { echo "worktree-add: $wt already exists" >&2; exit 1; }

git -C "$src" worktree add "$wt" -b "$branch" "$base" >&2 || exit 1
# Angular front ends: local dev-server configs are gitignored, so a new tree lacks them and
# `ng serve --configuration local<env>` 404s its config and never gets past its loading screen.
if [ -d "$wt/src/assets/config" ]; then
  for f in "$src"/src/assets/config/config.local*.json; do
    [ -f "$f" ] && cp "$f" "$wt/src/assets/config/" && echo "worktree-add: copied untracked $(basename "$f")" >&2
  done
fi
echo "worktree-add: product repos need 'npm ci' inside the tree (no node_modules junction)." >&2
echo "$wt"
