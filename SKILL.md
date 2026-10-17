---
name: agent-conductor
description: Run several coding agents in parallel, each in its own git worktree and tmux pane, then merge their branches back as a linear history. Use when the user has many small, independent tasks (tests for N endpoints, N pages, N READMEs, fixtures, refactors across separate modules) and wants them parallelized, or says "spawn workers/agents", "run in parallel", "fan out to worktrees", or "launch the grid". Works with any skill-capable agent as the manager. The user picks the worker agent (Antigravity agy, Claude Code, Codex, or any CLI).
---

# agent-conductor

> **Are you a worker?** If the environment variable `CONDUCTOR_WORKER` is set,
> you were started *by* this skill. Do **not** use it. Just do the task you
> were given. (`spawn.sh` refuses to run inside a worker anyway.)

You are the **manager**. You set up the run with the user, split the work, write
one task file per worker, spawn the workers, wait, review short summaries, merge,
and report. Workers do the coding. Each worker = one task = one worktree
(`.conductor/worktrees/<id>`) = one branch (`conductor/<id>`) = one tmux pane
in the session `conductor-<repo>`.

`$SKILL_DIR` below means the directory that contains this `SKILL.md`. Run every
script from inside the target repo (any subdirectory works). Requires `git`,
`tmux` and `bash`.

## 0. Setup dialog (the user chooses, never you)

Workers spend the user's quota for whichever agent runs them, so the user
chooses the agent. There is no default.

1. Run `$SKILL_DIR/scripts/configure.sh show`.
   - **Exit 0 (config exists):** ask one question: "Use the saved settings
     (`AGENT=…`, `MODEL=…`, `TEST_CMD=…`, `MAX_WORKERS=…`)?", with the options
     *Keep* / *Change*. On *Keep*, go to step 1 of the workflow.
   - **Exit 3 (no config), or the user chose *Change*:** continue below.
2. Run `$SKILL_DIR/scripts/configure.sh detect` and `$SKILL_DIR/scripts/configure.sh suggest`.
3. Ask the user, all in **one** dialog:
   - **Worker agent.** Options: every row with `STATUS ok`, in the printed
     order, plus *Custom command*. Don't mark any option as recommended and
     don't favour the agent you are running in. Mention `no-auth` agents in the
     question text, with their login hint. If **no** agent is `ok`, show the
     hints and stop. If exactly one is `ok`, name it and ask for a yes/no
     confirmation instead.
   - **Model.** *Agent default*, or a model name the user types.
   - **Tests.** The suggested `TEST_CMD` + `SETUP_CMD` from `suggest`, *No tests*,
     or a command the user types. A fresh worktree has no installed dependencies,
     so a test command usually needs a setup command.
   - **Parallel workers.** *2* / *4* / *6*.

   If your harness has a structured multiple-choice question tool, use it.
   Otherwise ask in plain text with numbered options.
4. Save the answers (empty value = unset):
   ```bash
   $SKILL_DIR/scripts/configure.sh set AGENT=<agent> MODEL=<model> TEST_CMD=<cmd> SETUP_CMD=<cmd> MAX_WORKERS=<n>
   ```
   For *Custom command*: `AGENT=custom AGENT_CMD=<cmd>`. The command is eval'd in
   the worktree with the prompt on stdin.

## Workflow (autonomous after setup: don't ask about every step)

1. **Split.** Read `$SKILL_DIR/references/task-splitting.md` first. Write one
   task file per worker to `.conductor/tasks/<NNN>-<slug>.md`, using a template
   from that file. The task's first `# H1` becomes the commit subject. Ask the
   user **only** when the definition of done is ambiguous or needs an
   architectural decision.

2. **Spawn** each task:
   ```bash
   $SKILL_DIR/scripts/spawn.sh .conductor/tasks/001-foo.md
   ```
   It returns immediately. The settings come from the config; flags override
   them for one task (`--agent`, `--model`, `--test`, `--setup`, `--timeout`,
   `--base`). Exit codes:
   - `5`: `MAX_WORKERS` are already running. Run `status.sh --wait-slot`, then spawn again.
   - `6`: no agent configured. Do the setup dialog.
   - `7`: the agent is not installed or not logged in. Tell the user the printed hint.
   - `8`: you are inside a worker. Stop.

