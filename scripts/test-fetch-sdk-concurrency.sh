#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_PREFIX="$ROOT/.fetch-sdk-concurrency-test.$$"
TEST_ROOT="$TEST_PREFIX"
FIRST_PID=""
SECOND_PID=""

test_suffix=0
while ! mkdir "$TEST_ROOT" 2>/dev/null; do
    test_suffix=$((test_suffix + 1))
    TEST_ROOT="$TEST_PREFIX.$test_suffix"
done

cleanup_processes() {
    if [[ -n "$FIRST_PID" ]] && kill -0 "$FIRST_PID" 2>/dev/null; then
        kill "$FIRST_PID" 2>/dev/null || true
        wait "$FIRST_PID" 2>/dev/null || true
    fi
    if [[ -n "$SECOND_PID" ]] && kill -0 "$SECOND_PID" 2>/dev/null; then
        kill "$SECOND_PID" 2>/dev/null || true
        wait "$SECOND_PID" 2>/dev/null || true
    fi
    FIRST_PID=""
    SECOND_PID=""
}

cleanup() {
    cleanup_processes
    rm -rf -- "$TEST_ROOT"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

output=""
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done

[[ -n "$output" ]]
printf '%s\n' "$output" > "$CONTROL_DIR/$FETCH_TEST_ID-output"
printf '%s\n' "$FETCH_TEST_ID" > "$output"
EOF

cat > "$TEST_ROOT/bin/tar" <<'EOF'
#!/bin/bash
set -euo pipefail

archive=""
destination=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -xzf)
            archive="$2"
            shift 2
            ;;
        -C)
            destination="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

payload="$(<"$archive")"
printf '%s\n' "$destination" > "$CONTROL_DIR/$FETCH_TEST_ID-destination"
mkdir -p "$destination/CmuxExtensionKit"
printf '%s\n' "$payload" > "$destination/CmuxExtensionKit/payload"
EOF

cat > "$TEST_ROOT/bin/mkdir" <<'EOF'
#!/bin/bash
set -euo pipefail

destination="${!#}"
case "$destination" in
    */.cmux-sdk-fetch*)
        if [[ "$FETCH_TEST_MODE" == "transaction-failure" ]]; then
            echo "simulated transaction allocation failure" >&2
            exit 73
        fi
        ;;
esac

exec /bin/mkdir "$@"
EOF

cat > "$TEST_ROOT/bin/ln" <<'EOF'
#!/bin/bash
set -euo pipefail

destination="${!#}"
if [[ "$destination" != */.cmux-sdk-install.lock ]]; then
    exec /bin/ln "$@"
fi

touch "$CONTROL_DIR/$FETCH_TEST_ID-lock-attempt"
if [[ "$FETCH_TEST_MODE" == "lock-disabled" ]]; then
    touch "$CONTROL_DIR/$FETCH_TEST_ID-lock-acquired"
    exit 0
fi

if /bin/ln "$@"; then
    touch "$CONTROL_DIR/$FETCH_TEST_ID-lock-created"
    if [[ "$FETCH_TEST_MODE" == "signal-interruption" ]]; then
        target_pid="$(<"$FETCH_TEST_PID_FILE")"
        kill -TERM "$target_pid"
    else
        touch "$CONTROL_DIR/$FETCH_TEST_ID-lock-acquired"
    fi
    exit 0
else
    status=$?
    if [[ "$FETCH_TEST_MODE" == "release-race" ]] &&
        [[ "$FETCH_TEST_ID" == "second" ]]; then
        touch "$CONTROL_DIR/$FETCH_TEST_ID-lock-failed"
        while [[ ! -f "$CONTROL_DIR/$FETCH_TEST_ID-lock-return" ]]; do
            /bin/sleep 0.05
        done
        exit "$status"
    fi
    if [[ -e "$destination" ]] || [[ -L "$destination" ]]; then
        touch "$CONTROL_DIR/$FETCH_TEST_ID-lock-contended"
    fi
    exit "$status"
fi
EOF

cat > "$TEST_ROOT/bin/mv" <<'EOF'
#!/bin/bash
set -euo pipefail

destination="${!#}"
if [[ "$destination" == */vendor/CmuxExtensionKit ]]; then
    touch "$CONTROL_DIR/$FETCH_TEST_ID-install-entered"
    while [[ ! -f "$CONTROL_DIR/$FETCH_TEST_ID-install-release" ]]; do
        /bin/sleep 0.05
    done
fi

exec /bin/mv "$@"
EOF

cat > "$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "$FETCH_TEST_MODE" != "stale-lock" ]]; then
    exec /bin/sleep "$@"
