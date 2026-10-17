#!/usr/bin/env bash
# spawn.sh — start ONE worker for ONE task: git worktree + tmux pane + agent.
#
# Usage:
#   spawn.sh <task.md> [--id ID] [--base BRANCH] [--agent agy|claude|codex|custom]
#            [--model MODEL] [--test "CMD"] [--setup "CMD"] [--timeout 20m]
#
# There is no default agent: it comes from --agent, CONDUCTOR_AGENT or
# .conductor/config (written by configure.sh after the manager asks the user).
#
# Returns immediately; the agent runs in a pane of the tmux session
# conductor-<repo>. Track it with status.sh, integrate with merge.sh.
#
# Internal: spawn.sh --run <id>   (what the tmux pane executes)
#
# Exit codes: 0 ok, 2 usage, 5 MAX_WORKERS reached, 6 no agent chosen,
#             7 agent not installed / not logged in, 8 called from a worker.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
SELF="$CONDUCTOR_SCRIPTS_DIR/spawn.sh"

# --- AGENT ADAPTER ----------------------------------------------------------
# Prompt arrives on stdin, output goes to stdout. Runs with cwd = worktree.
# Workers get --disable-slash-commands where the CLI has it, so they can't
# load skills (this one included) and spawn workers of their own.
run_agent() {
    if [[ "$AGENT" == custom ]]; then
        eval "$AGENT_CMD"
        return
    fi
    local prompt
    prompt="$(cat)"
    local model_args=()
    case "$AGENT" in
        agy)
            [[ -n "${MODEL:-}" ]] && model_args=(--model "$MODEL")
            # Without --add-dir agy headless treats its own scratch dir
            # (~/.gemini/antigravity-cli/scratch) as the workspace, not cwd.
            agy --print "$prompt" \
                --add-dir "$PWD" \
                --dangerously-skip-permissions \
                --disable-slash-commands \
                --print-timeout "$TIMEOUT" \
                ${model_args[@]+"${model_args[@]}"} </dev/null
            ;;
        claude)
            [[ -n "${MODEL:-}" ]] && model_args=(--model "$MODEL")
            claude -p "$prompt" \
                --dangerously-skip-permissions \
                --disable-slash-commands \
                ${model_args[@]+"${model_args[@]}"} </dev/null
            ;;
        codex)
            [[ -n "${MODEL:-}" ]] && model_args=(-m "$MODEL")
            printf '%s' "$prompt" | codex exec \
                --dangerously-bypass-approvals-and-sandbox \
                -C "$PWD" \
                ${model_args[@]+"${model_args[@]}"} -
            ;;
        *)
            echo "[run_agent] unknown agent '$AGENT'" >&2
            return 127
            ;;
    esac
}

agent_label() {
    if [[ "$AGENT" == custom ]]; then
        printf 'custom: %s' "$AGENT_CMD"
    else
        printf '%s%s' "$AGENT" "${MODEL:+ ($MODEL)}"
    fi
}

# --- RUN MODE (inside the tmux pane) ----------------------------------------

write_summary() {
    local result="$1" commit="-" stat="" files="(none)"
    if branch_exists "$BRANCH"; then
        if [[ "$(git -C "$WORKTREE" rev-list --count "$BASE_SHA..HEAD" 2>/dev/null)" != "0" ]]; then
            commit="$(git -C "$WORKTREE" rev-parse --short HEAD)"
            stat="$(git -C "$WORKTREE" diff --shortstat "$BASE_SHA..HEAD" | sed 's/^ *//')"
            files="$(git -C "$WORKTREE" diff --name-status "$BASE_SHA..HEAD")"
        fi
    fi
    {
        echo "# Summary: $ID"
        echo
        echo "- **RESULT:** $result"
        echo "- **AGENT:** $(agent_label)"
        echo "- **BRANCH:** $BRANCH (base $BASE_BRANCH @ ${BASE_SHA:0:7})"
        echo "- **COMMIT:** $commit"
        echo "- **DIFF:** ${stat:--}"
        echo "- **SETUP_CMD:** ${SETUP_CMD:-<none>}"
        echo "- **TEST_CMD:** ${TEST_CMD:-<skipped>}"
        echo "- **DURATION:** $(fmt_duration $(( $(date +%s) - STARTED_AT )))"
        echo
        echo "## Files"
        echo
        echo '```'
        echo "$files"
        echo '```'
        echo
        echo "Full log: \`$WD/agent.log\` — open only if RESULT is not done."
    } > "$WD/summary.md"
}

