#!/usr/bin/env bash
# PreToolUse hook (Agent). Warn-only. Two nudges, one fork budget (the only Agent hook):
#
# 1. Output budget: the prompt should state an explicit word cap. The parent pays the whole
#    report into context and it stays there for the rest of the session. Measured
#    2026-09-01: unbudgeted Explore agents returned 3-5k-token reports; the same tasks with
#    "report in under 400 words" came back at ~400 and lost nothing. -> hook context.
#    (Until 2026-11-19 this nudge was the reason of an `allow` decision; a probe on CLI
#    2.1.328 showed that text reaches nobody. GATES-AND-HOOKS.md, "Hook wiring".)
#
# 2. Model opt-up (2026-10-22, user policy [[regulation-tasks-on-sonnet]]): settings.json's
#    env sets CLAUDE_CODE_SUBAGENT_MODEL=sonnet, so an omitted `model` lands on Sonnet
#    mechanically (Agent tool AND Workflow agent() -- 396/396 workflow agents ran Sonnet
#    2026-10-21/22 with no model opt in any script). Right for regulation/mechanical work.
#    Real judgment (architecture call, adversarial verify, wrong call costly) belongs on the
#    SESSION's model, not a fixed "opus" -- the session may be on fable or already dropped
#    to opus at a cap. So when `model` is omitted, this hook names the live session model
#    (last assistant message in the transcript; settings.json `.model` before the first
#    reply) as additionalContext, so the caller can pass it exactly. Judgment is Claude's;
#    the value is mechanical.
#
# Warns only, in the full editions -- a genuinely open-ended audit legitimately has no word
# cap, and Sonnet is the right default for most spawns. The lite edition REFUSES an uncapped
# call instead and drops nudge 2 (see "Strength" below). Honors SUBAGENT_MODEL_TIERING=off.
set -u

[ "${SUBAGENT_MODEL_TIERING:-}" = "off" ] && exit 0

payload="$(cat | tr -d '\r')"

# Cheap pure-bash prefilter before any jq fork (GATES-AND-HOOKS.md fork-budget convention).
case "$payload" in *'"prompt"'*) ;; *) exit 0 ;; esac

prompt="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // empty')"
model="$(printf '%s' "$payload" | jq -r '.tool_input.model // empty')"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"

need_budget=1
printf '%s' "$prompt" | grep -qiE \
  'under [0-9]+ ?words|[0-9]+ ?words or (fewer|less)|no more than [0-9]+ ?words|at most [0-9]+ ?words|max(imum)? [0-9]+ ?words|[0-9]+[ -]?word (cap|limit|budget|max)|word (budget|cap|limit)|output budget|≤ ?[0-9]+ ?words|<= ?[0-9]+ ?words' \
  && need_budget=0

[ "$need_budget" = 0 ] && [ -n "$model" ] && exit 0

# Strength of the budget check. A warning in the full editions. In gate mode (the lite
# edition always; lib-hook-say.sh) a DENY: the model can add the cap alone, an Agent call is
# short to send again, and the refusal costs far less than the uncapped report it prevents.
. "${BASH_SOURCE[0]%/*}/lib-hook-say.sh" 2>/dev/null || exit 0
gate=""; gates_on && gate=deny
ctx=''


closing=' Not a mandate -- this never blocks.'
[ -n "$gate" ] && closing=' Refused: add a cap and send the call again.'
reason='No output budget in the prompt -- add an explicit cap (e.g. "report in under 400 words; bullets, file:line, no preamble"). You pay the whole report into context and it stays for the session; unbudgeted Explore/Plan agents routinely return 3-5k tokens. Rough defaults: lookup <=200, scoped investigation <=400, broad audit <=800.'"$closing"

if [ "$need_budget" = 1 ] && [ -n "$gate" ]; then
  hook_say "$gate" "$reason"
elif [ "$need_budget" = 1 ]; then
  # Both nudges ride in one context string; no permissionDecision (a warning approves nothing).
  hook_say "" "$reason${ctx:+

$ctx}"
elif [ -n "$ctx" ]; then
  hook_say "" "$ctx"
fi
