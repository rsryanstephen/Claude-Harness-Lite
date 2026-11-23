#!/usr/bin/env bash
# PostToolUse hook (Bash|PowerShell). Reads the tool RESPONSE, not the command, for a
# high-confidence secret shape, and says so loudly with the redaction + rotation path.
#
# Why output-side (PROJ-15426, 2026-09-17): an ordinary authenticated GET of
# Bitbucket's pipelines-config/variables dumped a live AWS key pair, a deploy-server API key and
# an app password into the transcript -- the command looked harmless, so
# no input-side gate could have caught it. Same failure one day earlier from Playwright
# request instrumentation (`"Password":"<cleartext>"`). Prose in two skills did not hold.
# Nothing here can un-print the value; the point is that the leak is NOTICED the moment it
# happens instead of the next morning, and the cleanup runs at once.
#
# Shapes, deliberately few and specific -- every false positive here is a wall of text on a
# routine command:
#   AKIA[0-9A-Z]{16}                 AWS access key id (the secret key travels beside it)
#   API-[A-Z0-9]{20,}                Octopus API key
#   "(Proposed)?Password"\s*:\s*"[^"]  Cognito / any JSON body carrying a cleartext password
set -u

IFS= read -r -d '' payload || true
# Raw-payload needle before any jq fork (GATES-AND-HOOKS.md fork budget). PowerShell/JSON
# escaping puts `\"` around keys, so the Password needle tolerates a backslash.
case "$payload" in
  *AKIA*|*API-*|*Password*|*password\"*|*assword*\\t*|*ecret*\\t*|*pwd*\\t*|*_pw=*|*_PW=*|*_pass=*|*_PASS=*|*PASSWORD=*|*password=*|*SECRET=*|*secret=*|*TOKEN=*|*token=*|*PASSPHRASE=*|*passphrase=*) ;;
  *) exit 0 ;;
esac
case "$payload" in *tool_response*) ;; *) exit 0 ;; esac

resp="$(printf '%s' "$payload" | jq -r '.tool_response // empty | if type == "string" then . else tojson end' 2>/dev/null)"
[ -n "$resp" ] || exit 0

hits=""
# AKIAIOSFODNN7EXAMPLE is AWS's documented example id -- it lives in check-gates.sh fixtures and
# every AWS doc page; a review reading those blocked on it (2026-11-02).
printf '%s' "$resp" | grep -oE 'AKIA[0-9A-Z]{16}' | grep -qv '^AKIAIOSFODNN7EXAMPLE$' && hits="${hits}AWS access key id (AKIA...); "
printf '%s' "$resp" | grep -qE 'API-[A-Z0-9]{20,}' && hits="${hits}Octopus API key (API-...); "
# tojson above re-escapes an already-escaped body, so any run of backslashes may precede a quote.
# The value must look like a VALUE, not a placeholder or a regex fragment. Reproduced
# 2026-09-22: `cat` of this very file blocked, because line 9 of its own header documents the
# shape as `"Password":"<cleartext>"` -- and that is the shape. Anything starting `< [ $ %`
# is a placeholder, a bracket expression or a shell variable, never a credential, and a real
# one is not 3 characters long. Cost of the floor: a genuine <4-char password is missed,
# which is a trade worth making against a gate that cries wolf on its own documentation.
printf '%s' "$resp" | grep -qiE '[\\]*"(Proposed)?Password[\\]*"[[:space:]]*:[[:space:]]*[\\]*"[^"\\<$%[][^"\\]{3,}' && hits="${hits}cleartext password in a JSON body; "
# Credential-named env var as printed by env/printenv/set (2026-10-08, `env | grep CLAUDE`
# dumped claude_*_pw test-user passwords). Same placeholder floor as above, plus `...`,
# null/none/true/false -- docs say `PGPASSWORD=...` and `claude_ui_test_pw=null` and must not block.
# A QUOTED value (`export x_pw="..."`, how ~/.bashrc writes them) arrives JSON-escaped as
# `=\"...`, and the first-character class rejects both `\` and `"` -- so every quoted
# assignment slipped through, as did PASSPHRASE names (2026-10-12: a profile read printed four
# credentials and this gate stayed silent). An optional quote, after any backslashes, now
# precedes the value; the placeholder floor still applies to the first character AFTER it.
# `#` joins the floor: an Octostache `#{token}` in a grepped .conf is a placeholder (2026-11-06).
printf '%s' "$resp" | grep -oE '(^|[^A-Za-z0-9_]|\\[nrt])[A-Za-z_][A-Za-z0-9_]*(_pw|_PW|_pass|_PASS|PASSWORD|password|Password|PASSPHRASE|passphrase|Passphrase|SECRET|secret|TOKEN|token)=([\\]*["'"'"'])?[^#$<[%{(`.*"'"'"'\\[:space:]][^`"'"'"'\\[:space:]]{3,}' \
  | grep -qvE '=([\\]*["'"'"'])?(null|none|None|true|false|set|unset)$' && hits="${hits}credential-named env var (*_pw= / *PASSWORD= / *PASSPHRASE= / *TOKEN= ...); "
