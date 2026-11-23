#!/usr/bin/env bash
# Two wirings, one file:
#   PostToolUse (Bash|PowerShell) --record  -- remember which branch this session left a repo on
#   PreToolUse  (Bash|PowerShell)           -- WARN when that collides with another live session
#
# TWO CHECKS in the PreToolUse half, deliberately in this one file rather than a second hook
# (the subagent-model-tiering-gate.sh precedent): the BRANCH collision below, and -- added
# 2026-09-01, PROJ-15368 -- a FILE collision at commit time, read out of the ledger
# file-claim-record.sh writes. A separate hook would pay another fork on every Bash call, and
# this one is already wired, already prefiltered on *git*, and already sources liveness.
#
# Why the file check fires at COMMIT and not at edit time: the raw collision rate is ~150
# same-file/different-session pairs a week and almost all are harmless, so warning per edit
# would be 150 interruptions for the two occurrences that actually hurt. Both of those were
# commits -- one session's uncommitted work swept into another's commit under an unrelated
# message, twice on 2026-09-01. See lib-file-claims.sh's header.
#
# Why. Every session shares ONE local clone per repo, so `git checkout` is global state:
# whichever session switches last wins, silently, for everyone else. Nothing in the harness
# knew another session existed, and a plan file's "repo X is owned by another agent" is true
# when written and false an hour later.
#
# WARNS, NEVER DENIES -- explicit user decision. A stale claim must never be able to wedge
# an urgent hotfix; a deny here would be the wrong strength. The warning goes out as hook
# context with NO permissionDecision. Until 2026-11-19 it was an `allow` decision carrying a
# reason, and a probe on CLI 2.1.328 showed that text reaches neither the model nor the user:
# this hook had warned nobody. Detail: GATES-AND-HOOKS.md, "Hook wiring".
#
# Deliberately not a lock/lease: locks need releasing, and this harness has no reliable
# session end (nothing cleans .session-chatfiles/), so a lease would strand repos forever.
# A claim plus a liveness test degrades safely -- worst case, one missed warning.
#
# Fails open everywhere. Never the reason a git command cannot run.
set -u

MODE="${1:-gate}"
HERE="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib-repo-claims.sh
. "$HERE/lib-repo-claims.sh" 2>/dev/null || exit 0
# shellcheck source=lib-session-liveness.sh
. "$HERE/lib-session-liveness.sh" 2>/dev/null || exit 0

IFS= read -r -d '' payload || true
case "$payload" in *git*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$command" ] && [ -n "$sid" ] || exit 0

# Resolve the command's REAL target dir, not the session cwd -- `git -C <path>` against a
# different repo is the common shape here, and using cwd would attribute it to the wrong
# repo entirely (the exact bug git-commit-ticket-gate.sh's header documents).
. "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0

root="$(claims_repo_root "$target_dir")"
[ -n "$root" ] || exit 0

# Single emitter -- the file check can exit early, and two copies of this jq drifted apart
# in an earlier version of this hook. A warning in the full editions. In gate mode (the lite
# edition always; lib-hook-say.sh) a DENY that names the safe alternative, so the model
# carries on alone and nobody has to click; USER_SAID_SO=1 passes it.
. "$HERE/lib-hook-say.sh" 2>/dev/null || exit 0
gate=""; gates_on && gate=deny
[ -n "$gate" ] && user_said_so "$command" && exit 0
emit_warn() {
  [ -n "$gate" ] && warn="REFUSED. $warn

$SAID_SO_HINT"
  hook_say "$gate" "${warn//\\n/$'\n'}"
}

# A checkout that restores FILES (`checkout [<tree>] -- <paths>`, `checkout .`) switches nothing.
switches_branch() {
  { is_git_cmd 'checkout' || is_git_cmd 'switch'; } \
    && ! printf '%s' "$command" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?checkout\s+((\S+\s+)*--(\s|\$)|\.(\s|\$))"
}

