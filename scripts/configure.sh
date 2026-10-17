#!/usr/bin/env bash
# configure.sh — backend for the manager's setup dialog.
#
# Usage:
#   configure.sh detect            # which worker agents are installed / logged in
#   configure.sh suggest           # TEST_CMD / SETUP_CMD guesses for this repo
#   configure.sh show              # current .conductor/config
#   configure.sh set KEY=VALUE...  # write answers (AGENT, MODEL, TEST_CMD, ...)
#   configure.sh unset KEY...
#
# Exit codes: 0 ok, 2 usage, 3 `show` found no config.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
    cat <<USAGE
Usage: $(basename "$0") detect | suggest | show | set KEY=VALUE... | unset KEY...

Keys: $CONFIG_KEYS
  AGENT        $KNOWN_AGENTS | custom (custom requires AGENT_CMD)
  AGENT_CMD    command eval'd in the worktree, prompt on stdin
  MODEL        passed to the agent as its model flag
  TEST_CMD     run after the agent; non-zero = test-fail
  SETUP_CMD    run in the fresh worktree before the agent (install deps)
  MAX_WORKERS  workers running at once (default 4)
  TIMEOUT      agent time limit, e.g. 20m (agy only)
USAGE
}

# --- detect -----------------------------------------------------------------

cmd_detect() {
    local a st ok=() rest=()
    for a in $KNOWN_AGENTS; do
        st="$(agent_check "$a")"
        if [[ "$st" == ok ]]; then ok+=("$a:$st"); else rest+=("$a:$st"); fi
    done
    # Logged-in agents first, then the rest; alphabetical within each group.
    printf '%-8s  %-8s  %s\n' AGENT STATUS NOTE
    local row name
    for row in ${ok[@]+"${ok[@]}"} ${rest[@]+"${rest[@]}"}; do
        name="${row%%:*}"
        st="${row#*:}"
        case "$st" in
            ok)      printf '%-8s  %-8s  %s\n' "$name" ok "ready" ;;
            no-auth) printf '%-8s  %-8s  %s\n' "$name" no-auth "$(agent_login_hint "$name")" ;;
            missing) printf '%-8s  %-8s  %s\n' "$name" missing "not installed" ;;
        esac
    done
    printf '%-8s  %-8s  %s\n' custom - "any CLI via AGENT_CMD (prompt on stdin)"
}

# --- suggest ----------------------------------------------------------------

has_npm_script() {
    grep -qE "\"$1\"[[:space:]]*:" "$REPO_ROOT/package.json" 2>/dev/null
}

cmd_suggest() {
    local r="$REPO_ROOT" test="" setup="" why=""
    if [[ -f "$r/package.json" ]]; then
        local pm=npm
        if   [[ -f "$r/pnpm-lock.yaml" ]]; then pm=pnpm; setup="pnpm install --frozen-lockfile"
        elif [[ -f "$r/yarn.lock" ]];      then pm=yarn; setup="yarn install --frozen-lockfile"
        elif [[ -f "$r/bun.lockb" || -f "$r/bun.lock" ]]; then pm=bun; setup="bun install --frozen-lockfile"
        elif [[ -f "$r/package-lock.json" ]]; then setup="npm ci"
        else setup="npm install"
        fi
        has_npm_script test && test="$pm test"
        why="package.json ($pm)"
    elif [[ -f "$r/pyproject.toml" || -f "$r/pytest.ini" || -f "$r/setup.cfg" ]]; then
        if [[ -f "$r/uv.lock" ]]; then setup="uv sync"; test="uv run pytest -q"
        else test="pytest -q"
        fi
        why="python project"
    elif [[ -f "$r/go.mod" ]]; then
        test="go test ./..."; why="go.mod"
    elif [[ -f "$r/Cargo.toml" ]]; then
        test="cargo test"; why="Cargo.toml"
    fi
    if [[ -z "$test" && -f "$r/Makefile" ]] && grep -qE '^test:' "$r/Makefile"; then
        test="make test"; why="${why:+$why, }Makefile"
    fi

    echo "DETECTED:  ${why:-nothing recognisable}"
    echo "TEST_CMD:  ${test:-(none)}"
    echo "SETUP_CMD: ${setup:-(none)}"
    echo
    echo "Suggestions only — confirm with the user before saving. Worktrees start"
    echo "without installed dependencies (node_modules, .venv, build output), so a"
    echo "TEST_CMD usually needs a SETUP_CMD."
}

# --- show / set / unset -------------------------------------------------------

cmd_show() {
    if [[ ! -s "$CONFIG_FILE" ]]; then
        echo "(no config: $CONFIG_FILE)"
        return 3
    fi
    cat "$CONFIG_FILE"
}

cmd_set() {
    (( $# > 0 )) || die "set needs KEY=VALUE" 2
    local kv key value
    # Validate everything first, write afterwards: all or nothing.
    for kv in "$@"; do
        [[ "$kv" == *=* ]] || die "expected KEY=VALUE, got '$kv'" 2
        key="${kv%%=*}"
        value="${kv#*=}"
        config_key_valid "$key" || die "unknown key '$key' (keys: $CONFIG_KEYS)" 2
        [[ "$value" != *$'\n'* ]] || die "$key: value must be a single line" 2
        case "$key" in
            AGENT)
                [[ -z "$value" || "$value" == custom ]] || agent_known "$value" \
                    || die "AGENT must be one of: $KNOWN_AGENTS custom" 2 ;;
            MAX_WORKERS)
                [[ -z "$value" || "$value" =~ ^[1-9][0-9]*$ ]] || die "MAX_WORKERS must be a positive number" 2 ;;
        esac
    done
    for kv in "$@"; do
        config_set "${kv%%=*}" "${kv#*=}"
    done
    if [[ "$(config_get AGENT)" == custom && -z "$(config_get AGENT_CMD)" ]]; then
        echo "WARNING: AGENT=custom but AGENT_CMD is empty" >&2
    fi
    cmd_show
}

cmd_unset() {
    (( $# > 0 )) || die "unset needs KEY" 2
    local key
    for key in "$@"; do
        config_key_valid "$key" || die "unknown key '$key'" 2
        config_set "$key" ""
    done
    cmd_show
}

# --- main ---------------------------------------------------------------------

sub="${1:-}"
[[ -n "$sub" ]] || { usage >&2; exit 2; }
shift
case "$sub" in
    -h|--help) usage; exit 0 ;;
    detect)    cmd_detect ;;
    suggest|show|set|unset)
        conductor_init
        conductor_ensure_state
        "cmd_$sub" "$@" ;;
    *)         usage >&2; exit 2 ;;
esac
