#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell): REFUSE a command that throws away uncommitted work.
#
#   git reset --hard                      every tracked change in the repo
#   git checkout|restore <paths>          the changes under those paths (`.` = all of them)
#   git checkout -f, git switch -f        every tracked change in the repo
#   git clean -f                          untracked files (ignored ones are not counted)
#   git worktree remove --force <tree>    everything uncommitted in that tree
#   rm / Remove-Item <path>               tracked files with uncommitted changes under it
#   git stash [push], and untracked files under an rm path:
#                                         only when ANOTHER session edited them (file claims)
#
# Why. The settings allow every shell command and no gate looked at these, so a session could
# wipe its own, the user's or another session's uncommitted edits with no prompt and no
# warning. The only guard was a prose rule (never stash or check out over another session's
# changes), and sessions here share one working tree.
#
# Never a warning: the loss cannot be undone, so a note that arrives while the command runs
# is too late. Never an ask either, in any edition (user 2026-11-21: no approval clicks; it
# asked until then, and an ask also stops a session dead where nobody is watching). A DENY:
# the model keeps the work (commits it, stashes it, or names only the paths it means) and
# carries on; USER_SAID_SO=1 in front of the command passes it when the user asked for the
# discard in words (lib-hook-say.sh).
#
# Silent inside a linked worktree whose repo-claim rows name only THIS session (its own
# scratch tree; see own_tree below, user 2026-11-20).
# Silent whenever nothing would be lost: clean tree, unchanged paths, dry runs, branch
# switches, ignored build output, paths outside a repo. A stash can be restored and an
# untracked path may be scratch, so those two count only when the file-claim ledger says
# another session edited the files -- that session would go on working on files that changed
# under it. Same for a CONFLICTED path under `checkout|restore <paths>` (--ours, --theirs,
# <tree> -- <path>): that is how a merge conflict gets resolved, both sides stay in the commits
# being merged, and the form without such a choice git refuses by itself (2026-11-21: the user
# was asked to approve a `checkout --ours` on a UU file).
#
# The command is read word by word, quotes kept together, so `git reset --hard` inside a
# commit message or an echo is text, not an invocation. Heredoc bodies are dropped first.
# Each clause gets its own directory (its `git -C`, or the `cd` before it): lib-git-target.sh's
# git_target_dir picks ONE directory per command, which is not enough for a path-scoped check.
#
# Known escapes: a command inside `bash -c "..."` or a script file, `find -delete`,
# `xargs rm`, a path held in a variable set outside the command. Fails open on anything it
# cannot resolve, and on its timeout (the dispatcher says so in the tool result).
set -u
export GIT_OPTIONAL_LOCKS=0

IFS= read -r -d '' payload || true
case "$payload" in
  *reset*|*checkout*|*restore*|*clean*|*stash*|*switch*|*worktree*remove*) ;;
  *'rm '*|*emove-*|*rmdir*|*'del '*|*'rd '*) ;;
  *) exit 0 ;;
esac

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE=.
. "$HERE/lib-command-text.sh" 2>/dev/null || exit 0
. "$HERE/lib-git-target.sh" 2>/dev/null || exit 0
. "$HERE/lib-file-claims.sh" 2>/dev/null || exit 0

nl=$'\n'
meta="$(printf '%s' "$payload" | jq -r '(.cwd // ""), (.session_id // ""), (.tool_input.command // "")' 2>/dev/null | tr -d '\r')"
case "$meta" in *"$nl"*"$nl"*) ;; *) exit 0 ;; esac
cwd="${meta%%"$nl"*}"; meta="${meta#*"$nl"}"
sid="${meta%%"$nl"*}"; command="${meta#*"$nl"}"
[ -n "$command" ] || exit 0
cwd="${cwd//\\//}"

# The user asked for this discard in words: the one way past (above).
. "$HERE/lib-hook-say.sh" 2>/dev/null || exit 0
user_said_so "$command" && exit 0

