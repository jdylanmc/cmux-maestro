#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/tests"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

"$ROOT/scripts/fetch-sdk.sh"
mkdir -p "$DERIVED_DATA"
SETTINGS=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CMUX_BUNDLE_ID_SUFFIX=.Validation.Tests
    "CMUX_DISPLAY_NAME_SUFFIX= (Test Validation)"
    CMUX_SIDEBAR_EXTENSION_POINT_ID=com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar
)

xcodebuild -project "$ROOT/CMUXMaestroPreview.xcodeproj" -alltargets \
    -configuration Debug -showBuildSettings -json "${SETTINGS[@]}" \
    > "$DERIVED_DATA/namespace-settings.json"
python3 "$ROOT/scripts/verify-build-metadata.py" --mode tests \
    --settings "$DERIVED_DATA/namespace-settings.json"

xcodebuild \
    -project "$ROOT/CMUXMaestroPreview.xcodeproj" \
    -scheme CMUXMaestroPreview \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    "${SETTINGS[@]}" \
    test

python3 "$ROOT/scripts/verify-build-metadata.py" --mode tests \
    --app "$DERIVED_DATA/Build/Products/Debug/CMUX Maestro Preview.app"
