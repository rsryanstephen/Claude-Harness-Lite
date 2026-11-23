#!/usr/bin/env bash
# Shared: the repo-claim registry.
#
# ~/.claude/.repo-claims, TSV:  <repo-abs-path>\t<sid>\t<branch>\t<epoch>
# One row per (repo, session) -- where each session last acted in it. Not a lock, not a lease:
# a record of who was last seen where. Until 2026-11-19 it was one row per REPO, so the newest
# actor overwrote everyone else: a session could no longer tell that the branch had moved
# under it, and a session that acted last looked alone in the clone. claims_get still answers
# "who acted last", for the callers that warn; claims_of / claims_others serve the gates.
#
# ONE FILE, deliberately. The obvious alternative is a per-session state file next to the
# others in .session-chatfiles/, and that would be a mistake: nothing in this harness
# deletes per-session state at SessionEnd (~380 files live there now, including orphans
# from removed features), and on-prompt.sh:77-83 records that scanning that directory once
# blew the 30s hook budget. A single self-pruning file cannot grow that way.
#
# NO LOCK, also deliberately. lib-sessions-lock.sh exists but is hardcoded to sessions.txt
# and its 10s-stale / 5s-give-up semantics are tuned for a fast rewrite, not this. A lost
# update here costs exactly one missed warning; paying lock complexity -- and lock-stranding
# risk -- for that is the wrong trade. Writes are atomic (temp + mv) so a concurrent reader
# never sees a half-written file, which is the only corruption that would actually matter.
#
# Sourced, not executed. Every function fails soft: a guard built on this stays silent
# rather than misfiring.

. "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib-claude-paths.sh"
CLAIMS_FILE="${CLAIMS_FILE:-$(hstate sessions .repo-claims)}"
CLAIMS_MAX_AGE_DAYS="${CLAIMS_MAX_AGE_DAYS:-7}"

# claims_repo_root <dir> -> absolute repo root, normalised, or empty.
# Normalising matters: the same repo arrives as C:/... from one payload and /c/... from
# another, and two spellings would read as two different repos.
claims_repo_root() {
  local d="${1:-}" root
  [ -n "$d" ] || return 0
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  printf '%s' "$root" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'
}

# claims_get <repo-root> -> "sid<TAB>branch<TAB>epoch" of the session that acted there LAST,
# or empty
claims_get() {
  local root="${1:-}"
  [ -n "$root" ] && [ -f "$CLAIMS_FILE" ] || return 0
  awk -F'\t' -v r="$root" '$1 == r && $4 + 0 >= best { best = $4 + 0; line = $2 "\t" $3 "\t" $4 }
    END { if (line != "") print line }' "$CLAIMS_FILE" 2>/dev/null
}

# claims_of <repo-root> <sid> -> "branch<TAB>epoch": where THAT session last acted there
claims_of() {
  local root="${1:-}" sid="${2:-}"
  [ -n "$root" ] && [ -n "$sid" ] && [ -f "$CLAIMS_FILE" ] || return 0
  awk -F'\t' -v r="$root" -v s="$sid" '$1 == r && $2 == s { print $3 "\t" $4; exit }' "$CLAIMS_FILE" 2>/dev/null
}

# claims_others <repo-root> <sid> -> "sid<TAB>branch<TAB>epoch" per OTHER session, newest first.
# Liveness is the caller's to test.
claims_others() {
  local root="${1:-}" sid="${2:-}"
  [ -n "$root" ] && [ -f "$CLAIMS_FILE" ] || return 0
  awk -F'\t' -v r="$root" -v s="$sid" '$1 == r && $2 != s && $2 != "" { print $4 "\t" $2 "\t" $3 "\t" $4 }' \
    "$CLAIMS_FILE" 2>/dev/null | sort -rn | cut -f2-
}

# claims_put <repo-root> <sid> <branch> -- upsert, prune, atomic replace
claims_put() {
  local root="${1:-}" sid="${2:-}" branch="${3:-}" now cutoff tmp
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  now="$(date +%s)"
  cutoff=$(( now - CLAIMS_MAX_AGE_DAYS * 86400 ))
  tmp="$(mktemp "${CLAIMS_FILE}.XXXXXX" 2>/dev/null)" || return 0

  # Keep every other row that is still recent, drop THIS session's old row for this repo and
  # anything past the cutoff -- pruning on write is what keeps this file from becoming
  # another pile nothing ever cleans.
  if [ -f "$CLAIMS_FILE" ]; then
    awk -F'\t' -v r="$root" -v s="$sid" -v c="$cutoff" \
      '!($1 == r && $2 == s) && $4 ~ /^[0-9]+$/ && $4 >= c' "$CLAIMS_FILE" >> "$tmp" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\n' "$root" "$sid" "$branch" "$now" >> "$tmp"
  mv -f "$tmp" "$CLAIMS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# claims_describe_age <epoch> -> "3m" / "2h" / "4d", for a human-readable warning
claims_describe_age() {
  local then="${1:-0}" now age
  case "$then" in ''|*[!0-9]*) echo "unknown"; return ;; esac
  now="$(date +%s)"; age=$(( now - then ))
  if   [ "$age" -lt 60 ];    then echo "${age}s"
  elif [ "$age" -lt 3600 ];  then echo "$(( age / 60 ))m"
  elif [ "$age" -lt 86400 ]; then echo "$(( age / 3600 ))h"
  else echo "$(( age / 86400 ))d"
  fi
}