scan="$command"
case "$scan" in *'<<'*) scan="$(printf '%s\n' "$scan" | command_without_heredoc_bodies)" ;; esac
scan="${scan//\\$nl/ }"                      # line continuations
[ "${#scan}" -le 20000 ] || scan="${scan:0:20000}"

here="$cwd"            # the directory the clause being read runs in; follows `cd`
WHERE=""               # the first repo something was found in, for the message
NL_TOPS="$nl"          # every repo something was found in, newline-delimited
CLEAN_DIRS=1           # 0 while judging a `git clean` without -d: untracked DIRECTORIES survive it
UNMERGED=""            # soft while judging `checkout|restore <paths>`: a conflicted path is being resolved
declare -a L_KIND=() L_LABEL=() L_ABS=() L_TXT=()
declare -A SEEN=()
n_found=0

# add <kind> <label> <absolute path> <status line>.  kind: hard = always refused,
# soft = only when another session edited it.
add() {
  [ "$n_found" -lt 200 ] || return 0
  [ -z "${SEEN[$3]:-}" ] || return 0
  SEEN[$3]=1
  L_KIND+=("$1"); L_LABEL+=("$2"); L_ABS+=("$3"); L_TXT+=("$4"); n_found=$((n_found+1))
}

# collect <kind for tracked changes> <kind for untracked> <label> <dir> [git status args]
# A kind of `-` leaves that class out. Not a repo, or nothing changed there: adds nothing.
collect() {
  local kt="$1" ku="$2" label="$3" dir="$4"; shift 4
  local out top line p k uf=no
  [ "$ku" = - ] || uf=normal
  out="$(git -C "$dir" status --porcelain --untracked-files="$uf" "$@" 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  [ -n "$WHERE" ] || WHERE="$top"
  case "$NL_TOPS" in *"$nl$top$nl"*) ;; *) NL_TOPS+="$top$nl" ;; esac
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ "${#line}" -gt 3 ] || continue
    p="${line:3}"; p="${p##* -> }"; p="${p#\"}"; p="${p%\"}"
    case "$line" in
      '??'*)
        [ "$ku" = - ] && continue
        if [ "$CLEAN_DIRS" = 0 ]; then case "$p" in */) continue ;; esac; fi
        add "$ku" "$label" "$top/$p" "$line" ;;
      *)
        [ "$kt" = - ] && continue
        k="$kt"
        case "${line:0:2}" in DD|AU|UD|UA|DU|AA|UU) k="${UNMERGED:-$kt}" ;; esac   # a merge conflict
        add "$k" "$label" "$top/$p" "$line" ;;
    esac
  done <<< "$out"
}

