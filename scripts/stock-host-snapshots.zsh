#!/bin/zsh
# Runner-only initial terminal command. Three fixed reads, never arbitrary commands.
set -eu
umask 077
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted &&
   "$HOME" == /Users/runner && $# == 2 ]] || exit 2
work="$1"
evidence="$2"
[[ "$work" == "$RUNNER_TEMP/stock-host-update" &&
   "$evidence" == "$RUNNER_TEMP/stock-host-update-evidence" &&
   -d "$work" && -d "$evidence" ]] || exit 2
cli="$work/cmux.app/Contents/Resources/bin/cmux"
[[ -x "$cli" && -n "${CMUX_WORKSPACE_ID:-}" ]] || exit 2
print -r -- "$$" > "$evidence/snapshot-worker.pid"
trap 'print -r -- "$?" > "$evidence/snapshot-worker.exit"' EXIT

wait_for() {
    while [[ ! -e "$1" ]]; do
        [[ ! -e "$evidence/snapshot-stop" ]] || exit 0
        if (( SECONDS >= 2100 )); then
            print -u2 -- "Snapshot observation exceeded its 2100-second bound"
            exit 2
        fi
        /bin/sleep 0.1
    done
}

for phase in baseline update rollback; do
    wait_for "$evidence/snapshot-request-$phase"
    if CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=10 "$cli" --json tree --all \
        > "$evidence/snapshot-$phase.json" 2> "$evidence/snapshot-$phase.stderr"; then
        code=0
    else
        code=$?
    fi
    print -r -- "$code" > "$evidence/snapshot-$phase.status.next"
    /bin/mv "$evidence/snapshot-$phase.status.next" "$evidence/snapshot-$phase.status"
    (( code == 0 )) || exit "$code"
done
# Keep the same terminal shell alive until acceptance has ended.
wait_for "$evidence/snapshot-stop"