fi

count_file="$CONTROL_DIR/$FETCH_TEST_ID-sleep-count"
count=0
if [[ -f "$count_file" ]]; then
    count="$(<"$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ "$count" -gt 250 ]]; then
    echo "Stale-lock wait exceeded test guard" >&2
    exit 74
fi
EOF

chmod +x "$TEST_ROOT/bin/"*

wait_for_file() {
    local path="$1"
    local attempt

    for ((attempt = 0; attempt < 200; attempt++)); do
        if [[ -f "$path" ]]; then
            return 0
        fi
        /bin/sleep 0.05
    done

    echo "Timed out waiting for $path" >&2
    return 1
}

setup_case() {
    local case_root="$1"

    mkdir -p "$case_root/scripts" "$case_root/control"
    cp "$ROOT/scripts/fetch-sdk.sh" "$case_root/scripts/fetch-sdk.sh"
    chmod +x "$case_root/scripts/fetch-sdk.sh"
}

run_fetch() {
    local case_root="$1"
    local id="$2"
    local mode="$3"

    CONTROL_DIR="$case_root/control" \
        FETCH_TEST_ID="$id" \
        FETCH_TEST_MODE="$mode" \
        FETCH_TEST_PID_FILE="$case_root/control/$id-pid" \
        FETCH_TEST_SCRIPT="$case_root/scripts/fetch-sdk.sh" \
        PATH="$TEST_ROOT/bin:$PATH" \
        /bin/bash -c 'printf "%s\n" "$$" > "$FETCH_TEST_PID_FILE"; exec "$FETCH_TEST_SCRIPT"'
}

verify_lock_exclusion() {
    local control_dir="$1"
    [[ ! -f "$control_dir/second-install-entered" ]]
}

run_contention_case() {
    local case_root="$1"
    local mode="$2"

    setup_case "$case_root"

    run_fetch "$case_root" first "$mode" > "$case_root/first.log" 2>&1 &
    FIRST_PID=$!
    wait_for_file "$case_root/control/first-lock-acquired"
    wait_for_file "$case_root/control/first-install-entered"

    run_fetch "$case_root" second "$mode" > "$case_root/second.log" 2>&1 &
    SECOND_PID=$!
    wait_for_file "$case_root/control/second-lock-attempt"

    if [[ "$mode" == "lock-disabled" ]]; then
        wait_for_file "$case_root/control/second-install-entered"
        if verify_lock_exclusion "$case_root/control"; then
            echo "Lock-disabled negative control unexpectedly preserved exclusion" >&2
            return 1
        fi
        touch "$case_root/control/first-install-release"
        touch "$case_root/control/second-install-release"
        wait "$FIRST_PID" 2>/dev/null || true
        wait "$SECOND_PID" 2>/dev/null || true
        FIRST_PID=""
        SECOND_PID=""
        return 0
    fi

    wait_for_file "$case_root/control/second-lock-contended"
    /bin/sleep 0.15
    if [[ -f "$case_root/control/second-lock-acquired" ]] ||
        ! verify_lock_exclusion "$case_root/control" ||
        ! kill -0 "$SECOND_PID" 2>/dev/null; then
        echo "Second fetch was not blocked by the held install lock" >&2
        cat "$case_root/second.log" >&2
        return 1
    fi

    touch "$case_root/control/first-install-release"
    if ! wait "$FIRST_PID"; then
        cat "$case_root/first.log" >&2
        return 1
    fi
    FIRST_PID=""

    if ! wait "$SECOND_PID"; then
        cat "$case_root/second.log" >&2
        return 1
    fi
    SECOND_PID=""

    [[ -f "$case_root/control/second-lock-acquired" ]]

    first_output="$(<"$case_root/control/first-output")"
    second_output="$(<"$case_root/control/second-output")"
    [[ "$first_output" != "$second_output" ]]

    first_destination="$(<"$case_root/control/first-destination")"
    second_destination="$(<"$case_root/control/second-destination")"
    [[ "$first_destination" != "$second_destination" ]]

    EXPECTED_COMMIT="ae7fbce99f98c98df5ccf915e548dd080d33cfa8"
    [[ "$(<"$case_root/vendor/CmuxExtensionKit/.cmux-commit")" == "$EXPECTED_COMMIT" ]]
    [[ "$(<"$case_root/vendor/CmuxExtensionKit/payload")" == "first" ]]

    if find "$case_root/vendor" -maxdepth 1 \
        \( -name '.cmux-sdk-fetch.*' -o -name '.cmux-sdk-install.lock' \) \
        -print -quit | grep -q .; then
        echo "Fetch transaction state was not cleaned up" >&2
        return 1
    fi
}