# expand <path> <base> -> EXP: absolute, forward slashes. Empty when it cannot be resolved
# here (a variable with no literal assignment in the command, a substitution, a glob).
# Same expansion as git_target_dir, applied to one clause's own path.
expand() {
  local d="$1" base="$2"
  EXP=""
  d="${d//\"/}"
  case "$d" in '$'*) d="$(_git_target_expand_var "$d" "$command")" ;; esac
  d="${d/#\~/$HOME}"; d="${d/#\$HOME/$HOME}"; d="${d/#\$\{HOME\}/$HOME}"
  case "$d" in ''|*'$'*|*'`'*|*'*'*|*'?'*) return 0 ;; esac
  d="${d//\\//}"
  case "$d" in /*|[A-Za-z]:*) ;; *) [ -n "$base" ] || return 0; d="$base/$d" ;; esac
  EXP="$d"
}

# split_dd <args> -> PRE (before `--`), POST (after it), HAS_DD
split_dd() {
  PRE=(); POST=(); HAS_DD=0
  local t
  for t in "$@"; do
    if [ "$HAS_DD" = 1 ]; then POST+=("$t")
    elif [ "$t" = -- ]; then HAS_DD=1
    else PRE+=("$t"); fi
  done
}

judge_git() {
  local -a a=("$@")
  local n=${#a[@]} i=0 dir="" verb t skip=0 probe
  while [ "$i" -lt "$n" ]; do
    case "${a[$i]}" in
      -C) dir="${a[$((i+1))]:-}"; i=$((i+2)) ;;
      -c|--git-dir|--work-tree|--namespace) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  verb="${a[$i]}"; i=$((i+1))
  if [ -n "$dir" ]; then expand "$dir" "$here"; dir="${EXP:-$here}"; else dir="$here"; fi
  [ -n "$dir" ] || return 0
  local -a r=("${a[@]:$i}") pos=() PRE=() POST=()
  local HAS_DD=0

  case "$verb" in
    reset)
      for t in "${r[@]}"; do
        [ "$t" = --hard ] && { collect hard - "git reset --hard" "$dir"; return 0; }
      done ;;

    switch)
      for t in "${r[@]}"; do
        case "$t" in -f|--force|--discard-changes) collect hard - "git switch --discard-changes" "$dir"; return 0 ;; esac
      done ;;

    checkout)
      split_dd "${r[@]}"
      local force=0 create=0
      for t in "${PRE[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$t" in
          -f|--force) force=1 ;;
          -b|-B|--orphan) create=1; skip=1 ;;
          -p|--patch) return 0 ;;                  # interactive: cannot run here anyway
          --pathspec-from-file) skip=1 ;;
          -*) ;;
          *) pos+=("$t") ;;
        esac
      done
      if [ "$force" = 1 ]; then collect hard - "git checkout --force" "$dir"; return 0; fi
      [ "$create" = 0 ] || return 0
      if [ "$HAS_DD" = 1 ]; then
        [ "${#POST[@]}" -gt 0 ] && { UNMERGED=soft; collect hard - "git checkout <paths>" "$dir" -- "${POST[@]}"; UNMERGED=""; }
        return 0
      fi
      [ "${#pos[@]}" -gt 0 ] || return 0
      # No `--`: the first word is a branch or commit when git can resolve it, else a path.
      # Status first -- on the usual `git checkout <branch>` it finds nothing, and that is
      # the whole answer for one process.
      probe="$(git -C "$dir" status --porcelain --untracked-files=no -- "${pos[@]}" 2>/dev/null)"
      [ -n "$probe" ] || return 0
      if git -C "$dir" rev-parse -q --verify "${pos[0]}^{commit}" >/dev/null 2>&1; then
        pos=("${pos[@]:1}")
        [ "${#pos[@]}" -gt 0 ] || return 0
      fi
      UNMERGED=soft; collect hard - "git checkout <paths>" "$dir" -- "${pos[@]}"; UNMERGED="" ;;

    restore)
      split_dd "${r[@]}"
      local staged=0 wt=0
      for t in "${PRE[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$t" in
          -S|--staged) staged=1 ;;
          -W|--worktree) wt=1 ;;
          -SW|-WS) staged=1; wt=1 ;;
          -s|--source|--pathspec-from-file) skip=1 ;;
          -p|--patch) return 0 ;;
          -*) ;;
          *) pos+=("$t") ;;
        esac
      done
      [ "$staged" = 1 ] && [ "$wt" = 0 ] && return 0      # only unstages: the file keeps its edits
      pos+=("${POST[@]}")
      [ "${#pos[@]}" -gt 0 ] && { UNMERGED=soft; collect hard - "git restore" "$dir" -- "${pos[@]}"; UNMERGED=""; } ;;

    clean)
      split_dd "${r[@]}"
      local force=0 dry=0 ign=0 dirs=0
      for t in "${PRE[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$t" in
          --force) force=1 ;;
          --dry-run|--interactive) dry=1 ;;
          -e|--exclude) skip=1 ;;
          --*) ;;
          -*)
            case "$t" in *f*) force=1 ;; esac
            case "$t" in *n*|*i*) dry=1 ;; esac
            case "$t" in *X*) ign=1 ;; esac          # -X removes ONLY ignored files
            case "$t" in *d*) dirs=1 ;; esac ;;
          *) pos+=("$t") ;;
        esac
      done
      [ "$force" = 1 ] && [ "$dry" = 0 ] && [ "$ign" = 0 ] || return 0
      pos+=("${POST[@]}")
      [ "${#pos[@]}" -gt 0 ] || pos=(.)              # clean works below the current directory
      CLEAN_DIRS="$dirs"
      collect - hard "git clean" "$dir" -- "${pos[@]}"
      CLEAN_DIRS=1 ;;

    stash)
      case "${r[0]:-}" in ''|-*|push|save) ;; *) return 0 ;; esac   # list/show/pop/apply/drop: nothing leaves the tree
      split_dd "${r[@]}"
      local ut=-
      for t in "${PRE[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$t" in
          -u|-ku|-uk|--include-untracked|-a|--all) ut=soft ;;
          -m|--message|--pathspec-from-file) skip=1 ;;
          -p|--patch) return 0 ;;
          push|save|-*) ;;
          *) [ "${r[0]:-}" = push ] && pos+=("$t") ;;
        esac
      done
      pos+=("${POST[@]}")
      if [ "${#pos[@]}" -gt 0 ]; then collect soft "$ut" "git stash" "$dir" -- "${pos[@]}"
      else collect soft "$ut" "git stash" "$dir"; fi ;;

    worktree)
      [ "${r[0]:-}" = remove ] || return 0
      local force=0 tgt=""
      for t in "${r[@]:1}"; do
        case "$t" in
          -f|-ff|--force) force=1 ;;
          -*) ;;
          *) [ -n "$tgt" ] || tgt="$t" ;;
        esac
      done
      [ "$force" = 1 ] && [ -n "$tgt" ] || return 0     # without --force git itself refuses a dirty tree
      expand "$tgt" "$dir"
      [ -n "$EXP" ] && [ -d "$EXP" ] || return 0
      collect hard hard "git worktree remove --force" "$EXP" ;;
  esac
  return 0
}

judge_rm() {
  local -a a=("$@") parts=()
  local t p q rest rec=0 seen=0 abs
  for t in "${a[@]}"; do case "$t" in -*[rR]*|/[sS]) rec=1 ;; esac; done
  for t in "${a[@]}"; do
    case "$t" in -*|/[a-zA-Z]) continue ;; esac
    IFS=, read -r -a parts <<< "$t"
    for p in "${parts[@]}"; do
      [ -n "$p" ] || continue
      seen=$((seen+1)); [ "$seen" -le 6 ] || return 0
      case "$p" in
        *[\*\?]*)
          # A glob: status the fixed leading directory, with the rest as the pathspec.
          q="${p%%[\*\?]*}"
          case "$q" in
            */*) rest="${p#"${q%/*}"/}"; q="${q%/*}"; [ -n "$q" ] || q=/ ;;
            *)   rest="$p"; q=. ;;
          esac
          expand "$q" "$here"
          [ -n "$EXP" ] && [ -d "$EXP" ] || continue
          collect hard soft "rm" "$EXP" -- "$rest" ;;
        *)
          expand "$p" "$here"; abs="$EXP"
          [ -n "$abs" ] && [ -e "$abs" ] && [ ! -L "$abs" ] || continue
          if [ -d "$abs" ]; then
            [ "$rec" = 1 ] && collect hard soft "rm" "$abs" -- .
          else
            collect hard soft "rm" "${abs%/*}" -- "${abs##*/}"
          fi ;;
      esac
    done
  done
  return 0
}