3. **Wait.** Make one blocking call rather than polling in a loop:
   ```bash
   $SKILL_DIR/scripts/status.sh --wait --timeout 540
   ```
   Keep `--timeout` below your shell tool's own command timeout. Exit `124` means
   workers are still running, so call it again. Give up after about 3 rounds
   without progress.

4. **Review (save tokens).** Read only:
   - `status.sh`: the table with STATUS, DIFF, and the `LARGE` and `DEAD` flags.
   - `status.sh <id>`: the worker's ~15-line summary.
   - `.conductor/workers/<id>/agent.log`: **only** for a failure status. Read it with `tail -50`, never the whole file.
   - The actual diff (`git diff <base>..conductor/<id>`): only when a summary looks
     suspicious or the worker is flagged `LARGE`.

5. **Merge.**
   ```bash
   $SKILL_DIR/scripts/merge.sh --all --dry-run   # preview
   $SKILL_DIR/scripts/merge.sh --all             # cherry-pick every "done" worker
   ```
   - A worker flagged `LARGE` (more than 100 inserted lines): show the user its
     summary and wait for approval before merging it (`merge.sh <id>`).
   - **Exit 4 = conflict.** Stop being autonomous: show the user the conflicting
     files and ask how to proceed.
   - Dependent tasks run in waves: merge wave 1, then spawn wave 2.

6. **Retry failures**, at most once per task. Fix the task file (clearer
   definition of done, narrower scope), run `cleanup.sh <id>`, then spawn again.

7. **Push.** **Always ask the user before `git push`.** Never push on your own.

8. **Clean up.** `$SKILL_DIR/scripts/cleanup.sh --all`. It refuses to delete
   running workers and unmerged commits unless you pass `--force`. Only use
   `--force` after the user agrees to discard that work.

9. **Report.** At most 10 lines: tasks done, merged, needing review, and
   failed (with a one-line reason each).

## Statuses

| Status | Meaning | Action |
|---|---|---|
| `running` | Agent is working | wait |
| `done` | Committed on `conductor/<id>` | merge |
| `no-changes` | Agent changed nothing | check the summary; usually the task is unclear or already done (expected for research tasks) |
| `setup-fail` | `SETUP_CMD` failed | `tail` the log; fix the setup command |
| `agent-fail` | Agent exited non-zero | `tail` the log, then fix the task or check the agent's login/quota |
| `timeout` | Agent exceeded `TIMEOUT` (default 20m) | split the task, or raise `--timeout` |
| `test-fail` | Test command failed; worktree kept as-is | inspect in the worktree, then retry |
| `commit-fail` | `git commit` failed (hooks?) | `tail` the log |
| `failed` | Worker was interrupted or killed | retry |
| `dead` | Shown as `running`, but the process is gone | cleanup, then retry |
| `merged` | Cherry-picked by `merge.sh` | nothing left to do |

## Configuration

Precedence: flag > the task's `## Test command` section > env > `.conductor/config`.

| Config key | Flag / env | Meaning |
|---|---|---|
| `AGENT` | `--agent` / `CONDUCTOR_AGENT` | `agy`, `claude`, `codex` or `custom`; no default |
| `AGENT_CMD` | `CONDUCTOR_AGENT_CMD` | command for `custom` (setting the env var alone implies custom) |
| `MODEL` | `--model` / `CONDUCTOR_MODEL` | passed to the agent's model flag |
| `SETUP_CMD` | `--setup` / `CONDUCTOR_SETUP_CMD` | runs in the fresh worktree before the agent; whatever it leaves untracked is never committed |
| `TEST_CMD` | `--test` / `CONDUCTOR_TEST_CMD` | runs after the agent; a non-zero exit gives `test-fail` |
| `MAX_WORKERS` | `CONDUCTOR_MAX_WORKERS` | workers running at once (default 4) |
| `TIMEOUT` | `--timeout` / `CONDUCTOR_TIMEOUT` | time limit per agent run (default `20m`) |
| — | `LARGE_DIFF_LINES` | threshold for the `LARGE` flag (default 100) |

Setup, test and agent commands can use `$CONDUCTOR_REPO_ROOT` and `$CONDUCTOR_WORKTREE`.

Problems: `$SKILL_DIR/references/troubleshooting.md`.