NORMAL_ROOT="$TEST_ROOT/normal"
run_contention_case "$NORMAL_ROOT" "normal"
echo "PASS: real install-lock contention blocked the second fetch"

NEGATIVE_ROOT="$TEST_ROOT/lock-disabled"
run_contention_case "$NEGATIVE_ROOT" "lock-disabled"
echo "PASS: lock-disabled negative control violated exclusion as expected"

STALE_ROOT="$TEST_ROOT/stale-lock"
setup_case "$STALE_ROOT"
mkdir -p "$STALE_ROOT/vendor/.cmux-sdk-install.lock"
if run_fetch "$STALE_ROOT" stale "stale-lock" > "$STALE_ROOT/stale.log" 2>&1; then
    echo "Stale install lock did not fail closed" >&2
    exit 1
fi
grep -q "Timed out after 10 seconds waiting for SDK install lock" "$STALE_ROOT/stale.log"
grep -q "If no fetch-sdk.sh process is running, remove the stale lock path and retry" "$STALE_ROOT/stale.log"
echo "PASS: stale install lock failed closed with recovery guidance"

RELEASE_RACE_ROOT="$TEST_ROOT/release-race"
setup_case "$RELEASE_RACE_ROOT"
run_fetch "$RELEASE_RACE_ROOT" first "release-race" > "$RELEASE_RACE_ROOT/first.log" 2>&1 &
FIRST_PID=$!
wait_for_file "$RELEASE_RACE_ROOT/control/first-lock-acquired"
wait_for_file "$RELEASE_RACE_ROOT/control/first-install-entered"

run_fetch "$RELEASE_RACE_ROOT" second "release-race" > "$RELEASE_RACE_ROOT/second.log" 2>&1 &
SECOND_PID=$!
wait_for_file "$RELEASE_RACE_ROOT/control/second-lock-failed"

touch "$RELEASE_RACE_ROOT/control/first-install-release"
if ! wait "$FIRST_PID"; then
    cat "$RELEASE_RACE_ROOT/first.log" >&2
    exit 1
fi
FIRST_PID=""
[[ ! -e "$RELEASE_RACE_ROOT/vendor/.cmux-sdk-install.lock" ]]

touch "$RELEASE_RACE_ROOT/control/second-lock-return"
if ! wait "$SECOND_PID"; then
    cat "$RELEASE_RACE_ROOT/second.log" >&2
    exit 1
fi
SECOND_PID=""

[[ -f "$RELEASE_RACE_ROOT/control/second-lock-acquired" ]]
[[ ! -e "$RELEASE_RACE_ROOT/vendor/.cmux-sdk-install.lock" ]]
if find "$RELEASE_RACE_ROOT/vendor" -maxdepth 1 -name '.cmux-sdk-fetch.*' \
    -print -quit | grep -q .; then
    echo "Release-race fetch left transaction state behind" >&2
    exit 1
fi
echo "PASS: contender retried after owner released before failure inspection"

SIGNAL_ROOT="$TEST_ROOT/signal-interruption"
setup_case "$SIGNAL_ROOT"
set +e
run_fetch "$SIGNAL_ROOT" interrupted "signal-interruption" > "$SIGNAL_ROOT/signal.log" 2>&1
signal_status=$?
set -e
if [[ "$signal_status" -ne 143 ]]; then
    cat "$SIGNAL_ROOT/signal.log" >&2
    echo "Signal-interrupted fetch exited $signal_status instead of 143" >&2
    exit 1
fi
[[ -f "$SIGNAL_ROOT/control/interrupted-lock-created" ]]
if [[ -e "$SIGNAL_ROOT/vendor/.cmux-sdk-install.lock" ]] ||
    find "$SIGNAL_ROOT/vendor" -maxdepth 1 -name '.cmux-sdk-fetch.*' -print -quit | grep -q .; then
    echo "Signal-interrupted fetch left lock or transaction state behind" >&2
    exit 1
fi
echo "PASS: TERM immediately after lock creation cleaned owned state"

FAILURE_ROOT="$TEST_ROOT/transaction-failure"
setup_case "$FAILURE_ROOT"
if run_fetch "$FAILURE_ROOT" allocation "transaction-failure" > "$FAILURE_ROOT/failure.log" 2>&1; then
    echo "Unrecoverable transaction creation failure did not exit" >&2
    exit 1
fi
grep -q "Unable to create SDK transaction directory" "$FAILURE_ROOT/failure.log"
grep -q "simulated transaction allocation failure" "$FAILURE_ROOT/failure.log"
echo "PASS: transaction creation failure exited without retrying"