# judge <words of one clause>
judge() {
  local -a a=("$@")
  local n=${#a[@]} i=0 w
  while [ "$i" -lt "$n" ]; do
    w="${a[$i]}"
    case "$w" in
      '{'|'}'|'!'|if|then|else|elif|do|while|until|time|command|env|winpty|nohup|builtin) i=$((i+1)) ;;
      *=*) if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i+1)); else break; fi ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  w="${a[$i]}"; i=$((i+1))
  w="${w##*/}"; w="${w##*\\}"; w="${w,,}"; w="${w%.exe}"
  case "$w" in
    cd|pushd|chdir|set-location|sl)
      while [ "$i" -lt "$n" ]; do
        case "${a[$i]}" in -*) i=$((i+1)) ;; *) break ;; esac
      done
      if [ "$i" -lt "$n" ]; then expand "${a[$i]}" "$here"; [ -n "$EXP" ] && here="$EXP"; fi ;;
    git) judge_git "${a[@]:$i}" ;;
    rm|rmdir|rd|del|ri|erase|remove-item) judge_rm "${a[@]:$i}" ;;
  esac
  return 0
}

# ---- read the command: words, quoted spans kept whole, clauses split at ; & | ( ) newline ----
declare -a ST=()
tok=""; intok=0; skipnext=0
push_tok() {
  [ "$intok" = 1 ] || return 0
  intok=0
  local t="$tok"; tok=""
  if [ "$skipnext" = 1 ]; then skipnext=0; return 0; fi
  case "$t" in
    [0-9]'>'*|[0-9]'<'*|'>'*|'<'*)                  # a redirection is not an operand
      case "$t" in *[!0-9\<\>]*) ;; *) skipnext=1 ;; esac   # a bare operator: its target is the next word
      return 0 ;;
  esac
  ST+=("$t")
}
push_seg() {
  push_tok
  [ "${#ST[@]}" -gt 0 ] && judge "${ST[@]}"
  ST=(); skipnext=0
}
re_sep='^(&&|\|\||[;|&()]|'"$nl"')'
re_ws='^[[:blank:]]+'
re_dq='^"(([^"\\]|\\.)*)"'
re_sq="^'([^']*)'"
re_run='^[^[:space:]"'"'"';|&()]+'
s="$scan"
while [ -n "$s" ]; do
  w="${s:0:4000}"          # match on a window: a regex over the whole remainder is slow
  if   [[ $w =~ $re_sep ]]; then m="${BASH_REMATCH[0]}"; push_seg
  elif [[ $w =~ $re_ws  ]]; then m="${BASH_REMATCH[0]}"; push_tok
  elif [[ $w =~ $re_dq  ]]; then m="${BASH_REMATCH[0]}"; tok+="${BASH_REMATCH[1]}"; intok=1
  elif [[ $w =~ $re_sq  ]]; then m="${BASH_REMATCH[0]}"; tok+="${BASH_REMATCH[1]}"; intok=1
  elif [[ $w =~ $re_run ]]; then m="${BASH_REMATCH[0]}"; tok+="$m"; intok=1
  elif [[ $s =~ $re_dq  ]]; then m="${BASH_REMATCH[0]}"; tok+="${BASH_REMATCH[1]}"; intok=1   # a quoted span longer than the window
  elif [[ $s =~ $re_sq  ]]; then m="${BASH_REMATCH[0]}"; tok+="${BASH_REMATCH[1]}"; intok=1
  else m="${s:0:1}"; tok+="$m"; intok=1            # an unmatched quote: carry on
  fi
  s="${s:${#m}}"
