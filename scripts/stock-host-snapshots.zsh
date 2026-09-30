#!/bin/zsh
# Runner-only initial terminal command. Four fixed reads, never arbitrary commands.
set -eu
umask 077
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted &&
   "$HOME" == /Users/runner && $# == 2 ]] || exit 2
work="$1"
evidence="$2"
[[ "$work" == "$RUNNER_TEMP/stock-host-update" &&
   "$evidence" == "$RUNNER_TEMP/stock-host-update-evidence" &&
   -d "$work" && -d "$evidence" ]] || exit 2
cli="/Applications/cmux.app/Contents/Resources/bin/cmux"
[[ -x "$cli" && -n "${CMUX_WORKSPACE_ID:-}" && -n "${CMUX_SURFACE_ID:-}" ]] || exit 2
# An unexpected replacement must not overwrite the original worker or snapshot evidence.
/bin/mkdir "$work/snapshot-worker-owner" || exit 2
terminal=$(/usr/bin/tty)
[[ "$terminal" == /dev/tty* ]] || exit 2
printf '{"pid":%d,"workspace":"%s","surface":"%s","tty":"%s"}\n' \
    "$$" "$CMUX_WORKSPACE_ID" "$CMUX_SURFACE_ID" "$terminal" > "$evidence/snapshot-worker.json.next"
/bin/mv "$evidence/snapshot-worker.json.next" "$evidence/snapshot-worker.json"
print -r -- "$$" > "$evidence/snapshot-worker.pid"
trap 'print -r -- "$?" > "$evidence/snapshot-worker.exit"' EXIT

park_until_host_quits() {
    print -r -- "$$" > "$evidence/snapshot-worker.parked"
    while [[ ! -e "$evidence/snapshot-exit" ]]; do
        (( SECONDS < 2100 )) || exit 2
        /bin/sleep 0.1
    done
    exit 0
}

wait_for() {
    while [[ ! -e "$1" ]]; do
        [[ ! -e "$evidence/snapshot-stop" ]] || park_until_host_quits
        if (( SECONDS >= 2100 )); then
            print -u2 -- "Snapshot observation exceeded its 2100-second bound"
            exit 2
        fi
        /bin/sleep 0.1
    done
    [[ ! -e "$evidence/snapshot-stop" ]] || park_until_host_quits
}

for phase in baseline repeat update compensation; do
    wait_for "$evidence/snapshot-request-$phase"
    if CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=10 "$cli" --id-format both --json tree --all \
        > "$evidence/snapshot-$phase.json" 2> "$evidence/snapshot-$phase.stderr"; then
        code=0
    else
        code=$?
    fi
    print -r -- "$code" > "$evidence/snapshot-$phase.status.next"
    /bin/mv "$evidence/snapshot-$phase.status.next" "$evidence/snapshot-$phase.status"
    (( code == 0 )) || exit "$code"
done
# Do not exit early and cause stock to create a replacement terminal during cleanup.
wait_for "$evidence/snapshot-stop"
