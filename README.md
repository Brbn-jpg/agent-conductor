# agent-conductor

> **An agent skill: run N coding agents in parallel, one git worktree and one tmux pane each. Bash + tmux + git. No frameworks.**

Any agent that loads skills can be the **manager**: Claude Code, Codex,
Antigravity CLI, and others. The manager splits a big job into small
independent tasks and spawns one worker per task. Each worker gets its own
worktree (`.conductor/worktrees/<id>`), its own branch (`conductor/<id>`), and its
own pane in the tmux session `conductor-<repo>`. When workers finish, the
manager reads 15-line summaries instead of full logs and cherry-picks the good
branches back as a linear history. It always asks before it pushes.

**You choose the worker agent.** There's no default. On the first run the
manager detects which agents are installed and logged in, then asks you: which
agent, which model, which test/setup commands, and how many workers at once.
It saves your answers in `.conductor/config`, and next time it only asks whether to keep them.

| Worker preset | Headless invocation |
|---|---|
| `agy` ([Antigravity CLI](https://antigravity.google/docs/cli/headless/)) | `agy --print … --add-dir <worktree> --dangerously-skip-permissions` |
| `claude` (Claude Code) | `claude -p … --dangerously-skip-permissions` |
| `codex` (Codex CLI) | `codex exec --dangerously-bypass-approvals-and-sandbox -C <worktree> -` |
| `custom` | any command; the prompt arrives on stdin |

The manager and the workers can be different agents, e.g. Claude Code
managing `agy` workers, or the other way round.

```
          manager (any skill-capable agent)
                         |
     setup dialog -> .conductor/config (agent, model, tests, N)
                         |
        writes .conductor/tasks/001-*.md, 002-*.md, ...
                         |
        spawn.sh ×N ------------------------------.
          |                    |                   |
   worktree + pane       worktree + pane     worktree + pane
   setup -> agent -> test -> commit (conductor/<id>)
          \____________________|___________________/
                               |
                 status.sh --wait  ->  summaries
                               |
                 merge.sh --all  (cherry-pick, linear)
                               |
                 cleanup.sh --all
```

## Install

Clone once into the shared skills directory, then link it into each agent's
skills directory:

```bash
git clone https://github.com/Brbn-jpg/agent-conductor.git ~/.agents/skills/agent-conductor

ln -s ../../.agents/skills/agent-conductor ~/.claude/skills/agent-conductor                      # Claude Code
ln -s ~/.agents/skills/agent-conductor ~/.codex/skills/agent-conductor                           # Codex
ln -s ~/.agents/skills/agent-conductor ~/.gemini/antigravity-cli/skills/agent-conductor          # Antigravity CLI
```

Restart the agent. The skill loads when you ask for parallel work, for example
*"write tests for these 6 endpoints in parallel"* or *"spawn workers for this"*.

### Requirements

- `git`, `tmux`, `bash` (3.2+ works, so stock macOS is fine)
- at least one worker agent, installed and logged in. Check with `scripts/configure.sh detect`.
  `agy` needs **one interactive sign-in**: headless mode uses cached credentials only.

## Scripts

All scripts run from anywhere inside the target repo.

| Script | What it does |
|---|---|
| `scripts/configure.sh` | Backend for the setup dialog: `detect` (which agents are ready), `suggest` (test/setup commands for this repo), `show`, `set KEY=VALUE…`, `unset`. |
| `scripts/spawn.sh <task.md>` | Creates the worktree and branch `conductor/<id>`, opens a tmux pane, and runs setup, agent, test and commit. Returns immediately. |
| `scripts/status.sh` | Table of workers: status, time, commit, diff, `LARGE`/`DEAD` flags. `status.sh <id>` shows a worker's summary. `--wait` / `--wait-slot` block until workers finish or a slot frees up. |
| `scripts/merge.sh --all` | Cherry-picks every `done` worker onto the current branch (1 task = 1 commit) and removes its worktree, branch and pane. Stops with exit 4 on a conflict. |
| `scripts/cleanup.sh --all` | Removes panes, worktrees, branches and state. Refuses to drop running workers or unmerged commits unless you pass `--force`. |

Using it by hand works the same as when the manager does it:

```bash
S=~/.agents/skills/agent-conductor/scripts
$S/configure.sh detect
$S/configure.sh set AGENT=agy TEST_CMD="npm test" SETUP_CMD="npm ci" MAX_WORKERS=4
mkdir -p .conductor/tasks && $EDITOR .conductor/tasks/001-add-foo.md   # template: references/task-splitting.md
$S/spawn.sh .conductor/tasks/001-add-foo.md
$S/status.sh --wait
$S/merge.sh --all
$S/cleanup.sh --all
```

## Configuration

Precedence: flag > the task's `## Test command` section > env > `.conductor/config`.

| Config key | Flag / env | Default | Meaning |
|---|---|---|---|
| `AGENT` | `--agent` / `CONDUCTOR_AGENT` | **none** | `agy`, `claude`, `codex`, `custom` |
| `AGENT_CMD` | `CONDUCTOR_AGENT_CMD` | — | command for `custom`, eval'd with the prompt on stdin |
| `MODEL` | `--model` / `CONDUCTOR_MODEL` | agent default | passed to the agent |
| `SETUP_CMD` | `--setup` / `CONDUCTOR_SETUP_CMD` | — | runs in the fresh worktree before the agent (installs deps); its untracked output is never committed |
| `TEST_CMD` | `--test` / `CONDUCTOR_TEST_CMD` | — | runs after the agent; a failure gives `test-fail` |
| `MAX_WORKERS` | `CONDUCTOR_MAX_WORKERS` | `4` | workers running at once (`spawn.sh` exits 5 beyond that) |
| `TIMEOUT` | `--timeout` / `CONDUCTOR_TIMEOUT` | `20m` | time limit per agent run; the process tree is killed when it's exceeded |
| — | `LARGE_DIFF_LINES` | `100` | threshold for the `LARGE` flag |

## How it stays safe

| Mechanism | What it solves |
|---|---|
| **Worktree per worker** | Agents never share a working tree, so there's no race on `git add -A`. |
| **Branch per task** | Every result is isolated. Merge what's good, drop the rest. |
| **Script commits, not the agent** | The commit subject is the task's `# H1`, plus a `Conductor-Task: <id>` trailer (`git log --grep Conductor-Task`). |
| **Explicit agent choice + login check** | No surprise spending on an agent you didn't pick. A missing login fails fast (exit 7) instead of N failing workers. |
| **Recursion guard** | Workers run with `CONDUCTOR_WORKER=1`, and `spawn.sh` refuses to run inside them. `agy`/`claude` workers also can't load skills. |
| **Timeouts + process-group stop** | Hung agents get killed. `merge`/`cleanup` kill the whole process group, not just the pane. |
| **Atomic status files** | `status` is written via tmp+mv. A `running` status whose process died shows as `DEAD`. |
| **Git-excluded state** | `.conductor/` goes into `.git/info/exclude`, so your `.gitignore` stays untouched. |
| **Cherry-pick, stop on conflict** | Linear history. The first conflict halts with exit 4 and nothing else is touched. |

## Layout

```
SKILL.md                      manager instructions (loaded by the agent)
scripts/                      configure.sh, spawn.sh, status.sh, merge.sh, cleanup.sh, _lib.sh
references/task-splitting.md  how to split work + task templates
references/troubleshooting.md
tests/smoke.sh                end-to-end test with a fake agent (no LLM)

<target repo>/.conductor/     runtime state (git-excluded)
  config                      saved setup answers (KEY=VALUE)
  tasks/                      task files written by the manager
  workers/<id>/               task.md, env, status, pgid, agent.log, summary.md
  worktrees/<id>/             the worker's git worktree
```

## tmux cheatsheet

```bash
tmux attach -t conductor-<repo>   # watch workers live
#   Ctrl-b d   detach    Ctrl-b z   zoom pane    Ctrl-b w   pick window
```

Upgrading from claude-conductor v0.x (`launch-grid.sh`, gemini-cli)? See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Jakub Kuźnicki
