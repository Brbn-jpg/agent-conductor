# Troubleshooting

Look at the worker first: `status.sh <id>`, then `tail -50 .conductor/workers/<id>/agent.log`.
To watch it live: `tmux attach -t conductor-<repo>` (detach with `Ctrl-b d`).

## Choosing and checking the agent

**`spawn.sh` exits 6: "no worker agent chosen"**
There's no default on purpose. Run the setup dialog from `SKILL.md`, then
`configure.sh set AGENT=<agent>`. For a one-off run, use `--agent <agent>`.

**`spawn.sh` exits 7: not installed / not logged in**
`configure.sh detect` shows every preset with a login hint:
- `agy`: run `agy` once interactively and sign in. Headless mode uses cached
  credentials only, and there's no API-key login yet
  (google-antigravity/antigravity-cli#78), so CI without a cached login won't work.
- `claude`: `claude auth login`.
- `codex`: `codex login`.

The check costs no model call: `agy models`, `claude auth status`,
`codex login status`. It runs once and is cached for 10 minutes
(`.conductor/.auth-ok-<agent>`).

**`detect` says `ok`, but every worker ends `agent-fail`**
The login check only proves the agent is logged in, not that the account can
run models. Look at the log tail for HTTP 401/402/429. Example: codex with
`402 Payment Required` / `deactivated_workspace` means the ChatGPT workspace is
inactive. Fix the account, or pick a different agent (`configure.sh set AGENT=…`).

**Unknown model**
The agent exits non-zero, so the worker ends `agent-fail`. List the valid names:
`agy models`, the `claude --model` aliases (`haiku`, `sonnet`, `opus`), the
models in your codex config.

**Another CLI**
Use `configure.sh set AGENT=custom AGENT_CMD='my-agent --yes --prompt "$(cat)"'`.
The command is eval'd in the worktree with the prompt on stdin, and exit code 0
counts as success. It is saved per worker at spawn time, so changing it later
doesn't affect running workers.

**Org policy forbids bypass/yolo modes**
The presets run fully unattended: `agy --dangerously-skip-permissions`,
`claude --dangerously-skip-permissions`,
`codex exec --dangerously-bypass-approvals-and-sandbox`. If that's not allowed,
use `AGENT=custom` with your own flags, e.g.
`AGENT_CMD='claude -p "$(cat)" --permission-mode acceptEdits'`.

## Agent behaviour

**agy says it created files but the worker ends `no-changes`**
agy wrote outside the worktree, usually into `~/.gemini/antigravity-cli/scratch/`.
`spawn.sh` passes `--add-dir <worktree>` and the absolute workspace path in the
prompt to prevent this. If it still happens, put explicit relative paths in the
task's `## Files to modify` and retry.

**`timeout`**
The agent ran longer than `TIMEOUT` (default 20m) and its process tree was
killed. Split the task, or use `--timeout 45m` / `configure.sh set TIMEOUT=45m`.

**A worker tried to start workers**
Workers run with `CONDUCTOR_WORKER=1`, and `spawn.sh` exits 8 there. `agy` and
`claude` workers also get `--disable-slash-commands`, so they can't load skills.
If a custom agent loops on this, tell it so in the task file.

## Setup and tests

**`setup-fail`**
`SETUP_CMD` exited non-zero before the agent started, so no agent time was spent.
Typical fixes: `npm ci` needs `package-lock.json` in git; `uv sync` needs `uv`
on the `PATH` that `spawn.sh` was called with.

**Setup is slow with many workers**
Every worktree installs its own dependencies. Options: a package manager with a
shared store (`pnpm install --frozen-lockfile`, `uv sync`), a lower `MAX_WORKERS`,
or a cheaper `SETUP_CMD` that reuses the main checkout, e.g.
`cp -Rc "$CONDUCTOR_REPO_ROOT/node_modules" .` (APFS clone on macOS). Don't
symlink `node_modules`: a symlink can slip past a `node_modules/` gitignore rule.
Untracked files that setup creates are never committed anyway.

**`test-fail`**
The worktree is left exactly as the agent left it, uncommitted:
`cd .conductor/worktrees/<id> && git status && <test cmd>`. Fix the task, then run
`cleanup.sh <id>` and spawn again. To skip tests for one task, put `none` in the
task's `## Test command` section.

**`commit-fail`**
Usually a pre-commit hook. The hook output is at the end of `agent.log`.

## Worker state

**`dead` in status**
The status still says `running`, but the worker process is gone (kill -9, crash,
reboot). Nothing will finish it. Run `cleanup.sh <id>` and spawn it again.

**`spawn.sh` exits 5: `MAX_WORKERS` reached**
Run `status.sh --wait-slot`, then spawn the next task. Raise the limit with
`configure.sh set MAX_WORKERS=6`.

**`branch conductor/<id> already exists` / `worker '<id>' already exists`**
There's a leftover from a previous run. If it was merged or is junk: `cleanup.sh <id>`.
If it has unmerged commits you want to keep: `merge.sh <id>` first. Otherwise spawn
with a different `--id`.

## Merge

**`merge.sh` exits 4 (conflict)**
Two tasks touched the same lines, which means the split violated disjoint
ownership. Options:
- resolve: `git status`, edit the files, `git add`, `git cherry-pick --continue`.
  Then `cleanup.sh <id> --force`: the branch's commit is now in HEAD under a
  different patch, so cleanup without `--force` would refuse.
- abort: `git cherry-pick --abort`. Then `cleanup.sh <id> --force` and re-spawn
  that task from the updated base (the agent sees the other task's changes).
Then `merge.sh --all` again for the rest.

**`working tree ... is not clean`**
`merge.sh` cherry-picks into the main checkout. Commit or stash your own edits
first (`.conductor/` itself is excluded and never counts).

**`current branch is a worker branch`**
Check out the target branch in the main repo (`git checkout main`).

## tmux

**Panes are tiny / a worker opened in a new window**
`spawn.sh` splits the `workers` window and falls back to a new window once
there's no room left. Everything still works. Browse with `Ctrl-b n` / `Ctrl-b w`.

**Session gone but workers listed**
Killing the session or panes by hand doesn't stop the agents. `cleanup.sh`
stops each worker's process group. Workers whose process died show up as
`dead`.

## Manual reset (last resort)

```bash
tmux kill-session -t conductor-<repo>
git worktree list | awk '/\.conductor\/worktrees\// {print $1}' | xargs -n1 git worktree remove --force
git branch --format='%(refname:short)' | grep '^conductor/' | xargs git branch -D
rm -rf .conductor/workers .conductor/worktrees
git worktree prune
```
