# Claude Harness Lite

A small set of hooks and skills for Claude Code on Windows, sized for a short project such as a
one-day hackathon. It is cut from the full Claude Harness and follows it: a fix to a shared hook
there arrives here with the next sync.

## What you get
- **No approval clicks.** Every shell command and file edit runs without a prompt, and no hook
  ever stops to ask. A session you are not watching keeps working.
- **Guard rails that cost no tokens until they fire.** The checks are shell scripts. A command
  that is fine passes silently. A dangerous one is refused with the fix, and Claude carries on
  by itself.
- **Low token use.** Under 500 words of instructions and skill descriptions per session, six
  skills, and nothing injected on each prompt.
- **Uncommitted work is not thrown away.** `git reset --hard`, a checkout or restore over
  changed files, `git clean`, or deleting a folder that holds changed files is refused until
  the work is committed or stashed, unless you asked for the discard. Resolving a merge
  conflict is not a discard and passes.
- **Secrets hygiene.** Claude is stopped from printing your key file and from writing shell
  traces to disk, and is told to scrub a key that shows up in command output.
- **Several sessions on one repo.** A one-line way to give each session its own worktree. In a
  shared tree a session cannot commit another session's files, sweep the tree with
  `git add -A`, or switch the branch under it. Any session can read what another is working on.
- **Slack and Gmail ready, the rest off.** Both connectors run without a prompt. Every other
  connector is switched off, which takes its tool list out of every session.
- **Its own profile if you want one.** Install it beside the setup you already have, use it
  for a day, and go back by opening a new terminal.
- **Windows shell traps.** Guards for the commands that hang or eat memory in Git Bash, and
  for two that quietly give a wrong answer there: `jq` output with Windows line endings fed
  into another command, and `TZ=<city> date`, which prints UTC.
- **Two sounds.** One tone when a reply is finished, another when a session needs you.

Left out on purpose: session lists, ticket and pull-request workflow, Slack and
mail rules, reminders and monitors, the memory store, machine tooling, the test suite, and any
configuration. The full edition has all of those.

## Requirements
- Windows 10 or 11 with Claude Code installed.
- Git for Windows (Git Bash, which brings perl).
- PowerShell 7 (`pwsh`).
- `jq` on the PATH.
- Developer Mode switched on (Settings > Privacy & security > For developers), or an elevated
  shell, so the installer can create symlinks.
- Python, only if you ever need the secret-scrubbing script.

## Install
Two ways. If `~/.claude` already holds a setup you want back afterwards, use the second.

### Into `~/.claude`
1. Clone this repo somewhere permanent. The install links into the clone, so do not move or
   delete it afterwards.
2. Run the installer from the clone:
   `pwsh -File scripts\install.ps1`
3. Open Claude Code. The hooks and skills load when a session starts.

What the installer does:
- Links `skills`, `hooks`, `scripts`, `CLAUDE.md`, `AGENTS.md` and `README.md` from the Claude
  folder into the clone. **Anything already at those paths is moved to
  `harness-state/settings-backups/` in that folder first**, with a timestamp. That includes
  skills and a `CLAUDE.md` of your own, so copy back what you still want.
- Merges the hook wiring and permission rules into `settings.json` there. Your own settings
  are kept, and the previous file is backed up to the same folder. Hook entries and a status
  line left by another harness, whose files this one does not ship, are dropped. The added
  rules include the two that let Slack and Gmail run unprompted and the ones that switch the
  other connectors off, and they stay when another harness is installed over this one later. So to return to a previous harness exactly, run
  its installer and then copy the backup the installer names back over `settings.json`.
- Adds one line to `~/.bashrc` that loads `~/.secrets`, and creates that file if it is missing.

Running it again is safe: links that are already right are left alone.

### Beside your previous harness (switch for a day, switch back)
Claude Code keeps everything it loads in one folder, `~/.claude` by default, and reads another
folder instead when the environment variable `CLAUDE_CONFIG_DIR` names one. So this harness can
live in a folder of its own. Your previous harness, its settings, skills and sessions are not
touched at any point.

Set up, once:
1. Clone this repo somewhere permanent.
2. Install into a new, empty folder. Any path works; this one is an example:
   `pwsh -File scripts\install.ps1 -ClaudeDir C:\Users\<you>\claude-lite`
