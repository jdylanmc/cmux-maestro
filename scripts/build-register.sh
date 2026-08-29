#!/bin/bash
set -euo pipefail

# Builds the preview ad hoc and registers the embedded sidebar extension.
#
# Every identifier and path used for verification is derived from the build
# itself, never restated by hand, so a stale entry left in the pluginkit
# registry by an earlier build cannot satisfy the check.
#
# The script registers the extension. It never enables it or selects it as
# CMUX's active sidebar provider, and it introduces no distribution signing.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DERIVED_DATA="$ROOT/.build/adhoc"
APP_TARGET="CMUXMaestroPreview"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

fail() {
    echo "build-register: $*" >&2
    exit 1
}

canonical_path() {
    local target="$1"
    local dir base
    dir="$(cd "$(dirname "$target")" && pwd -P)" || return 1
    base="$(basename "$target")"
    printf '%s/%s\n' "${dir%/}" "$base"
}

"$ROOT/scripts/fetch-sdk.sh"

xcodebuild \
    -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
    -scheme CMUXMaestroPreview \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    build

BUILD_SETTINGS="$(
    xcodebuild \
        -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
        -scheme CMUXMaestroPreview \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        -showBuildSettings
)"

build_setting() {
    printf '%s\n' "$BUILD_SETTINGS" | awk -v key="$1" -v target="$APP_TARGET" '
        /^Build settings for/ {
            active = ($0 ~ ("target " target ":$"))
            next
        }
        active && $1 == key && $2 == "=" {
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]=[[:space:]]?/, "")
            print
            exit
        }
    '
}

BUILT_PRODUCTS_DIR="$(build_setting BUILT_PRODUCTS_DIR)"
EXTENSIONS_FOLDER_PATH="$(build_setting EXTENSIONS_FOLDER_PATH)"
[[ -n "$BUILT_PRODUCTS_DIR" ]] || fail "could not read BUILT_PRODUCTS_DIR from the build"
[[ -n "$EXTENSIONS_FOLDER_PATH" ]] || fail "could not read EXTENSIONS_FOLDER_PATH from the build"

EXTENSIONS_DIR="$BUILT_PRODUCTS_DIR/$EXTENSIONS_FOLDER_PATH"
[[ -d "$EXTENSIONS_DIR" ]] || fail "the build produced no extensions directory at $EXTENSIONS_DIR"

BUILT_APPEXES=()
while IFS= read -r candidate; do
    BUILT_APPEXES+=("$candidate")
done < <(find "$EXTENSIONS_DIR" -maxdepth 1 -type d -name '*.appex' | LC_ALL=C sort)

(( ${#BUILT_APPEXES[@]} == 1 )) \
    || fail "expected exactly one built .appex in $EXTENSIONS_DIR, found ${#BUILT_APPEXES[@]}"

APPEX="$(canonical_path "${BUILT_APPEXES[0]}")" \
    || fail "could not resolve the built extension path"

APPEX_INFO_PLIST="$APPEX/Contents/Info.plist"
[[ -f "$APPEX_INFO_PLIST" ]] || fail "the built extension has no Info.plist at $APPEX_INFO_PLIST"

EXTENSION_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX_INFO_PLIST" 2>/dev/null
)" || fail "could not read CFBundleIdentifier from $APPEX_INFO_PLIST"
[[ -n "$EXTENSION_ID" ]] || fail "the built extension declares an empty CFBundleIdentifier"

echo "Built extension: $APPEX"
echo "Bundle identifier: $EXTENSION_ID"

registered_paths() {
    pluginkit -mAvvv -i "$EXTENSION_ID" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Path = //p'
}

# Drop this repository's own superseded registrations so verification cannot
# pass on a stale identity. Registrations owned by anything outside this
# repository are reported, never silently rewritten.
while IFS= read -r stale; do
    [[ -n "$stale" ]] || continue
    [[ "$stale" != "$APPEX" ]] || continue

    if [[ "$stale" == "$ROOT/"* ]]; then
        echo "Removing superseded registration: $stale"
        pluginkit -r "$stale" >/dev/null 2>&1 || true
    else
        fail "$EXTENSION_ID is already registered outside this checkout at $stale; remove it with 'pluginkit -r' and rerun"
    fi
done < <(registered_paths)

pluginkit -a "$APPEX"

DISCOVERED=()
while IFS= read -r discovered; do
    [[ -n "$discovered" ]] || continue
    DISCOVERED+=("$discovered")
done < <(registered_paths)

(( ${#DISCOVERED[@]} != 0 )) \
    || fail "pluginkit did not discover $EXTENSION_ID after registration"
(( ${#DISCOVERED[@]} == 1 )) \
    || fail "pluginkit discovered ${#DISCOVERED[@]} registrations for $EXTENSION_ID: ${DISCOVERED[*]}"
[[ "${DISCOVERED[0]}" == "$APPEX" ]] \
    || fail "pluginkit resolved $EXTENSION_ID to ${DISCOVERED[0]} instead of the freshly built $APPEX"

echo "pluginkit resolved $EXTENSION_ID to the freshly built extension."
echo "The extension is registered but not enabled or selected in CMUX."