# set/unset: a presence-only line (`claude_ui_test_pw=unset`) carries no value (blocked 2026-10-27).
# TSV row `<set>\t<name>-password\t<cleartext>\t<scope>` (Octopus variable dump, missed twice
# 2026-11-06/07): no `=`, no JSON key. Tab real (string response) or `\t` (tojson'd object).
# The match takes the WHOLE name token and up to two following columns, so two non-secrets can
# be told apart (2026-11-17/18, three false positives): a git ref ending in -password in a PR
# listing (`feature/X-admin-password<TAB><sha|title>`; prefix-anchored, so an SSM path
# `/yourproduct/prod/db-password` still fires), and a row the source masked itself (`<hidden>` a column on).
printf '%s' "$resp" | grep -oiE '[^[:space:]"\\]*(pass(word)?|pwd|secret)[A-Za-z0-9_.-]*(	|\\t)[^#$<[%{(`.*"\\[:space:]][^	"\\[:space:]]{3,}((	|\\t)[^	\\]{0,40}){0,2}' \
  | grep -viE '^[^	\\]*(	|\\t)(null|none|true|false|sensitive(=[A-Za-z]+)?|\*+)((	|\\t)|$)' \
  | grep -vE '^(feature|bugfix|hotfix|release|origin|refs)/' \
  | grep -qviE '(	|\\t)<(hidden|sensitive|masked|redacted)[^>]*>' && hits="${hits}credential-named TSV row (<name>-password<TAB><value>); "
[ -n "$hits" ] || exit 0

# Once per shape per session. This is a NOTIFICATION -- "a value of this shape just landed in
# your transcript" -- and re-issuing it on every later call that carries the same shape is
# pure cost: observed twice consecutively in session 738f4262 (2026-09-22) at 25-32s a time,
# after a redaction that correctly found nothing to redact. Nothing the agent can do clears
# the condition, because the value is still in the transcript by definition, so repeating the
# block cannot change the outcome -- it can only burn the turn. A genuinely NEW shape still
# blocks, and a new session starts clean.
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')"
if [ -n "$sid" ] && . "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib-claude-paths.sh" 2>/dev/null; then
  seen="$(hstate secrets "leak-notified-${sid}")"
  key="$(printf '%s' "${hits%; }" | tr -cd 'a-zA-Z ();.-')"
  if [ -f "$seen" ] && grep -qxF "$key" "$seen" 2>/dev/null; then
    exit 0
  fi
  printf '%s\n' "$key" >> "$seen" 2>/dev/null
fi

jq -cn --arg h "${hits%; }" '{decision:"block", reason:("SECRET IN TOOL OUTPUT: " + $h + ". That value is now in this session'"'"'s transcript. Do all three, now, without asking: (1) `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/redact-leaked-secrets.sh` (scrubs transcripts, scratch and the chat-log dirs, by assignment shape AND by the value of every credential-named env var); if the auto-mode classifier denies it as transcript tampering, do NOT work around it -- hand the user the exact line `! bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/redact-leaked-secrets.sh` to run themselves (their shell has the env values); (2) the chat log is a tracked file in a repo -- check `git -C <harness> status` and never commit/push it unredacted; (3) rotation is required only if the value reached somewhere published -- say so in the reply either way. Then stop reading raw output for this API: select the key names only (`.key`), never `.value` -- and in a Secrets Manager JSON the key NAME can itself be the credential (`{AKIA...: <secret>}`), so print `keys|length` or a prefix-masked name there -- and never log request bodies (the Bitbucket-API and UI-verify skills both carry the rule).")}'