3. Start Claude Code with that folder. Write the path with forward slashes.
   - PowerShell: `$env:CLAUDE_CONFIG_DIR = 'C:/Users/<you>/claude-lite'; claude`
   - Git Bash: `CLAUDE_CONFIG_DIR='C:/Users/<you>/claude-lite' claude`
4. Type `/login`. A config folder has its own login, settings, history and sessions, so the
   new one starts logged out. Connectors belong to your account and appear again after login.
5. Type `/mcp`: Slack and Gmail should be listed and connected. If either asks you to sign
   in, do it there.

Use this harness:
- Start Claude Code from a terminal where the variable is set, as in step 3. Every session
  started that way runs this harness: its hooks, its skills, its `CLAUDE.md`.
- Not sure which one a session is running? Type `/memory`: it lists the instruction files the
  session loaded. Here that is the `CLAUDE.md` in the new folder, titled "lite harness".

Switch back to your previous harness:
- Open a new terminal and start `claude` as you always did. Without the variable Claude Code
  reads `~/.claude`, which nothing above changed.
- In PowerShell, in the same window: `Remove-Item Env:CLAUDE_CONFIG_DIR`, then `claude`.
- If you made the variable permanent (a profile script, the Windows environment settings),
  remove it there as well.

Good to know:
- Sessions stay with their folder. To resume one, start Claude Code with the same variable.
- Your keys in `~/.secrets`, your git identity and your SSH keys are shared by both: they live
  in your home folder, not in the Claude folder.
- The installer still adds the `~/.secrets` loader line to `~/.bashrc` if it is missing.
- To remove this harness afterwards, delete the new folder and the clone.

## Credentials
Put API keys in `~/.secrets`, one `export NAME="value"` per line, and read them from the
environment in your code. Keep that file out of every repo. Claude is blocked from printing it.

## Several sessions on one repo
Give every extra session its own worktree from the start: ask Claude to work in a worktree and
it runs the `worktree-add.sh` script from this harness and carries on there.

If two sessions do share one working tree, each can still commit its own files. What is refused
is the part that hurts the other one: committing a file it edited, staging everything with
`git add -A`, switching the branch, or discarding its uncommitted edits.

To see what another session is busy with, ask Claude to peek at it: it runs `session-peek.sh`,
which lists recent sessions and prints the last prompts and replies of the one you name. Name
it by its session id (the first few characters are enough) or by part of its name.

## Permissions
Nothing in this harness asks you to approve a command. The settings allow shell commands and
file edits, a short deny list is refused outright (force-push, piping a download into a shell,
reading `.env`, and similar), and the hooks refuse rather than ask.

A refusal that is a judgement call can be overridden without a click: tell Claude in words to
do it ("yes, discard those changes") and it reruns the command with `USER_SAID_SO=1` in front.

## Connectors
- **Slack and Gmail run without a prompt, sending included.** Nothing here checks what they
  send, so say plainly what you want sent and to whom. To be asked instead, remove
  `mcp__claude_ai_Slack` and `mcp__claude_ai_Gmail` from `permissions.allow` in `settings.json`.
- **Every other connector is off.** Each connector your account has puts its tool list in
  front of Claude in every session, used or not. Measured once, on an account with 26
  connectors: about 5,000 tokens per session with all of them, about 600 with these two. So
  the settings deny the other claude.ai connectors by name (`mcp__claude_ai_<Name>` in
  `permissions.deny`). To use one of them after all, delete its line there.
- A connector that list does not name (a new or less common one) still shows up. Ask Claude to
  run `connectors-only.sh Slack Gmail`: it switches every connector except those two off for
  this Claude folder only. `--list` shows what is on, `--all` switches everything back on.
- A connector that answers "needs you to sign in again": run `/mcp` in Claude Code and sign in.

## Switching a hook off
Delete its line from `hooks/dispatch-pre-bash.manifest` or `hooks/dispatch-post-bash.manifest`,
or remove its entry from `settings.json` in the Claude folder. `AGENTS.md` lists every hook and
what it does.

## Uninstall
Installed beside your previous harness: delete the new folder and the clone.

Installed into `~/.claude`: delete the six links there, remove the hook entries from
`settings.json` (or restore the backed-up file), and move your own files back from
`harness-state/settings-backups/`.
