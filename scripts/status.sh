#!/usr/bin/env bash
# status.sh — state of conductor workers in this repo.
#
# Usage:
#   status.sh                         # table of all workers
#   status.sh <id>                    # summary.md (or log tail while running)
#   status.sh --wait [--timeout SEC]  # block until no worker is running
#   status.sh --wait-slot [--timeout SEC]  # block until running < MAX_WORKERS
#
# Exit codes: 0 ok, 124 --wait timed out.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

WAIT=0
WAIT_SLOT=0
WAIT_TIMEOUT=0
POLL="${CONDUCTOR_POLL:-5}"
SHOW_ID=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [<id>] [--wait | --wait-slot] [--timeout SEC]

  (no args)       Table: ID STATUS TIME COMMIT DIFF FLAGS.
  <id>            Print the worker's summary.md (log tail if still running).
  --wait          Block until no worker is running, then print the table.
  --wait-slot     Block until fewer than MAX_WORKERS are running (so the
                  next spawn.sh is allowed), then print the table.
  --timeout SEC   With --wait/--wait-slot: give up after SEC seconds (exit 124).

Flags: LARGE = insertions > LARGE_DIFF_LINES (${LARGE_DIFF_LINES:-100}),
       DEAD  = status running but the worker process is gone.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --wait)    WAIT=1; shift ;;
        --wait-slot) WAIT=1; WAIT_SLOT=1; shift ;;
        --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--timeout needs seconds" 2
                   WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        usage >&2; die "unknown option '$1'" 2 ;;
        *)         SHOW_ID="$1"; shift ;;
    esac
done

conductor_init

print_table() {
    local ids=() id
    while IFS= read -r id; do ids+=("$id"); done < <(list_worker_ids)
    if (( ${#ids[@]} == 0 )); then
        echo "(no workers in $STATE_DIR)"
        return
    fi

    local w=2
    for id in "${ids[@]}"; do (( ${#id} > w )) && w=${#id}; done

    local n_run=0 n_ok=0 n_fail=0 n_other=0
    printf "%-${w}s  %-11s  %-7s  %-8s  %-22s  %s\n" ID STATUS TIME COMMIT DIFF FLAGS
    for id in "${ids[@]}"; do
        local st branch base start end now commit="-" diff="-" flags="" ins
        st="$(effective_status "$id")"
        branch="$(worker_branch "$id")"
        base="$(worker_field "$id" base_sha)"
        start="$(worker_field "$id" started_at)"
        end="$(worker_field "$id" finished_at)"
        now="$(date +%s)"
        [[ -n "$end" ]] || end="$now"

        if [[ -n "$base" ]] && branch_exists "$branch" \
           && [[ "$(git -C "$REPO_ROOT" rev-list --count "$base..$branch" 2>/dev/null)" != "0" ]]; then
            local stat
            commit="$(git -C "$REPO_ROOT" rev-parse --short "$branch")"
            stat="$(git -C "$REPO_ROOT" diff --shortstat "$base..$branch" 2>/dev/null)"
            diff="$(fmt_shortstat "$stat")"
            ins="$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+')"
            (( ${ins:-0} > LARGE_DIFF_LINES )) && flags="LARGE"
        elif [[ "$st" == merged ]]; then
            commit="$(worker_field "$id" merged_commit)"
            [[ -n "$commit" ]] || commit="-"
        fi
        [[ "$st" == dead ]] && flags="${flags:+$flags,}DEAD"

        case "$st" in
            running)              n_run=$(( n_run + 1 )) ;;
            done|merged)          n_ok=$(( n_ok + 1 )) ;;
            no-changes)           n_other=$(( n_other + 1 )) ;;
            *)                    n_fail=$(( n_fail + 1 )) ;;
        esac

        printf "%-${w}s  %-11s  %-7s  %-8s  %-22s  %s\n" \
            "$id" "$st" "$(fmt_duration $(( end - ${start:-$now} )))" "$commit" "$diff" "$flags"
    done
    echo
    echo "running=$n_run  ok=$n_ok  failed=$n_fail  no-changes=$n_other  tmux=$(tmux has-session -t "=$SESSION" 2>/dev/null && echo "$SESSION" || echo none)"
}

if [[ -n "$SHOW_ID" ]]; then
    wd="$(worker_dir "$SHOW_ID")"
    [[ -d "$wd" ]] || die "no worker '$SHOW_ID'"
    st="$(effective_status "$SHOW_ID")"
    if [[ -r "$wd/summary.md" ]]; then
        cat "$wd/summary.md"
    else
        echo "STATUS: $st — no summary yet. Last 20 log lines:"
        echo
        tail -n 20 "$wd/agent.log" 2>/dev/null || echo "(no log yet)"
    fi
    exit 0
fi

if (( WAIT )); then
    started="$(date +%s)"
    last=""
    target=0
    (( WAIT_SLOT )) && target=$(( $(max_workers) - 1 ))
    while true; do
        n="$(count_running)"
        (( n <= target )) && break
        if [[ "$n" != "$last" ]]; then
            echo "[wait] $n worker(s) running (waiting for <= $target)..."
            last="$n"
        fi
        if (( WAIT_TIMEOUT > 0 && $(date +%s) - started >= WAIT_TIMEOUT )); then
            echo "[wait] timeout after ${WAIT_TIMEOUT}s"
            echo
            print_table
            exit 124
        fi
        sleep "$POLL"
    done
fi

print_table
