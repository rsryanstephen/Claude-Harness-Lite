#!/usr/bin/env bash
# Sourced. Credentials live in ~/.secrets (2026-10-28), which only an interactive ~/.bashrc loads:
# hooks, scheduled tasks (Watchers-Ensure) and headless runners never had them, so every key
# reader died at startup ("BITBUCKET_API_KEY is not set", 2026-10-28). One loader for all of them:
# sourced by hook-run.sh + dispatch.sh (every hook), lib-harness-repos.sh (most skill scripts),
# lib-jira-status.sh, lib-bitbucket.sh and the few scripts that source none of those.
# set -a exports whatever the file assigns, so children (curl, node, nested bash) see it too.
# Fork-free; a no-op when every key is already in the env or the file is absent.
# A key added to the file AFTER a session started is missing from that session's env while the
# four core keys are present -- so each such key needs its own test here, or nothing spawned from
# an open session ever loads it (SLACK_REMINDER_WEBHOOK_URL, 2026-11-05). It is optional: unset
# means re-sourcing every time, which is a builtin read of a ~1 KB file, still fork-free.
# Never print the file: dotfile-secret-print-gate.sh denies reads of it by design.
# HR_NO_SECRETS=1 (test seam) = load nothing: an optional key a test leaves blank would otherwise
# pull the REAL value in, over every fake one the test set (reminder-selftest.sh).
# The org edition's own keys join the "is a core key missing" test below (fork-free function).
hr_org_key_missing() { return 1; }
[ -n "${HR_NO_SECRETS:-}" ] ||
if [ -z "${ATLASSIAN_API_TOKEN:-}" ] || [ -z "${BITBUCKET_API_KEY:-}" ] || hr_org_key_missing \
   || [ -z "${SLACK_REMINDER_WEBHOOK_URL:-}" ] || [ -z "${SLACK_REMINDER_BOT_TOKEN:-}" ]; then
  if [ -f "$HOME/.secrets" ]; then
    set -a; . "$HOME/.secrets" 2>/dev/null; set +a
  fi
fi

# curl_as <user:secret> [curl args...] -- THE way a harness script hands curl a credential
# (2026-11-06). `-u "$email:$TOKEN"` put the token on curl's command line, where every process
# listing reads it (Win32_Process.CommandLine, Task Manager, the reaper; a listing printed a
# token fragment that day). Here it travels as a config file on stdin (`-K -`) written by the
# printf BUILTIN, so no process ever carries it in argv. Backslash and double quote are escaped
# per curl's config grammar (verified against httpbin basic-auth). A caller that feeds curl's
# own stdin (`-d @-`, `-T -`) cannot use this -- none does. Exported so a hook run under
# hook-run.sh/dispatch.sh inherits it; the suite runs gates directly, so hooks that source no
# other lib source this file themselves. Pinned by check-gates ("curl_as").
curl_as() {
  local cred="$1"; shift
  cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
  printf 'user = "%s"\n' "$cred" | curl -K - "$@"
}
export -f curl_as 2>/dev/null
