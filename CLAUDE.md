# Claude Code defaults (lite harness)

Small harness for short projects. What it installs and why: `AGENTS.md`, next to this file.

## How to work
- Terse replies: no preamble, no filler, fragments fine. Full sentences when explaining something, and for anything the user must act on.
- Simplest thing that works. No speculative features, abstractions or error handling. Change only what the task needs; match the existing style.
- State assumptions. A request with two readings: ask once, then go.
- Before saying "done", run it and look at the real output. Report what you saw, failures included.
- Commit small and often. Never commit secrets (`.env`, keys, tokens); read them from the environment.

## Tokens
- Do the work yourself unless it is parallel or would flood the context. Give every subagent a word cap for its report.
- New unrelated task, or a long session at a clean checkpoint: suggest `/clear <name>` or `/compact`. You cannot run them yourself.

## Hooks refuse, they never ask
- A hook refused a command: read its reason and do what it says; never retry it unchanged.
- `USER_SAID_SO=1` in front of a command passes a refusal, only when the user asked for exactly that in words.
- Slack and Gmail send without a prompt: send only what the user asked to send.

## Several sessions on one repo
- Second session on a repo: work in your own worktree, `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/worktree-add.sh <repo-path> <slug> <branch>`.
- Commit your own paths only: `git commit -m "..." -- <paths>`. Never `git add -A`.
- What another session is doing: `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/session-peek.sh` lists them; add an id or part of a name for its last exchanges.

## Shell (Windows + Git Bash)
- Pass paths as arguments instead of `cd`. Prefer the Read, Grep and Glob tools over shell commands.
- Odd, empty or garbled command output: `bash-command-correctness` skill.
