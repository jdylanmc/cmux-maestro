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
#
# Any failure or forced termination before that point recovers from what is
# actually on disk -- which backups, destinations and staged artifacts exist
# right now -- combined with whether each original existed before the
# transaction opened. No decision depends on bookkeeping that could lag behind
# a rename which already happened. A backup is restored whenever it exists, an
# original that was never displaced is left untouched, and a destination is
# only removed when a replacement is known to have been placed there or there
# was no original to protect. Rollback success is only reported once the prior
# SDK and provenance record are verified back in place.

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

# none -> the transaction never opened; started -> the transaction is open and
# recovery must run; complete -> the replacement is fully published.
#
# This flag is only ever advanced to "started" BEFORE the first destructive
# step, so it can lag in the safe direction (recovery runs when nothing was
# actually displaced) but never in the unsafe one (recovery skipped after
# something was displaced). It decides only whether recovery runs; every choice
# recovery then makes is read from the filesystem.
PUBLISH_STATE=none

# Pre-transaction truth about the originals: recorded before anything is
# touched and never updated afterwards, so it cannot lag behind a rename.
ORIGINAL_SDK_EXISTED=0
ORIGINAL_SDK_DIGEST=
ORIGINAL_PROVENANCE_EXISTED=0
ORIGINAL_PROVENANCE_DIGEST=

# Set once this run has created the rollback directory. Until then, a rollback
# directory on disk belongs to an earlier run and must never be deleted.
PREVIOUS_DIR_OWNED=0

RECOVERY_FAILED=0
RESTORED_COUNT=0

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

file_digest() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

read_provenance_field() {
    local field="$1"
    [[ -f "$PROVENANCE" ]] || return 0
    sed -n "s/^$field=//p" "$PROVENANCE" | head -n 1
}

# Positive evidence that a replacement reached its destination: the publication
# rename consumes the staged artifact, so a staged path that is gone together
# with a destination that exists can only mean the rename ran. Consulted only
# while the transaction is open, after staging has completed.
replacement_was_placed() {
    local staged="$1" dest="$2"
    [[ ! -e "$staged" && -e "$dest" ]]
}

# Recover one artifact from live filesystem state.
#
# Renames inside vendor/ are atomic, so while the transaction is open an
# original that existed is at exactly one of two places: still at its
# destination because its displacement never ran or failed, or in the rollback
# directory because its displacement did run. Both cases are read directly.
recover_artifact() {
    local staged="$1" dest="$2" backup="$3" existed="$4"

    # Remove a destination only with positive justification: a replacement is
    # known to have been placed there, or there was no original to protect.
    # Anything else is an untouched original and must survive.
    if [[ -e "$dest" ]]; then
        if replacement_was_placed "$staged" "$dest" || (( existed == 0 )); then
            rm -rf -- "$dest" || RECOVERY_FAILED=1
        fi
    fi

    # Restore whenever the backup exists, however far the transaction got.
    if [[ -e "$backup" ]]; then
        if [[ -e "$dest" ]]; then
            # Never rename a backup into an occupied destination; that would
            # nest it instead of restoring it.
            RECOVERY_FAILED=1
            return
        fi
        if mv "$backup" "$dest"; then
            RESTORED_COUNT=$(( RESTORED_COUNT + 1 ))
        else
            RECOVERY_FAILED=1
        fi
    fi
}

# The prior state is intact only when every original that existed is back at
# its destination with its pre-transaction content, and every destination that
# had no original is absent again.
previous_state_is_intact() {
    if (( ORIGINAL_SDK_EXISTED )); then
        [[ -d "$SDK_DIR" ]] || return 1
        [[ "$(content_digest "$SDK_DIR")" == "$ORIGINAL_SDK_DIGEST" ]] || return 1
    elif [[ -e "$SDK_DIR" ]]; then
        return 1
    fi

    if (( ORIGINAL_PROVENANCE_EXISTED )); then
        [[ -f "$PROVENANCE" ]] || return 1
        [[ "$(file_digest "$PROVENANCE")" == "$ORIGINAL_PROVENANCE_DIGEST" ]] || return 1
    elif [[ -e "$PROVENANCE" ]]; then
        return 1
    fi

    return 0
}

