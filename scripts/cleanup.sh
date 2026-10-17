#!/usr/bin/env bash
# cleanup.sh — remove workers: tmux pane, worktree, branch, state.
#
# Usage:
#   cleanup.sh <id> [<id>...]   # specific workers
#   cleanup.sh --all            # every worker + orphaned conductor/* branches
#
# Refuses (without --force) to touch a worker that is still running or whose
# branch has commits not yet in the current branch — finished work is never
# discarded silently.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

FORCE=0
KEEP_LOGS=0
ALL=0
IDS=()

usage() {
    cat <<USAGE
Usage: $(basename "$0") <id>... | --all [--force] [--keep-logs]

Options:
  --all         All workers plus orphaned conductor/* branches/worktrees;
                kills the tmux session when nothing is left.
  --force       Also remove running workers and unmerged branches.
  --keep-logs   Move workers/<id> to .conductor/archive/ instead of deleting.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --all)       ALL=1; shift ;;
        --force)     FORCE=1; shift ;;
        --keep-logs) KEEP_LOGS=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          usage >&2; die "unknown option '$1'" 2 ;;
        *)           IDS+=("${1#conductor/}"); shift ;;
    esac
done

if (( ALL )) && (( ${#IDS[@]} > 0 )); then
    die "--all and explicit ids are mutually exclusive" 2
fi
if (( ! ALL )) && (( ${#IDS[@]} == 0 )); then
    usage >&2
    exit 2
fi

conductor_init
cd "$REPO_ROOT" || exit 1

if (( ALL )); then
    while IFS= read -r id; do
        [[ -n "$id" ]] && IDS+=("$id")
    done < <( {
        list_worker_ids
        git branch --format='%(refname:short)' | sed -n 's#^conductor/##p'
        for d in "$WORKTREES_DIR"/*/; do [[ -d "$d" ]] && basename "$d"; done
    } | sort -u )
    if (( ${#IDS[@]} == 0 )); then
        echo "Nothing to clean."
    fi
fi

refused=0
removed=0
for id in ${IDS[@]+"${IDS[@]}"}; do
    branch="$(worker_branch "$id")"
    wt="$(worker_tree "$id")"
    wd="$(worker_dir "$id")"
    st="$(get_status "$id")"

    if [[ ! -d "$wd" && ! -d "$wt" ]] && ! branch_exists "$branch"; then
        echo "  SKIP: $id — no such worker"
        continue
    fi

    if (( ! FORCE )); then
        if [[ "$st" == running ]] && worker_alive "$id"; then
            echo "  REFUSE: $id — still running (use --force to kill it)"
            refused=$(( refused + 1 ))
            continue
        fi
        if branch_exists "$branch"; then
            unmerged="$(git cherry HEAD "$branch" 2>/dev/null | grep -c '^+' || true)"
            if (( unmerged > 0 )); then
                echo "  REFUSE: $id — $branch has $unmerged commit(s) not in HEAD (merge.sh $id, or --force)"
                refused=$(( refused + 1 ))
                continue
            fi
        fi
    fi

    stop_worker "$id"
    if [[ -d "$wt" ]]; then
        git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    fi
    if branch_exists "$branch"; then
        git branch -D "$branch" >/dev/null
    fi
    if [[ -d "$wd" ]]; then
        if (( KEEP_LOGS )); then
            mkdir -p "$STATE_DIR/archive"
            mv "$wd" "$STATE_DIR/archive/${id}-$(date +%Y%m%d-%H%M%S)"
        else
            rm -rf "$wd"
        fi
    fi
    echo "  removed: $id"
    removed=$(( removed + 1 ))
done

git worktree prune

if (( ALL )) && [[ -z "$(list_worker_ids)" ]]; then
    tmux kill-session -t "=$SESSION" >/dev/null 2>&1 && echo "  killed tmux session $SESSION"
fi

echo
echo "Done. removed=$removed  refused=$refused"
(( refused == 0 ))