done
push_seg

[ "$n_found" -gt 0 ] || exit 0

# ---- which of them did another session edit? (ledger rows: path, session, time) -------------
declare -a FK=() FS=() FT=()
printf -v now '%(%s)T' -1 2>/dev/null
case "${now:-}" in ''|*[!0-9]*) now=0 ;; esac
if [ -n "$sid" ] && [ -r "$FCLAIMS_FILE" ]; then
  while IFS=$'\t' read -r k o t; do
    [ -n "$k" ] && [ -n "$o" ] && [ "$o" != "$sid" ] || continue
    case "$k" in nudge:*) continue ;; esac
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ "$now" = 0 ] || [ $(( now - t )) -le "$FCLAIMS_MAX_AGE_SECS" ] || continue
    FK+=("$k"); FS+=("$o"); FT+=("$t")
  done < "$FCLAIMS_FILE"
fi
nf=${#FK[@]}

count=0; hard=0; foreign=0; nshown=0; shown=""; labels=""; who=""; who_ts=0
i=0
while [ "$i" -lt "$n_found" ]; do
  mark=""
  if [ "$nf" -gt 0 ]; then
    fclaims_norm "${L_ABS[$i]}"; key="$FCLAIMS_KEY"
    j=$((nf-1))                                   # newest row first
    while [ "$j" -ge 0 ]; do
      hit=0
      case "$key" in
        */) case "${FK[$j]}" in "$key"*) hit=1 ;; esac ;;       # an untracked directory: any file below it
        *)  [ "${FK[$j]}" = "$key" ] && hit=1 ;;
      esac
      if [ "$hit" = 1 ]; then
        mark="${FS[$j]}"
        [ "${FT[$j]}" -gt "$who_ts" ] && { who_ts="${FT[$j]}"; who="${FS[$j]}"; }
        break
      fi
      j=$((j-1))
    done
  fi
  if [ "${L_KIND[$i]}" = soft ] && [ -z "$mark" ]; then i=$((i+1)); continue; fi
  count=$((count+1))
  [ "${L_KIND[$i]}" = hard ] && hard=$((hard+1))
  [ -n "$mark" ] && foreign=$((foreign+1))
  if [ "$nshown" -lt 12 ]; then
    shown+="  ${L_TXT[$i]}${mark:+    <- session ${mark%%-*} edited this}"$'\n'
    nshown=$((nshown+1))
  fi
  case ", $labels, " in *", ${L_LABEL[$i]}, "*) ;; *) labels+="${labels:+, }${L_LABEL[$i]}" ;; esac
  i=$((i+1))
