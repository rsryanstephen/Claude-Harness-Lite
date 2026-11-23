#!/usr/bin/env bash
# session-peek.sh                  list the sessions active lately on this machine
# session-peek.sh <id|name> [n]    the last n exchanges (default 6) of one of them
#
# What is another Claude Code session working on? Claude Code itself keeps every session's
# transcript at ~/.claude/projects/<folder>/<session-id>.jsonl, megabytes of JSON. This prints
# a short digest from the TAIL of that file -- the user's prompts and the text of the replies,
# clipped, no tool traffic -- so one session can look at another for a few hundred tokens.
# Read-only. Needs nothing the harness writes: no chat logs, no session list.
#
# <id|name>: the start of a session id, or part of a session's name (its /rename title when
# it has one, else its first prompt). The newest match wins.
set -u
P="${CLAUDE_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
[ -d "$P" ] || { echo "no transcripts under $P" >&2; exit 1; }
want="${1:-}"; n="${2:-6}"
case "$n" in ''|*[!0-9]*) n=6 ;; esac

# A transcript's tail as clean JSON lines. The first line of a byte window is cut mid-entry, so
# it is dropped -- but only when the file is larger than the window.
tail_json() {
  if [ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -gt "$2" ]; then
    tail -c "$2" "$1" 2>/dev/null | tail -n +2 | tr -d '\r'
  else
    tr -d '\r' < "$1" 2>/dev/null
  fi
}

# name_of <file>: the name the user gave it (/rename) if any, else Claude Code's own title for
# it, else the last real prompt in the window, clipped. The user's name wins even when an
# auto-title was written after it (2026-11-21: a renamed session was listed under a stale
# auto-title).
name_of() {
  # split/join, not gsub: jq 1.5's gsub eats characters after any non-ASCII one.
  tail_json "$1" 600000 | jq -r '
    def flat: split("\n") | join(" ") | split("\r") | join("") | split("\t") | join(" ");
    if (.customTitle | type) == "string" and .customTitle != "" then "C\t" + .customTitle
      elif (.aiTitle | type) == "string" and .aiTitle != "" then "T\t" + .aiTitle
      elif .type == "user" and .isMeta != true and .isSidechain != true and (.message.content | type) == "string"
           and (.message.content | startswith("<") | not)
        then "P\t" + (.message.content | flat | .[0:70])
      else empty end' 2>/dev/null \
  | awk -F'\t' '$1 == "C" { c = $2 } $1 == "T" { t = $2 } $1 == "P" { p = $2 } END { if (c != "") print c; else if (t != "") print t; else print p }'
}

now="$(date +%s)"
# An unattended run (claude -p, a scheduled job) is not what "another session" means, and a
# machine can have dozens a day. Its transcript says "entrypoint":"sdk-cli" on its first user
# line -- an unescaped JSON key, so a session that merely talks about it does not match. Read
# from the head only: the line sits within the first few records, one of which can be ~240 KB.
is_headless() { head -c 400000 "$1" 2>/dev/null | grep -q -m1 '"entrypoint":"sdk-cli"'; }
list() {   # newest first: age, short id, folder, name -- sessions a person started
  local shown=0 f age id dir
  while IFS= read -r f; do
    [ "$shown" -lt "${1:-12}" ] || break
    is_headless "$f" && continue
    age=$(( (now - $(stat -c %Y "$f" 2>/dev/null || echo "$now")) / 60 ))
    id="${f##*/}"; id="${id%.jsonl}"; dir="${f%/*}"; dir="${dir##*/}"
    printf '%4s min  %s  %-28s  %s\n' "$age" "${id:0:8}" "${dir:0:28}" "$(name_of "$f")"
    shown=$((shown + 1))
  done < <(ls -t "$P"/*/*.jsonl 2>/dev/null | head -n 80)
}

if [ -z "$want" ]; then
  echo "Sessions by last activity (age, id, project folder, name):"
  list 12
  echo "Then:  bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/session-peek.sh <id or part of the name> [exchanges]"
  exit 0
fi

file="$(ls -t "$P"/*/"$want"*.jsonl 2>/dev/null | head -n 1)"
if [ -z "$file" ]; then
  lw="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r f; do
    case "$(name_of "$f" | tr '[:upper:]' '[:lower:]')" in *"$lw"*) file="$f"; break ;; esac
  done < <(ls -t "$P"/*/*.jsonl 2>/dev/null | head -n 30)
fi
[ -n "$file" ] || { echo "no session matches '$want'. Known:" >&2; list 12 >&2; exit 1; }

id="${file##*/}"; id="${id%.jsonl}"
echo "Session ${id:0:8} ($(name_of "$file")), last written $(( (now - $(stat -c %Y "$file")) / 60 )) min ago. Last $n exchanges:"
tail_json "$file" 2500000 | jq -r '
  def clip(n): if length > n then .[0:n] + " ..." else . end;
  def flat: split("\n") | join(" ") | split("\r") | join("") | split("\t") | join(" ");
  select(.isSidechain != true and .isMeta != true)
  | if .type == "user" then
      (.message.content | if type == "string" then . else (map(select(.type == "text") | .text) | join(" ")) end) as $t
      | select($t != "" and ($t | startswith("<") | not))
      | "USER:  " + ($t | flat | clip(500))
    elif .type == "assistant" then
      (.message.content | map(select(.type == "text") | .text) | join(" ")) as $t
      | select($t != "")
      | "REPLY: " + ($t | flat | clip(600))
    else empty end' 2>/dev/null \
| awk -v n="$n" '
    { line[NR] = $0 }
    /^USER:/ { u[++k] = NR }
    END { start = (k > n) ? u[k - n + 1] - 1 : 1; for (i = start; i <= NR; i++) print line[i] }'
