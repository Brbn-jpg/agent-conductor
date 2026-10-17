# shellcheck shell=bash
# _lib.sh — shared helpers for agent-conductor scripts. Source it, don't run it.
#
# Compatible with bash 3.2 (stock macOS): no mapfile, no associative arrays,
# guard empty-array expansions under `set -u`.
#
# Variables set here are consumed by the scripts that source this file.
# shellcheck disable=SC2034

CONDUCTOR_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo "ERROR: $1" >&2
    exit "${2:-1}"
}

# --- REPO / PATHS -----------------------------------------------------------

# Sets REPO_ROOT, GIT_COMMON_DIR, STATE_DIR, WORKERS_DIR, WORKTREES_DIR,
# TASKS_DIR, CONFIG_FILE, SESSION. Resolves the MAIN repo even when cwd is inside one of
# the conductor worktrees (via --git-common-dir, which is shared by worktrees).
conductor_init() {
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null)" \
        || die "not inside a git repository (cwd: $PWD)"
    GIT_COMMON_DIR="$(cd "$common" && pwd)"
    REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"

    STATE_DIR="$REPO_ROOT/.conductor"
    WORKERS_DIR="$STATE_DIR/workers"
    WORKTREES_DIR="$STATE_DIR/worktrees"
    TASKS_DIR="$STATE_DIR/tasks"
    CONFIG_FILE="$STATE_DIR/config"

    # tmux session names must not contain '.' or ':'.
    SESSION="conductor-$(basename "$REPO_ROOT" | sed 's/[^A-Za-z0-9_-]/_/g')"
    LARGE_DIFF_LINES="${LARGE_DIFF_LINES:-100}"
}

# Creates the state dirs and keeps .conductor/ out of git status in the
# target repo — via .git/info/exclude, so the repo's .gitignore stays untouched.
conductor_ensure_state() {
    mkdir -p "$WORKERS_DIR" "$WORKTREES_DIR" "$TASKS_DIR" "$GIT_COMMON_DIR/info"
    local exclude="$GIT_COMMON_DIR/info/exclude"
    if ! grep -qxF '/.conductor/' "$exclude" 2>/dev/null; then
        printf '\n# agent-conductor runtime state\n/.conductor/\n' >> "$exclude"
    fi
}

# --- WORKERS ----------------------------------------------------------------

worker_dir()    { printf '%s/%s' "$WORKERS_DIR" "$1"; }
worker_branch() { printf 'conductor/%s' "$1"; }
worker_tree()   { printf '%s/%s' "$WORKTREES_DIR" "$1"; }

# Atomic write (tmp + mv), so readers never see a half-written status.
set_status() {
    local d
    d="$(worker_dir "$1")"
    printf '%s\n' "$2" > "$d/status.tmp" && mv -f "$d/status.tmp" "$d/status"
}

get_status() {
    local f
    f="$(worker_dir "$1")/status"
    if [[ -r "$f" ]]; then cat "$f"; else echo "unknown"; fi
}

# Reads a one-line field file from the worker dir (empty if missing).
worker_field() {
    cat "$(worker_dir "$1")/$2" 2>/dev/null || true
}

# Prints worker ids, one per line, sorted.
list_worker_ids() {
    local d
    for d in "$WORKERS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done
}

branch_exists() {
    git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$1" >/dev/null
}

pane_exists() {
    [[ -n "$1" ]] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"
}

# True if the worker process (spawn.sh --run) is still alive. Falls back to
# the pane when the pgid isn't recorded yet (pane just opened).
worker_alive() {
    local pgid
    pgid="$(worker_field "$1" pgid)"
    if [[ -n "$pgid" ]]; then
        kill -0 "$pgid" 2>/dev/null
    else
        pane_exists "$(worker_field "$1" pane)"
    fi
}

# Stops the worker's whole process group (agent included) and closes its
# pane. Killing only the pane is not enough — the agent keeps running.
stop_worker() {
    local pgid pane own
    pgid="$(worker_field "$1" pgid)"
    pane="$(worker_field "$1" pane)"
    own="$(ps -o pgid= -p $$ | tr -d ' ')"
    if [[ -n "$pgid" && "$pgid" != "$own" ]] && kill -0 "$pgid" 2>/dev/null; then
        kill -TERM -- "-$pgid" 2>/dev/null
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pgid" 2>/dev/null || break
            sleep 0.3
        done
        kill -KILL -- "-$pgid" 2>/dev/null
    fi
    pane_exists "$pane" && tmux kill-pane -t "$pane" >/dev/null 2>&1
    return 0
}

# --- TASK FILES -------------------------------------------------------------