is_git_cmd() { printf '%s' "$command" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?$1\b"; }

# --- PostToolUse: record where this session left the repo -----------------------------
if [ "$MODE" = "--record" ]; then
  if is_git_cmd 'checkout' || is_git_cmd 'switch' || is_git_cmd 'commit' || is_git_cmd 'push'; then
    branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && claims_put "$root" "$sid" "$branch"
  fi
  exit 0
fi

# --- PreToolUse: warn ------------------------------------------------------------------
warn=""

# Check 2 of 2: FILE collisions at commit time. Runs before the repo-claim early-exit below,
# because a file collision is real whether or not anyone recorded a branch claim.
if is_git_cmd 'commit' || printf '%s' "$command" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?add\s+(-A\b|--all\b|\.(\s|$))"; then
  # Sourced HERE, not at the top: the common case is a git command that is not a commit, and
  # this file is read on every Bash call that mentions git.
  [ -n "${FCLAIMS_FILE:-}" ] && FCLAIMS_FILE_WAS_SET=1
  if . "$HERE/lib-file-claims.sh" 2>/dev/null; then
    # A commit that names its paths (`git commit ... -- <paths>`) ships those and nothing
    # else, so only they are checked; a sweeping one is checked against the whole tree. Read
    # with quoted spans removed, so a ` -- ` inside a message is not taken for a pathspec (a
    # QUOTED path then goes unseen and the whole tree is checked: the safe side).
    fc_spec=()
    if is_git_cmd 'commit'; then
      fc_scan="$(printf '%s' "$command" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')"
      if [[ "$fc_scan" =~ ^.*[[:space:]]--[[:space:]]+([^\;\&\|]+) ]]; then
        read -r -a fc_spec <<< "${BASH_REMATCH[1]}"
      fi
    fi
    # One `git status` fork, paid only on commit/add-all. Porcelain v1: XY then the path.
    fc_hits=""; fc_n=0; fc_owners=""
    while IFS= read -r st_line; do
      rel="${st_line:3}"
      # Rename/copy entries read "old -> new"; the new path is the one being committed.
      case "$rel" in *' -> '*) rel="${rel##* -> }" ;; esac
      rel="${rel%\"}"; rel="${rel#\"}"
      [ -n "$rel" ] || continue
      while IFS=$'	' read -r o_sid o_ts; do
        [ -n "$o_sid" ] || continue
        session_is_live "$o_sid" || continue
        fc_n=$(( fc_n + 1 ))
        [ "$fc_n" -le 5 ] && fc_hits="${fc_hits:+$fc_hits
}  - $rel (session ${o_sid%%-*}, $(claims_describe_age "$o_ts") ago)"
        # One reopen command per owning session, for the "owner is closed" branch of the rule below.
        case "$fc_owners" in *"$o_sid"*) ;; *)
          fc_row="$(grep -F -- "$o_sid" "${REMINDER_SESSIONS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions.txt}" 2>/dev/null | head -1 | tr -d '\r')"
          case "$fc_row" in *' cd '*) fc_cmd="cd ${fc_row#* cd }" ;; *) fc_cmd="claude -r $o_sid" ;; esac
          fc_owners="${fc_owners:+$fc_owners
}  - session ${o_sid%%-*} ($o_sid): $fc_cmd" ;;
        esac
      done <<FCEOF
$(fclaims_others "$root/$rel" "$sid")
FCEOF
    done <<STEOF
$(git -C "$target_dir" status --porcelain ${fc_spec[@]:+-- "${fc_spec[@]}"} 2>/dev/null)
STEOF
    if [ -n "$fc_hits" ]; then
      repo_name_fc="${root##*/}"
      more=""
      [ "$fc_n" -gt 5 ] && more="
  ...and $(( fc_n - 5 )) more."
      # Gate mode: what to do instead. Warn mode: the working rules for a shared tree.
      _fc_why="Committing them now ships that session's unfinished edits under your message. Commit only your own paths:  git commit -m \"...\" -- <your paths>"
      warn="FILES IN YOUR TREE BELONG TO ANOTHER LIVE SESSION:
$fc_hits$more

$_fc_why"
    fi
  fi
fi

head_branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
repo_name="$(basename "$root")"

if [ -n "$gate" ]; then
  # GATE mode. The ledger keeps one row per (repo, session), so this session still knows the
  # branch IT last acted on, and every other session stays visible whoever acted last.
  mine="$(claims_of "$root" "$sid")"
  my_branch="${mine%%	*}"
  if [ -n "$my_branch" ] && [ -n "$head_branch" ] && [ "$head_branch" != "$my_branch" ] \
     && { is_git_cmd 'commit' || is_git_cmd 'push'; }; then
    warn="${warn:+$warn

}THE BRANCH MOVED UNDER YOU. You last acted in $repo_name on \"$my_branch\"; the clone is now on \"$head_branch\", so something else switched it, and this commit or push would land on \"$head_branch\". Do not commit here: continue in your own tree (bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/worktree-add.sh $root <slug> $my_branch), or tell the user what happened."
  fi
  # Any switch in a clone another LIVE session is working in -- also while the clone is still
  # on that session's branch, which is the usual case and the one that moves its files.
  if switches_branch; then
    while IFS='	' read -r o_sid o_branch o_when; do
      [ -n "$o_sid" ] || continue
      session_is_live "$o_sid" || continue
      warn="${warn:+$warn

}ANOTHER LIVE SESSION (${o_sid%%-*}) is working in this clone, on \"$o_branch\", last active $(claims_describe_age "$o_when") ago. A clone has one working tree, so switching branches here switches that session's files too, and it would go on committing onto whatever is checked out. Take your own tree instead and work there:  bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/worktree-add.sh $root <slug> <branch>"
      break
    done <<OEOF
$(claims_others "$root" "$sid")
OEOF
  fi
  [ -n "$warn" ] || exit 0
  emit_warn
  exit 0
fi

