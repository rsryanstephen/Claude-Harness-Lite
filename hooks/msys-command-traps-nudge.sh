#!/usr/bin/env bash
# PreToolUse nudge (Bash tool only -- never denies, never emits a permissionDecision: an
# explicit "allow" can override a sibling deny gate, see GATES-AND-HOOKS.md). Three
# git-bash/MSYS command traps that were prose-only in AGENTS.md until PROJ-15361:
#   1. jq --slurpfile: this box's jq 1.5rc1 exits 2 -- stdin or --argfile instead.
#   2. jq piped into jq without tr -d '\r': jq -r emits CRLF here, every line but the
#      last carries a \r and silently matches nothing downstream (lib-harness-repos.sh's
#      _jqr exists for this).
#   3. schtasks with single-slash flags: MSYS rewrites /query into a path; under
#      2>/dev/null that reads as "no task found". Needs doubled slashes.
#   4. TZ=<Area/City> date: git-bash date has no tzdata, so an IANA zone silently prints UTC
#      (hour AND label wrong), with no error.
#
# Lite edition: nothing there warns (lite-mirror-include.txt), so this hook REFUSES the two traps
# that give a silently wrong answer (raw jq output into jq or a read loop; TZ=<Area/City> date),
# with the fix, and stays silent on the rest. USER_SAID_SO=1 passes a refusal.
set -u
strict=1

IFS= read -r -d '' payload || true
case "$payload" in *jq*|*schtasks*|*aws*|*TZ=*) ;; *) exit 0 ;; esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' | tr -d '\r')"
[ "$tool" = "Bash" ] || exit 0
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$command" ] || exit 0
flat="$(printf '%s' "$command" | tr '\n' ';')"

notes=""; refuse=""
# jq -b/--binary writes LF, so a pipe from it is clean.
binary_jq() { printf '%s' "$flat" | grep -qE '\bjq\b[^;|]*[[:space:]](-[A-Za-z]*b[A-Za-z]*|--binary)([[:space:]]|$)'; }
# Raw output (-r, -j, combined like -rc) is the only kind whose \r reaches a value.
raw_jq_into_jq() { printf '%s' "$flat" | grep -qE '\bjq\b[^;|]*([[:space:]]-[A-Za-z]*[rj][A-Za-z]*|--raw-output|--join-output)[^;|]*\|[^;]*\bjq\b'; }
jqr_ref1=""; jqr_ref2=""
case "$flat" in
  *--slurpfile*) notes="jq --slurpfile is unsupported on this box (jq 1.5rc1, exits 2) -- read the second document on stdin, or use --argfile. " ;;
  *--rawfile*)   notes="jq --rawfile is unsupported on this box (jq 1.5rc1, 'Unknown option') -- jq -Rs the file into a JSON string and pass it with --argfile (create-bitbucket-pr.sh, 2026-11-05). " ;;
esac
if printf '%s' "$flat" | grep -qE '\bjq\b[^;|]*\|[^;]*\bjq\b'; then
  case "$flat" in
    *"tr -d"*) : ;;
    *) notes="${notes}This pipes jq output onward into another jq: jq -r output is CRLF here, so every line but the last silently matches nothing -- insert | tr -d '\\r' after the first jq${jqr_ref1}. "
       raw_jq_into_jq && ! binary_jq && refuse="${refuse}Raw jq output piped into another jq: Windows jq writes CRLF, so every value but the last carries a \\r and silently matches nothing. Add | tr -d '\\r' after the first jq, or give it -b (--binary). " ;;
  esac
fi
# Same CRLF trap, different consumer: jq -r feeding a `while read` loop. Only jq-into-jq was
# matched before, so this shape sailed through -- PROJ-15355's fix read task ARNs that
# way and every one carried a trailing \r, which AWS rejected as "Unexpected number of
# separators" / "taskId length should be one of [32,36]", naming everything except
# whitespace. A read loop over jq output essentially always wants the \r gone, so this stays
# low-noise; a bare `aws ... | jq` that only prints is deliberately NOT matched.
if printf '%s' "$flat" | grep -qE '\bjq\b[^;]*\|[^;]*\bwhile\b[^;]*\bread\b' \
   || printf '%s' "$flat" | grep -qE '\bwhile\b[^;]*\bread\b[^;]*<[[:space:]]*\([^)]*\bjq\b' \
   || printf '%s' "$flat" | grep -qE '\bwhile\b[^;]*\bread\b.*\bdone[[:space:]]*<[[:space:]]*<\([^)]*\bjq\b'; then
  case "$flat" in
    *"tr -d"*|*'sed s/\r$//'*|*"sed 's/\\r\$//'"*) : ;;
    *) notes="${notes}This feeds jq -r output into a read loop: jq emits CRLF here, so every value carries a trailing \\r. Passed to a native exe (aws.exe, docker.exe, node.exe) the error names anything but whitespace. Strip it per value -- | tr -d '\\r'${jqr_ref2}. "
       binary_jq || refuse="${refuse}jq output feeds a read loop: Windows jq writes CRLF, so every value carries a trailing \\r (a compare fails, a native exe rejects it naming anything but whitespace). Add | tr -d '\\r' after jq, or give jq -b (--binary). " ;;
  esac
fi
if printf '%s' "$flat" | grep -qE '\bschtasks(\.exe)?\s+/[a-z]' && ! printf '%s' "$flat" | grep -qE '\bschtasks(\.exe)?\s+//'; then
  notes="${notes}schtasks from git-bash needs DOUBLED slashes (schtasks.exe //query //tn ...) -- MSYS rewrites /query into a path and under 2>/dev/null that reads as \"no task found\". "
fi
# aws.exe arg starting with / (log-group names: /aws/ecs/x) -> MSYS rewrites it to
# C:/Program Files/Git/aws/...; put-retention-policy failed its regex, create-log-group
# "failed" silently (2026-10-20).
if printf '%s' "$flat" | grep -qE "(^|[;&|(]|[[:space:]])aws(\.exe)?[[:space:]][^;&|]*[[:space:]=][\"']?/[A-Za-z]" \
   && ! printf '%s' "$flat" | grep -q 'MSYS_NO_PATHCONV=1'; then
  notes="${notes}An aws argument starts with / (e.g. a /aws/... log-group name): MSYS rewrites it into a Windows path before aws.exe sees it -- prefix the command with MSYS_NO_PATHCONV=1. "
fi
if printf '%s' "$flat" | grep -qE '(^|[;&|(]|[[:space:]])TZ=[A-Za-z]+/[A-Za-z_]+[^;&|]*[[:space:]]date\b'; then
  et_ref=""
  notes="${notes}TZ=<Area/City> date prints UTC on git-bash (no tzdata) -- wrong hour, wrong label, no error.${et_ref} Other zones: python zoneinfo, or powershell.exe [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId. "
  refuse="${refuse}TZ=<Area/City> date prints UTC in Git Bash (it has no time-zone data): wrong hour, wrong label, no error. Ask Windows instead: powershell.exe -NoProfile -Command \"[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Eastern Standard Time')\" (Windows zone ids: tzutil /l). "
fi
if [ -n "$strict" ]; then
  [ -n "$refuse" ] || exit 0
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  . "$HERE/lib-hook-say.sh" 2>/dev/null || exit 0
  user_said_so "$command" && exit 0
  hook_say deny "REFUSED: ${refuse}Then run it again."
  exit 0
fi
[ -n "$notes" ] || exit 0

jq -cn --arg r "$notes" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("MSYS command-trap check (warn-only, command still runs): " + $r)
  }
}'
