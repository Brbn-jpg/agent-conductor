# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), versioning: [SemVer](https://semver.org/).

## [1.0.0] — 2026-10-17

**claude-conductor becomes agent-conductor:** an agent skill that any skill-capable agent (Claude Code, Codex, Antigravity CLI, …) can run as the manager. The user chooses the worker agent. gemini-cli stopped serving individual accounts on 2026-06-18, so v0.x workers no longer run.

### Breaking

- **Install as a skill:** clone into `~/.agents/skills/agent-conductor` and symlink it into each agent's skills directory. The manager instructions moved from `CLAUDE.md` to `SKILL.md`.
- **Spawn per task instead of a queue:** the manager calls `spawn.sh` once per task. There is no `.tasks/todo` queue, no mkdir locks and no `in_progress/`.
- **No default worker agent.** A setup dialog (backed by `configure.sh`) asks the user for the agent, model, test/setup commands and parallelism, and saves the answers in `.conductor/config`. Presets: `agy`, `claude`, `codex`; any other CLI via `AGENT=custom` + `AGENT_CMD`.
- **Runtime state** lives in `<target repo>/.conductor/` (auto-added to `.git/info/exclude`). Branches are `conductor/<id>` instead of `ai-grid/<task>`. The commit trailer is `Conductor-Task: <id>` instead of `AI-Grid: <task>`.
- Env vars are namespaced: `CONDUCTOR_TEST_CMD` instead of `TEST_CMD`.
- Scripts run against the repo you're in, not the repo they live in.

### Script map

| v0.x | v1.0 |
|---|---|
| `launch-grid.sh` + `worker-agent.sh` | `scripts/spawn.sh` |
| `status.sh` | `scripts/status.sh` (+ `--wait`, `--wait-slot`, `<id>`, `DEAD` detection) |
| `integrate.sh` | `scripts/merge.sh` (merges only `done` workers) |
| manual worktree/branch removal | `scripts/cleanup.sh` (refuses unmerged work without `--force`) |
| `run_ai()` edits | `scripts/configure.sh` + `.conductor/config` |
| `.tasks/_template*.md` | `references/task-splitting.md` |

### Added

- `configure.sh detect` checks every preset's login without a model call (`agy models`, `claude auth status`, `codex login status`). `spawn.sh` runs the same check (cached 10 min) and fails fast with exit 7 and a login hint.
- `SETUP_CMD` runs in each fresh worktree before the agent (installs deps). Untracked files it creates are never committed. `configure.sh suggest` proposes test/setup commands from `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml` or `Makefile`.
- A per-task `## Test command` section overrides `TEST_CMD`; `none` skips tests for that task.
- `TIMEOUT` applies to every agent (default 20m). A hung agent's process tree is killed and the worker ends with the new status `timeout`.
- `MAX_WORKERS` is enforced: `spawn.sh` exits 5 beyond the limit, and `status.sh --wait-slot` waits for a free slot.
- Recursion guard: workers run with `CONDUCTOR_WORKER=1`, `spawn.sh` exits 8 inside a worker, and `agy`/`claude` workers get `--disable-slash-commands`.
- Worker statuses: `running`, `done`, `no-changes`, `setup-fail`, `agent-fail`, `timeout`, `test-fail`, `commit-fail`, `failed`, `dead`, `merged`.
- Process-group stop: killing a pane doesn't stop the agent, so `merge.sh` and `cleanup.sh` kill the worker's process group.
- `references/troubleshooting.md`.

### Removed

- `launch-grid.sh`, `worker-agent.sh`, `integrate.sh`, root `status.sh`, `.tasks/`, `.agent-locks/`, `.agent-logs/`, `demo/`. They are still available at tag `v0.4.1`.

## [0.4.1] — 2026-05-21

Project translated to English. All docs (README, CHANGELOG, CLAUDE.md), shell script comments, log messages, templates, and output strings are now in English. Behavior is unchanged.

### Changed

- **All scripts** — comments, log messages, error output, and help text translated. `extract_commit_subject` in `worker-agent.sh` also recognizes the new English template placeholders as fallback markers.
- **All docs** — README.md, CHANGELOG.md, CLAUDE.md translated.
- **Both templates** — `.tasks/_template.md` and `.tasks/_template-research.md` translated, default placeholders are now `<Short feature description — ...>` and `<short topic description — ...>`.

