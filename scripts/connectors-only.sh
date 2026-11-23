#!/usr/bin/env bash
# connectors-only.sh <Name> [<Name> ...]  |  --list  |  --all
#
# Keeps only the named claude.ai connectors in THIS Claude Code profile and switches every
# other one off. Each connector an account has puts its tool names in front of the model in
# every session, used or not (measured 2026-11-21: 26 connectors cost about 5,000 tokens per
# session); a connector that is off costs nothing.
#
#   connectors-only.sh Slack Gmail    keep these two, switch the rest off
#   connectors-only.sh --list         what the account has, and what is off in this profile
#   connectors-only.sh --all          switch everything back on
#
# A name is what `claude mcp list` prints after "claude.ai " (case does not matter; quote a
# name with a space: "Google Calendar"). Takes effect in NEW sessions. Run it again after
# adding a connector to the account: a new one starts out on.
#
# How. Every connector not kept is written to deniedMcpServers in the profile's settings.json.
# Claude Code then does not connect it and lists none of its tools (probed, same date: one
# denied connector gone from the session, a name no server has changed nothing). Only entries
# named "claude.ai ..." are managed here; any other deniedMcpServers entry is left alone.
# Connectors already off are not printed by `claude mcp list`, so the account's list is what it
# prints plus what this profile already denies. settings.json is copied to
# harness-state/settings-backups/ before it is rewritten.
#
# Why not an allow list: allowedMcpServers naming two connectors blocked EVERY connector, the
# two named ones included (probed), and it would also block a server added by hand.
#
# The profile is $CLAUDE_CONFIG_DIR when set, else ~/.claude. CONNECTORS_SETTINGS=<file> is a
# test seam: the settings file to rewrite instead.
set -u

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; dir="${dir//\\//}"
settings="${CONNECTORS_SETTINGS:-$dir/settings.json}"
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

mode=keep
case "${1:-}" in
  ''|-h|--help) usage; exit 2 ;;
  --list) mode=list ;;
  --all)  mode=all ;;
  -*) echo "connectors-only: unknown option $1" >&2; exit 2 ;;
esac
[ -f "$settings" ] || { echo "connectors-only: no settings.json at $settings" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "connectors-only: the claude command is not on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "connectors-only: jq is needed" >&2; exit 1; }

nl=$'\n'
listed="$(claude mcp list 2>/dev/null | tr -d '\r' | sed -n 's/^claude\.ai \(.*\): https\{0,1\}:\/\/.*$/\1/p')"
off_now="$(jq -r '(.deniedMcpServers // [])[] | (.serverName // "") | select(startswith("claude.ai ")) | .[10:]' "$settings" 2>/dev/null | tr -d '\r')"
all="$(printf '%s\n%s\n' "$listed" "$off_now" | awk 'NF && !seen[tolower($0)]++')"
[ -n "$all" ] || { echo "connectors-only: this account shows no claude.ai connectors (is this profile logged in? run: claude mcp list)" >&2; exit 1; }

is_off() { printf '%s\n' "$off_now" | grep -qixF -- "$1"; }

if [ "$mode" = list ]; then
  while IFS= read -r n; do
    if is_off "$n"; then printf 'off  %s\n' "$n"; else printf 'on   %s\n' "$n"; fi
  done <<< "$all"
  exit 0
fi

deny=""
if [ "$mode" = keep ]; then
  for k in "$@"; do
    printf '%s\n' "$all" | grep -qixF -- "$k" \
      || { echo "connectors-only: no connector named \"$k\" on this account. It has: $(printf '%s' "$all" | paste -sd, - | sed 's/,/, /g')" >&2; exit 1; }
  done
  while IFS= read -r n; do
    hit=0
    for k in "$@"; do [ "${n,,}" = "${k,,}" ] && hit=1; done
    [ "$hit" = 1 ] || deny+="$n$nl"
  done <<< "$all"
fi

new="$(jq --arg names "$deny" '
    ($names | split("\n") | map(select(length > 0)) | map({serverName: ("claude.ai " + .)})) as $d
    | .deniedMcpServers = (((.deniedMcpServers // []) | map(select(((.serverName // "") | startswith("claude.ai ")) | not))) + $d)
    | if (.deniedMcpServers | length) == 0 then del(.deniedMcpServers) else . end
  ' "$settings")" || { echo "connectors-only: could not rewrite $settings (not valid JSON?)" >&2; exit 1; }
[ -n "$new" ] || { echo "connectors-only: empty result, $settings left as it was" >&2; exit 1; }

if [ -z "${CONNECTORS_SETTINGS:-}" ]; then
  bdir="$dir/harness-state/settings-backups"; mkdir -p "$bdir" 2>/dev/null
  cp "$settings" "$bdir/settings.json.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null \
    || { echo "connectors-only: could not back up $settings, nothing changed" >&2; exit 1; }
fi
printf '%s\n' "$new" > "$settings"      # written through: a linked settings.json stays a link

n_off="$(printf '%s' "$deny" | awk 'NF { n++ } END { print n + 0 }')"
if [ "$mode" = all ]; then
  echo "Every connector is on again in $dir. New sessions pick this up."
else
  echo "Kept: $(printf '%s, ' "$@" | sed 's/, $//'). Switched off in $dir: $n_off connector(s). New sessions pick this up."
fi