# Commit subject = first H1 of the task file. Template placeholders (anything
# with <...>) or a missing H1 fall back to a slug of the id
# (task-101-job-electrician -> job-electrician).
extract_commit_subject() {
    local task_file="$1" id="$2" h1=""
    if [[ -r "$task_file" ]]; then
        h1="$(grep -m1 '^# ' "$task_file" 2>/dev/null | sed -e 's/^# *//' -e 's/[[:space:]]*$//')"
    fi
    case "$h1" in
        ""|*"<"*">"*)
            local slug="$id"
            slug="${slug#task-}"
            slug="${slug#research-}"
            # shellcheck disable=SC2001
            echo "$slug" | sed 's/^[0-9][0-9]*-//'
            ;;
        *)
            echo "$h1"
            ;;
    esac
}

# --- FORMATTING -------------------------------------------------------------

fmt_duration() {
    local s="$1"
    if (( s >= 3600 )); then
        printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif (( s >= 60 )); then
        printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf '%ds' "$s"
    fi
}

# "3 files changed, 40 insertions(+), 2 deletions(-)" -> "+40 -2 (3 files)"
fmt_shortstat() {
    local stat="$1" files ins del
    [[ -z "$stat" ]] && { echo "-"; return; }
    files="$(echo "$stat" | grep -oE '[0-9]+ files? changed' | grep -oE '^[0-9]+')"
    ins="$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+')"
    del="$(echo "$stat" | grep -oE '[0-9]+ deletion' | grep -oE '^[0-9]+')"
    printf '+%s -%s (%s files)' "${ins:-0}" "${del:-0}" "${files:-0}"
}

# --- CONFIG (.conductor/config) --------------------------------------------
# Plain KEY=VALUE lines, one value per line, no quoting. Parsed, never
# sourced. Written by configure.sh from the manager's setup dialog.

CONFIG_KEYS="AGENT AGENT_CMD MODEL TEST_CMD SETUP_CMD MAX_WORKERS TIMEOUT"

config_key_valid() {
    case " $CONFIG_KEYS " in *" $1 "*) return 0 ;; esac
    return 1
}

config_get() {
    [[ -r "$CONFIG_FILE" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$1="*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "$CONFIG_FILE"
}

config_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$STATE_DIR"
    tmp="$CONFIG_FILE.tmp"
    if [[ -r "$CONFIG_FILE" ]]; then
        grep -v "^$key=" "$CONFIG_FILE" > "$tmp" || true
    else
        : > "$tmp"
    fi
    [[ -n "$value" ]] && printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

# --- AGENTS -----------------------------------------------------------------

# Built-in worker presets. Anything else goes through AGENT=custom + AGENT_CMD.
KNOWN_AGENTS="agy claude codex"

agent_known() {
    case " $KNOWN_AGENTS " in *" $1 "*) return 0 ;; esac
    return 1
}

agent_login_hint() {
    case "$1" in
        agy)    echo "run 'agy' once interactively and sign in (headless mode uses cached credentials only)" ;;
        claude) echo "run 'claude auth login'" ;;
        codex)  echo "run 'codex login'" ;;
    esac
}

# Kills a process and all its descendants (children first).
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$1" 2>/dev/null
}

# Runs a command with a time limit (macOS has no `timeout`). Returns the
# command's exit code, or 124 when it was killed. stdin is passed through —
# the explicit <&0 matters: bash gives background jobs /dev/null otherwise.
run_with_timeout() {
    local secs="$1"; shift
    "$@" <&0 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= secs * 10 )); then
            kill_tree "$pid"
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    wait "$pid"
}

# "90" / "90s" / "20m" / "2h" -> seconds (empty on bad input).
duration_to_secs() {
    local d="$1" n
    n="${d%[smh]}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    case "$d" in
        *h) echo $(( n * 3600 )) ;;
        *m) echo $(( n * 60 )) ;;
        *)  echo "$n" ;;
    esac
}

# Cheap "is it logged in" probe per preset — no model call.
_agent_probe() {
    case "$1" in
        agy)    agy models </dev/null >/dev/null 2>&1 ;;
        claude) claude auth status </dev/null 2>/dev/null | grep -q '"loggedIn": *true' ;;
        codex)  codex login status </dev/null >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Prints: ok | no-auth | missing | unknown
agent_check() {
    local a="$1"
    agent_known "$a" || { echo unknown; return; }
    command -v "$a" >/dev/null 2>&1 || { echo missing; return; }
    if run_with_timeout 20 _agent_probe "$a"; then echo ok; else echo no-auth; fi
}

# --- WORKER COUNTING --------------------------------------------------------

# "running" whose process is gone is reported as "dead".
effective_status() {
    local s
    s="$(get_status "$1")"
    if [[ "$s" == running ]] && ! worker_alive "$1"; then
        echo dead
    else
        echo "$s"
    fi
}

count_running() {
    local id n=0
    while IFS= read -r id; do
        [[ "$(effective_status "$id")" == running ]] && n=$(( n + 1 ))
    done < <(list_worker_ids)
    echo "$n"
}

max_workers() {
    local m="${CONDUCTOR_MAX_WORKERS:-}"
    [[ -n "$m" ]] || m="$(config_get MAX_WORKERS)"
    [[ "$m" =~ ^[1-9][0-9]*$ ]] || m=4
    echo "$m"
}
