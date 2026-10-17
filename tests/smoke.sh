#!/usr/bin/env bash
# tests/smoke.sh — end-to-end test of the scripts with a fake agent (no LLM,
# no network, ~1 min). Runs in a temp repo; leaves nothing behind.
#
# The fake agent executes the "FAKE: <shell cmd>" line of each task file.
# Usage: tests/smoke.sh        Exit code: 0 all passed, 1 otherwise.
set -u
C="$(cd "$(dirname "$0")/../scripts" && pwd)"
S="$(mktemp -d "${TMPDIR:-/tmp}/conductor-smoke.XXXXXX")"
S="$(cd "$S" && pwd -P)"
R="$S/smoke-repo"
T="$S/tasks"
trap 'tmux kill-session -t conductor-smoke-repo 2>/dev/null; rm -rf "$S"' EXIT
# shellcheck disable=SC2016  # expanded later, inside the worker
FAKE='sh -c "$(sed -n "s/^FAKE: //p")"'
pass=0; fail=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok   $1"
    else fail=$((fail+1)); echo "  FAIL $1: expected [$2] got [$3]"; fi
}
st() { cat "$R/.conductor/workers/$1/status" 2>/dev/null; }
mk() { printf '# %s\n\nFAKE: %s\n%s' "$2" "$3" "${4:-}" > "$T/$1.md"; }

tmux kill-session -t conductor-smoke-repo 2>/dev/null
mkdir -p "$R" "$T"; cd "$R" || exit 1
git init -q -b main && git config user.email smoke@test && git config user.name smoke && echo base > README && printf '{"scripts":{"test":"x"}}' > package.json \
  && touch package-lock.json && git add . && git commit -qm init
unset CONDUCTOR_AGENT CONDUCTOR_AGENT_CMD CONDUCTOR_MODEL CONDUCTOR_TEST_CMD CONDUCTOR_SETUP_CMD \
      CONDUCTOR_MAX_WORKERS CONDUCTOR_TIMEOUT CONDUCTOR_WORKER CONDUCTOR_WORKER_ID

echo "== no agent chosen"
mk 001-alpha "Add alpha" 'echo alpha > alpha.txt'
"$C/spawn.sh" "$T/001-alpha.md" >/dev/null 2>"$S/err.txt"; check "exit 6 without agent" 6 $?
grep -q 'configure.sh set AGENT' "$S/err.txt"; check "error shows how to choose" 0 $?

echo "== configure"
"$C/configure.sh" suggest | grep -q 'TEST_CMD:  npm test'; check "suggest npm test" 0 $?
"$C/configure.sh" suggest | grep -q 'SETUP_CMD: npm ci'; check "suggest npm ci" 0 $?
"$C/configure.sh" show >/dev/null; check "show w/o config = 3" 3 $?
"$C/configure.sh" set BOGUS=1 >/dev/null 2>&1; check "unknown key rejected" 2 $?
"$C/configure.sh" set AGENT=nope >/dev/null 2>&1; check "unknown agent rejected" 2 $?
"$C/configure.sh" set AGENT=custom "AGENT_CMD=$FAKE" MAX_WORKERS=2 TIMEOUT=3s >/dev/null; check "set ok" 0 $?
check "config AGENT" custom "$(sed -n 's/^AGENT=//p' .conductor/config)"
check "config AGENT_CMD verbatim" "$FAKE" "$(sed -n 's/^AGENT_CMD=//p' .conductor/config)"
"$C/configure.sh" detect | head -1 | grep -q '^AGENT'; check "detect prints table" 0 $?

echo "== recursion guard"
CONDUCTOR_WORKER=1 "$C/spawn.sh" "$T/001-alpha.md" >/dev/null 2>&1; check "exit 8 inside worker" 8 $?