finish() {
    local result="$1" code="$2"
    write_summary "$result"
    echo "$code" > "$WD/exit_code"
    date +%s > "$WD/finished_at"
    set_status "$ID" "$result"
}

# Runs a shell command (setup/test) in the worktree, output to pane + log.
# Returns the command's exit code.
run_step() {
    local name="$1" cmd="$2" log="$3"
    echo "===== $name ($cmd) =====" | tee -a "$log"
    ( eval "$cmd" ) 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
}

run_worker() {
    ID="$1"
    conductor_init
    WD="$(worker_dir "$ID")"
    [[ -r "$WD/env" ]] || die "no worker '$ID' (missing $WD/env)"
    # shellcheck source=/dev/null
    source "$WD/env"
    export PATH
    # Recursion guard: anything started from here (agent, setup, tests)
    # sees it and spawn.sh refuses to run.
    export CONDUCTOR_WORKER=1 CONDUCTOR_WORKER_ID="$ID"
    export CONDUCTOR_REPO_ROOT="$REPO_ROOT" CONDUCTOR_WORKTREE="$WORKTREE"
    local log="$WD/agent.log"
    # Process group of this pane — stop_worker kills it (agent included).
    ps -o pgid= -p $$ | tr -d ' ' > "$WD/pgid"

    # Anything that kills us while still "running" leaves a failed status.
    trap 'exit 130' INT TERM HUP
    trap '[[ "$(get_status "$ID")" == running ]] && finish failed "${rc:-1}"' EXIT

    cd "$WORKTREE" || { finish failed 1; exit 1; }
    : > "$log"
    rc=0

    # 1. Setup (deps etc.). Whatever it leaves untracked is never committed.
    local setup_untracked="$WD/setup_untracked"
    : > "$setup_untracked"
    if [[ -n "${SETUP_CMD:-}" ]]; then
        run_step SETUP "$SETUP_CMD" "$log"
        rc=$?
        if (( rc != 0 )); then
            finish setup-fail "$rc"
            return
        fi
        git ls-files --others --exclude-standard --directory > "$setup_untracked"
    fi

    # 2. Agent.
    local prompt
    prompt="$(cat <<EOF
You are a programming expert working in a local git repository.
Your workspace is the git worktree at: $WORKTREE
All file paths in the task are relative to that directory. Never create or
modify files outside it. Execute the task below by modifying project files.
Strictly follow the "Constraints (Definition of Done)" section.
Do not ask questions — make the changes. Do NOT run git commit, git checkout
or git reset; the orchestrator commits your changes after you finish.
Do not start other agents or orchestration tools.
When done, reply with a short confirmation of what you changed.

=== TASK ($ID) ===
$(cat "$WD/task.md")
=== END OF TASK ===
EOF
)"
    {
        echo "===== PROMPT ====="
        echo "$prompt"
        echo "===== AGENT OUTPUT ($(agent_label), cwd=$WORKTREE, branch=$BRANCH) ====="
    } >> "$log"

    echo "[$ID] agent: $(agent_label)  branch: $BRANCH  timeout: $TIMEOUT"
    local secs
    secs="$(duration_to_secs "$TIMEOUT")"
    printf '%s' "$prompt" | run_with_timeout "${secs:-1200}" run_agent 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[1]}
    if (( rc == 124 )); then
        echo "===== AGENT TIMEOUT after $TIMEOUT =====" | tee -a "$log"
        finish timeout "$rc"
        return
    elif (( rc != 0 )); then
        echo "===== AGENT EXIT CODE: $rc =====" >> "$log"
        finish agent-fail "$rc"
        return
    fi

    # 3. Tests.
    if [[ -n "${TEST_CMD:-}" ]]; then
        run_step TEST "$TEST_CMD" "$log"
        rc=$?
        if (( rc != 0 )); then
            # Worktree is left as-is so the failure can be inspected.
            finish test-fail "$rc"
            return
        fi
    fi

    # 4. Commit (without setup artifacts).
    local subject path
    subject="$(extract_commit_subject "$WD/task.md" "$ID")"
    git add -A >> "$log" 2>&1
    while IFS= read -r path; do
        [[ -n "$path" ]] && git reset -q -- "$path" >> "$log" 2>&1
    done < "$setup_untracked"
    if ! git diff --cached --quiet; then
        if ! git commit -q -m "$subject" -m "Conductor-Task: $ID" >> "$log" 2>&1; then
            rc=1
            finish commit-fail 1
            return
        fi
    fi
    # Also counts commits the agent made itself despite the prompt.
    if [[ "$(git rev-list --count "$BASE_SHA..HEAD")" == "0" ]]; then
        finish no-changes 0
    else
        finish "done" 0
    fi
}

