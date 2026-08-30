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
# Replacement is published as an explicit transaction: the new SDK tree and its
# new provenance record are both fully staged before the previous ones are
# displaced, and the transaction is only marked complete once both are in place.
# Any failure before that flag is set rolls the previous SDK and the previous
# provenance record back byte for byte and discards the replacement.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX_REPO_URL="https://github.com/manaflow-ai/cmux.git"
CMUX_COMMIT="ae7fbce99f98c98df5ccf915e548dd080d33cfa8"
SDK_SUBPATH="Packages/macOS/CmuxExtensionKit"

VENDOR_DIR="$ROOT/vendor"
SDK_DIR="$VENDOR_DIR/CmuxExtensionKit"
PROVENANCE="$VENDOR_DIR/.cmux-sdk-provenance"

STAGE_DIR="$VENDOR_DIR/.cmux-sdk-stage"
STAGED_SDK="$STAGE_DIR/CmuxExtensionKit"
STAGED_PROVENANCE="$STAGE_DIR/provenance"

# Both backups live inside the single ignored rollback directory so a completed
# or rolled-back run leaves no residue anywhere else in vendor/.
PREVIOUS_DIR="$VENDOR_DIR/.cmux-sdk-previous"
PREVIOUS_SDK="$PREVIOUS_DIR/CmuxExtensionKit"
PREVIOUS_PROVENANCE="$PREVIOUS_DIR/provenance"

# none -> nothing displaced; started -> previous state displaced and not yet
# replaced; complete -> replacement fully published.
PUBLISH_STATE=none
PREVIOUS_SDK_SAVED=0
PREVIOUS_PROVENANCE_SAVED=0

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
    local rollback_failed=0

    # Disarm before doing any work so a failing rollback command cannot
    # re-enter this handler and skip the rest of it.
    trap - EXIT

    if [[ "$PUBLISH_STATE" == "started" ]]; then
        # The previous SDK and provenance were displaced but the replacement
        # was never completed. Discard whatever the replacement managed to put
        # in place, then restore the previous state exactly.
        rm -rf -- "$SDK_DIR" || rollback_failed=1
        rm -f -- "$PROVENANCE" || rollback_failed=1

        if (( PREVIOUS_SDK_SAVED )); then
            mv "$PREVIOUS_SDK" "$SDK_DIR" || rollback_failed=1
        fi
        if (( PREVIOUS_PROVENANCE_SAVED )); then
            mv "$PREVIOUS_PROVENANCE" "$PROVENANCE" || rollback_failed=1
        fi

        if (( rollback_failed )); then
            echo "fetch-sdk: could not roll back; the previous SDK and provenance are kept in $PREVIOUS_DIR" >&2
        else
            echo "fetch-sdk: rolled back to the previous CmuxExtensionKit checkout and provenance" >&2
        fi
    fi

    rm -rf -- "$STAGE_DIR"
    if (( rollback_failed == 0 )); then
        rm -rf -- "$PREVIOUS_DIR"
    fi

    exit "$status"
}

trap restore_previous_sdk_on_failure EXIT
# A forced late termination must roll back too, so route signals through the
# normal exit path instead of letting bash tear the process down mid-publish.
trap 'exit 1' INT TERM HUP

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
mkdir -p "$STAGE_DIR" "$PREVIOUS_DIR"

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

[[ -d "$CLONE_DIR/$SDK_SUBPATH" ]] \
    || fail "$SDK_SUBPATH is missing from $CMUX_COMMIT"
mv "$CLONE_DIR/$SDK_SUBPATH" "$STAGED_SDK"

[[ -f "$STAGED_SDK/Package.swift" ]] \
    || fail "staged SDK is missing Package.swift"
[[ -d "$STAGED_SDK/Sources/CmuxExtensionKit" ]] \
    || fail "staged SDK is missing Sources/CmuxExtensionKit"

STAGED_DIGEST="$(content_digest "$STAGED_SDK")"
[[ -n "$STAGED_DIGEST" ]] || fail "could not compute a digest for the staged SDK"

# Stage the new provenance record before anything is displaced, so publishing
# it is a rename of a complete file rather than a truncating write over the
# previous record.
printf 'commit=%s\ndigest=%s\nsource=%s\nsubpath=%s\n' \
    "$CMUX_COMMIT" "$STAGED_DIGEST" "$CMUX_REPO_URL" "$SDK_SUBPATH" \
    > "$STAGED_PROVENANCE" \
    || fail "could not stage the provenance record"
[[ -s "$STAGED_PROVENANCE" ]] || fail "the staged provenance record is empty"

# Publish transaction. Everything between here and PUBLISH_STATE=complete is
# recoverable: on any failure the trap discards the replacement and restores
# both the previous SDK and the previous provenance record byte for byte.
PUBLISH_STATE=started

if [[ -f "$PROVENANCE" ]]; then
    mv "$PROVENANCE" "$PREVIOUS_PROVENANCE" \
        || fail "could not set the previous provenance record aside"
    PREVIOUS_PROVENANCE_SAVED=1
fi
if [[ -d "$SDK_DIR" ]]; then
    mv "$SDK_DIR" "$PREVIOUS_SDK" \
        || fail "could not set the previous SDK checkout aside"
    PREVIOUS_SDK_SAVED=1
fi

mv "$STAGED_SDK" "$SDK_DIR" || fail "could not publish the staged SDK"
mv "$STAGED_PROVENANCE" "$PROVENANCE" || fail "could not publish the staged provenance record"

PUBLISH_STATE=complete

echo "Fetched and verified CmuxExtensionKit at $CMUX_COMMIT"
echo "Content digest: $STAGED_DIGEST"
