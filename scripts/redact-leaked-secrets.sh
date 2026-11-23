#!/usr/bin/env bash
# Scrub leaked credentials out of Claude transcripts and scratch files (and out of the chat
# logs this harness wrote until 2026-11-21, where such a folder still exists).
#
# Run this the moment a credential lands in tool output -- do NOT ask the user first, and do
# NOT recommend rotating on account of the transcript alone: ~/.claude/projects is gitignored
# (.gitignore:5), so nothing reaches a remote.
# Rotation is only warranted if the value leaked somewhere that IS published.
#
# usage: redact-leaked-secrets.sh [extra paths...]   (defaults cover the usual three)
# REDACT_SWEEP_ROOTS="<dir> ..." replaces the defaults entirely (fleet-health's selftest).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${REDACT_SWEEP_ROOTS:-}" ]; then
    # shellcheck disable=SC2086
    exec python "$HERE/redact-leaked-secrets.py" $REDACT_SWEEP_ROOTS "$@"
fi

DEFAULTS=(
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scratch"
)
# Old chat-log dirs vary per adopter; include whichever still exist. NOT claude-harness-local-chat-files:
# a full harness checkout with zero chat logs -- the sweep rewrote 9 placeholder/code lines in
# its tracked docs (2026-10-28, left dirty) and had nothing there to clean.
for d in "$HOME/Repos/YourRepos/Local Chat Files" \
         "$HOME/Repos/YourRepos/claude-harness/Local Chat Files"; do
    [ -d "$d" ] && DEFAULTS+=("$d")
done

# hook-run.sh blanks <pid>.{in,out,err} only when the hook exits normally; session start/clean
# exit prune them too (log-session-start.sh, on-session-end.sh). Hooks time out in minutes, so a copy over 60 minutes old belongs to a dead PID: delete
# it here, before scanning, so the nightly sweep stops re-redacting the same stdin copies.
find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scratch/hook-run" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null

python "$HERE/redact-leaked-secrets.py" "${DEFAULTS[@]}" "$@"