done
[ "$count" -gt 0 ] || exit 0

# This session's own worktree (user 2026-11-20): a linked worktree whose repo-claim rows name
# THIS session and no other is scratch the session made for itself -- discarding there costs
# nobody else anything, and refusing a session that reverts its own experiment is what gets
# a guard switched off. Any other session's row, or any foreign file claim, or the
# main clone -> still refused. Bash-made edits (sed -i) never reach the file-claim ledger,
# which is why ownership is read off the worktree rather than the files.
own_tree() {   # <repo top> -> 0 when a linked worktree only this session has claimed
  local t="$1" gd cd root
  gd="$(git -C "$t" rev-parse --git-dir 2>/dev/null)" || return 1
  cd="$(git -C "$t" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ "$gd" != "$cd" ] || return 1
  root="$(claims_repo_root "$t")"
  [ -n "$root" ] && [ -n "$(claims_of "$root" "$sid")" ] && [ -z "$(claims_others "$root" "$sid")" ]
}
if [ "$foreign" = 0 ] && [ -n "$sid" ] && . "$HERE/lib-repo-claims.sh" 2>/dev/null; then
  all_own=1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    own_tree "$t" || { all_own=0; break; }
  done <<< "$NL_TOPS"
  [ "$all_own" = 1 ] && exit 0
fi

more=""; [ "$count" -gt "$nshown" ] && more=" (first $nshown shown)"
if [ "$hard" -gt 0 ]; then
  head="This would throw away uncommitted work, and nothing brings it back afterwards."
else
  head="This would take files another session edited, and has not committed, out from under it."
fi
other=""
if [ "$foreign" -gt 0 ]; then
  age=$(( now - who_ts ))
  if   [ "$now" = 0 ];      then ago=""
  elif [ "$age" -lt 60 ];   then ago=", ${age}s ago"
  elif [ "$age" -lt 3600 ]; then ago=", $(( age / 60 ))m ago"
  else                           ago=", $(( age / 3600 ))h ago"
  fi
  other="
$foreign of them were edited by another session (${who%%-*}${ago}): not this session's to discard. Sessions working side by side need a tree each: bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/worktree-add.sh <repo-path> <slug> <branch>
"
fi
# Read by the model: what to do instead, and the one way past.
reason="REFUSED. $head

  command:  $labels
  repo:     $WHERE
  at stake: $count file(s)$more

$shown$other
Keep the work instead: commit it first (git commit -m \"...\" -- <paths>), stash it (git stash push -- <paths>), or name only the paths you really mean.

$SAID_SO_HINT"

hook_say deny "$reason"