if [[ "${1:-}" == "--run" ]]; then
    [[ -n "${2:-}" ]] || die "--run needs a worker id" 2
    run_worker "$2"
    echo
    echo "[$2 finished: $(get_status "$2")] — pane stays open until merge.sh/cleanup.sh"
    read -r _ || true
    exit 0
fi

# --- SPAWN MODE -------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") <task.md> [options]

Creates worktree .conductor/worktrees/<id> on branch conductor/<id>,
opens a pane in tmux session conductor-<repo> and runs the agent there.

Options (precedence: flag > task file > env > .conductor/config):
  --id ID          Worker id (default: task file name without .md).
  --base BRANCH    Branch/commit to start from (default: current branch).
  --agent NAME     $KNOWN_AGENTS | custom          [env: CONDUCTOR_AGENT]
  --model MODEL    Model passed to the agent.      [env: CONDUCTOR_MODEL]
  --setup "CMD"    Run in the fresh worktree before the agent (install deps).
                                                   [env: CONDUCTOR_SETUP_CMD]
  --test "CMD"     Run after the agent; non-zero = test-fail. A task file may
                   set it in a "## Test command" section ("none" disables).
                                                   [env: CONDUCTOR_TEST_CMD]
  --timeout DUR    Agent time limit, e.g. 20m (default 20m). [env: CONDUCTOR_TIMEOUT]
  -h, --help       Show this help.

AGENT=custom runs CONDUCTOR_AGENT_CMD / AGENT_CMD: eval'd in the worktree with
the prompt on stdin. Setting CONDUCTOR_AGENT_CMD alone implies --agent custom.
Choose and save defaults with configure.sh.
USAGE
}

