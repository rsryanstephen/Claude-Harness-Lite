#!/usr/bin/env bash
# statusLine command. Claude Code invokes this every render with a JSON payload on
# stdin (model, cost, context_window, session_id, rate_limits.five_hour/.seven_day.
# used_percentage + resets_at -- session_id confirmed via code.claude.com/docs/en/
# statusline, "Unique session identifier"). Renders a colored bar (ANSI -- the terminal
# draws this directly, unlike chat replies which only render markdown, no color).
# Shows model | ctx:% | 5h:% | wk:% (green, amber at 60/75%, red at 80/90%). Nothing else:
# no state files, no notices, no scheduled tasks.
#
# Fork budget: this renders continuously (Claude Code's own docs: "runs frequently
# during active sessions... can cause lag"), and process creation costs ~60ms on this
# machine (Sysmon/Intune tax, see on-prompt.sh:465's sibling comment). It used to fork
# ~25 processes per render (7 jq on the same payload, awk per threshold check, jq per
# statefile read/write, command-substituted shell functions -- MSYS has no real fork(),
# so even $(shell_function) is a full process). Now: cat + ONE jq + rare-path extras.
payload="$(cat)"

# Single jq for all seven fields (was seven separate jq re-parsing the same payload).
# Payload sends raw floats (eg. 14.000000000000002) -- round once here so both the bar
# AND any notice text quoting these same vars get
# clean integers, instead of formatting at every print site. `// ""` (never `// empty`)
# so a missing field still emits its line and the positional reads below stay aligned.
# jq.exe emits CRLF and `read` (unlike `$(...)`) does NOT strip the \r, so strip it
# from each explicitly -- resets are compared numerically below, a stray \r breaks that.
model=""; sid=""; five_pct=""; five_reset=""; week_pct=""; week_reset=""; ctx_pct=""
{ IFS= read -r model; IFS= read -r sid; IFS= read -r five_pct; IFS= read -r five_reset
  IFS= read -r week_pct; IFS= read -r week_reset; IFS= read -r ctx_pct; } < <(
  printf '%s' "$payload" | jq -r '
    def r(v): if v == null then "" else ((v + 0.5) | floor) end;
    (.model.display_name // .model.id // "?"),
    (.session_id // ""),
    r(.rate_limits.five_hour.used_percentage),
    (.rate_limits.five_hour.resets_at // ""),
    r(.rate_limits.seven_day.used_percentage),
    (.rate_limits.seven_day.resets_at // ""),
    r(.context_window.used_percentage)
  ' 2>/dev/null)
model="${model%$'\r'}"; sid="${sid%$'\r'}"
five_pct="${five_pct%$'\r'}"; five_reset="${five_reset%$'\r'}"
week_pct="${week_pct%$'\r'}"; week_reset="${week_reset%$'\r'}"
ctx_pct="${ctx_pct%$'\r'}"
[ -n "$model" ] || model="?"

printf -v now '%(%s)T' -1   # bash builtin -- no date fork, no subshell

# Sets $__color instead of printing -- $(shell_function) is a full process creation
# under MSYS (no real fork()), so every command substitution of a local function costs
# like an external tool. Threshold compares are plain bash arithmetic now that the pct
# values are jq-rounded integers (see the payload read above). Caller guards non-empty.
color_for() {
  if [ "$1" -ge 90 ]; then __color=$'\033[1;31m'
  elif [ "$1" -ge 75 ]; then __color=$'\033[1;33m'
  else __color=$'\033[32m'; fi
}

color_for_ctx() {
  if [ "$1" -ge 80 ]; then __color=$'\033[1;31m'
  elif [ "$1" -ge 60 ]; then __color=$'\033[1;33m'
  else __color=$'\033[32m'; fi
}

# Sets $__delta ("~2h13m" / "~45m" / "soon") -- same no-print reasoning as color_for.
human_delta() {
  local secs="$1"
  [ -n "$secs" ] || { __delta='soon'; return; }
  [ "$secs" -lt 0 ] && secs=0
  local h=$((secs / 3600)) m=$(( (secs % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then __delta="~${h}h${m}m"; else __delta="~${m}m"; fi
}


# Countdown suffix once a window is effectively exhausted -- resets_at/now are
# recomputed fresh on every render, so this ticks down for free with no separate poller;
# Claude Code already re-invokes this script continuously while the terminal sits idle.
# Sets $__suffix -- same no-print reasoning as color_for.
resuming_suffix() {
  local pct="$1" reset="$2"
  __suffix=""
  [ "$pct" -ge 99 ] && [ -n "$reset" ] || return 0
  human_delta $((reset - now))
  local word="resets"
  __suffix=" ($word $__delta)"
}

bar="$model"
if [ -n "$ctx_pct" ]; then
  color_for_ctx "$ctx_pct"
  bar="$bar | ${__color}ctx:${ctx_pct}%\033[0m"
fi
if [ -n "$five_pct" ]; then
  color_for "$five_pct"; resuming_suffix "$five_pct" "$five_reset"
  bar="$bar | ${__color}5h:${five_pct}%${__suffix}\033[0m"
fi
if [ -n "$week_pct" ]; then
  color_for "$week_pct"; resuming_suffix "$week_pct" "$week_reset"
  bar="$bar | ${__color}wk:${week_pct}%${__suffix}\033[0m"
fi
printf '%b\n' "$bar"