### Note for existing users

Tasks already in `todo/` with Polish placeholders still work — the worker's fallback in `extract_commit_subject` accepts both the old and new placeholders. New tasks should follow the English template.

## [0.4.0] — 2026-05-20

Feature-named commits. The worker now reads the H1 from the task file and uses it as the commit subject instead of the generic `[AI-Grid] Zrobiono task-XXX.md`. The audit tag moves to an `AI-Grid: <task-name>` trailer in the commit body — `git log --oneline` is clean, `git log --grep="AI-Grid:"` still finds all AI commits.

### Changed

- **`worker-agent.sh`** — new `extract_commit_subject` function parses the first `# H1` from the task file. Template placeholders are ignored and replaced with the filename slug. Commit message: `<H1>\n\nAI-Grid: <task-name>`.
- **`.tasks/_template.md`** — hint above the H1: "THIS becomes the commit message" plus examples (`Add electrician job page`, `Refactor auth middleware`).
- **`.tasks/_template-research.md`** — same: H1 = subject.

### Migration

Old commits with `[AI-Grid] Zrobiono task-XXX.md` remain as-is (history unchanged). New tasks automatically use the new format — just write a readable H1 in the task file.

### Before / After

```
BEFORE:                                       AFTER:
[AI-Grid] Zrobiono task-101-job-electrician   Add electrician job page
[AI-Grid] Zrobiono task-102-job-economist     Add economist job page
[AI-Grid] Zrobiono task-110-org-drugs         Hide drugs section for non-orgs
```

## [0.3.0] — 2026-05-20

Linear-history integration. With 14 workers the default `git merge --no-ff` produced spaghetti (28 commits + 14 parallel rails for 14 tasks). The new `integrate.sh` uses cherry-pick: each task -> one commit on main, no merge commits, with automatic worktree and branch cleanup.

### Added

- **`integrate.sh`** — cherry-picks `ai-grid/*` branches onto the current branch. Modes: single branch, `--all`, `--dry-run`, `--keep-branch`. Sanity-checks the working tree before starting; STOPS with a clear message on conflict (exit code 4), leaving remaining branches untouched. After success, removes the worker's worktree + the `ai-grid/<task>` branch.

### Changed

- **`CLAUDE.md`** — "Integration" section in "Autonomous mode": the manager uses `./integrate.sh --all` instead of `git merge --no-ff`. On conflict — break out of autonomy and ask the user.
- **`README.md`** — quickstart shows `./integrate.sh --all`, the "Cleanup" section notes that integrate.sh handles this automatically.

### Why

`git merge --no-ff` preserves "this was on a separate branch" — but in our workflow each branch has exactly 1 commit (the worker commits once), so that info is worthless. Cherry-pick rewrites the commit onto main with a new SHA but the same commit message ("[AI-Grid] Zrobiono task-XXX"). Result: readable `git log --oneline`, `git bisect` works normally, review is 1:1 with the task.

## [0.2.0] — 2026-05-20

Token-saving for the manager (Claude Code / other LLM orchestrator). The worker writes a concise per-task summary, the new `status.sh` aggregates grid state in one call, and a research task template lets you delegate codebase exploration to gemini. The manager can operate end-to-end autonomously instead of asking about every step.

### Added

- **Task summary per worker** — after the commit the worker writes `.agent-logs/<worker>_<task>.summary.md` with `WORKER`, `RESULT` (OK/AI-FAIL/TEST-FAIL/COMMIT-FAIL/NO-CHANGES), `BRANCH`, `COMMIT`, `FILES_CHANGED`, `DIFF`, `TEST_CMD`, `FINISHED` + the file list. The manager reads 16 lines instead of the full AI log (~3–5x savings in the review phase).
- **`status.sh`** — one-call status report: queue (todo/in_progress/done), `ai-grid/*` branches with diff stats, large-diff flags (> `LARGE_DIFF_LINES`, default 100), locks with stale-detection (>60 min), tmux sessions, recent summaries with `RESULT`. Bash 3.2-portable.
- **`.tasks/_template-research.md`** — research-task template: gemini explores the specified scope, writes a report to `.tasks/research/<slug>.md` (TL;DR + Findings + Recommendations, max 300 words). Manager consumes the summary instead of reading raw code (~5–10x savings in the discovery phase).
- **"Autonomous mode" section in `CLAUDE.md`** — instructions for an LLM manager: plan -> launch `./launch-grid.sh --no-attach` yourself -> poll `.tasks/done/` -> review via `./status.sh` + summary files (not full logs) -> auto-merge for diffs < `LARGE_DIFF_LINES` -> ALWAYS ask before `git push`.

