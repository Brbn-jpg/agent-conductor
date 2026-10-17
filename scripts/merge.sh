#!/usr/bin/env bash
# merge.sh — cherry-pick finished worker branches onto the current branch.
#
# Linear history: each task -> its commit(s) on the current branch, no merge
# commits. On success removes the worker's pane, worktree and branch.
#
# Usage:
#   merge.sh <id> [<id>...]     # specific workers
#   merge.sh --all              # every worker with status "done", in id order
#   merge.sh --all --dry-run    # preview
#   merge.sh --all --keep       # keep conductor/<id> branches after picking
#
# Exit codes: 0 ok, 2 usage, 3 repo not clean, 4 CONFLICT (stopped).

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DRY_RUN=0
KEEP=0
ALL=0
IDS=()

usage() {
    cat <<USAGE
Usage: $(basename "$0") <id>... | --all [--dry-run] [--keep]

Cherry-picks conductor/<id> onto the current branch of the main repo.
Only workers with status "done" are merged.

Options:
  --all       All "done" workers in lexicographic id order
              (zero-padded ids = chronological).
  --dry-run   Show what would happen.
  --keep      Keep the conductor/<id> branch after a successful pick.

On conflict the script STOPS with exit code 4. Resolve with
git cherry-pick --continue / --abort; remaining workers are untouched.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --all)      ALL=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --keep)     KEEP=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         usage >&2; die "unknown option '$1'" 2 ;;
        *)          IDS+=("${1#conductor/}"); shift ;;
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
cd "$REPO_ROOT"

# --- SANITY ----------------------------------------------------------------

if [[ -n "$(git status --porcelain)" ]]; then
    git status --short >&2
    die "working tree of $REPO_ROOT is not clean — commit or stash first" 3
fi
if [[ -f "$GIT_COMMON_DIR/CHERRY_PICK_HEAD" || -f "$GIT_COMMON_DIR/MERGE_HEAD" \
   || -d "$GIT_COMMON_DIR/rebase-merge" || -d "$GIT_COMMON_DIR/rebase-apply" ]]; then
    die "a cherry-pick/merge/rebase is in progress — finish it first" 3
fi
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
case "$CURRENT_BRANCH" in
    conductor/*) die "current branch is a worker branch ($CURRENT_BRANCH) — checkout your target branch" 3 ;;
esac

# --- MERGE ONE --------------------------------------------------------------

# Returns 0 merged, 1 skipped, 2 conflict.
merge_one() {
    local id="$1" branch st base count tip subject
    branch="$(worker_branch "$id")"
    st="$(get_status "$id")"

    if [[ "$st" != "done" ]]; then
        echo "  SKIP: $id — status '$st' (only 'done' is merged)"
        return 1
    fi
    if ! branch_exists "$branch"; then
        echo "  SKIP: $id — branch $branch does not exist"
        return 1
    fi

    base="$(git merge-base HEAD "$branch")"
    count="$(git rev-list --count "$base..$branch")"
    if (( count == 0 )); then
        echo "  SKIP: $id — nothing to pick (already in HEAD)"
        return 1
    fi
    tip="$(git rev-parse --short "$branch")"
    subject="$(git log -1 --format='%s' "$branch")"

    if (( DRY_RUN )); then
        echo "  DRY-RUN: cherry-pick $branch (${count}x, tip=$tip) \"$subject\""
        return 0
    fi

    echo "  -> cherry-pick $branch (${count}x) \"$subject\""
    if ! git cherry-pick --no-edit "$base..$branch"; then
        cat >&2 <<EOF

  CONFLICT on $id ($branch). Resolve manually:
    git status                    # see conflicts
    \$EDITOR <files>               # resolve
    git add <files>
    git cherry-pick --continue
  Or abort:
    git cherry-pick --abort
  Then re-run merge.sh for the remaining workers.
EOF
        return 2
    fi

    local new_sha
    new_sha="$(git rev-parse --short HEAD)"
    echo "     OK: $tip -> $new_sha"
    echo "$new_sha" > "$(worker_dir "$id")/merged_commit"
    set_status "$id" merged

    stop_worker "$id"
    local wt
    wt="$(worker_tree "$id")"
    if [[ -d "$wt" ]]; then
        git worktree remove --force "$wt" >/dev/null 2>&1 || true
    fi
    if (( ! KEEP )); then
        git branch -D "$branch" >/dev/null
    fi
    return 0
}

# --- MAIN -------------------------------------------------------------------

if (( ALL )); then
    while IFS= read -r id; do
        [[ "$(get_status "$id")" == "done" ]] && IDS+=("$id")
    done < <(list_worker_ids)
    if (( ${#IDS[@]} == 0 )); then
        echo "No workers with status 'done' to merge."
        exit 0
    fi
fi

echo "Merge ${#IDS[@]} worker(s) onto $CURRENT_BRANCH:"
ok=0
skipped=0
for id in "${IDS[@]}"; do
    rc=0
    merge_one "$id" || rc=$?
    case "$rc" in
        0) ok=$(( ok + 1 )) ;;
        2) exit 4 ;;
        *) skipped=$(( skipped + 1 )) ;;
    esac
done
git worktree prune
echo
echo "Done. merged=$ok  skipped=$skipped  total=${#IDS[@]}"
