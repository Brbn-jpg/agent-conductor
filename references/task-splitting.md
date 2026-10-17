# Splitting work into worker tasks

Workers run in parallel, each in its own worktree branched from the same base.
They can't see each other's changes, and nobody resolves conflicts mid-run.
A good split means `merge.sh --all` goes through without a single conflict.

## Rules

1. **Disjoint file ownership.** Every file that gets modified belongs to exactly
   one task. List the files in each task's `## Files to modify` and check that
   the lists don't overlap before you spawn anything.

2. **Keep hotspots out of parallel tasks.** These files get touched by
   "everyone", so give each one to a single task or edit it yourself after the
   merge:
   - lockfiles and manifests (`package.json`, `package-lock.json`, `go.mod`,
     `Cargo.toml`, `pyproject.toml`)
   - barrel/index exports (`index.ts`, `__init__.py`, `mod.rs`)
   - routers, registries, DI containers, navigation/menu configs
   - `CHANGELOG.md`, README tables of contents, i18n catalogs
   - DB migrations (numbering collides) and generated code / snapshots

   Typical pattern: N workers create `pages/<x>.tsx`, then **you** add the N
   router entries in one follow-up commit (or one final worker task).

3. **Dependencies run in waves, never in parallel.** If B needs A's code, spawn
   A, merge it, then spawn B (it branches from the updated base). Plan the
   waves up front: wave 1 = shared foundations, wave 2+ = independent leaves.

4. **Size.** One task is about one commit of 20–150 changed lines that a worker
   finishes in under 15 minutes. Split anything bigger. Fold anything trivial
   (rename one constant) into another task, or do it yourself.

5. **Self-contained context.** The worker sees only the task file and the
   repo. Put in the paths, function names, the conventions to copy ("follow
   `src/pages/about.tsx`"), and the exact expected behaviour. Never write "as
   discussed" or point to the conversation.

6. **Checkable Definition of Done.** Make it concrete: a command that must pass
   (also give it via `spawn.sh --test "..."`), a file that must exist, a function
   signature. Leave out "make it nice".

7. **Ids sort in execution order.** Use zero-padded ids (`001-...`, `002-...`).
   `merge.sh --all` picks in lexicographic order.

8. **Parallelism.** Keep 4 or fewer workers running at once unless the user asks for more.
   Every worker is a full agent session (API quota, CPU for test runs).

## When NOT to use workers

- The tasks all edit the same few files, so it's really one task.
- The change needs a design decision first. Make the decision (or ask the
  user), then split.
- It's less than about 3 tasks of real work. Doing it yourself is cheaper than
  orchestrating it.

## Research tasks

Use a research task when you need to understand a large codebase area.
A worker explores and writes a short report, and you read about 300 words instead
of thousands of lines. Research workers change **only**
`.conductor/research/<slug>.md`. Because `.conductor/` is git-excluded, the worker
ends as `no-changes`, which is expected. Read the report straight from the
worker's worktree:
`.conductor/worktrees/<id>/.conductor/research/<slug>.md`. Then run `cleanup.sh <id>`.

---

## Template: code task

Save as `.conductor/tasks/<NNN>-<slug>.md`.

```markdown
# <Short imperative summary — becomes the commit subject>

## Goal
<!-- 1–2 sentences: what is true when this task is done. -->

## Context
<!-- Why. Current vs. expected state. Conventions/files to imitate. -->

## Files to modify
- `path/to/file.ext`
- `path/to/new-file.ext` (new)

## Constraints (Definition of Done)
- Do not modify files outside the list above.
- Preserve existing code style and naming conventions.
- `<test command>` passes.
- Do not add external dependencies.

## Test command
<!-- Optional. Overrides TEST_CMD from .conductor/config for this task only.
     First line is the command; write `none` to skip tests for this task.
     Delete the section to use the configured TEST_CMD. -->
`npm test -- src/pages/foo.test.tsx`
```

The orchestrator runs the test command in the worktree after the agent finishes.
A non-zero exit gives `test-fail` and the work is not committed. Narrow the
command to the files the task touches where you can, so it's faster and failures
point at this task.

## Template: research task

Save as `.conductor/tasks/<NNN>-research-<slug>.md`.

```markdown
# Research: <topic>

## Goal
<!-- What you want to learn. -->

## Exploration scope
- `src/...`
- skip: ...

## Questions to answer
1. ...
2. ...

## Output format (DoD)
- Write the report to `.conductor/research/<slug>.md` (create the directory).
- Max 300 words. Sections: `## TL;DR` (3 lines), `## Findings` (bullets,
  each with `path/to/file.ext:LINE`), `## Recommendations` (optional).

## Constraints
- Do NOT modify any file outside `.conductor/research/`.
- Code quotes max 5 lines each.
```