### Changed

- `worker-agent.sh` — added the `write_task_summary` function called at each terminal of `execute_task` (success / AI-fail / test-fail / commit-fail / no-changes).

## [0.1.0] — 2026-05-20

First public release. A local **multi-agent coding grid** built exclusively from native tools: Bash, the filesystem, `tmux`, gemini CLI. Spawn N AI workers in parallel — each in an isolated git worktree, each committing to its own `ai-grid/<task>` branch.

### Highlights

- **Atomic locking via `mkdir`** — POSIX-atomic guard. Two workers seeing the same file in the queue never claim it concurrently. No `flock`, no SQL, no Redis.
- **Worktree per worker** — each worker operates in `.worktrees/<worker-id>/`. No shared working tree -> no race on `git add -A` or file conflict between concurrent gemini instances.
- **Branch per task** — `git checkout -B ai-grid/<task-name> $BASE_SHA` before each task. Merge what's good, drop the rest.
- **Crash-safe** — `trap EXIT/INT/TERM` returns the task from `in_progress/` to `todo/` and releases the lock on SIGINT/SIGTERM/exception.
- **Stale-lock cleanup** — `launch-grid.sh` removes locks older than 60 minutes at startup (for workers that died before their trap fired).
- **Pluggable AI backend** — the `run_ai()` function at the top of `worker-agent.sh` is the adapter — swap for claude-code, ollama, llm, or anything else.

### Components

| File | Role |
|---|---|
| `launch-grid.sh` | Tmux orchestrator: `--workers N`, `--no-attach`, old-lock cleanup |
| `worker-agent.sh` | Single worker (claim -> AI -> tests -> commit -> done) in worktree |
| `.tasks/_template.md` | Task template (Goal / Context / Files / Definition of Done) |
| `CLAUDE.md` | Instructions for Claude Code as manager (optional) |
| `README.md`, `LICENSE` | Documentation + MIT License |

### Requirements

- bash 4+ (5+ recommended)
- git, tmux
- gemini CLI ([Google Gemini CLI](https://github.com/google-gemini/gemini-cli)) — tested on 0.42.0, one-time `gemini auth login`

### Quick start

```bash
git clone https://github.com/Brbn-jpg/claude-conductor.git && cd claude-conductor
cp .tasks/_template.md .tasks/todo/task-001-something.md
$EDITOR .tasks/todo/task-001-something.md
./launch-grid.sh --workers 2
```

### Known limitations

- **Workers exit when `todo/` is empty** — they don't run as daemons. For background daemons reacting to new tasks, replace `break` with `sleep "$POLL_INTERVAL"; continue` in the worker's main loop.
- **No retry counter** — a crashed AI task returns to the queue with no limit.
- **Stale-lock threshold is hardcoded (60 min)** — bump `STALE_LOCK_MINUTES` in `launch-grid.sh` for long-running tasks.
- **`gemini --yolo` = full trust in the AI**. The framework isolates workers via worktrees, but the prompt's quality (the DoD in the template) determines output quality.
- **Scripts assume they live at the target repo root** (`REPO_ROOT="$SCRIPT_DIR"`). Reusing in another repo = copy the files there (see README).

### Acknowledgments

Inspired by a Reddit thread on lightweight multi-agent setups. Built on the principle "how much can you squeeze out of native POSIX tools before reaching for an orchestrator".

---

[1.0.0]: https://github.com/Brbn-jpg/agent-conductor/releases/tag/v1.0.0
[0.4.1]: https://github.com/Brbn-jpg/agent-conductor/releases/tag/v0.4.1
[0.4.0]: https://github.com/Brbn-jpg/agent-conductor/releases/tag/v0.4.0
[0.3.0]: https://github.com/Brbn-jpg/agent-conductor/releases/tag/v0.3.0
[0.2.0]: https://github.com/Brbn-jpg/agent-conductor/releases/tag/v0.2.0
[0.1.0]: https://github.com/Brbn-jpg/agent-conductor/releases/tag/v0.1.0
