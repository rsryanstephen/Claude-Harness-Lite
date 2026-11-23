# Lite harness: what is installed

Agent reference for the lite edition (humans: `README.md`). It is cut from the full generic
harness; anything not named here is not installed, so a hook message that points at a file you
cannot find refers to the full edition.

## Two rules of this edition
- **Nothing waits for a click.** The installed settings run every shell command and file edit
  without a prompt, and no hook asks. A session nobody is watching keeps going.
- **Nothing warns.** A check passes silently, or it refuses and names the fix; then carry on
  alone. A refusal that is a judgement call (a discard, a commit over another session's file, a
  branch switch under it) passes with `USER_SAID_SO=1` in front of the command -- only when
  the user asked for exactly that, in words. In PowerShell: `$env:USER_SAID_SO=1; <command>`.

## Where it lives
The Claude folder is `$CLAUDE_CONFIG_DIR` when the session was started with that variable (this
harness installed beside another one, in a profile of its own), else `~/.claude`. Below,
`~/.claude/...` means that folder. Hooks, state, scratch and session transcripts all resolve
there, so two profiles never share claims or state.

## How hooks run
- `settings.json` in the Claude folder starts each hook through `hooks/hook-run.sh`.
- Shell calls (Bash, PowerShell) go through one dispatcher each way: `hooks/dispatch.sh` with
  `hooks/dispatch-pre-bash.manifest` and `hooks/dispatch-post-bash.manifest`. It starts only the
  gates whose trigger text appears in the command. A gate that overruns its time limit is
  skipped and says so in the tool result.
- State: `~/.claude/harness-state/`. Scratch: `~/.claude/scratch/`.

## Hooks
| Hook | Fires | Effect |
|---|---|---|
| `bash-trace-leak-gate.sh` | before a shell call | Refuses `bash -x` / `set -x` with stderr sent to a file: a trace prints secrets. |
| `dotfile-secret-print-gate.sh` | before Read, Grep, shell | Refuses printing `~/.secrets` or a profile file that holds key exports. |
| `output-secret-leak-gate.sh` | after a shell call | A key or cleartext password showed up in output: run `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/redact-leaked-secrets.sh` at once (needs Python), do not ask first. |
| `inplace-edit-gate.sh` | before a shell call | Refuses `sed -i`, `perl -i`, `mv`, `rm` on a linked `~/.claude` path: they replace the link with a real file. Use Edit. |
| `symlink-write-gate.sh` | before Edit, Write | Rewrites a write to a linked `~/.claude` path so it lands on the real file in the clone. |
| `worktree-junction-remove-gate.sh` | before a shell call | Refuses `git worktree remove` while the tree still holds a junction or symlink: the removal would follow it. |
| `discard-uncommitted-gate.sh` | before a shell call | Refuses a command that would throw away uncommitted work: `git reset --hard`, `git checkout` or `git restore` over changed paths, `git clean -f`, a forced worktree removal, `rm` or `Remove-Item` of a path holding changed tracked files. `git stash`, and `rm` of untracked files, only when another session edited those files. Lists what is at stake. Silent when nothing would be lost, and when a merge conflict is being resolved (`git checkout --ours <file>`). Passes with `USER_SAID_SO=1`. |
| `cross-session-repo-claim.sh` | before and after git calls | Records the branch each session last acted on. Refuses: a commit that takes a file another live session edited (a commit that names only your own paths passes); a branch switch in a clone another live session is working in; a commit or push after the branch moved under this session. Passes with `USER_SAID_SO=1`. |
| `file-claim-record.sh` | before Edit, Write | Records which session edited which file. Silent. |
| `foreign-worktree-changes-gate.sh` | before a shell call | Refuses `git add -A`, `git add .` or a commit with no pathspec while another live session works in the clone and tracked files are modified. Name your own paths. Passes with `USER_SAID_SO=1`. |
| `git-commit-scope-gate.sh` | before a shell call | Refuses `git add <files> && git commit` with no pathspec: a commit takes the whole index. Use `git commit -m "..." -- <paths>`. |
| `grep-memory-gate.sh` | before a shell call | Refuses a recursive grep without `-I`. See the `grep-usage` skill. |
| `substitution-stdin-hang-gate.sh` | before a shell call | Refuses a filter whose only file operands come from an unquoted `$(...)`: an empty result makes it wait on stdin forever. |
| `short-path-gate.sh` | before a shell call | Refuses a path with an 8.3 short-name segment (`NAME~1`). Use the long path. |
| `msys-command-traps-nudge.sh` | before a Bash call | Refuses two Git Bash traps that give a wrong answer with no error: raw `jq` output piped into `jq` or a `while read` loop with no `tr -d '\r'` or `-b` (Windows jq writes CRLF), and `TZ=<Area/City> date` (prints UTC). Passes with `USER_SAID_SO=1`. |
| `subagent-model-tiering-gate.sh` | before an Agent call | Refuses a subagent call whose prompt has no word cap for the report. Add one and send it again. |
| `notify-sound.sh` | Stop, Notification | Plays one tone when a reply is finished and another when the session needs the user. |

Also in force: the deny list in `settings.json` (force-push, `curl | sh`, reading `.env`, and
similar).

## Connectors
- Slack and Gmail tools are allowed, whole connector, sending included
  (`mcp__claude_ai_Slack`, `mcp__claude_ai_Gmail` in `permissions.allow`). No hook checks what
  goes out: send only what the user asked to send.
- Every other known claude.ai connector is denied in `permissions.deny`
  (`mcp__claude_ai_<Name>`): its tools are not in the session. To use one, the user removes its
  line there.
- A connector not on that list: `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/connectors-only.sh Slack Gmail` switches
  it off for this Claude folder (`deniedMcpServers` in `settings.json`; new sessions only).
  `--list` shows on/off, `--all` switches all back on.
- "needs you to sign in again" from a connector: the user runs `/mcp` and signs in.

## Several sessions on one repo
- Claims: `~/.claude/harness-state/sessions/.repo-claims` (repo, session, branch, time; one row
  per session) and `.file-claims` (file, session, time). A session counts as live while its
  transcript is still being written.
- Own worktree: `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/worktree-add.sh <repo-path> <slug> <branch> [base]`
  creates `<parent>/.worktrees/<repo>-<slug>` and prints its path. Remove it with
  `git worktree remove` once the branch is merged.
- What another session is doing: `bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/session-peek.sh` lists recent sessions;
  `session-peek.sh <id or part of its name> [n]` prints its last n prompts and replies, read
  from Claude Code's own transcript.

## Skills
`karpathy-guidelines`, `caveman`, `verify`, `grill-me`, `grep-usage`, `bash-command-correctness`.

## Switching a hook off
Delete its line from the dispatch manifest, or its entry in the Claude folder's `settings.json`.
Re-running `scripts/install.ps1` (with the same `-ClaudeDir`, if one was used) puts settings
entries back.

## Known limits
- `USER_SAID_SO=1` is on your honour: no hook can check what the user said.
- Two sessions may share one working tree without being told. Nothing happens until one of
  them commits the other's file, sweeps the tree, switches branch or discards; those are refused.
- The discard guard reads the command text. It does not see a discard inside a script file or
  `bash -c "..."`, `find -delete`, or a file overwritten through an editor tool.
- `hook-run.sh` and `dispatch.sh` keep small per-process files in `~/.claude/scratch/hook-run/`
  and nothing prunes them in this edition. Delete the folder whenever no session is running.
- No commit-time secret scan: the gates above watch command output and file prints only.
