# agent-conductor (contributor notes)

This repo **is** an agent skill (the `SKILL.md` format, loadable by Claude Code,
Codex, Antigravity CLI, …). The manager workflow lives in `SKILL.md`; this file
only covers working on the skill itself.

- Keep `SKILL.md` and the docs **agent-neutral**: no harness-specific tool
  names or limits as requirements. The worker agent is always the user's choice
  (no default).
- Scripts must stay **bash 3.2 compatible** (stock macOS): no `mapfile`, no
  associative arrays, guard empty arrays under `set -u` (`${a[@]+"${a[@]}"}`).
- Shared code goes in `scripts/_lib.sh`; keep the entry scripts thin.
- New worker presets only with flags verified against the CLI's own `--help`
  plus a real headless run.
- Before committing: `shellcheck -x scripts/*.sh tests/*.sh` must be clean and
  `tests/smoke.sh` must pass. It's an end-to-end run with a fake agent (no LLM,
  ~1 min, temp repo) that executes the `FAKE: <shell cmd>` line of each task.
  Add a case there for every new status, exit code or option.
- **Always ask before `git push`.**
- Keep docs in English. Update `CHANGELOG.md` (Keep a Changelog, SemVer).
