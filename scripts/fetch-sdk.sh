#!/bin/bash
set -euo pipefail

# Acquires the pinned CmuxExtensionKit SDK.
#
# Acquisition is verified by Git object identity: the exact pinned commit is
# fetched over HTTPS and Git's content addressing guarantees the fetched tree
# hashes back to that commit. A deterministic digest of the extracted SDK tree
# is then recorded outside the SDK directory so a cached tree is re-verified
# before it is trusted.
#
# Replacement is staged: the previous usable SDK and its provenance record
# survive any failed fetch, extraction, or verification.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX_REPO_URL="https://github.com/manaflow-ai/cmux.git"
CMUX_COMMIT="ae7fbce99f98c98df5ccf915e548dd080d33cfa8"
SDK_SUBPATH="Packages/macOS/CmuxExtensionKit"

VENDOR_DIR="$ROOT/vendor"
SDK_DIR="$VENDOR_DIR/CmuxExtensionKit"
PROVENANCE="$VENDOR_DIR/.cmux-sdk-provenance"
STAGE_DIR="$VENDOR_DIR/.cmux-sdk-stage"
PREVIOUS_DIR="$VENDOR_DIR/.cmux-sdk-previous"

fail() {
    echo "fetch-sdk: $*" >&2
    exit 1
}

# Deterministic digest of the SDK tree.
#
# Locally generated, non-upstream paths are excluded so a plain build does not
# invalidate the record: Git metadata, SwiftPM/Xcode scratch directories, and
# Finder droppings.
content_digest() {
    local dir="$1"
    (
        cd "$dir" || exit 1
        find . \
            \( -name .git -o -name .build -o -name .swiftpm \) -prune -o \
            -type f ! -name .DS_Store -print0 \
            | LC_ALL=C sort -z \
            | while IFS= read -r -d '' file; do
                printf '%s  %s\n' "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" "$file"
            done
    ) | shasum -a 256 | cut -d ' ' -f 1
}

read_provenance_field() {
    local field="$1"
    [[ -f "$PROVENANCE" ]] || return 0
    sed -n "s/^$field=//p" "$PROVENANCE" | head -n 1
}

restore_previous_sdk_on_failure() {
    local status=$?

    if (( status != 0 )); then
        if [[ ! -d "$SDK_DIR" && -d "$PREVIOUS_DIR" ]]; then
            mv "$PREVIOUS_DIR" "$SDK_DIR"
            echo "fetch-sdk: restored the previous CmuxExtensionKit checkout" >&2
        fi
    fi

    rm -rf -- "$STAGE_DIR"
    if [[ -d "$PREVIOUS_DIR" ]]; then
        rm -rf -- "$PREVIOUS_DIR"
    fi

    exit "$status"
}

trap restore_previous_sdk_on_failure EXIT

[[ "$CMUX_REPO_URL" == https://* ]] || fail "SDK source must be fetched over HTTPS"
[[ "$CMUX_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "pinned commit must be a full 40-character SHA"
command -v git >/dev/null 2>&1 || fail "git is required to verify the pinned SDK commit"

# Trust the cached SDK only when its recorded commit matches the pin and the
# tree still hashes to the recorded digest.
if [[ -d "$SDK_DIR" && -f "$PROVENANCE" ]]; then
    recorded_commit="$(read_provenance_field commit)"
    recorded_digest="$(read_provenance_field digest)"

    if [[ "$recorded_commit" == "$CMUX_COMMIT" && -n "$recorded_digest" ]]; then
        if [[ "$(content_digest "$SDK_DIR")" == "$recorded_digest" ]]; then
            echo "CmuxExtensionKit verified at $CMUX_COMMIT"
            exit 0
        fi
        echo "fetch-sdk: cached CmuxExtensionKit failed digest verification; reacquiring" >&2
    fi
fi

mkdir -p "$VENDOR_DIR"
rm -rf -- "$STAGE_DIR" "$PREVIOUS_DIR"
mkdir -p "$STAGE_DIR"

CLONE_DIR="$STAGE_DIR/cmux"
git init -q "$CLONE_DIR"
git -C "$CLONE_DIR" remote add origin "$CMUX_REPO_URL"
git -C "$CLONE_DIR" config core.sparseCheckout true
printf '/%s/*\n' "$SDK_SUBPATH" > "$CLONE_DIR/.git/info/sparse-checkout"

# GIT_ALLOW_PROTOCOL keeps the transport on HTTPS, including across redirects.
GIT_ALLOW_PROTOCOL=https \
    git -C "$CLONE_DIR" -c http.sslVerify=true \
    fetch --depth 1 --filter=blob:none origin "$CMUX_COMMIT" \
    || fail "could not fetch pinned commit $CMUX_COMMIT from $CMUX_REPO_URL"

FETCHED_COMMIT="$(git -C "$CLONE_DIR" rev-parse FETCH_HEAD^{commit})"
[[ "$FETCHED_COMMIT" == "$CMUX_COMMIT" ]] \
    || fail "fetched commit $FETCHED_COMMIT does not match the pin $CMUX_COMMIT"

GIT_ALLOW_PROTOCOL=https \
    git -C "$CLONE_DIR" checkout -q --detach "$CMUX_COMMIT" \
    || fail "could not check out $CMUX_COMMIT"

CHECKED_OUT_COMMIT="$(git -C "$CLONE_DIR" rev-parse HEAD)"
[[ "$CHECKED_OUT_COMMIT" == "$CMUX_COMMIT" ]] \
    || fail "checked out $CHECKED_OUT_COMMIT instead of $CMUX_COMMIT"

STAGED_SDK="$STAGE_DIR/CmuxExtensionKit"
[[ -d "$CLONE_DIR/$SDK_SUBPATH" ]] \
    || fail "$SDK_SUBPATH is missing from $CMUX_COMMIT"
mv "$CLONE_DIR/$SDK_SUBPATH" "$STAGED_SDK"

[[ -f "$STAGED_SDK/Package.swift" ]] \
    || fail "staged SDK is missing Package.swift"
[[ -d "$STAGED_SDK/Sources/CmuxExtensionKit" ]] \
    || fail "staged SDK is missing Sources/CmuxExtensionKit"

STAGED_DIGEST="$(content_digest "$STAGED_SDK")"
[[ -n "$STAGED_DIGEST" ]] || fail "could not compute a digest for the staged SDK"

# Only now is the previous checkout displaced, and it stays recoverable until
# the replacement is in place.
if [[ -d "$SDK_DIR" ]]; then
    mv "$SDK_DIR" "$PREVIOUS_DIR"
fi
mv "$STAGED_SDK" "$SDK_DIR"

printf 'commit=%s\ndigest=%s\nsource=%s\nsubpath=%s\n' \
    "$CMUX_COMMIT" "$STAGED_DIGEST" "$CMUX_REPO_URL" "$SDK_SUBPATH" \
    > "$PROVENANCE"

echo "Fetched and verified CmuxExtensionKit at $CMUX_COMMIT"
echo "Content digest: $STAGED_DIGEST"