restore_previous_sdk_on_failure() {
    local status=$?

    # Disarm everything first: a failing recovery command must not re-enter
    # this handler, and a second signal must not tear down a rollback that is
    # partway through restoring an original.
    trap - EXIT
    trap '' INT TERM HUP

    if [[ "$PUBLISH_STATE" == "started" ]]; then
        recover_artifact "$STAGED_SDK" "$SDK_DIR" "$PREVIOUS_SDK" "$ORIGINAL_SDK_EXISTED"
        recover_artifact "$STAGED_PROVENANCE" "$PROVENANCE" "$PREVIOUS_PROVENANCE" "$ORIGINAL_PROVENANCE_EXISTED"

        if (( RECOVERY_FAILED )) || ! previous_state_is_intact; then
            RECOVERY_FAILED=1
            echo "fetch-sdk: could not restore the previous CmuxExtensionKit state; whatever was set aside is kept in $PREVIOUS_DIR" >&2
        elif (( RESTORED_COUNT > 0 )); then
            echo "fetch-sdk: rolled back to the previous CmuxExtensionKit checkout and provenance record, byte for byte" >&2
        else
            echo "fetch-sdk: publication stopped with nothing displaced; the previous state is unchanged" >&2
        fi

        # An open transaction never ends successfully.
        (( status != 0 )) || status=1
    fi

    rm -rf -- "$STAGE_DIR"
    if (( PREVIOUS_DIR_OWNED && RECOVERY_FAILED == 0 )); then
        rm -rf -- "$PREVIOUS_DIR"
    fi

    exit "$status"
}

# An earlier run whose rollback could not finish leaves the displaced original
# in the rollback directory. Restore it before this run does anything else, so
# a backup is never discarded while the artifact it protects is missing.
adopt_previous_backup() {
    local backup="$1" dest="$2"

    [[ -e "$backup" ]] || return 0
    if [[ -e "$dest" ]]; then
        fail "both $backup and $dest exist, so an earlier rollback did not finish; inspect $PREVIOUS_DIR and remove it once the intended state is in place"
    fi
    mv "$backup" "$dest" \
        || fail "could not restore $dest from $backup left behind by an interrupted run"
    echo "fetch-sdk: restored $dest that an interrupted earlier run had set aside" >&2
}

trap restore_previous_sdk_on_failure EXIT
# A forced late termination must roll back too, so route signals through the
# normal exit path instead of letting bash tear the process down mid-publish.
trap 'exit 1' INT TERM HUP

[[ "$CMUX_REPO_URL" == https://* ]] || fail "SDK source must be fetched over HTTPS"
[[ "$CMUX_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "pinned commit must be a full 40-character SHA"
command -v git >/dev/null 2>&1 || fail "git is required to verify the pinned SDK commit"

adopt_previous_backup "$PREVIOUS_SDK" "$SDK_DIR"
adopt_previous_backup "$PREVIOUS_PROVENANCE" "$PROVENANCE"

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
PREVIOUS_DIR_OWNED=1

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

# Publish transaction.
#
# Record the pre-transaction truth about the originals first: whether each one
# exists and, when it does, its exact content. Both are captured before a
# single byte moves, so recovery can never mistake an untouched original for a
# displaced one, and rollback success can be proven rather than assumed.
if [[ -d "$SDK_DIR" ]]; then
    ORIGINAL_SDK_EXISTED=1
    ORIGINAL_SDK_DIGEST="$(content_digest "$SDK_DIR")"
    [[ -n "$ORIGINAL_SDK_DIGEST" ]] \
        || fail "could not digest the previous SDK checkout before replacing it"
fi
if [[ -f "$PROVENANCE" ]]; then
    ORIGINAL_PROVENANCE_EXISTED=1
    ORIGINAL_PROVENANCE_DIGEST="$(file_digest "$PROVENANCE")"
    [[ -n "$ORIGINAL_PROVENANCE_DIGEST" ]] \
        || fail "could not digest the previous provenance record before replacing it"
fi

# Everything from here until PUBLISH_STATE=complete is recoverable: on any
# failure or forced termination the trap reads the filesystem, discards the
# replacement, and restores whatever was displaced byte for byte.
PUBLISH_STATE=started

if (( ORIGINAL_PROVENANCE_EXISTED )); then
    mv "$PROVENANCE" "$PREVIOUS_PROVENANCE" \
        || fail "could not set the previous provenance record aside"
fi
if (( ORIGINAL_SDK_EXISTED )); then
    mv "$SDK_DIR" "$PREVIOUS_SDK" \
        || fail "could not set the previous SDK checkout aside"
fi

mv "$STAGED_SDK" "$SDK_DIR" || fail "could not publish the staged SDK"
mv "$STAGED_PROVENANCE" "$PROVENANCE" || fail "could not publish the staged provenance record"

PUBLISH_STATE=complete

echo "Fetched and verified CmuxExtensionKit at $CMUX_COMMIT"
echo "Content digest: $STAGED_DIGEST"
