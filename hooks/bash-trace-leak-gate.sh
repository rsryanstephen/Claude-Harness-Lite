#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Denies an xtrace run (`bash -x`, `set -x`, `set -o
# xtrace`, `PS4=`, `BASH_XTRACEFD=`) whose stderr lands in a FILE without a redactor in the
# way. The trace expands every `-u "$AUTH"` / `-H "X-Api-Key: $KEY"` argument, so the
# Atlassian token sat in scratch/backlog-timing/trace.txt in plain text (2026-11-06, session
# 738a6d80: 5 lines, redacted by hand). output-secret-leak-gate.sh scrubs tool OUTPUT, but a
# `2> file` never reaches it -- this is the file-side half. The prescribed shape is in
# bash-command-style "Tracing or timing a harness script": `2> >(awk -v tok="$TOKEN" ... >
# trace.txt)`, i.e. a process substitution that redacts, which this gate allows.
#
# Allowed: trace with no stderr redirect at all (goes to the tool result, where the output
# gate sees it); stderr to /dev/null; a `>( ... )` process substitution whose text names
# redact/REDACT (the awk line above, or scripts/redact-leaked-secrets.*).
#
# Sibling: trace-secret-gate.sh denies ANY trace of a harness-path script (output side), with
# an HARNESS_ALLOW_TRACE=1 hatch for scripts that provably read no secret. This gate has no hatch
# and no path test: a trace file is never scrubbed by the output gate, and the 2026-11-06 leak
# was exactly a "provably no secret" call that sourced a lib which did. Redact in line.
#
# One jq fork, then bash [[ =~ ]] only: a grep -P chain took 4-7 s per call under suite load
# (124 live shell processes, 2026-11-06) and the dispatcher skipped it at 20 s -- fail-open.
set -u

IFS= read -r -d '' payload || true
# Cheap pre-filter before any fork (precedent: bare-cd-gate.sh). Every deniable command
# carries one of these literally.
case "$payload" in *-x*|*xtrace*|*PS4=*|*BASH_XTRACEFD*) ;; *) exit 0 ;; esac

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r' | tr '\n' ';')"
[ -n "$cmd" ] || exit 0

sp='[[:space:]]'
# xtrace on: `bash -x`/`-xv`/`-vx` (bash/sh, .exe too), `set -x`/`-xv`/`-o xtrace`, PS4= or
# BASH_XTRACEFD= assignments. Leading context = start, separator, or `(`.
re_trace="(^|[[:space:];&|(])((bash|sh)(\.exe)?$sp+(-[a-wyz]+$sp+)*-[a-z]*x|set$sp+(-[a-z]*x|-o$sp+xtrace)|(PS4|BASH_XTRACEFD)=)"
[[ $cmd =~ $re_trace ]] || exit 0

# stderr to a file: `2>`/`2>>`/`&>`/`&>>`/`|&`, or `> file 2>&1` in either order. A bare
# `2>&1` sends it to stdout, which is fine unless stdout is itself a file.
re_err_file="(^|[^>&0-9])(2>>?|&>>?)$sp*[^&>([:space:]]"
re_out_file="(^|[^>&0-9])(1?>>?)$sp*[^&>([:space:]]"
to_file=0
[[ $cmd =~ $re_err_file ]] && to_file=1
[[ $cmd == *'2>&1'* && $cmd =~ $re_out_file ]] && to_file=1
[[ $cmd == *'|&'* ]] && to_file=1
[ "$to_file" = 1 ] || exit 0
# /dev/null is not a file anyone reads.
re_null="(2>>?|&>>?)$sp*/dev/null"
[[ $cmd =~ $re_null ]] && exit 0
# A redacting process substitution on stderr is the prescribed shape.
re_redact="2>$sp*>\(.*[Rr][Ee][Dd][Aa][Cc][Tt]"
[[ $cmd =~ $re_redact ]] && exit 0

awk_ref=''
reason='xtrace with stderr going to a FILE: `bash -x`/`set -x` expands every `-u "$AUTH"` argument, so the token lands in that file in plain text (scratch/backlog-timing/trace.txt, 2026-11-06). Redact in line instead -- `2> >(awk -v tok="$ATLASSIAN_API_TOKEN" ... > trace.txt)`'"$awk_ref"' -- or leave stderr on the tool result, where output-secret-leak-gate.sh scrubs it.'
jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
