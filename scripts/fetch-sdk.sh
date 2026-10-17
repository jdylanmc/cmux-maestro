#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX_COMMIT="ae7fbce99f98c98df5ccf915e548dd080d33cfa8"
SDK_DIR="$ROOT/vendor/CmuxExtensionKit"
STAMP="$SDK_DIR/.cmux-commit"
# Reviewed Maestro patches, applied in name order to the pinned SDK before install.
PATCH_DIR="$ROOT/scripts/sdk-patches"
INSTALL_LOCK="$ROOT/vendor/.cmux-sdk-install.lock"
TRANSACTION_PREFIX="$ROOT/vendor/.cmux-sdk-fetch.$$"
TRANSACTION_DIR="$TRANSACTION_PREFIX"
TRANSACTION_ATTEMPTS=100
INSTALL_LOCK_ATTEMPTS=200
INSTALL_LOCK_WAIT_SECONDS=0.05
INSTALL_LOCK_TIMEOUT_SECONDS=10
LOCK_ACQUIRED=0

PATCHES=("$PATCH_DIR"/*.patch)
if [[ ! -f "${PATCHES[0]}" ]]; then
    echo "No SDK patches found in $PATCH_DIR" >&2
    exit 1
fi
PATCH_DIGEST="$(cat "${PATCHES[@]}" | shasum -a 256 | cut -d' ' -f1)"
EXPECTED_STAMP="$(printf '%s\npatches %s' "$CMUX_COMMIT" "$PATCH_DIGEST")"

if [[ -f "$STAMP" ]] && [[ "$(<"$STAMP")" == "$EXPECTED_STAMP" ]]; then
    echo "CmuxExtensionKit already pinned at $CMUX_COMMIT (patches $PATCH_DIGEST)"
    exit 0
fi

mkdir -p "$ROOT/vendor"

transaction_suffix=0
transaction_created=0
while [[ "$transaction_suffix" -lt "$TRANSACTION_ATTEMPTS" ]]; do
    transaction_error=""
    if transaction_error="$(umask 077; mkdir "$TRANSACTION_DIR" 2>&1)"; then
        transaction_created=1
        break
    fi

    if [[ ! -e "$TRANSACTION_DIR" ]]; then
        echo "Unable to create SDK transaction directory $TRANSACTION_DIR: $transaction_error" >&2
        exit 1
    fi

    transaction_suffix=$((transaction_suffix + 1))
    TRANSACTION_DIR="$TRANSACTION_PREFIX.$transaction_suffix"
done

if [[ "$transaction_created" -ne 1 ]]; then
    echo "Unable to allocate a unique SDK transaction directory after $TRANSACTION_ATTEMPTS attempts" >&2
    exit 1
fi

FETCH_DIR="$TRANSACTION_DIR/extract"
ARCHIVE="$TRANSACTION_DIR/cmux-sdk.tar.gz"
LOCK_TOKEN="$TRANSACTION_DIR/install-lock-owner"
: > "$LOCK_TOKEN"

cleanup() {
    if [[ -e "$INSTALL_LOCK" ]] && [[ "$INSTALL_LOCK" -ef "$LOCK_TOKEN" ]]; then
        rm -f -- "$INSTALL_LOCK"
    fi
    rm -rf -- "$TRANSACTION_DIR"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FETCH_DIR"

curl -fsSL \
    "https://github.com/manaflow-ai/cmux/archive/$CMUX_COMMIT.tar.gz" \
    -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$FETCH_DIR" \
    --strip-components=3 \
    "cmux-$CMUX_COMMIT/Packages/macOS/CmuxExtensionKit"

for sdk_patch in "${PATCHES[@]}"; do
    # Exact context only: a drifted SDK must fail here, not apply with fuzz.
    patch -p1 -N -s -F 0 -d "$FETCH_DIR/CmuxExtensionKit" -i "$sdk_patch"
done
if find "$FETCH_DIR/CmuxExtensionKit" \( -name '*.rej' -o -name '*.orig' \) -print -quit | grep -q .; then
    echo "SDK patches left rejected or backup files; refusing to install" >&2
    exit 1
fi

lock_attempt=0
while [[ "$lock_attempt" -lt "$INSTALL_LOCK_ATTEMPTS" ]]; do
    if [[ -d "$INSTALL_LOCK" ]] || [[ -L "$INSTALL_LOCK" ]]; then
        lock_attempt=$((lock_attempt + 1))
        sleep "$INSTALL_LOCK_WAIT_SECONDS"
        continue
    fi

    lock_error=""
    if lock_error="$(ln "$LOCK_TOKEN" "$INSTALL_LOCK" 2>&1)"; then
        LOCK_ACQUIRED=1
        break
    fi

    if [[ ! -e "$INSTALL_LOCK" ]] && [[ ! -L "$INSTALL_LOCK" ]]; then
        lock_error=""
        if lock_error="$(ln "$LOCK_TOKEN" "$INSTALL_LOCK" 2>&1)"; then
            LOCK_ACQUIRED=1
            break
        fi
        if [[ ! -e "$INSTALL_LOCK" ]] && [[ ! -L "$INSTALL_LOCK" ]]; then
            echo "Unable to create SDK install lock $INSTALL_LOCK: $lock_error" >&2
            exit 1
        fi
    fi

    lock_attempt=$((lock_attempt + 1))
    sleep "$INSTALL_LOCK_WAIT_SECONDS"
done

if [[ "$LOCK_ACQUIRED" -ne 1 ]]; then
    echo "Timed out after $INSTALL_LOCK_TIMEOUT_SECONDS seconds waiting for SDK install lock: $INSTALL_LOCK" >&2
    echo "Another fetch may still be active. If no fetch-sdk.sh process is running, remove the stale lock path and retry." >&2
    exit 1
fi

if [[ -f "$STAMP" ]] && [[ "$(<"$STAMP")" == "$EXPECTED_STAMP" ]]; then
    echo "CmuxExtensionKit already pinned at $CMUX_COMMIT (patches $PATCH_DIGEST)"
    exit 0
fi

rm -rf -- "$SDK_DIR"
mv "$FETCH_DIR/CmuxExtensionKit" "$SDK_DIR"
printf '%s\n' "$EXPECTED_STAMP" > "$STAMP"

echo "Fetched CmuxExtensionKit at $CMUX_COMMIT (patches $PATCH_DIGEST)"
