#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/unsigned"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

"$ROOT/scripts/fetch-sdk.sh"
mkdir -p "$DERIVED_DATA"
SETTINGS=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CMUX_BUNDLE_ID_SUFFIX=.Validation.Unsigned
    "CMUX_DISPLAY_NAME_SUFFIX= (Unsigned Validation)"
    CMUX_SIDEBAR_EXTENSION_POINT_ID=com.jdylanmc.CMUXMaestroPreview.validation.unsigned.sidebar
)

xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -alltargets \
    -configuration Debug -showBuildSettings -json "${SETTINGS[@]}" \
    > "$DERIVED_DATA/namespace-settings.json"
python3 "$ROOT/scripts/verify-build-metadata.py" --mode unsigned \
    --settings "$DERIVED_DATA/namespace-settings.json"

xcodebuild \
    -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
    -scheme CMUXMaestroPreview \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    "${SETTINGS[@]}" \
    build

python3 "$ROOT/scripts/verify-build-metadata.py" --mode unsigned \
    --app "$DERIVED_DATA/Build/Products/Debug/CMUX Maestro Preview.app"