# First line of a "## Test command" section, without backticks.
task_test_cmd() {
    awk '
        /^## / { insec = ($0 ~ /^## [Tt]est command[[:space:]]*$/); next }
        insec && NF && $0 !~ /^[[:space:]]*<!--/ && $0 !~ /^[[:space:]]*```/ {
            gsub(/^[[:space:]]*`?|`?[[:space:]]*$/, ""); print; exit
        }
    ' "$1"
}

if [[ -n "${CONDUCTOR_WORKER:-}" ]]; then
    die "running inside conductor worker '${CONDUCTOR_WORKER_ID:-?}' — workers must not spawn workers" 8
fi

TASK_FILE=""
ID=""
BASE_BRANCH=""
F_AGENT="" F_MODEL="" F_TEST="" F_TEST_SET=0 F_SETUP="" F_SETUP_SET=0 F_TIMEOUT=""

need_arg() { [[ -n "${2:-}" ]] || die "$1 requires a value" 2; }

while (( $# > 0 )); do
    case "$1" in
        --id)      need_arg "$1" "${2:-}"; ID="$2"; shift 2 ;;
        --base)    need_arg "$1" "${2:-}"; BASE_BRANCH="$2"; shift 2 ;;
        --agent)   need_arg "$1" "${2:-}"; F_AGENT="$2"; shift 2 ;;
        --model)   need_arg "$1" "${2:-}"; F_MODEL="$2"; shift 2 ;;
        --test)    (( $# > 1 )) || die "--test requires a value" 2; F_TEST="$2"; F_TEST_SET=1; shift 2 ;;
        --setup)   (( $# > 1 )) || die "--setup requires a value" 2; F_SETUP="$2"; F_SETUP_SET=1; shift 2 ;;
        --timeout) need_arg "$1" "${2:-}"; F_TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        usage >&2; die "unknown option '$1'" 2 ;;
        *)
            [[ -z "$TASK_FILE" ]] || die "only one task file per spawn (got '$TASK_FILE' and '$1')" 2
            TASK_FILE="$1"; shift ;;
    esac
done

[[ -n "$TASK_FILE" ]] || { usage >&2; exit 2; }
[[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"
TASK_FILE="$(cd "$(dirname "$TASK_FILE")" && pwd)/$(basename "$TASK_FILE")"

[[ -n "$ID" ]] || ID="$(basename "$TASK_FILE" .md)"
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid id '$ID' (use letters, digits, . _ -)" 2

command -v tmux >/dev/null 2>&1 || die "tmux not found in PATH"

conductor_init
conductor_ensure_state

# --- resolve settings: flag > task file > env > config ----------------------

first_set() { local v; for v in "$@"; do [[ -n "$v" ]] && { printf '%s' "$v"; return; }; done; }

if [[ -n "$F_AGENT" ]]; then
    AGENT="$F_AGENT"
elif [[ -n "${CONDUCTOR_AGENT_CMD:-}" ]]; then
    AGENT=custom
else
    AGENT="$(first_set "${CONDUCTOR_AGENT:-}" "$(config_get AGENT)")"
fi
AGENT_CMD="$(first_set "${CONDUCTOR_AGENT_CMD:-}" "$(config_get AGENT_CMD)")"
MODEL="$(first_set "$F_MODEL" "${CONDUCTOR_MODEL:-}" "$(config_get MODEL)")"
TIMEOUT="$(first_set "$F_TIMEOUT" "${CONDUCTOR_TIMEOUT:-}" "$(config_get TIMEOUT)" 20m)"
[[ -n "$(duration_to_secs "$TIMEOUT")" ]] || die "invalid timeout '$TIMEOUT' (e.g. 900, 20m, 1h)" 2

if (( F_SETUP_SET )); then
    SETUP_CMD="$F_SETUP"
else
    SETUP_CMD="$(first_set "${CONDUCTOR_SETUP_CMD:-}" "$(config_get SETUP_CMD)")"
fi
if (( F_TEST_SET )); then
    TEST_CMD="$F_TEST"
else
    TEST_CMD="$(task_test_cmd "$TASK_FILE")"
    [[ -n "$TEST_CMD" ]] || TEST_CMD="$(first_set "${CONDUCTOR_TEST_CMD:-}" "$(config_get TEST_CMD)")"
fi
[[ "$TEST_CMD" == none ]] && TEST_CMD=""

# --- agent checks -----------------------------------------------------------

if [[ -z "$AGENT" ]]; then
    {
        echo "ERROR: no worker agent chosen. Ask the user which one to use, then save it:"
        echo "  $CONDUCTOR_SCRIPTS_DIR/configure.sh set AGENT=<name>"
        echo
        "$CONDUCTOR_SCRIPTS_DIR/configure.sh" detect
    } >&2
    exit 6
fi
if [[ "$AGENT" == custom ]]; then
    [[ -n "$AGENT_CMD" ]] || die "AGENT=custom needs CONDUCTOR_AGENT_CMD or AGENT_CMD in config" 2
elif ! agent_known "$AGENT"; then
    die "unknown agent '$AGENT' (one of: $KNOWN_AGENTS custom)" 2
else
    # Login probe, cached for 10 minutes so a batch of spawns pays it once.
    auth_mark="$STATE_DIR/.auth-ok-$AGENT"
    if [[ -z "$(find "$auth_mark" -mmin -10 2>/dev/null)" ]]; then
        case "$(agent_check "$AGENT")" in
            ok)      touch "$auth_mark" ;;
            missing) die "'$AGENT' is not installed (see configure.sh detect)" 7 ;;
            *)       die "'$AGENT' is not logged in — $(agent_login_hint "$AGENT")" 7 ;;
        esac
    fi
fi

running="$(count_running)"
limit="$(max_workers)"
if (( running >= limit )); then
    die "$running/$limit workers running (MAX_WORKERS) — wait with: status.sh --wait-slot" 5
fi

# --- worktree + state -------------------------------------------------------

BRANCH="$(worker_branch "$ID")"
WORKTREE="$(worker_tree "$ID")"
WD="$(worker_dir "$ID")"

branch_exists "$BRANCH" && die "branch $BRANCH already exists — pick another --id or run cleanup.sh $ID"
[[ -e "$WORKTREE" || -e "$WD" ]] && die "worker '$ID' already exists — run cleanup.sh $ID first"

if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null)" \
        || die "main repo is on a detached HEAD — pass --base"
fi
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_BRANCH^{commit}")" \
    || die "base '$BASE_BRANCH' not found"

mkdir -p "$WD"
cp "$TASK_FILE" "$WD/task.md"
if ! git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WORKTREE" "$BASE_SHA" > "$WD/spawn.log" 2>&1; then
    cat "$WD/spawn.log" >&2
    rm -rf "$WD"
    die "git worktree add failed"
fi

# The pane does NOT inherit this shell's environment (tmux server env is used),
# so everything the worker needs — including PATH — goes into an env file.
{
    printf 'ID=%q\n' "$ID"
    printf 'BRANCH=%q\n' "$BRANCH"
    printf 'WORKTREE=%q\n' "$WORKTREE"
    printf 'BASE_BRANCH=%q\n' "$BASE_BRANCH"
    printf 'BASE_SHA=%q\n' "$BASE_SHA"
    printf 'AGENT=%q\n' "$AGENT"
    printf 'AGENT_CMD=%q\n' "$AGENT_CMD"
    printf 'MODEL=%q\n' "$MODEL"
    printf 'SETUP_CMD=%q\n' "$SETUP_CMD"
    printf 'TEST_CMD=%q\n' "$TEST_CMD"
    printf 'TIMEOUT=%q\n' "$TIMEOUT"
    printf 'STARTED_AT=%q\n' "$(date +%s)"
    printf 'PATH=%q\n' "$PATH"
} > "$WD/env"
echo "$BASE_SHA" > "$WD/base_sha"
date +%s > "$WD/started_at"
set_status "$ID" running

PANE_CMD="$(printf '%q --run %q' "$SELF" "$ID")"
if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
    PANE="$(tmux new-session -d -s "$SESSION" -n workers -x 240 -y 70 -c "$WORKTREE" \
                 -P -F '#{pane_id}' "$PANE_CMD")" || PANE=""
    if [[ -n "$PANE" ]]; then
        tmux set-option -w -t "=$SESSION:workers" pane-border-status top >/dev/null 2>&1 || true
        tmux set-option -w -t "=$SESSION:workers" pane-border-format ' #{pane_title} ' >/dev/null 2>&1 || true
    fi
else
    # Split the workers window; when it's out of room, open a new window.
    PANE="$(tmux split-window -t "=$SESSION:workers" -c "$WORKTREE" -P -F '#{pane_id}' "$PANE_CMD" 2>/dev/null)" \
        || PANE="$(tmux new-window -t "=$SESSION" -c "$WORKTREE" -P -F '#{pane_id}' "$PANE_CMD")" \
        || PANE=""
fi
if [[ -z "$PANE" ]]; then
    set_status "$ID" failed
    die "could not open a tmux pane — worktree kept; run cleanup.sh $ID"
fi
echo "$PANE" > "$WD/pane"
tmux select-pane -t "$PANE" -T "$ID" >/dev/null 2>&1 || true
tmux select-layout -t "$PANE" tiled >/dev/null 2>&1 || true

echo "spawned $ID"
echo "  branch:   $BRANCH (from $BASE_BRANCH @ ${BASE_SHA:0:7})"
echo "  worktree: $WORKTREE"
echo "  agent:    $(agent_label)  timeout: $TIMEOUT"
echo "  setup:    ${SETUP_CMD:-<none>}   test: ${TEST_CMD:-<none>}"
echo "  tmux:     $SESSION ($PANE) — tmux attach -t $SESSION"
