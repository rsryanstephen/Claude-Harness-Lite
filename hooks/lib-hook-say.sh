#!/usr/bin/env bash
# How a PreToolUse hook delivers what it found, and which strength this install runs at.
#
#   hook_say <decision> <text> [context]
#     decision ""    a WARNING: hookSpecificOutput.additionalContext and no permissionDecision.
#                    The model reads it with the tool result -- AFTER the command has run. It
#                    costs tokens each time and can only inform, never stop.
#     decision deny  a GATE: refused, <text> goes to the model, which carries on by itself
#                    with a corrected call. Costs tokens only when it fires. Keep to calls that
#                    are short to send again: a refused Write is re-sent whole.
#     decision ask   a GATE that waits for a person: Claude Code prompts the user, <text> is
#                    the reason shown. The model never sees that reason, so [context] (one
#                    short line) says what was asked. A session nobody is watching stalls on it.
#   Never `allow`: the text of an allow decision reaches nobody (GATES-AND-HOOKS.md "Hook
#   wiring"; the suite's warn-dialect lint fails on it).
#
#   gates_on
#     True when this install runs its coordination and discard checks as DENY gates. The lite
#     edition always does (user, 2026-11-19): nothing there may wait for a click, so no hook
#     asks, and nothing is left to a warning -- a check that passes costs CPU and no tokens.
#     The full editions keep warnings for the cross-session guards; HARNESS_GATES=1 switches
#     the lite behaviour on, which is how check-gates.sh exercises it. The discard gate does
#     not look at this switch: it denies in every edition (user, 2026-11-21).
#
#   user_said_so "<command>"
#     The one way past such a deny: the command carries USER_SAID_SO=1 (as an environment
#     prefix, or anywhere in a PowerShell command). For when the user has asked for exactly
#     this, in words -- never the model's own judgement. No prompt, no click.
#
# Sourced, not executed.
gates_on() {
  local g
  g=1
  case "$g" in ''|0|off) return 1 ;; esac
  return 0
}

user_said_so() { case "${1:-}" in *USER_SAID_SO=1*) return 0 ;; esac; return 1; }
SAID_SO_HINT='Has the user asked for exactly this, in words? Then run it again with USER_SAID_SO=1 in front of the command. Never add that on your own judgement.'

hook_say() {
  jq -cn --arg d "${1:-}" --arg r "${2:-}" --arg c "${3:-}" '{
    hookSpecificOutput: ({ hookEventName: "PreToolUse" }
      + (if $d == "" then { additionalContext: $r }
         else { permissionDecision: $d, permissionDecisionReason: $r }
              + (if $c != "" then { additionalContext: $c } else {} end)
         end))
  }'
}