echo "== spawn from config, setup, task test command, timeout"
mk 002-setup "Setup artifacts" 'echo b > beta.txt'
mk 003-tasktest "Task test fails" 'echo t > t.txt' $'\n## Test command\n`false`\n'
mk 004-slow "Too slow" 'sleep 31337; echo s > s.txt'
"$C/spawn.sh" "$T/001-alpha.md" >/dev/null; check "spawn alpha" 0 $?
"$C/spawn.sh" "$T/002-setup.md" --setup 'mkdir -p deps && echo x > deps/lib.js' >/dev/null; check "spawn setup" 0 $?
"$C/spawn.sh" "$T/003-tasktest.md" >/dev/null 2>&1; check "limit reached = 5" 5 $?
"$C/status.sh" --wait-slot --timeout 20 >/dev/null; check "wait-slot" 0 $?
"$C/spawn.sh" "$T/003-tasktest.md" >/dev/null; check "spawn tasktest" 0 $?
"$C/status.sh" --wait-slot --timeout 20 >/dev/null
"$C/spawn.sh" "$T/004-slow.md" >/dev/null; check "spawn slow" 0 $?
"$C/status.sh" --wait --timeout 30 >/dev/null; check "wait all" 0 $?
check "alpha done" "done" "$(st 001-alpha)"
check "setup done" "done" "$(st 002-setup)"
check "setup artifacts not committed" "beta.txt" "$(git diff --name-only main..conductor/002-setup)"
check "task test cmd -> test-fail" test-fail "$(st 003-tasktest)"
check "timeout status" timeout "$(st 004-slow)"
pgrep -f 'sleep 31337' >/dev/null; check "timed-out agent killed" 1 $?

echo "== nested spawn from inside a worker fails"
mk 005-nested "Nested" "$C/spawn.sh $T/001-alpha.md --id nested-x"
"$C/spawn.sh" "$T/005-nested.md" --timeout 20s >/dev/null; "$C/status.sh" --wait --timeout 30 >/dev/null
check "nested worker agent-fail" agent-fail "$(st 005-nested)"
grep -q 'workers must not spawn workers' .conductor/workers/005-nested/agent.log; check "nested refused msg" 0 $?
nested=1; [[ -d .conductor/workers/nested-x ]] && nested=0; check "no nested worker created" 1 "$nested"

echo "== 'none' disables config test"
"$C/configure.sh" set TEST_CMD=false >/dev/null
mk 006-none "No test" 'echo n > n.txt' $'\n## Test command\nnone\n'
"$C/spawn.sh" "$T/006-none.md" >/dev/null; "$C/status.sh" --wait --timeout 20 >/dev/null
check "none -> done" "done" "$(st 006-none)"
"$C/configure.sh" unset TEST_CMD >/dev/null

echo "== merge + conflict + cleanup"
mk 007-c1 "Clash one" 'echo one > clash.txt'
mk 008-c2 "Clash two" 'echo two > clash.txt'
"$C/spawn.sh" "$T/007-c1.md" >/dev/null; "$C/spawn.sh" "$T/008-c2.md" >/dev/null
"$C/status.sh" --wait --timeout 20 >/dev/null
"$C/merge.sh" --all >/dev/null 2>&1; check "merge conflict = 4" 4 $?
git cherry-pick --abort
check "linear history" "Clash one|No test|Setup artifacts|Add alpha|init" "$(git log --format=%s | paste -sd'|' -)"
"$C/cleanup.sh" --all >/dev/null; check "cleanup refuses unmerged" 1 $?
"$C/cleanup.sh" --all --force >/dev/null; check "cleanup --force" 0 $?
check "no worktrees left" 1 "$(git worktree list | wc -l | tr -d ' ')"
check "no conductor branches" 0 "$(git branch | grep -c conductor/)"
tmux has-session -t conductor-smoke-repo 2>/dev/null; check "session gone" 1 $?
check "repo clean" "" "$(git status --porcelain)"

echo
echo "PASS=$pass FAIL=$fail"
(( fail == 0 ))
